import Foundation
import FBControlCore
import FBSimulatorControl

/// The everyday view of a simulator's screens and hinge. The full measurements, receipts and boot
/// identity stay behind `--verbose`.
enum HingePosture: String, Encodable, Sendable {
    case closed, partiallyOpen, open

    /// Uses the sensed angle and `hinge set`'s default 0.5 degree tolerance.
    init(degrees: Double) {
        if degrees <= 0.5 { self = .closed }
        else if degrees >= 179.5 { self = .open }
        else { self = .partiallyOpen }
    }

    var text: String {
        switch self {
        case .closed: return "closed"
        case .partiallyOpen: return "partially open"
        case .open: return "open"
        }
    }
}

/// `degrees` is the angle iOS senses, which is the true pose. `mechanicalDegrees` is the angle
/// `hinge set` drives and compares against; at rest the two can differ by a degree or two.
struct HingeStateOutput: Encodable, Sendable {
    let degrees: Double
    let mechanicalDegrees: Double
    let posture: HingePosture

    init(sensed: Double, mechanical: Double) {
        degrees = DeviceStateText.rounded(sensed)
        mechanicalDegrees = DeviceStateText.rounded(mechanical)
        posture = HingePosture(degrees: degrees)
    }

    init(_ sample: FBSimulatorHingeSample) {
        self.init(sensed: sample.sensedDegrees, mechanical: sample.mechanicalDegrees)
    }

    init(_ observation: FBSimulatorHingeObservation) {
        self.init(sensed: observation.sensedDegrees, mechanical: observation.mechanicalDegrees)
    }

    var text: String { "\(DeviceStateText.degrees(degrees)), \(posture.text)" }
}

struct ScreenStateOutput: Encodable, Sendable {
    enum State: String, Encodable, Sendable { case on, locked, off, starting, unknown }

    let id: UInt32
    let uuid: String
    /// `outer` or `inner` on a two-screen device, `main` on a one-screen device.
    let role: String
    /// Oriented logical points for the active screen, the same values as the agent capture's
    /// `capture.screen`. Unrotated points for an inactive screen.
    let width: Double
    let height: Double
    let scale: Int
    let rotation: Int?
    let orientation: String?
    let state: State
}

struct DisplaysOutput: Encodable, Sendable {
    let udid: String
    let name: String
    let hinge: HingeStateOutput?
    let activeScreen: ScreenStateOutput
    let otherScreens: [ScreenStateOutput]

    var textLines: [String] {
        var lines = ["\(name)  \(udid)"]
        if let hinge { lines.append("Hinge   " + hinge.text) }
        lines.append("")
        lines += DeviceStateText.screenLines(activeScreen, active: true)
        for screen in otherScreens { lines += DeviceStateText.screenLines(screen, active: false) }
        return lines
    }
}

enum DeviceStateText {
    static func rounded(_ value: Double) -> Double { (value * 10).rounded() / 10 }

    static func number(_ value: Double) -> String {
        let value = rounded(value)
        return value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    static func degrees(_ value: Double) -> String { number(value) + "°" }

    static func screenLines(_ screen: ScreenStateOutput, active: Bool) -> [String] {
        let label: String
        if active {
            label = "Active"
        } else {
            switch screen.state {
            case .on: label = "On"
            case .locked: label = "Locked"
            case .off: label = "Off"
            case .starting: label = "Starting"
            case .unknown: label = "Unknown"
            }
        }
        var summary = pad(label, 8) + pad(screen.role, 7)
            + "\(number(screen.width))×\(number(screen.height)) pt @\(screen.scale)x"
        if active {
            if let orientation = screen.orientation { summary += "  " + orientation }
            switch screen.state {
            case .locked: summary += ", locked"
            case .starting: summary += ", starting"
            case .off: summary += ", off"
            case .on, .unknown: break
            }
        }
        return [summary, pad("", 8) + pad("id \(screen.id)", 7) + screen.uuid]
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }
}

/// Reads used by `displays`, `hinge set` and `rotate` to report the device after a change.
@MainActor
enum DeviceState {
    static func bootedSimulator(udid: String, logger: AxeLogger) async throws -> FBSimulator {
        try await performGlobalSetup(logger: logger)
        let set = try await getSimulatorSet(deviceSetPath: nil, logger: logger, reporter: EmptyEventReporter.shared)
        guard let simulator = set.allSimulators.first(where: { UUID(uuidString: $0.udid) == UUID(uuidString: udid) }) else {
            throw CLIOutputFailure(code: "simulatorNotFound", message: "No simulator has UDID \(udid).")
        }
        guard simulator.state == .booted else {
            throw CLIOutputFailure(code: "notBooted",
                message: "\(simulator.name) is not booted. Boot it first, for example with xcrun simctl boot \(udid).")
        }
        return simulator
    }

    /// The boot identity the command pins for its whole duration when no `--expected-boot` is given.
    nonisolated static func currentBootIdentity(udid: String) throws -> String {
        do {
            let boot = try HIDBroker.currentBootIdentity(simulatorUDID: udid)
            return "\(boot.processIdentifier):\(boot.startSeconds):\(boot.startMicroseconds)"
        } catch {
            throw CLIOutputFailure(code: "notBooted",
                message: "Simulator \(udid) is not booted or has not finished booting.")
        }
    }

    /// Waits out a fold or rotation, then reports the screens and the hinge.
    static func displays(for simulator: FBSimulator,
                         discovery existing: ActivePanelDiscoveryResult? = nil) async throws -> (ActivePanelDiscoveryResult, DisplaysOutput) {
        let discovery: ActivePanelDiscoveryResult
        if let existing { discovery = existing } else { discovery = try await settledDiscovery(for: simulator) }
        let snapshot = discovery.readback.snapshot
        var hinge: HingeStateOutput?
        if let capability = try? FBSimulatorNativeContextReader.capability(for: simulator), capability.hinge == .supported {
            hinge = HingeStateOutput(try await FBSimulatorHingeReader.read(for: simulator))
        }
        let screens = try screens(from: snapshot)
        return (discovery, DisplaysOutput(udid: simulator.udid, name: simulator.name, hinge: hinge,
            activeScreen: screens.active, otherScreens: screens.others))
    }

    static func settledDiscovery(for simulator: FBSimulator) async throws -> ActivePanelDiscoveryResult {
        do {
            return try await DisplayTransition.settledDiscovery(for: simulator)
        } catch FBSimulatorContextError.changedDuringRead {
            throw CLIOutputFailure(code: "screensDidNotSettle",
                message: "The screens were still changing after \(DeviceStateText.number(DisplayTransition.settleBudgetSeconds)) s. Read them again.")
        }
    }

    nonisolated static func screens(from snapshot: ActivePanelSnapshot) throws -> (active: ScreenStateOutput, others: [ScreenStateOutput]) {
        let panels = snapshot.panels
        let areas = panels.map { $0.nativePixelWidth * $0.nativePixelHeight }
        func role(_ panel: ActivePanel) -> String {
            guard panels.count == 2, let index = panels.firstIndex(of: panel) else {
                return panels.count == 1 ? "main" : "screen"
            }
            return areas[index] <= areas[1 - index] ? "outer" : "inner"
        }
        func state(_ panel: ActivePanel) -> ScreenStateOutput.State {
            switch panel.backlightState {
            case "activeOn": return .on
            case "inactiveOn": return .locked
            case "off": return .off
            case "unknown": return .starting
            default: return .unknown
            }
        }
        let active = snapshot.activePanel
        let rotation = rotationDegrees(active.currentOrientation)
        guard let displayRotation = FBSimulatorHIDDisplayRotation(rawValue: rotation) else {
            throw CLIOutputFailure(code: "displayUnavailable", message: "The active screen reported an unsupported rotation.")
        }
        let context = try FBSimulatorHIDDisplayContext(hidTarget: UInt64(active.identity.displayID),
            nativePixelSize: CGSize(width: active.nativePixelWidth, height: active.nativePixelHeight),
            scale: Double(active.pointScale), rotation: displayRotation)
        let size = context.logicalSize
        let activeScreen = ScreenStateOutput(id: active.identity.displayID, uuid: active.identity.uniqueID.uuidString,
            role: role(active), width: Double(size.width), height: Double(size.height), scale: active.pointScale,
            rotation: rotation, orientation: size.width > size.height ? "landscape" : "portrait", state: state(active))
        let others = panels.filter { $0.identity != active.identity }.map { panel in
            ScreenStateOutput(id: panel.identity.displayID, uuid: panel.identity.uniqueID.uuidString, role: role(panel),
                width: panel.nativePixelWidth / Double(max(panel.pointScale, 1)),
                height: panel.nativePixelHeight / Double(max(panel.pointScale, 1)),
                scale: panel.pointScale, rotation: nil, orientation: nil, state: state(panel))
        }
        return (activeScreen, others)
    }

    nonisolated static func rotationDegrees(_ rotation: ActivePanelRotation) -> Int {
        switch rotation {
        case .rot0: return 0
        case .rot90: return 90
        case .rot180: return 180
        case .rot270: return 270
        @unknown default: return -1
        }
    }

    /// Writes the compact value with `--output`, otherwise the plain text lines.
    nonisolated static func emit<Value: Encodable>(_ value: Value, text: [String]) throws {
        if CLIOutput.isFormatted { try CLIOutput.writeJSON(value) }
        else { text.forEach { CLIOutput.message($0) } }
    }

    /// The broker reply, unchanged, for `--verbose`.
    nonisolated static func printVerbose(_ response: SelectedHIDResponse) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try CLIOutput.writeJSONData(encoder.encode(response))
    }
}

/// Plain errors for the hinge and rotation broker replies. The full reply is available with `--verbose`.
enum DeviceStateFailure {
    static func hinge(_ response: SelectedHIDResponse) -> CLIOutputFailure {
        var failure: CLIOutputFailure
        if let hinge = response.hinge?.failure {
            switch hinge.reason {
            case .unsupported:
                failure = CLIOutputFailure(code: "noHinge",
                    message: "This simulator has no hinge. Hinge commands work on iPhone Duo simulators.")
            case .bootChanged:
                failure = CLIOutputFailure(code: "bootChanged",
                    message: "The simulator restarted during the command. Read its state again.")
            case .busy:
                failure = busy
            case .timeout:
                let target = hinge.requestedDegrees.map { " " + DeviceStateText.degrees($0) } ?? ""
                failure = CLIOutputFailure(code: "timeout", message: "The hinge did not reach\(target) before the timeout.")
            case .invalidRequest:
                failure = CLIOutputFailure(code: "invalidArguments", message: hinge.detail)
            case .closed, .unavailable, .cancelled:
                failure = CLIOutputFailure(code: "hingeUnavailable", message: "The hinge could not be read or set: \(hinge.detail)")
            @unknown default:
                failure = CLIOutputFailure(code: "hingeUnavailable", message: "The hinge could not be read or set: \(hinge.detail)")
            }
            if hinge.delivery == .uncertain {
                failure = uncertain(failure, response: response)
            }
        } else if response.hinge?.readinessPreflightFailure != nil || response.outcome == "mechanicalTargetObservedDisplayIncomplete" {
            failure = CLIOutputFailure(code: "screensDidNotSettle",
                message: "The hinge moved, but the expected screen did not become active in time. Read the screens again.")
        } else {
            failure = generic(response)
        }
        return failure
    }

    static func rotation(_ response: SelectedHIDResponse) -> CLIOutputFailure {
        guard let rotation = response.rotation?.failure else { return generic(response) }
        let failure = CLIOutputFailure(code: "rotationFailed", message: "The rotation did not complete: \(rotation.detail)")
        return rotation.delivery == .uncertain ? uncertain(failure, response: response) : failure
    }

    static let busy = CLIOutputFailure(code: "busy",
        message: "Another AXe command is using the simulator. Try again when it finishes.")

    private static func generic(_ response: SelectedHIDResponse) -> CLIOutputFailure {
        let detail = response.error ?? response.outcome
        if detail == SelectedHIDFailure.busy.errorDescription { return busy }
        if let quarantine = response.quarantine {
            return CLIOutputFailure(code: "quarantined",
                message: "Device input is quarantined; nothing was sent. " + HIDInputQuarantine.recoveryStep(recordPath: quarantine.recordPath))
        }
        return CLIOutputFailure(code: "commandFailed", message: detail)
    }

    private static func uncertain(_ failure: CLIOutputFailure, response: SelectedHIDResponse) -> CLIOutputFailure {
        var message = failure.message + " The request may have reached the simulator; it was not repeated."
        if let quarantine = response.quarantine {
            message += " " + HIDInputQuarantine.recoveryStep(recordPath: quarantine.recordPath)
        }
        return CLIOutputFailure(code: failure.code, message: message)
    }
}
