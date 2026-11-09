import ArgumentParser
import AXeCore
import Foundation

extension RuntimeSwipeDirection: ExpressibleByArgument {}

enum AgentModeCommandAdapter {
    static func validateContext(input: SelectedInputOptions, expectedPID: Int32?) throws {
        try input.validate()
        if let expectedPID, expectedPID <= 0 {
            throw ValidationError("--expected-pid must be positive when provided with --agent.")
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

    static func send(_ originalRequest: SelectedHIDRequest, simulatorUDID: String) throws {
        try AutomationTarget.refuseOnDevice(simulatorUDID, "Agent mode is available on simulators only.")
        guard UUID(uuidString: simulatorUDID) != nil else {
            throw ValidationError("--udid must be a nonempty simulator UUID. Set SIM_UUID or run axe list-simulators.")
        }
        let view = CLIOutput.context?.agentView ?? .full
        var request = originalRequest
        if view == .reading, request.agentBatch != nil || request.agent?.rowLimit == 64 {
            request.includeReadingContinuation = true
        }
        let response = try sendTimed(request, simulatorUDID: simulatorUDID)
        guard let result = response.agent else {
            throw CLIError(errorDescription: "Agent mode returned no agent result. Inspect the broker state before retrying.")
        }
        guard view == .reading, let continuation = response.readingContinuation else {
            try CLIOutput.writeJSON(result)
            if result.didError { throw ExitCode.failure }
            return
        }
        let original = try JSONDecoder().decode(CLIOutputValue.self, from: JSONEncoder().encode(result))
        let page = try JSONDecoder().decode(CLIOutputValue.self, from: JSONEncoder().encode(continuation))
        try CLIOutput.writeJSON(AgentPageEnrichment.enrich(original, continuation: page))
        if result.didError { throw ExitCode.failure }
    }

    /// Records client and broker phases only when AXE_TIMING is set. Standard output is unchanged.
    /// Phases are reported even when the exchange fails, so a slow connect or broker start is visible.
    private static func sendTimed(_ original: SelectedHIDRequest, simulatorUDID: String) throws -> SelectedHIDResponse {
        guard let destination = PhaseTimingOutput.destination() else {
            return try SelectedHIDBroker.send(original, simulatorUDID: simulatorUDID)
        }
        var request = original
        request.timing = true
        let timer = PhaseTimer()
        var response: SelectedHIDResponse?
        defer {
            PhaseTimingOutput.emit(PhaseTimingOutput.record(command: PhaseTimingOutput.commandName,
                requestID: request.requestID, client: timer, broker: response?.timing), to: destination)
        }
        let result = try PhaseTimer.$current.withValue(timer) {
            try SelectedHIDBroker.send(request, simulatorUDID: simulatorUDID)
        }
        response = result
        return result
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
