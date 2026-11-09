import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl

enum GesturePreset: String, CaseIterable, ExpressibleByArgument, Codable, Sendable {
    case scrollUp = "scroll-up"
    case scrollDown = "scroll-down" 
    case scrollLeft = "scroll-left"
    case scrollRight = "scroll-right"
    case swipeFromLeftEdge = "swipe-from-left-edge"
    case swipeFromRightEdge = "swipe-from-right-edge"
    case swipeFromTopEdge = "swipe-from-top-edge"
    case swipeFromBottomEdge = "swipe-from-bottom-edge"
    
    var description: String {
        switch self {
        case .scrollUp:
            return "Scroll up in the center of screen"
        case .scrollDown:
            return "Scroll down in the center of screen"
        case .scrollLeft:
            return "Scroll left in the center of screen"
        case .scrollRight:
            return "Scroll right in the center of screen"
        case .swipeFromLeftEdge:
            return "Swipe from left edge to center (back navigation)"
        case .swipeFromRightEdge:
            return "Swipe from right edge to center (forward navigation)"
        case .swipeFromTopEdge:
            return "Swipe from top edge downward"
        case .swipeFromBottomEdge:
            return "Swipe from bottom edge upward"
        }
    }
    
    func coordinates(screenWidth: Double = 390, screenHeight: Double = 844, edgeInset: Double? = nil) -> (startX: Double, startY: Double, endX: Double, endY: Double) {
        let centerX = screenWidth / 2
        let centerY = screenHeight / 2
        let edgeMargin = 20.0
        let startInset = edgeInset ?? edgeMargin
        let scrollDistance = 200.0
        
        switch self {
        case .scrollUp:
            return (centerX, centerY + scrollDistance/2, centerX, centerY - scrollDistance/2)
        case .scrollDown:
            return (centerX, centerY - scrollDistance/2, centerX, centerY + scrollDistance/2)
        case .scrollLeft:
            return (centerX + scrollDistance/2, centerY, centerX - scrollDistance/2, centerY)
        case .scrollRight:
            return (centerX - scrollDistance/2, centerY, centerX + scrollDistance/2, centerY)
        case .swipeFromLeftEdge:
            return (startInset, centerY, screenWidth - edgeMargin, centerY)
        case .swipeFromRightEdge:
            return (screenWidth - startInset, centerY, edgeMargin, centerY)
        case .swipeFromTopEdge:
            return (centerX, startInset, centerX, screenHeight - edgeMargin)
        case .swipeFromBottomEdge:
            return (centerX, screenHeight - startInset, centerX, edgeMargin)
        }
    }
    
    /// Validate an explicit start inset without changing existing default geometry.
    /// Selected paths supply the dimensions only after the owner reads the display.
    func validateEdgeInset(_ inset: Double?, screenWidth: Double? = nil, screenHeight: Double? = nil) throws {
        guard let inset else { return }
        let length: Double?
        switch self {
        case .swipeFromLeftEdge, .swipeFromRightEdge:
            length = screenWidth
        case .swipeFromTopEdge, .swipeFromBottomEdge:
            length = screenHeight
        case .scrollUp, .scrollDown, .scrollLeft, .scrollRight:
            throw ValidationError("--edge-inset is available only for edge presets.")
        }
        guard inset.isFinite, inset > 0 else {
            throw ValidationError("Edge inset must be finite and greater than zero logical points.")
        }
        if let length {
            guard length.isFinite, length > 20, inset < length - 20 else {
                throw ValidationError("Edge inset must leave an inward path to the opposite 20-point margin.")
            }
        }
    }

    var defaultDuration: Double {
        switch self {
        case .scrollUp, .scrollDown, .scrollLeft, .scrollRight:
            return 0.5
        case .swipeFromLeftEdge, .swipeFromRightEdge, .swipeFromTopEdge, .swipeFromBottomEdge:
            return 0.3
        }
    }
    
    var defaultDelta: Double {
        switch self {
        case .scrollUp, .scrollDown, .scrollLeft, .scrollRight:
            return 25.0
        case .swipeFromLeftEdge, .swipeFromRightEdge, .swipeFromTopEdge, .swipeFromBottomEdge:
            return 50.0
        }
    }
}

enum GestureAction: ExpressibleByArgument {
    case preset(GesturePreset)
    case pinch
    case doubleTap
    case rotate
    case twoFingerTap
    case twoFingerHold
    case twoFingerSwipe

    init?(argument: String) {
        switch argument {
        case "pinch": self = .pinch; return
        case "double-tap": self = .doubleTap; return
        case "rotate": self = .rotate; return
        case "two-finger-tap": self = .twoFingerTap; return
        case "two-finger-hold": self = .twoFingerHold; return
        case "two-finger-swipe": self = .twoFingerSwipe; return
        default: break
        }
        guard let preset = GesturePreset(rawValue: argument) else { return nil }
        self = .preset(preset)
    }
}

struct Gesture: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Perform a preset or a complete coordinate gesture.",
        discussion: """
        Execute a preset, or one complete gesture with selected input (the active screen unless --screen-id/--screen-uuid guard it) or on a physical device.
        Complete gesture names: pinch, double-tap, rotate, two-finger-tap, two-finger-hold, two-finger-swipe.
        Double-tap requires -x/-y; rotate also requires --radius/--degrees.
        With --agent, double-tap instead requires a current --snapshot-id/--ref; --expected-pid is optional.
        It uses the fresh target point; the app can change between the two taps.
        Agent pinch uses a current area reference plus --radius/--scale, without -x/-y.
        Both starts are checked before input; folding/rotation checks and owned release continue during motion.
        Two-finger actions require -x/-y/--x2/--y2; hold also requires --hold.
        Two-finger-swipe also requires --end-x/--end-y/--end-x2/--end-y2.
        Both straight paths share duration and delta; either finger may stay still.
        Contacts must remain distinct at the same time; crossing at different times is allowed.
        Two-finger-swipe is standalone only; batch rejects it.
        Edge presets accept --edge-inset for the start only (default 20 logical points).
        The opposite endpoint remains 20 points from its edge. No Back action is inferred.
        With --edge-inset, legacy input requires the path span to be at least --delta.
        No retained token or app-recognizer completion is implied.
        Coordinate pinch requires -x, -y, --radius and --scale. Simulators also require selected input.
        Scale below 1 moves fingers inward; above 1 moves them outward. Scale 1 fails.
        Pinch defaults: duration 0.6 seconds, delta 5 logical points; no retained token.
        
        Available presets:
          scroll-up, scroll-down, scroll-left, scroll-right
          swipe-from-left-edge, swipe-from-right-edge
          swipe-from-top-edge, swipe-from-bottom-edge
        
        Examples:
          axe gesture scroll-up --udid SIMULATOR_UDID
          axe gesture scroll-down --duration 1.5 --udid SIMULATOR_UDID
          axe gesture swipe-from-left-edge --screen-width 430 --screen-height 932 --udid SIMULATOR_UDID
        """
    )
    
    @Argument(help: "A preset, pinch, double-tap, rotate, two-finger-tap, two-finger-hold or two-finger-swipe.")
    var gesture: GestureAction

    @Option(name: .customShort("x"), help: "Selected gesture center or first contact X in logical points.")
    var centerX: Double?

    @Option(name: .customShort("y"), help: "Selected gesture center or first contact Y in logical points.")
    var centerY: Double?

    @Option(name: .long, help: "Pinch/rotate only: explicit positive radius in logical points.")
    var radius: Double?

    @Option(name: .long, help: "Pinch only: final radius divided by starting radius; positive and not 1.")
    var scale: Double?
    
    @Option(name: .long, help: "Rotate only: nonzero clockwise angle in -360...360 degrees.")
    var degrees: Double?

    @Option(name: .customLong("x2"), help: "Two-finger actions only: second contact X in logical points.")
    var secondX: Double?

    @Option(name: .customLong("y2"), help: "Two-finger actions only: second contact Y in logical points.")
    var secondY: Double?

    @Option(name: .customLong("end-x"), help: "Two-finger-swipe only: first contact end X in logical points.")
    var endX: Double?

    @Option(name: .customLong("end-y"), help: "Two-finger-swipe only: first contact end Y in logical points.")
    var endY: Double?

    @Option(name: .customLong("end-x2"), help: "Two-finger-swipe only: second contact end X in logical points.")
    var secondEndX: Double?

    @Option(name: .customLong("end-y2"), help: "Two-finger-swipe only: second contact end Y in logical points.")
    var secondEndY: Double?

    @Option(name: .long, help: "Contact hold in seconds (0, 10]; required for two-finger-hold.")
    var hold: Double?

    @Option(name: .long, help: "Double-tap only: release-to-next-down interval (0, 10], default 0.1 seconds.")
    var interval: Double?

    @Option(name: .long, help: "Edge presets only: positive start inset in logical points (default 20); opposite inset stays 20.")
    var edgeInset: Double?

    @Option(name: .customLong("screen-width"), help: "Screen width in points (default: 390 for iPhone 15).")
    var screenWidth: Double?
    
    @Option(name: .customLong("screen-height"), help: "Screen height in points (default: 844 for iPhone 15).")
    var screenHeight: Double?
    
    @Option(name: .customLong("duration"), help: "Motion duration in seconds (preset default, or 0.6 for pinch/rotate/two-finger-swipe).")
    var duration: Double?
    
    @Option(name: .customLong("delta"), help: "Preset touch spacing; pinch/rotate/two-finger-swipe use maximum spacing in logical points (default 5).")
    var delta: Double?
    
    @Option(name: .customLong("pre-delay"), help: "Delay before starting the gesture in seconds.")
    var preDelay: Double?
    
    @Option(name: .customLong("post-delay"), help: "Delay after completing the gesture in seconds.")
    var postDelay: Double?
    
    @Option(name: .customLong("udid"), help: "The UDID of the simulator or physical device.")
    var simulatorUDID: String

    @OptionGroup var selectedInput: SelectedInputOptions
    @OptionGroup var selectedOutput: SelectedOutputOptions
    @OptionGroup var agentMode: AgentModeOptions

    @Option(name: .customLong("expected-pid"), help: "Agent gesture only: optional assertion of the snapshot owner PID.")
    var expectedPID: Int32?

    func validate() throws {
        try agentMode.validate()
        if agentMode.enabled {
            try validateAgentGesture()
            return
        }
        guard expectedPID == nil else {
            throw ValidationError("--expected-pid requires gesture double-tap or pinch --agent.")
        }
        try selectedInput.validate()
        let physical = AutomationTarget.isPhysicalInputUDID(simulatorUDID)
        if let edgeInset {
            guard case let .preset(preset) = gesture else {
                throw ValidationError("--edge-inset is available only for edge presets.")
            }
            if selectedInput.mode == .selected || physical {
                try preset.validateEdgeInset(edgeInset)
            } else {
                try preset.validateEdgeInset(edgeInset, screenWidth: screenWidth ?? 390, screenHeight: screenHeight ?? 844)
                let points = preset.coordinates(screenWidth: screenWidth ?? 390, screenHeight: screenHeight ?? 844, edgeInset: edgeInset)
                let span = hypot(points.endX - points.startX, points.endY - points.startY)
                guard span >= (delta ?? preset.defaultDelta) else {
                    throw ValidationError("Explicit legacy edge inset requires a path span at least as large as delta.")
                }
            }
        }
        if endX != nil || endY != nil || secondEndX != nil || secondEndY != nil {
            guard case .twoFingerSwipe = gesture else {
                throw ValidationError("Contact endpoints are available only for two-finger-swipe.")
            }
        }
        switch gesture {
        case .pinch:
            guard degrees == nil, secondX == nil, secondY == nil, hold == nil, interval == nil else {
                throw ValidationError("Pinch does not accept rotation or contact-hold options.")
            }
            guard physical || selectedInput.mode == .selected, screenWidth == nil, screenHeight == nil else {
                throw ValidationError("Simulator pinch requires selected input. Pinch does not accept screen dimension overrides.")
            }
            try selectedPinch().validate()
        case .preset:
            guard centerX == nil, centerY == nil, radius == nil, scale == nil,
                  degrees == nil, secondX == nil, secondY == nil, hold == nil, interval == nil else {
                throw ValidationError("Explicit geometry and contact timing are not preset options.")
            }
            if selectedInput.mode == .selected { try selectedPath().validate() }
        case .doubleTap, .rotate, .twoFingerTap, .twoFingerHold, .twoFingerSwipe:
            guard physical || selectedInput.mode == .selected, screenWidth == nil, screenHeight == nil else {
                throw ValidationError("Complete simulator gestures require selected input. Complete gestures do not accept screen dimension overrides.")
            }
            try selectedCompleteGesture().validate()
        }
        // Validate screen dimensions if provided
        if let screenWidth = screenWidth {
            guard screenWidth > 0 && screenWidth <= 2000 else {
                throw ValidationError("Screen width must be between 1 and 2000 points.")
            }
        }
        
        if let screenHeight = screenHeight {
            guard screenHeight > 0 && screenHeight <= 3000 else {
                throw ValidationError("Screen height must be between 1 and 3000 points.")
            }
        }
        
        // Validate duration if provided
        if let duration = duration {
            guard duration > 0 && duration <= 10.0 else {
                throw ValidationError("Duration must be between 0 and 10 seconds.")
            }
        }
        
        // Validate delta if provided
        if let delta = delta {
            guard delta > 0 && delta <= 200 else {
                throw ValidationError("Delta must be between 1 and 200 pixels.")
            }
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

    func selectedPath() throws -> SelectedHIDPath {
        guard case let .preset(preset) = gesture else {
            throw ValidationError("Pinch is not a preset path.")
        }
        return SelectedHIDPath(kind: .preset, preset: preset, duration: duration ?? preset.defaultDuration,
            delta: delta ?? preset.defaultDelta, preDelay: preDelay ?? 0, postDelay: postDelay ?? 0,
            expectedWidth: screenWidth, expectedHeight: screenHeight, edgeInset: edgeInset)
    }

    func selectedPinch() throws -> SelectedHIDPinch {
        guard case .pinch = gesture, let centerX, let centerY, let radius, let scale else {
            throw ValidationError("Pinch requires explicit -x, -y, --radius and --scale.")
        }
        return SelectedHIDPinch(centerX: centerX, centerY: centerY, scale: scale, radius: radius,
            duration: duration ?? 0.6, spacing: delta ?? 5, preDelay: preDelay ?? 0, postDelay: postDelay ?? 0)
    }

    func selectedCompleteGesture() throws -> SelectedHIDCompleteGesture {
        guard let centerX, let centerY, scale == nil else {
            throw ValidationError("Complete gestures require explicit -x/-y and do not accept --scale.")
        }
        let point = SelectedHIDCompleteGesture.Point(x: centerX, y: centerY)
        let timing = SelectedHIDCompleteGesture.Timing(preDelay: preDelay ?? 0, postDelay: postDelay ?? 0)
        switch gesture {
        case .doubleTap:
            guard radius == nil, degrees == nil, secondX == nil, secondY == nil, duration == nil, delta == nil else {
                throw ValidationError("Double-tap accepts only its point, hold, interval and delays.")
            }
            return .doubleTap(.init(point: point, hold: hold ?? 0.06, interval: interval ?? 0.1, timing: timing))
        case .rotate:
            guard let radius, let degrees, secondX == nil, secondY == nil, hold == nil, interval == nil else {
                throw ValidationError("Rotate requires --radius/--degrees and does not accept contact-hold options.")
            }
            return .rotate(.init(center: point, radius: radius, degrees: degrees,
                duration: duration ?? 0.6, spacing: delta ?? 5, timing: timing))
        case .twoFingerSwipe:
            guard let secondX, let secondY, let endX, let endY, let secondEndX, let secondEndY,
                  radius == nil, degrees == nil, hold == nil, interval == nil else {
                throw ValidationError("Two-finger-swipe requires both start/end pairs and accepts only duration, delta and delays.")
            }
            return .twoFingerSwipe(.init(firstStart: point,
                firstEnd: .init(x: endX, y: endY), secondStart: .init(x: secondX, y: secondY),
                secondEnd: .init(x: secondEndX, y: secondEndY), duration: duration ?? 0.6,
                spacing: delta ?? 5, timing: timing))
        case .twoFingerTap, .twoFingerHold:
            guard let secondX, let secondY, radius == nil, degrees == nil, interval == nil,
                  duration == nil, delta == nil else {
                throw ValidationError("Two-finger actions require --x2/--y2 and accept only hold and delays.")
            }
            let second = SelectedHIDCompleteGesture.Point(x: secondX, y: secondY)
            if case .twoFingerHold = gesture {
                guard let hold else { throw ValidationError("Two-finger-hold requires an explicit --hold.") }
                return .twoFingerHold(.init(first: point, second: second, hold: hold, timing: timing))
            }
            return .twoFingerTap(.init(first: point, second: second, hold: hold ?? 0.1, timing: timing))
        case .pinch, .preset:
            throw ValidationError("Use the existing pinch or preset payload.")
        }
    }

    private func validateAgentGesture() throws {
        if case .pinch = gesture {
            try validateAgentPinch()
            return
        }
        try AgentModeCommandAdapter.validateContext(input: selectedInput, expectedPID: expectedPID)
        guard case .doubleTap = gesture else {
            throw ValidationError("Gesture agent mode supports double-tap and pinch only.")
        }
        guard agentMode.elementRef != nil else {
            throw ValidationError("Agent double-tap requires --snapshot-id and --ref.")
        }
        guard centerX == nil, centerY == nil, radius == nil, scale == nil, degrees == nil,
              secondX == nil, secondY == nil, endX == nil, endY == nil,
              secondEndX == nil, secondEndY == nil, edgeInset == nil,
              screenWidth == nil, screenHeight == nil, duration == nil, delta == nil else {
            throw ValidationError("Agent double-tap accepts a reference and timing only, without coordinates, geometry or dimension overrides.")
        }
        try SelectedAXDoubleTapTiming(hold: hold ?? 0.06, interval: interval ?? 0.1)
            .validate(preDelay: preDelay ?? 0, postDelay: postDelay ?? 0)
    }

    private func validateAgentPinch() throws {
        try AgentModeCommandAdapter.validateContext(input: selectedInput, expectedPID: expectedPID)
        guard agentMode.elementRef != nil, let radius, let scale else {
            throw ValidationError("Agent pinch requires --snapshot-id, --ref, --radius and --scale.")
        }
        guard centerX == nil, centerY == nil, degrees == nil, secondX == nil, secondY == nil,
              endX == nil, endY == nil, secondEndX == nil, secondEndY == nil,
              hold == nil, interval == nil, edgeInset == nil, screenWidth == nil, screenHeight == nil else {
            throw ValidationError("Agent pinch accepts an area reference, radius, scale, duration, delta and delays only; coordinates and other gesture options are not supported.")
        }
        try AgentModePinch(radius: radius, scale: scale, spacing: delta ?? 5)
            .selected(at: .zero, duration: duration ?? 0.6, preDelay: preDelay ?? 0, postDelay: postDelay ?? 0)
            .validate()
    }

    func agentRequest() throws -> SelectedHIDRequest {
        try validate()
        if case .pinch = gesture {
            guard let radius, let scale else {
                throw ValidationError("Agent pinch requires --radius and --scale.")
            }
            return try AgentModeCommandAdapter.request(AgentModeRequest(kind: .pinch,
                expectedPID: expectedPID, snapshotID: agentMode.snapshotID, ref: agentMode.elementRef,
                duration: duration ?? 0.6, preDelay: preDelay ?? 0, postDelay: postDelay ?? 0,
                pinch: .init(radius: radius, scale: scale, spacing: delta ?? 5)), input: selectedInput)
        }
        return try AgentModeCommandAdapter.request(AgentModeRequest(kind: .doubleTap,
            expectedPID: expectedPID, snapshotID: agentMode.snapshotID, ref: agentMode.elementRef,
            preDelay: preDelay ?? 0, postDelay: postDelay ?? 0,
            doubleTapTiming: .init(hold: hold ?? 0.06, interval: interval ?? 0.1)), input: selectedInput)
    }

    private func validateDeviceOptions() throws {
        try PhysicalDeviceGestures.requireCoordinateInput(selectedInput, agent: agentMode)
        if case .preset(.swipeFromRightEdge) = gesture {
            throw AutomationTarget.unsupportedOnDevice("Right edge swipe is not supported on a physical device.")
        }
    }

    func runOnDevice(_ input: PhysicalDeviceInput) async throws {
        try validateDeviceOptions()
        switch gesture {
        case .preset(let preset):
            let edge: PhysicalTouchEdge
            switch preset {
            case .swipeFromLeftEdge: edge = .left
            case .swipeFromBottomEdge: edge = .bottom
            default: edge = .none
            }
            try await PhysicalDeviceGestures.path(selectedPath(), edge: edge, on: input)
        case .pinch:
            try await PhysicalDeviceGestures.pinch(selectedPinch(), on: input)
        case .doubleTap, .rotate, .twoFingerTap, .twoFingerHold, .twoFingerSwipe:
            try await PhysicalDeviceGestures.complete(selectedCompleteGesture(), on: input)
        }
    }

    func run() async throws {
        if AutomationTarget.isPhysicalInputUDID(simulatorUDID),
           let device = try await AutomationTarget.physicalInputDevice(udid: simulatorUDID) {
            try validateDeviceOptions()
            try await PhysicalDeviceInput.withSession(for: device) { input in
                try await runOnDevice(input)
            }
            return
        }
        if agentMode.enabled {
            try AgentModeCommandAdapter.send(agentRequest(), simulatorUDID: simulatorUDID)
            return
        }
        if selectedInput.mode == .selected {
            let request: SelectedHIDRequest
            switch gesture {
            case .preset: request = try selectedInput.pathRequest(selectedPath())
            case .pinch: request = try selectedInput.pinchRequest(selectedPinch())
            case .doubleTap, .rotate, .twoFingerTap, .twoFingerHold, .twoFingerSwipe:
                request = try selectedInput.gestureRequest(selectedCompleteGesture())
            }
            try SelectedHIDBroker.printResponse(SelectedHIDBroker.send(request, simulatorUDID: simulatorUDID),
                verbose: selectedOutput.verbose)
            return
        }
        guard case let .preset(preset) = gesture else {
            throw ValidationError("Complete gestures are supported only with selected input.")
        }
        let logger = AxeLogger()
        try await setup(logger: logger)
        
        try await performGlobalSetup(logger: logger)

        // Duo and verified DTUHID devices use the broker's retained input connection.
        let route = try await LegacyDuoInput.captureRoute(
            simulatorUDID: simulatorUDID, preDelay: preDelay, logger: logger, includeVerifiedRigid: true
        )
        let context = route?.context
        let measured = route?.isDuo == true ? context : nil

        // Keep explicit overrides and rigid-device defaults; measure omitted Duo dimensions.
        let width = screenWidth ?? measured?.logicalWidth ?? 390.0
        let height = screenHeight ?? measured?.logicalHeight ?? 844.0
        
        // Get gesture coordinates
        let coords = preset.coordinates(screenWidth: width, screenHeight: height, edgeInset: edgeInset)
        
        // Use provided values or preset defaults
        let gestureDuration = duration ?? preset.defaultDuration
        let gestureDelta = delta ?? preset.defaultDelta
        
        logger.info().log("Performing \(preset.description)")
        logger.info().log("Screen size: \(width)x\(height)")
        logger.info().log("Coordinates: (\(coords.startX), \(coords.startY)) to (\(coords.endX), \(coords.endY))")
        logger.info().log("Duration: \(gestureDuration)s, Delta: \(gestureDelta)px")
        
        if let context {
            let path = LegacyDuoPath(kind: .swipe, startX: coords.startX, startY: coords.startY,
                endX: coords.endX, endY: coords.endY, duration: gestureDuration, delta: gestureDelta)
            try await LegacyDuoInput.perform(path: path, context: context,
                simulatorUDID: simulatorUDID, postDelay: postDelay, logger: logger)
            logger.info().log("Gesture completed successfully")
            return
        }

        // Create gesture events with timing controls
        var events: [FBSimulatorHIDEvent] = []
        
        // Add pre-delay if specified
        if let preDelay = preDelay, preDelay > 0 {
            logger.info().log("Pre-delay: \(preDelay)s")
            events.append(FBSimulatorHIDEvent.delay(preDelay))
        }
        
        // Add the main gesture
        let gestureEvent = FBSimulatorHIDEvent.swipe(
            coords.startX,
            yStart: coords.startY,
            xEnd: coords.endX,
            yEnd: coords.endY,
            delta: gestureDelta,
            duration: gestureDuration
        )
        events.append(gestureEvent)
        
        // Add post-delay if specified
        if let postDelay = postDelay, postDelay > 0 {
            logger.info().log("Post-delay: \(postDelay)s")
            events.append(FBSimulatorHIDEvent.delay(postDelay))
        }
        
        // Execute the gesture sequence
        let finalEvent = events.count == 1 ? events[0] : FBSimulatorHIDEvent.composite(events)
        
        try await HIDInteractor
            .performHIDEvent(
                finalEvent,
                for: simulatorUDID,
                logger: logger
            )
        
        logger.info().log("Gesture completed successfully")
    }
} 
