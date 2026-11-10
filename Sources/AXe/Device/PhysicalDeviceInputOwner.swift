import CoreGraphics
import Darwin
import Foundation

enum PhysicalTouchEdge: String, Codable, Sendable { case none, left, top, bottom }

enum PhysicalTouchPhase: UInt64, Codable, Sendable {
    case down = 0
    case move = 1
    case up = 2
}

struct PhysicalTouchStep: Codable, Sendable {
    let points: [CGPoint]
    let phase: PhysicalTouchPhase
    var edge: PhysicalTouchEdge = .none
    var delayAfter: TimeInterval = 0
}

struct PhysicalKeyStep: Codable, Sendable {
    let code: UInt64
    let pressed: Bool
    var delayAfter: TimeInterval = 0.03
}

enum PhysicalRotationDirection: String, Codable, Sendable { case left, right }

enum PhysicalDeviceButton: UInt64, Codable, Sendable {
    case home = 0x40
    case lock = 0x30
    case siri = 0xCF
}

/// Holds one RSD and HID session and owns every contact and key it starts.
actor PhysicalDeviceInputOwner {
    private static let controlService = "com.apple.coredevice.devicecontrol"

    let directory: DeviceServiceDirectory
    private let tunnelAddress: String
    private let deviceIdentifier: String
    private let coreDeviceVersion: String
    private var lease: PhysicalDeviceInputLease?
    private var busy = false
    private var closed = false
    private var uncertain = false
    private var contact: HeldContact?
    private var pressedKeys: [UInt64] = []
    private var pressedButton: PhysicalDeviceButton?

    private init(directory: DeviceServiceDirectory, tunnelAddress: String, deviceIdentifier: String,
                 coreDeviceVersion: String, lease: PhysicalDeviceInputLease) {
        self.directory = directory
        self.tunnelAddress = tunnelAddress
        self.deviceIdentifier = deviceIdentifier
        self.coreDeviceVersion = coreDeviceVersion
        self.lease = lease
    }

    /// Fresh CoreDevice details for a listed device, refusing unless every readiness check passes and it is
    /// unlocked. Input leases and the native display stream use it.
    static func readyDevice(_ listedDevice: CoreDevice) async throws -> CoreDevice {
        let device = try await CoreDeviceInventory.details(for: listedDevice)
        if let check = DeviceInspection.inventoryChecks(for: device).first(where: { $0.status != .ready }) {
            throw CLIOutputFailure(code: check.id, message: check.message ?? "The device is not ready.")
        }
        guard try await CoreDeviceInventory.lockState(for: device) == false else {
            throw CLIOutputFailure(code: "deviceLocked", message: "Unlock the device before sending input or reading its screen.")
        }
        return device
    }

    static func connectReadyDevice(_ device: CoreDevice) async throws -> PhysicalDeviceInputOwner {
        guard let address = device.tunnelAddress, let udid = device.udid,
              let version = device.coreDeviceVersion else {
            throw CLIOutputFailure(code: "targetNotReady",
                message: "CoreDevice did not report the tunnel address, hardware UDID, or version. Check the device in Xcode.")
        }

        let lease = try PhysicalDeviceInputLease(udid: udid)
        let directory = try await DeviceServiceDirectory.connect(tunnelAddress: address, expectedUDID: udid)
        return PhysicalDeviceInputOwner(directory: directory, tunnelAddress: address, deviceIdentifier: device.identifier,
                                   coreDeviceVersion: version, lease: lease)
    }

    var acceptsInput: Bool { !closed && !uncertain }

    func matchesReadyDevice(_ device: CoreDevice) -> Bool {
        !closed && !uncertain && device.tunnelAddress == tunnelAddress
            && device.identifier == deviceIdentifier && device.coreDeviceVersion == coreDeviceVersion
    }

    func display(timeout: TimeInterval = 8) async throws -> PhysicalDeviceDisplay {
        try begin()
        defer { busy = false }
        return try await readDisplay(timeout: timeout)
    }

    func perform(_ plan: [PhysicalTouchStep], on display: PhysicalDeviceDisplay? = nil,
                 allowPartial: Bool = false, admissionDeadline: ContinuousClock.Instant? = nil) async throws {
        try begin()
        defer { busy = false }
        guard !plan.isEmpty, plan.count <= 8_192 else {
            throw CLIOutputFailure(code: "invalidArguments", message: "Device touch requires 1 to 8192 steps.")
        }

        let geometry: PhysicalDeviceDisplay
        if let display {
            geometry = display
        } else {
            geometry = try await readDisplay(timeout: 8)
        }
        if let contact, contact.display != geometry {
            try await releaseHeldInput()
            throw CLIOutputFailure(code: "screenChanged", message: "The device display changed during a held contact.")
        }

        var activeCount = contact?.points.count
        var activeEdge = contact?.edge
        let steps = try plan.map { step -> (HeldContact, PhysicalTouchPhase, TimeInterval) in
            guard (1...2).contains(step.points.count),
                  step.points.count == 1 || step.points[0] != step.points[1] else {
                throw CLIOutputFailure(code: "invalidArguments", message: "A touch step requires one or two distinct points.")
            }
            try Self.validateDelay(step.delayAfter)
            let sample = try HeldContact(points: step.points.map(geometry.normalized),
                edge: geometry.wireEdge(step.edge), display: geometry)
            switch step.phase {
            case .down:
                guard activeCount == nil else { throw Self.invalidContactSequence }
                activeCount = step.points.count
                activeEdge = sample.edge
            case .move, .up:
                guard activeCount == step.points.count, activeEdge == sample.edge else {
                    throw Self.invalidContactSequence
                }
                if step.phase == .up {
                    activeCount = nil
                    activeEdge = nil
                }
            }
            return (sample, step.phase, step.delayAfter)
        }
        guard allowPartial || activeCount == nil else { throw Self.invalidContactSequence }

        try await directory.prepareHID()
        if let admissionDeadline, ContinuousClock().now >= admissionDeadline {
            throw CLIOutputFailure(code: "timeout",
                message: "The element selection expired before AXe could send input.")
        }
        do {
            for (sample, phase, delay) in steps {
                try Task.checkCancellation()
                // A failed write may already have sent part of the event.
                contact = sample
                try await directory.sendHID(sample.message(phase))
                if phase == .up { contact = nil }
                try await Self.wait(delay)
            }
        } catch {
            try await handleInterruptedInput(error)
        }
    }

    func keys(_ steps: [PhysicalKeyStep]) async throws {
        try begin()
        defer { busy = false }
        try requireNoContact()
        guard !steps.isEmpty, steps.count <= 8_192 else {
            throw CLIOutputFailure(code: "invalidArguments", message: "Device keyboard input requires 1 to 8192 steps.")
        }
        var planned: Set<UInt64> = []
        for step in steps {
            try Self.validateDelay(step.delayAfter)
            guard step.code <= 255 else {
                throw CLIOutputFailure(code: "invalidArguments", message: "HID key usage codes must be between 0 and 255.")
            }
            if step.pressed {
                guard planned.insert(step.code).inserted else { throw Self.invalidKeySequence }
            } else {
                guard planned.remove(step.code) != nil else { throw Self.invalidKeySequence }
            }
        }
        guard planned.isEmpty else { throw Self.invalidKeySequence }

        try await directory.prepareHID()
        do {
            for step in steps {
                try Task.checkCancellation()
                if step.pressed { pressedKeys.append(step.code) }
                try await directory.sendHID(Self.keyMessage(step.code, pressed: step.pressed))
                if !step.pressed { pressedKeys.removeAll { $0 == step.code } }
                try await Self.wait(step.delayAfter)
            }
        } catch {
            try await handleInterruptedInput(error)
        }
    }

    func pressButton(_ button: PhysicalDeviceButton, hold: TimeInterval = 0.08) async throws {
        try begin()
        defer { busy = false }
        try requireNoContact()
        try Self.validateDelay(hold)
        try await directory.prepareHID()
        do {
            try Task.checkCancellation()
            pressedButton = button
            try await directory.sendHID(Self.buttonMessage(button, pressed: true))
            try await Self.wait(hold)
            try await directory.sendHID(Self.buttonMessage(button, pressed: false))
            pressedButton = nil
        } catch {
            try await handleInterruptedInput(error)
        }
    }

    func rotate(_ direction: PhysicalRotationDirection, timeout: TimeInterval = 8) async throws {
        try begin()
        defer { busy = false }
        try requireNoContact()
        guard timeout.isFinite, (0.5...15).contains(timeout) else {
            throw CLIOutputFailure(code: "invalidArguments", message: "Device rotation timeout must be 0.5 to 15 seconds.")
        }

        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(timeout)
        func remaining() throws -> TimeInterval {
            let interval = clock.now.duration(to: deadline)
            guard interval > .zero else {
                throw CLIOutputFailure(code: "rotationUnconfirmed",
                    message: "The device did not report a changed display orientation within the rotation timeout.")
            }
            return interval.timeInterval
        }
        // Fail before rotating if the display cannot be read.
        var previous = try await readDisplay(timeout: remaining())
        let reply = try await directory.request(service: Self.controlService, body: [
            "featureIdentifier": .string("com.apple.coredevice.feature.remote.devicecontrol.orientation"),
            "messageType": .string("OrientationRequest"),
            "payload": .dictionary(["rotate": .dictionary(["_0": .string(direction.rawValue)])]),
        ], timeout: remaining())
        let payload = reply["payload"]?.dictionaryValue ?? reply
        guard let reported = payload["currentDeviceOrientation"]?.stringValue,
              let locked = payload["currentDeviceOrientationLocked"],
              locked == .bool(false) || locked == .bool(true) else {
            // The request was delivered, so the device may have turned.
            throw CLIOutputFailure(code: "rotationUnconfirmed",
                message: "The device returned an unreadable rotation reply, so AXe could not confirm whether it "
                    + "rotated. Read the screen before rotating again.")
        }
        guard locked == .bool(false) else {
            throw CLIOutputFailure(code: "rotationLocked",
                message: "The device reported orientation lock, so the rotation request had no effect. Turn off "
                    + "the orientation lock and rotate again.")
        }
        let unconfirmed = CLIOutputFailure(code: "rotationUnconfirmed",
            message: "The device reported \(reported), but its display did not reach that orientation. The app or "
                + "device may not support it, or the display state lagged. Rotate again.")
        // Confirmed turns matched within about a second. An iPhone asked to turn upside down, or an iPad whose
        // display state lagged, never changed afterwards, so stop once the display has stood still this long.
        let settle: Duration = .milliseconds(2_500)
        var lastChange = clock.now
        while true {
            let now = clock.now
            guard now.duration(to: deadline) > .milliseconds(150), now - lastChange < settle else { throw unconfirmed }
            let after: PhysicalDeviceDisplay
            do {
                after = try await readDisplay(timeout: remaining())
            } catch DeviceServiceError.timeout {
                throw unconfirmed
            }
            if after.matches(deviceOrientation: reported), (try? after.requireResolvedOrientation()) != nil { return }
            if after != previous {
                previous = after
                lastChange = clock.now
            }
            try await Self.wait(min(0.1, try remaining()))
        }
    }

    func close() async throws {
        guard !closed else { return }
        closed = true
        defer {
            directory.close()
            lease = nil
        }
        try await finishClient()
    }

    func finishClient() async throws {
        guard !busy else {
            throw CLIOutputFailure(code: "busy", message: "The current device operation has not stopped.")
        }
        do {
            try await releaseHeldInput()
            try await directory.drainHID()
        } catch {
            uncertain = true
            throw error
        }
    }

    private func begin() throws {
        try Task.checkCancellation()
        guard !closed, !uncertain else {
            throw CLIOutputFailure(code: "inputUnavailable", message: "The physical device input session cannot accept more input.")
        }
        guard !busy else {
            throw CLIOutputFailure(code: "busy", message: "Another action owns this physical device input session.")
        }
        busy = true
    }

    private func requireNoContact() throws {
        if contact != nil {
            throw CLIOutputFailure(code: "busy", message: "Finish the held device touch before sending other input.")
        }
    }

    private func readDisplay(timeout: TimeInterval) async throws -> PhysicalDeviceDisplay {
        try await directory.readDisplay(deviceIdentifier: deviceIdentifier, coreDeviceVersion: coreDeviceVersion,
                                        timeout: timeout)
    }

    private func handleInterruptedInput(_ error: Error) async throws -> Never {
        uncertain = true
        try await releaseHeldInput()
        throw error
    }

    private func releaseHeldInput() async throws {
        var failures = false
        if let contact {
            do {
                try await directory.sendHID(contact.message(.up), cleanup: true)
                self.contact = nil
            } catch { failures = true }
        }
        for key in pressedKeys.reversed() {
            do {
                try await directory.sendHID(Self.keyMessage(key, pressed: false), cleanup: true)
                pressedKeys.removeAll { $0 == key }
            } catch { failures = true }
        }
        if let pressedButton {
            do {
                try await directory.sendHID(Self.buttonMessage(pressedButton, pressed: false), cleanup: true)
                self.pressedButton = nil
            } catch { failures = true }
        }
        if failures {
            throw CLIOutputFailure(code: "cleanupUncertain",
                message: "AXe could not send all release events. Check the device before sending more input.")
        }
    }

    private static var invalidContactSequence: CLIOutputFailure {
        CLIOutputFailure(code: "invalidArguments", message: "Device touch steps must use matching down, move, and up contacts.")
    }

    private static var invalidKeySequence: CLIOutputFailure {
        CLIOutputFailure(code: "invalidArguments", message: "Each device key down requires one matching key up.")
    }

    private static func validateDelay(_ delay: TimeInterval) throws {
        guard delay.isFinite, (0...30).contains(delay) else {
            throw CLIOutputFailure(code: "invalidArguments", message: "An input step delay must be 0 to 30 seconds.")
        }
    }

    private static func wait(_ delay: TimeInterval) async throws {
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
    }

    private static func keyMessage(_ code: UInt64, pressed: Bool) -> [String: RemoteXPCValue] {
        hidMessage("IndigoKeyboardButtonEvent", feature: "keyboard",
                   payload: ["usageCode": .uint64(code), "state": .uint64(pressed ? 1 : 2)])
    }

    private static func buttonMessage(_ button: PhysicalDeviceButton, pressed: Bool) -> [String: RemoteXPCValue] {
        hidMessage("IndigoButtonEvent", feature: "button", payload: [
            "usagePage": .uint64(0x0C), "usageCode": .uint64(button.rawValue), "state": .uint64(pressed ? 1 : 2),
        ])
    }

    private static func hidMessage(_ type: String, feature: String,
                                   payload: [String: RemoteXPCValue]) -> [String: RemoteXPCValue] {
        [
            "messageType": .string(type),
            "featureIdentifier": .string("com.apple.coredevice.feature.remote.hid.\(feature)"),
            "payload": .dictionary(payload),
        ]
    }

    private struct HeldContact {
        let points: [RemoteXPCValue]
        let edge: UInt64
        let display: PhysicalDeviceDisplay

        func message(_ phase: PhysicalTouchPhase) -> [String: RemoteXPCValue] {
            var payload: [String: RemoteXPCValue] = [
                "pointOne": points[0], "eventType": .uint64(phase.rawValue), "edge": .uint64(edge), "target": .uint64(0),
            ]
            if points.count == 2 { payload["pointTwo"] = points[1] }
            return hidMessage("IndigoDigitizerEvent", feature: "digitizer", payload: payload)
        }
    }
}

private final class PhysicalDeviceInputLease: Sendable {
    private let descriptor: Int32

    init(udid: String) throws {
        let endpoint = try HIDBroker.endpointPath(simulatorUDID: udid.uppercased(),
            developerDirectory: "/physical-device-input", version: 1)
        do {
            descriptor = try HIDBroker.acquireLifetimeLock(endpoint: endpoint)
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EWOULDBLOCK) {
            throw CLIOutputFailure(code: "busy", message: "Another AXe process owns input on this physical device.")
        }
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}
