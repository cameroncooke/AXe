import ArgumentParser
import Foundation

struct SelectedOutputOptions: ParsableArguments {
    @Flag(name: .customLong("verbose"), help: "Print the full input receipt as JSON, including context, target checks and cleanup evidence, where AXe owns the input (selected input, and ordinary input on the iPhone Duo and DTUHID simulators).")
    var verbose = false
}

/// The default result of a selected command, matching what the plain command reports. The full
/// receipt stays behind `--verbose`.
struct SelectedInputSummary: Encodable {
    struct Screen: Encodable {
        let id: UInt32
        let uuid: String
        let width: Double
        let height: Double
        let rotation: Int
    }
    /// Always `completed`: a failed reply is an error, and the broker's transport outcome is
    /// receipt detail.
    let outcome = "completed"
    let screen: Screen?
    let pid: Int32?
    let token: UUID?

    init(_ response: SelectedHIDResponse) {
        screen = response.context.map {
            Screen(id: $0.screenID, uuid: $0.screenUUID, width: $0.logicalWidth, height: $0.logicalHeight,
                rotation: $0.rotationDegrees)
        }
        pid = response.ax?.expectedPID ?? response.keyboard?.expectedPID
        token = response.token
    }
}

extension SelectedHIDFailure {
    /// The broker writes `String(describing:)` of its error into the reply; this is `busy`'s.
    static let busyWireDescription = String(describing: SelectedHIDFailure.busy)
}

enum SelectedInputOutput {
    static func failed(_ response: SelectedHIDResponse) -> Bool {
        response.error != nil || response.quarantine != nil || response.cleanup == "uncertain"
    }

    static func print(_ response: SelectedHIDResponse) throws {
        if failed(response) { throw failure(response) }
        if let ax = response.ax, ax.kind == .describe || ax.kind == .describePoint {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try CLIOutput.writeJSONText(String(decoding: try encoder.encode(ax.roots ?? []), as: UTF8.self))
            return
        }
        if CLIOutput.isFormatted {
            try CLIOutput.writeJSON(SelectedInputSummary(response))
        } else if let token = response.token {
            CLIOutput.message("Contact token: \(token.uuidString)")
        }
    }

    /// One code and a sentence that says whether input was sent. The broker's outcome, event
    /// count and cleanup state stay in the `--verbose` receipt.
    static func failure(_ response: SelectedHIDResponse) -> CLIOutputFailure {
        if let quarantine = response.quarantine {
            return CLIOutputFailure(code: "quarantined",
                message: "Device input is quarantined; nothing was sent. " + HIDInputQuarantine.recoveryStep(recordPath: quarantine.recordPath))
        }
        if response.error == SelectedHIDFailure.busyWireDescription { return DeviceStateFailure.busy }
        let code: String
        if let ax = response.ax?.failure {
            switch ax {
            case .waitTimedOut: code = "timeout"
            case .waitCancelled: code = "interrupted"
            default: code = ax.rawValue
            }
        }
        else if response.cleanup == "uncertain" { code = "cleanupUncertain" }
        else if response.enqueuedEventCount > 0 { code = "inputFailed" }
        else { code = "rejectedBeforeInput" }
        let sent = response.enqueuedEventCount == 0 && response.cleanup != "uncertain"
            ? "No input was sent."
            : CLIErrorMapping.someInputSent
        let detail = CLIErrorMapping.readable(response.error)
            ?? (response.enqueuedEventCount == 0 ? "The input was refused." : "Input stopped.")
        return CLIOutputFailure(code: code, message: "\(detail) \(sent)")
    }
}
