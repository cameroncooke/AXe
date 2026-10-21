import ArgumentParser
import AXeCore
import Foundation

extension RuntimeSwipeDirection: ExpressibleByArgument {}

enum AgentModeCommandAdapter {
    static func validateContext(input: SelectedInputOptions, expectedPID: Int32?) throws {
        try input.validate()
        guard let expectedPID, expectedPID > 0 else {
            throw ValidationError("--agent requires a positive --expected-pid.")
        }
    }

    static func request(_ agent: AgentModeRequest, input: SelectedInputOptions,
                        path: SelectedHIDPath? = nil) throws -> SelectedHIDRequest {
        try validateContext(input: input, expectedPID: agent.expectedPID)
        var request = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
            screenID: input.screenID, screenUUID: input.screenUUID.flatMap { UUID(uuidString: $0) },
            operation: .complete, token: nil, primitives: [], path: path)
        request.agent = agent
        try request.validate()
        return request
    }

    static func send(_ request: SelectedHIDRequest, simulatorUDID: String) throws {
        let response = try SelectedHIDBroker.send(request, simulatorUDID: simulatorUDID)
        guard let result = response.agent else {
            throw CLIError(errorDescription: "Agent mode returned no agent result. Inspect the broker state before retrying.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(result), as: UTF8.self))
        if result.didError {
            throw CLIError(errorDescription: "Agent action failed. Inspect the JSON result before retrying.")
        }
    }

    static func validateDelay(_ value: Double?, name: String) throws {
        if let value, !value.isFinite || !(0...10).contains(value) {
            throw ValidationError("\(name) must be finite and in 0...10 seconds.")
        }
    }

    static func readText(_ literal: String?, useStdin: Bool, inputFile: String?,
                         standardInput: FileHandle = .standardInput) throws -> String {
        switch (literal, useStdin, inputFile) {
        case (let literal?, false, nil): return literal
        case (nil, true, nil): return try SelectedKeyboardOptions.readText(from: standardInput)
        case (nil, false, let file?):
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: file))
            defer { try? handle.close() }
            return try SelectedKeyboardOptions.readText(from: handle)
        default: throw ValidationError("Select one text input source.")
        }
    }
}
