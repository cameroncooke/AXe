import ArgumentParser
import Foundation

struct Drag: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Perform a low-level point-to-point drag using explicit touch move events."
    )

    private static let defaultDuration: TimeInterval = 0.6
    private static let defaultSteps = 60
    private static let maxSteps = 1_000
    private static let initialHold: TimeInterval = 0.05
    private static let finalHold: TimeInterval = 0.05

    @Option(name: .customLong("start-x"), help: "The X coordinate of the starting point.")
    var startX: Double?

    @Option(name: .customLong("start-y"), help: "The Y coordinate of the starting point.")
    var startY: Double?

    @Option(name: .customLong("end-x"), help: "The X coordinate of the ending point.")
    var endX: Double

    @Option(name: .customLong("end-y"), help: "The Y coordinate of the ending point.")
    var endY: Double

    @Option(name: .customLong("duration"), help: "Duration of the drag movement in seconds.")
    var duration: Double = Self.defaultDuration

    @Option(name: .customLong("steps"), help: "Number of touch move events to emit during the drag.")
    var steps: Int = Self.defaultSteps

    @Option(name: .customLong("pre-delay"), help: "Delay before starting the drag in seconds.")
    var preDelay: Double?

    @Option(name: .customLong("post-delay"), help: "Delay after completing the drag in seconds.")
    var postDelay: Double?

    @Option(name: .customLong("udid"), help: "The UDID of the simulator.")
    var simulatorUDID: String

    @OptionGroup var selectedInput: SelectedInputOptions
    @OptionGroup var selectedAX: SelectedAXOptions
    @OptionGroup var agentMode: AgentModeOptions

    func validate() throws {
        try agentMode.validate()
        if agentMode.enabled {
            try AgentModeCommandAdapter.validateContext(input: selectedInput, expectedPID: selectedAX.expectedPID)
            guard startX == nil, startY == nil, agentMode.elementRef != nil else {
                throw ValidationError("Agent drag requires --ref and does not accept --start-x or --start-y.")
            }
            _ = try agentRequest()
            return
        }
        try selectedAX.validate(required: false)
        guard let startX, let startY else {
            throw ValidationError("Drag requires --start-x and --start-y without --agent.")
        }
        try selectedInput.validate()
        if selectedInput.mode == .selected { try selectedPath.validate() }
        guard startX >= 0, startY >= 0, endX >= 0, endY >= 0 else {
            throw ValidationError("Coordinates must be non-negative values.")
        }
        guard startX != endX || startY != endY else {
            throw ValidationError("Start and end points must be different.")
        }
        guard duration > 0 else {
            throw ValidationError("Duration must be greater than 0.")
        }
        guard (1...Self.maxSteps).contains(steps) else {
            throw ValidationError("Steps must be between 1 and \(Self.maxSteps).")
        }
        if let preDelay {
            guard preDelay >= 0 && preDelay <= 10.0 else {
                throw ValidationError("Pre-delay must be between 0 and 10 seconds.")
            }
        }
        if let postDelay {
            guard postDelay >= 0 && postDelay <= 10.0 else {
                throw ValidationError("Post-delay must be between 0 and 10 seconds.")
            }
        }
    }

    var selectedPath: SelectedHIDPath { SelectedHIDPath(kind: .drag, startX: startX, startY: startY, endX: endX, endY: endY, duration: duration, steps: steps, preDelay: preDelay ?? 0, postDelay: postDelay ?? 0) }

    func selectedRequest() throws -> SelectedHIDRequest {
        guard !agentMode.enabled else {
            throw ValidationError("Agent mode requires standalone commands and is not supported in batch steps.")
        }
        return try selectedInput.pathRequest(selectedPath)
    }

    func agentRequest() throws -> SelectedHIDRequest {
        try AgentModeCommandAdapter.request(AgentModeRequest(kind: .drag,
            expectedPID: selectedAX.expectedPID, snapshotID: agentMode.snapshotID, ref: agentMode.elementRef,
            destination: SelectedAXPoint(x: endX, y: endY), steps: steps, duration: duration,
            preDelay: preDelay ?? 0, postDelay: postDelay ?? 0), input: selectedInput)
    }

    func run() async throws {
        if agentMode.enabled {
            try AgentModeCommandAdapter.send(agentRequest(), simulatorUDID: simulatorUDID)
            return
        }
        if selectedInput.mode == .selected {
            let request = try selectedRequest()
            try SelectedHIDBroker.printResponse(SelectedHIDBroker.send(request, simulatorUDID: simulatorUDID))
            return
        }
        guard let startX, let startY else {
            throw ValidationError("Drag requires --start-x and --start-y without --agent.")
        }
        let logger = AxeLogger()
        try await setup(logger: logger)
        try await performGlobalSetup(logger: logger)

        logger.info().log("Performing low-level drag from (\(startX), \(startY)) to (\(endX), \(endY))")
        logger.info().log("Duration: \(duration)s, steps: \(steps)")

        if let context = try await LegacyDuoInput.captureContext(
            simulatorUDID: simulatorUDID, preDelay: preDelay, logger: logger
        ) {
            let path = LegacyDuoPath(kind: .drag, startX: startX, startY: startY,
                endX: endX, endY: endY, duration: duration, steps: steps)
            try await LegacyDuoInput.perform(path: path, context: context,
                simulatorUDID: simulatorUDID, postDelay: postDelay, logger: logger)
            logger.info().log("Low-level drag completed successfully")
            return
        }

        if let preDelay, preDelay > 0 {
            logger.info().log("Pre-delay: \(preDelay)s")
            try await Task.sleep(for: .seconds(preDelay))
        }

        let physicalPoints = try await OrientationAwareCoordinates.translateBatch(
            points: [(x: startX, y: startY), (x: endX, y: endY)],
            for: simulatorUDID,
            logger: logger
        )

        try await HIDInteractor.performCompositeDrag(
            from: physicalPoints[0],
            to: physicalPoints[1],
            duration: duration,
            steps: steps,
            initialHold: Self.initialHold,
            finalHold: Self.finalHold,
            for: simulatorUDID,
            logger: logger
        )

        if let postDelay, postDelay > 0 {
            logger.info().log("Post-delay: \(postDelay)s")
            try await Task.sleep(for: .seconds(postDelay))
        }

        logger.info().log("Low-level drag completed successfully")
    }
}
