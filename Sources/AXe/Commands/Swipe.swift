import ArgumentParser
import AXeCore
import Foundation
import FBControlCore
import FBSimulatorControl

struct Swipe: PhysicalDeviceCommand {
    static let configuration = CommandConfiguration(
        abstract: "Swipe in a straight line from one point to another.",
        discussion: """
        With --agent, swipe inside an element with --ref and --direction instead of coordinates.

        Examples:
          axe swipe --start-x 200 --start-y 600 --end-x 200 --end-y 300 --udid <UDID>
          axe swipe --start-x 350 --start-y 400 --end-x 50 --end-y 400 --udid <UDID>
        """
    )
    
    @Option(name: .customLong("start-x"), help: "Start X in points.")
    var startX: Double?
    
    @Option(name: .customLong("start-y"), help: "Start Y in points.")
    var startY: Double?
    
    @Option(name: .customLong("end-x"), help: "End X in points.")
    var endX: Double?
    
    @Option(name: .customLong("end-y"), help: "End Y in points.")
    var endY: Double?
    
    @Option(name: .customLong("duration"), help: "Seconds the swipe takes (default 1).")
    var duration: Double?
    
    @Option(name: .customLong("delta"), help: "Distance between touch samples in points (default 50).")
    var delta: Double?
    
    @Option(name: .customLong("pre-delay"), help: "Seconds to wait before the swipe, 0 to 10.")
    var preDelay: Double?
    
    @Option(name: .customLong("post-delay"), help: "Seconds to wait after the swipe, 0 to 10.")
    var postDelay: Double?
    
    @Option(name: .customLong("udid"), help: "UDID of the simulator or physical device.")
    var simulatorUDID: String


    @OptionGroup var selectedInput: SelectedInputOptions
    @OptionGroup var selectedOutput: SelectedOutputOptions
    @OptionGroup var agentMode: AgentModeOptions

    @Option(name: .customLong("expected-pid"), help: "Agent only: require this frontmost app PID.")
    var expectedPID: Int32?

    @Option(name: .customLong("direction"), help: "Agent only: swipe up, down, left or right inside the --ref element.")
    var agentDirection: RuntimeSwipeDirection?

    @Option(name: .customLong("distance"), help: "Agent only: fraction of the element to cross, above 0 to 1 (default 1).")
    var agentDistance: Double?

    func validate() throws {
        try agentMode.validate()
        if agentMode.enabled {
            try validateAgent()
            return
        }
        guard agentDirection == nil, agentDistance == nil else {
            throw ValidationError("--direction and --distance require --agent.")
        }
        guard expectedPID == nil else { throw ValidationError("--expected-pid requires --agent.") }
        try selectedInput.validate()
        guard let startX, let startY, let endX, let endY else {
            throw ValidationError("Swipe requires --start-x, --start-y, --end-x and --end-y.")
        }
        if selectedInput.mode == .selected { try selectedPath.validate() }
        // Validate coordinates are non-negative
        guard startX >= 0, startY >= 0, endX >= 0, endY >= 0 else {
            throw ValidationError("Coordinates must be non-negative values.")
        }
        
        // Validate duration if provided
        if let duration = duration {
            guard duration > 0 else {
                throw ValidationError("Duration must be greater than 0.")
            }
        }
        
        // Validate delta if provided
        if let delta = delta {
            guard delta > 0 else {
                throw ValidationError("Delta must be greater than 0.")
            }
        }
        
        // Validate that start and end points are different
        guard startX != endX || startY != endY else {
            throw ValidationError("Start and end points must be different.")
        }
        
        // Validate delays if provided
        if let preDelay = preDelay {
            guard preDelay >= 0 && preDelay <= 10.0 else {
                throw ValidationError("Pre-delay must be between 0 and 10 seconds.")
            }
        }
        
        if let postDelay = postDelay {
            guard postDelay >= 0 && postDelay <= 10.0 else {
                throw ValidationError("Post-delay must be between 0 and 10 seconds.")
            }
        }
    }

    private func validateAgent() throws {
        try AgentModeCommandAdapter.validateContext(input: selectedInput, expectedPID: expectedPID)
        let coordinates = [startX, startY, endX, endY]
        if agentMode.elementRef != nil {
            guard coordinates.allSatisfy({ $0 == nil }), agentDirection != nil, delta == nil else {
                throw ValidationError("Agent ref swipe requires --direction and does not accept coordinates or --delta.")
            }
            let distance = agentDistance ?? 1
            guard distance.isFinite, distance > 0, distance <= 1 else {
                throw ValidationError("--distance must be finite and in (0,1].")
            }
        } else {
            guard agentDirection == nil, agentDistance == nil else {
                throw ValidationError("--direction and --distance require an agent --ref.")
            }
            try agentMode.requireSnapshot()
            try selectedPath.validate()
        }
        if let duration, !duration.isFinite || duration <= 0 || duration > 10 {
            throw ValidationError("Agent swipe duration must be finite and in (0,10] seconds.")
        }
        try AgentModeCommandAdapter.validateDelay(preDelay, name: "--pre-delay")
        try AgentModeCommandAdapter.validateDelay(postDelay, name: "--post-delay")
    }

    func agentRequest() throws -> SelectedHIDRequest {
        if agentMode.elementRef != nil {
            return try AgentModeCommandAdapter.request(AgentModeRequest(kind: .swipe,
                expectedPID: expectedPID, snapshotID: agentMode.snapshotID, ref: agentMode.elementRef,
                direction: agentDirection, distance: agentDistance ?? 1, duration: duration ?? 1,
                preDelay: preDelay ?? 0, postDelay: postDelay ?? 0), input: selectedInput)
        }
        // An agent swipe ends at rest so its replacement read can settle; raw swipes stay linear.
        var path = selectedPath
        path.endsAtRest = true
        return try AgentModeCommandAdapter.request(AgentModeRequest(kind: .complete,
            expectedPID: expectedPID, snapshotID: agentMode.snapshotID),
            input: selectedInput, path: path)
    }

    var selectedPath: SelectedHIDPath { SelectedHIDPath(kind: .swipe, startX: startX, startY: startY, endX: endX, endY: endY, duration: duration ?? 1, delta: delta ?? 50, preDelay: preDelay ?? 0, postDelay: postDelay ?? 0) }

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
            let request = try selectedInput.pathRequest(selectedPath)
            try SelectedHIDBroker.printResponse(SelectedHIDBroker.send(request, simulatorUDID: simulatorUDID),
                verbose: selectedOutput.verbose)
            return
        }
        guard let startX, let startY, let endX, let endY else {
            throw ValidationError("Swipe requires --start-x, --start-y, --end-x and --end-y.")
        }
        let logger = AxeLogger()
        try await setup(logger: logger)
        
        try await performGlobalSetup(logger: logger)

        // Use default values if not provided
        let swipeDuration = duration ?? 1.0  // Default 1 second
        let swipeDelta = delta ?? 50.0       // Default 50 pixels
        
        logger.info().log("Performing swipe from (\(startX), \(startY)) to (\(endX), \(endY))")
        logger.info().log("Duration: \(swipeDuration)s, Delta: \(swipeDelta)px")

        // Duo and verified DTUHID devices use the broker's retained input connection.
        if let context = try await OrdinaryBrokerInput.captureRoute(
            simulatorUDID: simulatorUDID, preDelay: preDelay, logger: logger, includeVerifiedRigid: true
        )?.context {
            let path = SelectedHIDPath(kind: .swipe, startX: startX, startY: startY,
                endX: endX, endY: endY, duration: swipeDuration, delta: swipeDelta, generator: .ordinary)
            try await OrdinaryBrokerInput.perform(path: path, context: context,
                simulatorUDID: simulatorUDID, postDelay: postDelay, logger: logger, verbose: selectedOutput.verbose)
        } else {
            try await performLegacySwipe(startX: startX, startY: startY, endX: endX, endY: endY,
                swipeDuration: swipeDuration, swipeDelta: swipeDelta, logger: logger)
        }

        logger.info().log("Swipe gesture completed successfully")
    }
    private func performLegacySwipe(
        startX: Double, startY: Double, endX: Double, endY: Double,
        swipeDuration: Double, swipeDelta: Double, logger: AxeLogger
    ) async throws {
        let physicalPoints = try await OrientationAwareCoordinates.translateBatch(
            points: [(x: startX, y: startY), (x: endX, y: endY)],
            for: simulatorUDID,
            logger: logger
        )
        try await HIDInteractor.performHIDEvent(
            hidEvent(from: physicalPoints[0], to: physicalPoints[1], duration: swipeDuration, delta: swipeDelta),
            for: simulatorUDID, logger: logger)
    }

    /// The ordinary swipe between physical points with its pre and post delays, for the
    /// standalone command and batch steps.
    func hidEvent(from start: (x: Double, y: Double), to end: (x: Double, y: Double),
                  duration: Double, delta: Double) -> FBSimulatorHIDEvent {
        var events: [FBSimulatorHIDEvent] = []
        if let preDelay, preDelay > 0 { events.append(.delay(preDelay)) }
        events.append(.swipe(start.x, yStart: start.y, xEnd: end.x, yEnd: end.y, delta: delta, duration: duration))
        if let postDelay, postDelay > 0 { events.append(.delay(postDelay)) }
        return events.count == 1 ? events[0] : .composite(events)
    }
}
