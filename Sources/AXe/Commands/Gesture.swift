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
    /// Down from the top right corner: Control Centre on an iPhone with Face ID and on an iPad.
    case swipeFromTopRightCorner = "swipe-from-top-right-corner"

    /// A scroll crosses this fraction of the screen's height or width when --distance is given.
    static let distanceRange = 0.05...0.95
    /// The corner preset's distance from the right edge, inside the area that opens Control Centre.
    static let cornerInset = 30.0

    var isScroll: Bool {
        switch self {
        case .scrollUp, .scrollDown, .scrollLeft, .scrollRight: return true
        default: return false
        }
    }

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
        case .swipeFromTopRightCorner:
            return "Swipe down from the top right corner (Control Centre)"
        }
    }

    /// `distance` is a scroll's length as a fraction of the screen's height (up, down) or width (left, right);
    /// nil keeps 200 points.
    func coordinates(screenWidth: Double = 390, screenHeight: Double = 844, edgeInset: Double? = nil,
                     distance: Double? = nil) -> (startX: Double, startY: Double, endX: Double, endY: Double) {
        let centerX = screenWidth / 2
        let centerY = screenHeight / 2
        let edgeMargin = 20.0
        let startInset = edgeInset ?? edgeMargin
        let vertical = self == .scrollUp || self == .scrollDown
        let scrollDistance = distance.map { $0 * (vertical ? screenHeight : screenWidth) } ?? 200.0

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
        case .swipeFromTopRightCorner:
            return (screenWidth - Self.cornerInset, startInset, screenWidth - Self.cornerInset, screenHeight / 2)
        }
    }

    func validateDistance(_ distance: Double?) throws {
        guard let distance else { return }
        guard isScroll else { throw ValidationError("--distance is available only for scroll presets.") }
        guard distance.isFinite, Self.distanceRange.contains(distance) else {
            throw ValidationError("Distance must be a fraction of the screen from 0.05 to 0.95.")
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
        case .swipeFromTopEdge, .swipeFromBottomEdge, .swipeFromTopRightCorner:
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
        case .swipeFromLeftEdge, .swipeFromRightEdge, .swipeFromTopEdge, .swipeFromBottomEdge, .swipeFromTopRightCorner:
            return 0.3
        }
    }
    
    var defaultDelta: Double {
        switch self {
        case .scrollUp, .scrollDown, .scrollLeft, .scrollRight:
            return 25.0
        case .swipeFromLeftEdge, .swipeFromRightEdge, .swipeFromTopEdge, .swipeFromBottomEdge, .swipeFromTopRightCorner:
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

struct Gesture: PhysicalDeviceCommand {
    static let configuration = CommandConfiguration(
        abstract: "Perform a preset swipe, a pinch or another multi-touch gesture.",
        discussion: """
        Presets: scroll-up, scroll-down, scroll-left, scroll-right, swipe-from-left-edge, swipe-from-right-edge, swipe-from-top-edge, swipe-from-bottom-edge and swipe-from-top-right-corner (Control Centre). A scroll preset moves 200 points, or the fraction of the screen given by --distance. With --until-id or --until-label it repeats until that element is on screen, and stops early when the content reaches its end; --inside-id or --inside-label scrolls inside one element instead of the screen. Physical devices do not support swipe-from-right-edge.

        Coordinate gestures take points in the current orientation:
          pinch             --scale, and optionally -x/-y and --radius
          double-tap        -x/-y
          rotate            -x/-y, --radius, --degrees
          two-finger-tap    -x/-y, --x2/--y2
          two-finger-hold   -x/-y, --x2/--y2, --hold
          two-finger-swipe  -x/-y, --x2/--y2, --end-x/--end-y, --end-x2/--end-y2

        A pinch without -x/-y uses the centre of the screen, and without --radius a quarter of its shorter side, or less so that both ends stay 16 points inside the screen. With --agent, double-tap and pinch act on --ref instead of coordinates.

        Examples:
          axe gesture scroll-up --udid <UDID>
          axe gesture pinch --scale 2 --udid <UDID>
          axe gesture rotate -x 200 -y 400 --radius 80 --degrees 90 --udid <UDID>
          axe gesture swipe-from-left-edge --udid <UDID>
        """
    )
    
    @Argument(help: "A preset or a coordinate gesture, listed above.")
    var gesture: GestureAction

    @Option(name: .customShort("x"), help: "Centre or first contact X in points.")
    var centerX: Double?

    @Option(name: .customShort("y"), help: "Centre or first contact Y in points.")
    var centerY: Double?

    @Option(name: .long, help: "pinch, rotate: start radius in points; required for rotate and agent pinch.")
    var radius: Double?

    @Option(name: .long, help: "pinch: end radius divided by start radius, not 1; above 1 zooms in.")
    var scale: Double?
    
    @Option(name: .long, help: "rotate: clockwise angle in degrees, -360 to 360, not 0.")
    var degrees: Double?

    @Option(name: .customLong("x2"), help: "Two-finger gestures: second contact X in points.")
    var secondX: Double?

    @Option(name: .customLong("y2"), help: "Two-finger gestures: second contact Y in points.")
    var secondY: Double?

    @Option(name: .customLong("end-x"), help: "two-finger-swipe: end X of the first contact.")
    var endX: Double?

    @Option(name: .customLong("end-y"), help: "two-finger-swipe: end Y of the first contact.")
    var endY: Double?

    @Option(name: .customLong("end-x2"), help: "two-finger-swipe: end X of the second contact.")
    var secondEndX: Double?

    @Option(name: .customLong("end-y2"), help: "two-finger-swipe: end Y of the second contact.")
    var secondEndY: Double?

    @Option(name: .long, help: "Seconds each touch is held, above 0 to 10; required for two-finger-hold.")
    var hold: Double?

    @Option(name: .long, help: "double-tap: seconds between the taps, above 0 to 10 (default 0.1).")
    var interval: Double?

    @Option(name: .long, help: "Edge presets: start distance from the edge in points (default 20).")
    var edgeInset: Double?

    @Option(name: .long, help: "Scroll presets: length as a fraction of the screen, 0.05 to 0.95 (default 200 points).")
    var distance: Double?

    @OptionGroup var until: ScrollUntilOptions

    @Option(name: .customLong("inside-id"), help: "Scroll presets: scroll inside the element with this accessibility identifier, not the screen.")
    var insideID: String?

    @Option(name: .customLong("inside-label"), help: "Scroll presets: scroll inside the element with this accessibility label, not the screen.")
    var insideLabel: String?

    /// The element a scroll preset moves inside, if any.
    var insideQuery: AccessibilityQuery? {
        if let insideID { return .id(insideID) }
        if let insideLabel { return .label(insideLabel) }
        return nil
    }

    /// A scroll inside an element crosses this fraction of it when --distance is not given.
    static let insideDistance = 0.6

    private func validateUntil() throws {
        guard insideID == nil || insideLabel == nil else {
            throw ValidationError("Pass --inside-id or --inside-label, not both.")
        }
        guard until.query != nil || insideQuery != nil else { return }
        guard case let .preset(preset) = gesture, preset.isScroll else {
            throw ValidationError("--until-id, --until-label, --inside-id and --inside-label are available only for scroll presets.")
        }
        guard !agentMode.enabled, selectedInput.mode != .selected else {
            throw ValidationError("--until-id, --until-label, --inside-id and --inside-label need plain input, without --agent or selected input.")
        }
    }

    @Option(name: .customLong("screen-width"), help: "Presets: screen width in points, up to 2000. Defaults to the measured screen in the current orientation, or 390 where it is not measured (see README).")
    var screenWidth: Double?
    
    @Option(name: .customLong("screen-height"), help: "Presets: screen height in points, up to 3000. Defaults to the measured screen in the current orientation, or 844 where it is not measured (see README).")
    var screenHeight: Double?
    
    @Option(name: .customLong("duration"), help: "Seconds the motion takes, above 0 to 10 (default 0.5 scroll, 0.3 edge, 0.6 pinch, rotate, two-finger-swipe).")
    var duration: Double?
    
    @Option(name: .customLong("delta"), help: "Distance between touch samples in points, up to 200 (default 25 scroll, 50 edge, 5 pinch, rotate, two-finger-swipe).")
    var delta: Double?
    
    @Option(name: .customLong("pre-delay"), help: "Seconds to wait before the gesture, 0 to 10.")
    var preDelay: Double?
    
    @Option(name: .customLong("post-delay"), help: "Seconds to wait after the gesture, 0 to 10.")
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
            try validateAgentGesture()
            return
        }
        guard expectedPID == nil else {
            throw ValidationError("--expected-pid requires gesture double-tap or pinch --agent.")
        }
        try selectedInput.validate()
        let physical = AutomationTarget.isPhysicalInputUDID(simulatorUDID)
        try validateUntil()
        if let distance {
            guard case let .preset(preset) = gesture else {
                throw ValidationError("--distance is available only for scroll presets.")
            }
            try preset.validateDistance(distance)
        }
        if let edgeInset {
            guard case let .preset(preset) = gesture else {
                throw ValidationError("--edge-inset is available only for edge presets.")
            }
            try preset.validateEdgeInset(edgeInset)
            // The ordinary route checks the span on the size it uses: here when both dimensions are
            // explicit, otherwise once it has measured the display or chosen 390×844.
            if selectedInput.mode != .selected, !physical, screenWidth != nil, screenHeight != nil {
                _ = try legacySwipe(preset, measured: nil)
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
            guard screenWidth == nil, screenHeight == nil else {
                throw ValidationError("Pinch does not accept screen dimension overrides.")
            }
            try selectedPinch().validate()
        case .preset:
            guard centerX == nil, centerY == nil, radius == nil, scale == nil,
                  degrees == nil, secondX == nil, secondY == nil, hold == nil, interval == nil else {
                throw ValidationError("Explicit geometry and contact timing are not preset options.")
            }
            if selectedInput.mode == .selected { try selectedPath().validate() }
        case .doubleTap, .rotate, .twoFingerTap, .twoFingerHold, .twoFingerSwipe:
            guard screenWidth == nil, screenHeight == nil else {
                throw ValidationError("Coordinate gestures do not accept screen dimension overrides.")
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

    /// The ordinary preset swipe on explicit dimensions, else the measured display, else 390×844.
    struct LegacySwipe {
        let width, height, startX, startY, endX, endY, duration, delta: Double

        /// The HID swipe with the requested delays around it.
        func event(preDelay: Double?, postDelay: Double?, endsAtRest: Bool = false) -> FBSimulatorHIDEvent {
            var events: [FBSimulatorHIDEvent] = []
            if let preDelay, preDelay > 0 { events.append(.delay(preDelay)) }
            if endsAtRest {
                events += SelectedHIDPath.restingSwipe(from: CGPoint(x: startX, y: startY), to: CGPoint(x: endX, y: endY),
                    duration: duration, delta: delta).map(\.event)
            } else {
                events.append(.swipe(startX, yStart: startY, xEnd: endX, yEnd: endY, delta: delta, duration: duration))
            }
            if let postDelay, postDelay > 0 { events.append(.delay(postDelay)) }
            return events.count == 1 ? events[0] : .composite(events)
        }
    }

    /// An explicit edge inset also needs a path span of at least the delta on the dimensions used.
    func legacySwipe(_ preset: GesturePreset, measured: (width: Double, height: Double)?) throws -> LegacySwipe {
        let width = screenWidth ?? measured?.width ?? 390
        let height = screenHeight ?? measured?.height ?? 844
        let points = preset.coordinates(screenWidth: width, screenHeight: height, edgeInset: edgeInset, distance: distance)
        let swipeDelta = delta ?? preset.defaultDelta
        if let edgeInset {
            try preset.validateEdgeInset(edgeInset, screenWidth: width, screenHeight: height)
            guard hypot(points.endX - points.startX, points.endY - points.startY) >= swipeDelta else {
                throw ValidationError("Explicit legacy edge inset requires a path span at least as large as delta.")
            }
        }
        return LegacySwipe(width: width, height: height, startX: points.startX, startY: points.startY,
            endX: points.endX, endY: points.endY, duration: duration ?? preset.defaultDuration, delta: swipeDelta)
    }

    private var isPreset: Bool {
        if case .preset = gesture { return true }
        return false
    }

    func selectedPath() throws -> SelectedHIDPath {
        guard case let .preset(preset) = gesture else {
            throw ValidationError("Pinch is not a preset path.")
        }
        return SelectedHIDPath(kind: .preset, preset: preset, duration: duration ?? preset.defaultDuration,
            delta: delta ?? preset.defaultDelta, preDelay: preDelay ?? 0, postDelay: postDelay ?? 0,
            expectedWidth: screenWidth, expectedHeight: screenHeight, edgeInset: edgeInset, distance: distance)
    }

    func selectedPinch() throws -> SelectedHIDPinch {
        guard case .pinch = gesture, let scale else {
            throw ValidationError("Pinch requires --scale: above 1 zooms in, below 1 zooms out.")
        }
        guard (centerX == nil) == (centerY == nil) else {
            throw ValidationError("Pass both -x and -y, or neither to pinch at the centre of the screen.")
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

    func validateOnDevice(inBatch: Bool) throws {
        if inBatch, !isPreset {
            throw AutomationTarget.unsupportedOnDevice("Physical batch gesture steps require a preset.")
        }
        try selectedInput.refuseOnDevice(agent: agentMode.enabled)
        guard insideQuery == nil else {
            throw AutomationTarget.unsupportedOnDevice("--inside-id and --inside-label are not supported on a physical device. Use swipe with coordinates and --until-label.")
        }
        if case .preset(.swipeFromRightEdge) = gesture {
            throw AutomationTarget.unsupportedOnDevice("Right edge swipe is not supported on a physical device.")
        }
    }

    func runOnDevice(_ input: PhysicalDeviceInput) async throws {
        switch gesture {
        case .preset(let preset):
            let edge: PhysicalTouchEdge
            switch preset {
            case .swipeFromLeftEdge: edge = .left
            case .swipeFromBottomEdge: edge = .bottom
            case .swipeFromTopRightCorner: edge = .top
            default: edge = .none
            }
            if let query = until.query {
                try await until.run(query, waitsForRest: false,
                    observe: { try await PhysicalAccessibilityCommands.observe(query, on: input) },
                    scroll: {
                        // Each step ends at rest; see `Swipe.restingPath`.
                        var path = try selectedPath()
                        path.endsAtRest = true
                        // A scroll preset is at least 200 points long; 25 points a move gives eight or more.
                        path.delta = min(path.delta ?? 50, 25)
                        try await PhysicalDeviceGestures.path(path, edge: edge, on: input)
                    })
            } else {
                try await PhysicalDeviceGestures.path(selectedPath(), edge: edge, on: input)
            }
        case .pinch:
            try await PhysicalDeviceGestures.pinch(selectedPinch(), on: input)
        case .doubleTap, .rotate, .twoFingerTap, .twoFingerHold, .twoFingerSwipe:
            try await PhysicalDeviceGestures.complete(selectedCompleteGesture(), on: input)
        }
    }

    func run() async throws {
        if try await runOnDeviceIfTargeted() { return }
        if agentMode.enabled {
            try AgentModeCommandAdapter.send(agentRequest(), simulatorUDID: simulatorUDID)
            return
        }
        // Coordinate gestures always use the owned input session, bound to the active screen unless
        // --screen-id/--screen-uuid guard it. A preset keeps its ordinary route without selected input.
        if selectedInput.mode == .selected || !isPreset {
            var owned = selectedInput
            owned.mode = .selected
            let request: SelectedHIDRequest
            switch gesture {
            case .preset: request = try owned.pathRequest(selectedPath())
            case .pinch: request = try owned.pinchRequest(selectedPinch())
            case .doubleTap, .rotate, .twoFingerTap, .twoFingerHold, .twoFingerSwipe:
                request = try owned.gestureRequest(selectedCompleteGesture())
            }
            try SelectedHIDBroker.printResponse(SelectedHIDBroker.send(request, simulatorUDID: simulatorUDID),
                verbose: selectedOutput.verbose)
            return
        }
        guard case let .preset(preset) = gesture else {
            throw ValidationError("Only a preset uses the ordinary swipe route.")
        }
        let logger = AxeLogger()
        try await setup(logger: logger)
        
        try await performGlobalSetup(logger: logger)

        // Duo and verified DTUHID devices use the broker's retained input connection.
        let route = try await OrdinaryBrokerInput.captureRoute(
            simulatorUDID: simulatorUDID, preDelay: preDelay, logger: logger, includeVerifiedRigid: true
        )
        let context = route?.context

        // Explicit overrides win; omitted dimensions use the display the route already measured.
        // A route without a measured context (older rigid input) keeps 390×844.
        var swipe = try legacySwipe(preset, measured: context.map { ($0.logicalWidth, $0.logicalHeight) })
        if let insideQuery {
            // The same preset, laid out inside the element's frame instead of the screen.
            let match = try await AccessibilityPoller.resolveElementWithPolling(query: insideQuery,
                simulatorUDID: simulatorUDID, waitTimeout: 0, pollInterval: 0.25, logger: logger)
            guard let frame = match.element.frame, frame.width > 0, frame.height > 0 else {
                throw CLIError(errorDescription: "The element to scroll inside has no frame.", code: .elementNotFound)
            }
            let inside = preset.coordinates(screenWidth: frame.width, screenHeight: frame.height,
                distance: distance ?? Self.insideDistance)
            swipe = LegacySwipe(width: swipe.width, height: swipe.height, startX: frame.x + inside.startX,
                startY: frame.y + inside.startY, endX: frame.x + inside.endX, endY: frame.y + inside.endY,
                duration: swipe.duration, delta: min(swipe.delta, max(5, hypot(inside.endX - inside.startX, inside.endY - inside.startY) / 4)))
        }
        logger.info().log("Performing \(preset.description)")
        logger.info().log("Screen size: \(swipe.width)x\(swipe.height)")
        logger.info().log("Coordinates: (\(swipe.startX), \(swipe.startY)) to (\(swipe.endX), \(swipe.endY))")
        logger.info().log("Duration: \(swipe.duration)s, Delta: \(swipe.delta)px")

        if let query = until.query {
            // The route capture above already waited the pre-delay; each scroll then goes out alone.
            try await until.run(query, observe: {
                try await ScrollUntilOptions.observe(query, simulatorUDID: simulatorUDID, logger: logger)
            }) {
                // Each step ends at rest; see `Swipe.restingPath`.
                if let context {
                    let path = SelectedHIDPath(kind: .swipe, startX: swipe.startX, startY: swipe.startY,
                        endX: swipe.endX, endY: swipe.endY, duration: swipe.duration, delta: swipe.delta,
                        endsAtRest: true, generator: .ordinary)
                    try await OrdinaryBrokerInput.perform(path: path, context: context,
                        simulatorUDID: simulatorUDID, postDelay: nil, logger: logger, verbose: false)
                } else {
                    try await HIDInteractor.performHIDEvent(swipe.event(preDelay: nil, postDelay: nil, endsAtRest: true),
                        for: simulatorUDID, logger: logger)
                }
            }
            if let postDelay, postDelay > 0 { try await Task.sleep(for: .seconds(postDelay)) }
            return
        }

        if let context {
            let path = SelectedHIDPath(kind: .swipe, startX: swipe.startX, startY: swipe.startY,
                endX: swipe.endX, endY: swipe.endY, duration: swipe.duration, delta: swipe.delta, generator: .ordinary)
            try await OrdinaryBrokerInput.perform(path: path, context: context,
                simulatorUDID: simulatorUDID, postDelay: postDelay, logger: logger, verbose: selectedOutput.verbose)
            logger.info().log("Gesture completed successfully")
            return
        }

        try await HIDInteractor.performHIDEvent(swipe.event(preDelay: preDelay, postDelay: postDelay),
            for: simulatorUDID, logger: logger)
        logger.info().log("Gesture completed successfully")
    }
} 
