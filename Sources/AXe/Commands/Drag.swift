import ArgumentParser
import Foundation

struct Drag: PhysicalDeviceCommand {
    static let configuration = CommandConfiguration(
        abstract: "Drag from one point to another with explicit touch moves.",
        discussion: """
        The touch rests briefly at both ends and moves in --steps events, which suits drag and drop. --hold makes the first rest longer: a list starts a reorder, and an icon lifts, only after about half a second. With --agent, --ref replaces the start point.

        Examples:
          axe drag --start-x 100 --start-y 500 --end-x 300 --end-y 500 --udid <UDID>
          axe drag --start-x 200 --start-y 300 --end-x 200 --end-y 500 --hold 0.6 --udid <UDID>    # reorder a row
          axe drag --start-x 200 --start-y 300 --end-x 200 --end-y 700 --duration 1.5 --udid <UDID>
        """
    )

    private static let defaultDuration: TimeInterval = 0.6
    private static let defaultSteps = 60
    private static let maxSteps = 1_000
    /// Every drag route holds the contact this long before and after its movement.
    static let initialHold: TimeInterval = 0.05
    static let finalHold: TimeInterval = 0.05
    static let maximumHold: TimeInterval = 10

    @Option(name: .customLong("start-x"), help: "Start X in points.")
    var startX: Double?

    @Option(name: .customLong("start-y"), help: "Start Y in points.")
    var startY: Double?

    @Option(name: .customLong("end-x"), help: "End X in points.")
    var endX: Double

    @Option(name: .customLong("end-y"), help: "End Y in points.")
    var endY: Double

    @Option(name: .customLong("duration"), help: "Seconds the movement takes.")
    var duration: Double = Self.defaultDuration

    @Option(name: .customLong("steps"), help: "Number of touch moves, 1 to 1000.")
    var steps: Int = Self.defaultSteps

    @Option(name: .customLong("hold"), help: "Seconds the finger rests on the start before it moves, 0 to 10 (default 0.05). About 0.6 starts a reorder or lifts an item.")
    var hold: Double?

    @Option(name: .customLong("pre-delay"), help: "Seconds to wait before the drag, 0 to 10.")
    var preDelay: Double?

    @Option(name: .customLong("post-delay"), help: "Seconds to wait after the drag, 0 to 10.")
    var postDelay: Double?

    @Option(name: .customLong("udid"), help: "UDID of the simulator or physical device.")
    var simulatorUDID: String

    @OptionGroup var selectedInput: SelectedInputOptions
    @OptionGroup var selectedOutput: SelectedOutputOptions
    @OptionGroup var agentMode: AgentModeOptions

    @Option(name: .customLong("expected-pid"), help: "Agent only: require this frontmost app PID.")
    var expectedPID: Int32?

    func validate() throws {
        try agentMode.validate()
        if agentMode.enabled {
            try AgentModeCommandAdapter.validateContext(input: selectedInput, expectedPID: expectedPID)
            guard startX == nil, startY == nil, agentMode.elementRef != nil else {
                throw ValidationError("Agent drag requires --ref and does not accept --start-x or --start-y.")
            }
            _ = try agentRequest()
            return
        }
        guard expectedPID == nil else { throw ValidationError("--expected-pid requires --agent.") }
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
        if let hold {
            guard hold.isFinite, (0...Self.maximumHold).contains(hold) else {
                throw ValidationError("Hold must be between 0 and 10 seconds.")
            }
            guard !agentMode.enabled else {
                throw ValidationError("Agent drag does not take --hold.")
            }
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

    var selectedPath: SelectedHIDPath { SelectedHIDPath(kind: .drag, startX: startX, startY: startY, endX: endX, endY: endY, duration: duration, steps: steps, preDelay: preDelay ?? 0, postDelay: postDelay ?? 0, hold: hold) }

    func selectedRequest() throws -> SelectedHIDRequest {
        guard !agentMode.enabled else {
            throw ValidationError("Agent mode requires standalone commands and is not supported in batch steps.")
        }
        return try selectedInput.pathRequest(selectedPath)
    }

    func agentRequest() throws -> SelectedHIDRequest {
        try AgentModeCommandAdapter.request(AgentModeRequest(kind: .drag,
            expectedPID: expectedPID, snapshotID: agentMode.snapshotID, ref: agentMode.elementRef,
            destination: SelectedAXPoint(x: endX, y: endY), steps: steps, duration: duration,
            preDelay: preDelay ?? 0, postDelay: postDelay ?? 0), input: selectedInput)
    }

    func validateOnDevice(inBatch: Bool) throws {
        try selectedInput.refuseOnDevice(agent: agentMode.enabled)
        try selectedPath.validate()
    }

    func runOnDevice(_ input: PhysicalDeviceInput) async throws {
        try await PhysicalDeviceGestures.path(selectedPath, on: input)
    }

    func run() async throws {
        if try await runOnDeviceIfTargeted() { return }
        if agentMode.enabled {
            try AgentModeCommandAdapter.send(agentRequest(), simulatorUDID: simulatorUDID)
            return
        }
        if selectedInput.mode == .selected {
            let request = try selectedRequest()
            try SelectedHIDBroker.printResponse(SelectedHIDBroker.send(request, simulatorUDID: simulatorUDID),
                verbose: selectedOutput.verbose)
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

        // Duo and verified DTUHID devices use the broker's retained input connection.
        if let context = try await OrdinaryBrokerInput.captureRoute(
            simulatorUDID: simulatorUDID, preDelay: preDelay, logger: logger, includeVerifiedRigid: true
        )?.context {
            let path = SelectedHIDPath(kind: .drag, startX: startX, startY: startY,
                endX: endX, endY: endY, duration: duration, steps: steps, hold: hold, generator: .ordinary)
            try await OrdinaryBrokerInput.perform(path: path, context: context,
                simulatorUDID: simulatorUDID, postDelay: postDelay, logger: logger, verbose: selectedOutput.verbose)
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
            initialHold: hold ?? Self.initialHold,
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
