import ArgumentParser
import Foundation
import FBSimulatorControl

struct SelectedKeyboardOptions: ParsableArguments {
    @Option(name: .customLong("expected-pid"), help: "Selected or agent: require this frontmost app PID.")
    var expectedPID: Int32?
    @Option(name: .customLong("focus-id"), help: "ID of the focused TextField (required when selected).")
    var focusID: String?

    func validate(input: SelectedInputOptions) throws {
        try input.validate()
        guard input.mode == .selected else {
            guard expectedPID == nil, focusID == nil else {
                throw ValidationError("--expected-pid and --focus-id require --input-mode selected.")
            }
            return
        }
        if let expectedPID, expectedPID <= 0 {
            throw ValidationError("--expected-pid must be a positive process ID.")
        }
        guard let focusID, !focusID.isEmpty, focusID.utf8.count <= 4096,
              focusID == focusID.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw ValidationError("Selected keyboard requires the exact --focus-id of the focused TextField.")
        }
    }

    func request(input: SelectedInputOptions, event: FBSimulatorHIDEvent) throws -> SelectedHIDRequest {
        try validate(input: input)
        guard input.mode == .selected, let focusID else {
            throw ValidationError("Missing selected keyboard field identity.")
        }
        var request = try input.baseRequest(operation: .complete, token: nil, primitives: [])
        request.keyboard = SelectedKeyboardRequest(expectedPID: expectedPID, focusID: focusID,
            events: try KeyboardPrimitives.from(event))
        try request.validate()
        return request
    }

    func send(input: SelectedInputOptions, event: FBSimulatorHIDEvent, simulatorUDID: String,
              verbose: Bool = false) throws {
        try SelectedHIDBroker.printResponse(SelectedHIDBroker.send(
            request(input: input, event: event), simulatorUDID: simulatorUDID), verbose: verbose)
    }

    /// Preserve all input bytes. Cap memory before conversion; never trim or truncate input.
    static func readText(from handle: FileHandle) throws -> String {
        var data = Data()
        while data.count <= SelectedKeyboardRequest.maximumTextBytes {
            let remaining = SelectedKeyboardRequest.maximumTextBytes + 1 - data.count
            guard let chunk = try handle.read(upToCount: remaining), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= SelectedKeyboardRequest.maximumTextBytes,
              let text = String(data: data, encoding: .utf8) else {
            throw ValidationError("Selected text must be valid UTF-8 and at most 256 bytes.")
        }
        return text
    }
}
