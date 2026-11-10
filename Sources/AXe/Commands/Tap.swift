import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl

struct Tap: PhysicalDeviceCommand {
    static let configuration = CommandConfiguration(
        abstract: "Tap a point, or an element found by accessibility.",
        discussion: """
        Pass -x and -y, or one of --id, --label and --value; --element-type narrows a selector. On success it prints the tapped point. --hold makes a long press, --count 2 a double tap and --touches 2 a two-finger tap, on a point or on an element.

        Examples:
          axe tap -x 200 -y 400 --udid <UDID>
          axe tap --id SaveButton --element-type Button --udid <UDID>
          axe tap --label Done --wait-timeout 5 --udid <UDID>
          axe tap --label Photo --hold 1 --udid <UDID>          # long press
          axe tap --id Map --count 2 --udid <UDID>              # double tap
          axe tap --id Canvas --touches 2 --udid <UDID>         # two-finger tap
        """
    )

    @Flag(name: .customLong("semantic-press"), help: "Press the native CheckBox with this --id through accessibility and confirm its value changed. Simulators need --input-mode selected.")
    var semanticPress = false

    @Option(name: .customShort("x"), help: "X coordinate of the tap in points.")
    var pointX: Double?

    @Option(name: .customShort("y"), help: "Y coordinate of the tap in points.")
    var pointY: Double?

    @Option(name: [.customLong("id")], help: "Tap the element with this accessibility identifier.")
    var elementID: String?

    @Option(name: [.customLong("label")], help: "Tap the element with this accessibility label.")
    var elementLabel: String?

    @Option(name: [.customLong("value")], help: "Tap the element with this accessibility value.")
    var elementValue: String?

    @Option(name: .customLong("label-contains"), help: "Agent only: tap the one element whose label contains this text (case-sensitive).")
    var labelContains: String?

    @Option(name: .customLong("label-regex"), help: "Agent only: tap the one element whose label matches this regular expression, at most 128 bytes.")
    var labelRegex: String?

    @Option(name: .customLong("frame"), help: "Agent only: keep selector matches inside these bounds in points, such as minY=100,maxY=400.")
    var selectorFrame: String?

    @Option(name: [.customLong("element-type")], help: "Only match elements of this accessibility type, such as Button or Switch.")
    var elementType: String?

    @Option(name: .customLong("pre-delay"), help: "Seconds to wait before the tap, 0 to 10.")
    var preDelay: Double?

    @Option(name: .customLong("post-delay"), help: "Seconds to wait after the tap, 0 to 10.")
    var postDelay: Double?

    @Option(name: .customLong("hold"), help: "Seconds the finger stays down, above 0 to 10: a long press.")
    var hold: Double?

    @Option(name: .customLong("count"), help: "Taps in a row, 1 or 2; 2 is a double tap.")
    var count: Int = 1

    @Option(name: .customLong("touches"), help: "Fingers, 1 or 2; 2 is a two-finger tap, 40 points apart around the point.")
    var touches: Int = 1

    @Option(name: .customLong("tap-style"), help: "Event style: automatic touches switches and sends a simulator tap otherwise; physical always touches; simulator always sends a simulator tap. Default automatic, or physical with selected input or --agent.")
    var tapStyle: TapStyle?

    @Option(name: .customLong("wait-timeout"), help: "Seconds to wait for an --id, --label or --value match to appear; at most 30 with selected input.")
    var waitTimeout: Double = 0

    @Option(name: .customLong("poll-interval"), help: "Seconds between accessibility reads while waiting (default 0.25; 0.05 to 30 with selected input).")
    var pollInterval: Double?

    @Option(name: .customLong("udid"), help: "UDID of the simulator or physical device.")
    var simulatorUDID: String


    @OptionGroup var selectedInput: SelectedInputOptions
    @OptionGroup var selectedOutput: SelectedOutputOptions
    @OptionGroup var selectedAX: SelectedAXOptions
    @OptionGroup var agentMode: AgentModeOptions

    /// Half the distance between the two contacts of a two-finger tap.
    static let twoFingerHalfSpread = 20.0

    /// A long press, a double tap or a two-finger tap, rather than one quick tap.
    var isTouchGesture: Bool { hold != nil || count != 1 || touches != 1 }

    private func validateTouchGesture() throws {
        if let hold {
            guard hold.isFinite, hold > 0, hold <= 10 else {
                throw ValidationError("Hold must be above 0 and at most 10 seconds.")
            }
        }
        guard (1...2).contains(count) else { throw ValidationError("Count must be 1 or 2.") }
        guard (1...2).contains(touches) else { throw ValidationError("Touches must be 1 or 2.") }
        guard isTouchGesture else { return }
        guard count == 1 || touches == 1 else {
            throw ValidationError("A double tap takes one finger: pass --count 2 or --touches 2, not both.")
        }
        guard !semanticPress, tapStyle == nil || tapStyle == .physical else {
            throw ValidationError("--hold, --count and --touches send real touches: remove --semantic-press and --tap-style.")
        }
        guard !agentMode.enabled, selectedInput.mode != .selected else {
            throw ValidationError("--hold, --count and --touches need plain input. With --agent or selected input, use touch or gesture with a point or --ref.")
        }
    }

    /// The contacts of the tap around `point`: one, or two side by side kept on the screen's left edge.
    static func contacts(at point: CGPoint, touches: Int) -> [CGPoint] {
        guard touches == 2 else { return [point] }
        let centre = max(point.x, twoFingerHalfSpread)
        return [CGPoint(x: centre - twoFingerHalfSpread, y: point.y), CGPoint(x: centre + twoFingerHalfSpread, y: point.y)]
    }

    /// The device touch plan for a long press, a double tap or a two-finger tap at `point`.
    func deviceSteps(at point: CGPoint) -> [PhysicalTouchStep] {
        let points = Self.contacts(at: point, touches: touches)
        return (0..<count).flatMap { index in
            [PhysicalTouchStep(points: points, phase: .down, delayAfter: hold ?? 0.05),
             PhysicalTouchStep(points: points, phase: .up, delayAfter: index + 1 < count ? 0.1 : 0)]
        }
    }

    /// The sibling command that performs this tap's gesture on a simulator, as its arguments.
    func simulatorGestureArguments(at point: (x: Double, y: Double)) -> [String] {
        let contacts = Self.contacts(at: CGPoint(x: point.x, y: point.y), touches: touches)
        let first = ["-x", String(Double(contacts[0].x)), "-y", String(Double(contacts[0].y))]
        let target = ["--udid", simulatorUDID]
        if touches == 2 {
            let second = ["--x2", String(Double(contacts[1].x)), "--y2", String(Double(contacts[1].y))]
            if let hold { return ["gesture", "two-finger-hold"] + first + second + ["--hold", String(hold)] + target }
            return ["gesture", "two-finger-tap"] + first + second + target
        }
        if count == 2 {
            return ["gesture", "double-tap"] + first + (hold.map { ["--hold", String($0)] } ?? []) + target
        }
        return ["touch"] + first + ["--down", "--up", "--delay", String(hold ?? 0.1)] + target
    }

    func validate() throws {
        try validateTouchGesture()
        if AutomationTarget.isPhysicalInputUDID(simulatorUDID) {
            if hasSimulatorOnlyOptions || (!semanticPress && tapStyle == .simulator) { return }
            if semanticPress {
                _ = try physicalSemanticIdentifier()
                return
            }
        }
        try agentMode.validate()
        if agentMode.enabled {
            try validateAgent()
            return
        }
        guard labelContains == nil, labelRegex == nil, selectorFrame == nil else {
            throw ValidationError("--label-contains, --label-regex and --frame require --agent.")
        }
        try selectedInput.validate()
        if semanticPress {
            guard selectedInput.mode == .selected, elementID != nil, elementLabel == nil, elementValue == nil,
                  pointX == nil, pointY == nil, preDelay == nil, postDelay == nil else {
                throw ValidationError("--semantic-press requires selected input, one exact --id and no coordinates, label, value or delays.")
            }
        }
        if selectedInput.mode == .selected {
            guard tapStyle == nil || (!semanticPress && (tapStyle == .physical || tapStyle == .simulator || tapStyle == .automatic)) else {
                throw ValidationError("Selected ordinary tap supports omitted style, physical, simulator or automatic. Semantic press rejects explicit styles.")
            }
            let hasCoordinates = pointX != nil || pointY != nil
            _ = try selectedWaitPolicy(hasCoordinates: hasCoordinates)
            if let elementType {
                guard !hasCoordinates, !semanticPress,
                      !elementType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ValidationError("Selected --element-type requires an ordinary ID/label/value tap and a nonempty type.")
                }
            }
            if hasCoordinates, elementID != nil || elementLabel != nil || elementValue != nil {
                throw ValidationError("Selected tap cannot mix coordinates and selectors.")
            }
            try selectedAX.validate(allowed: !hasCoordinates)
        } else {
            try selectedAX.validate(allowed: false)
        }
        if pointX != nil || pointY != nil {
            guard let pointX, let pointY else {
                throw ValidationError("Both -x and -y must be provided together.")
            }
            guard pointX >= 0, pointY >= 0 else {
                throw ValidationError("Coordinates must be non-negative values.")
            }
        } else {
            let selectorCount = [elementID != nil, elementLabel != nil, elementValue != nil].filter { $0 }.count
            if selectorCount == 0 {
                throw ValidationError("Either provide both -x/-y, or use --id/--label/--value to tap an element.")
            }
            if selectorCount > 1 {
                throw ValidationError("Use only one of --id, --label, or --value.")
            }
            if let elementID, elementID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError("--id must not be empty.")
            }
            if let elementLabel, elementLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError("--label must not be empty.")
            }
            if let elementValue, elementValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError("--value must not be empty.")
            }
        }


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

        guard waitTimeout >= 0 else {
            throw ValidationError("--wait-timeout must be non-negative.")
        }

        if waitTimeout > 0, let pollInterval {
            guard pollInterval > 0 else {
                throw ValidationError("--poll-interval must be greater than 0 when --wait-timeout is active.")
            }
        }
    }

    private func validateAgent() throws {
        try AgentModeCommandAdapter.validateContext(input: selectedInput, expectedPID: selectedAX.expectedPID)
        guard !semanticPress, waitTimeout == 0, pollInterval == nil else {
            throw ValidationError("Agent tap does not accept semantic press or polling overrides.")
        }
        let selectors = [elementID, elementLabel, elementValue, labelContains, labelRegex].compactMap { $0 }
        let hasPoint = pointX != nil || pointY != nil
        let targetCount = (agentMode.elementRef == nil ? 0 : 1) + (hasPoint ? 1 : 0) + selectors.count
        guard targetCount == 1 else {
            throw ValidationError("Agent tap requires one ref, one selector, or one coordinate pair.")
        }
        if hasPoint {
            guard let pointX, let pointY, pointX.isFinite, pointY.isFinite, pointX >= 0, pointY >= 0 else {
                throw ValidationError("Agent coordinates require finite non-negative -x and -y.")
            }
            try agentMode.requireSnapshot()
        }
        if let selector = selectors.first, selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("Agent selectors must not be empty.")
        }
        if let elementType {
            guard !hasPoint, agentMode.elementRef == nil,
                  !elementType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError("Agent --element-type requires an explicit selector and a nonempty type.")
            }
        }
        do { _ = try extendedAgentSelector() }
        catch let error as AgentModeFailure { throw ValidationError(error.message) }
        try AgentModeCommandAdapter.validateDelay(preDelay, name: "--pre-delay")
        try AgentModeCommandAdapter.validateDelay(postDelay, name: "--post-delay")
    }

    func agentRequest() throws -> SelectedHIDRequest {
        let extended = try extendedAgentSelector()
        let selectorKind: SelectedAXRequest.SelectorKind?
        if extended != nil { selectorKind = nil }
        else if elementID != nil { selectorKind = .id }
        else if elementLabel != nil { selectorKind = .label }
        else if elementValue != nil { selectorKind = .value }
        else { selectorKind = nil }
        let point: SelectedAXPoint?
        if let pointX, let pointY { point = SelectedAXPoint(x: pointX, y: pointY) }
        else { point = nil }
        let style: SelectedTapStyle
        switch tapStyle {
        case .physical, nil: style = .physical
        case .simulator: style = .simulator
        case .automatic: style = .automatic
        }
        return try AgentModeCommandAdapter.request(AgentModeRequest(kind: .tap,
            expectedPID: selectedAX.expectedPID, snapshotID: agentMode.snapshotID, ref: agentMode.elementRef,
            point: point, selectorKind: selectorKind,
            selectorValue: extended == nil ? elementID ?? elementLabel ?? elementValue : nil,
            tapSelector: extended,
            elementType: elementType, preDelay: preDelay ?? 0, postDelay: postDelay ?? 0, tapStyle: style),
            input: selectedInput)
    }

    private func extendedAgentSelector() throws -> AgentModeTapSelector? {
        guard labelContains != nil || labelRegex != nil || selectorFrame != nil else { return nil }
        let candidates: [(AgentModeTapSelector.Kind, String?)] = [
            (.id, elementID), (.label, elementLabel), (.value, elementValue),
            (.labelContains, labelContains), (.labelRegex, labelRegex),
        ]
        let provided = candidates.compactMap { kind, value in value.map { (kind, $0) } }
        guard provided.count == 1, pointX == nil, pointY == nil, agentMode.elementRef == nil else {
            throw ValidationError("Agent label patterns and --frame require one explicit selector, without a ref or coordinates.")
        }
        let frame = try selectorFrame.map { try AgentModeFrameFilter(specification: $0) }
        let selector = AgentModeTapSelector(kind: provided[0].0, query: provided[0].1, frame: frame)
        try selector.validate()
        return selector
    }

    func selectedRequest() throws -> SelectedHIDRequest {
        let waitPolicy = try selectedWaitPolicy(hasCoordinates: pointX != nil || pointY != nil)
        let selectedStyle: SelectedTapStyle?
        switch tapStyle {
        case .automatic: selectedStyle = .automatic
        case .simulator: selectedStyle = .simulator
        case .physical, nil: selectedStyle = nil
        }
        if let selectorValue = elementID ?? elementLabel ?? elementValue {
            let selectorKind: SelectedAXRequest.SelectorKind
            if elementID != nil { selectorKind = .id }
            else if elementLabel != nil { selectorKind = .label }
            else { selectorKind = .value }
            return try selectedAX.request(input: selectedInput, kind: semanticPress ? .semanticPress : .tap,
                selectorKind: selectorKind, selectorValue: selectorValue,
                preDelay: preDelay ?? 0, postDelay: postDelay ?? 0, elementType: elementType, tapStyle: selectedStyle,
                waitPolicy: waitPolicy)
        }
        guard let pointX, let pointY else { throw ValidationError("Selected tap requires coordinates or one selector") }
        var primitives: [SelectedHIDPrimitive] = []
        if let preDelay { primitives.append(.delay(preDelay)) }
        let coordinateStyle = try (selectedStyle ?? .physical).resolved(for: nil)
        primitives += try coordinateStyle.primitives(x: pointX, y: pointY)
        if let postDelay { primitives.append(.delay(postDelay)) }
        return try selectedInput.request(operation: .complete, token: nil, primitives: primitives)
    }

    private func selectedWaitPolicy(hasCoordinates: Bool) throws -> SelectedAXWaitPolicy? {
        if hasCoordinates || semanticPress {
            guard waitTimeout == 0, pollInterval == nil else {
                throw ValidationError("Selected coordinate taps and semantic press do not support polling options.")
            }
            return nil
        }
        guard waitTimeout.isFinite, waitTimeout >= 0, waitTimeout <= SelectedAXWaitPolicy.maximumTimeout else {
            throw ValidationError("Selected --wait-timeout must be finite and in 0...30 seconds.")
        }
        guard waitTimeout > 0 else {
            guard pollInterval == nil else {
                throw ValidationError("Selected --poll-interval requires a positive --wait-timeout.")
            }
            return nil
        }
        let policy = SelectedAXWaitPolicy(timeoutSeconds: waitTimeout, pollIntervalSeconds: pollInterval ?? 0.25)
        do { try policy.validate() }
        catch { throw ValidationError(error.localizedDescription) }
        return policy
    }

    private var hasSimulatorOnlyOptions: Bool {
        PhysicalAccessibilityCommands.usesSimulatorOptions(input: selectedInput, ax: selectedAX, agent: agentMode)
            || labelContains != nil || labelRegex != nil || selectorFrame != nil
    }

    private func physicalSemanticIdentifier() throws -> String {
        guard !hasSimulatorOnlyOptions else {
            throw AutomationTarget.unsupportedOnDevice("Physical semantic press does not accept agent mode or simulator display and process options.")
        }
        // The broker validates the identifier itself.
        guard let elementID else {
            throw ValidationError("Physical --semantic-press requires one exact --id.")
        }
        guard pointX == nil, pointY == nil, elementLabel == nil, elementValue == nil, elementType == nil,
              tapStyle == nil, preDelay == nil, postDelay == nil, waitTimeout == 0, pollInterval == nil else {
            throw ValidationError("Physical --semantic-press accepts only --id and --udid. Remove coordinates, other selectors, style, delays and polling.")
        }
        return elementID
    }

    private func validateDeviceTapOptions() throws {
        guard !semanticPress else {
            throw AutomationTarget.unsupportedOnDevice("Run physical semantic press as a standalone tap command.")
        }
        guard !hasSimulatorOnlyOptions else {
            throw AutomationTarget.unsupportedOnDevice("Physical tap does not accept agent mode or simulator display and process options.")
        }
        guard tapStyle != .simulator else {
            throw AutomationTarget.unsupportedOnDevice("Use the physical tap style on a physical device.")
        }
        if pointX != nil || pointY != nil {
            guard elementID == nil, elementLabel == nil, elementValue == nil, elementType == nil,
                  waitTimeout == 0, pollInterval == nil else {
                throw ValidationError("Physical coordinate taps do not accept selectors or polling options.")
            }
        }
    }

    /// A semantic press runs only as a standalone command.
    func validateOnDevice(inBatch: Bool) throws {
        if semanticPress, !inBatch {
            _ = try physicalSemanticIdentifier()
        } else {
            try validateDeviceTapOptions()
        }
    }

    /// Returns the receipt of a semantic press, which the broker returns only for a confirmed value change.
    func runOnDevice(_ input: PhysicalDeviceInput) async throws -> PhysicalSemanticPressReceipt? {
        if semanticPress {
            return try await input.semanticPress(identifier: physicalSemanticIdentifier())
        }
        if let preDelay { try await Task.sleep(for: .seconds(preDelay)) }
        if let pointX, let pointY {
            if isTouchGesture {
                try await input.perform(deviceSteps(at: CGPoint(x: pointX, y: pointY)))
            } else {
                try await input.tap(at: CGPoint(x: pointX, y: pointY))
            }
        } else {
            let query: AccessibilityQuery
            if let elementID { query = .id(elementID) }
            else if let elementLabel { query = .label(elementLabel) }
            else if let elementValue { query = .value(elementValue) }
            else { throw ValidationError("Physical tap requires coordinates or one accessibility selector.") }

            try await PhysicalAccessibilityCommands.tap(query: query, elementType: elementType,
                waitTimeout: waitTimeout, pollInterval: pollInterval, on: input,
                steps: isTouchGesture ? { deviceSteps(at: $0) } : nil)
        }
        if let postDelay { try await Task.sleep(for: .seconds(postDelay)) }
        return nil
    }

    func reportOnDevice(_ receipt: PhysicalSemanticPressReceipt?) throws {
        guard let receipt, let elementID else { return }
        if selectedOutput.verbose {
            try CLIOutput.writeJSON(receipt)
        } else {
            let output = SemanticPressOutput(identifier: elementID, before: receipt.stateBefore,
                after: receipt.stateAfter)
            try DeviceState.emit(output, text: [output.text])
        }
    }

    func run() async throws {
        if try await runOnDeviceIfTargeted() { return }
        if agentMode.enabled {
            try AgentModeCommandAdapter.send(agentRequest(), simulatorUDID: simulatorUDID)
            return
        }
        if selectedInput.mode == .selected {
            // The broker confirms a semantic press's value change before it reports success.
            try SelectedHIDBroker.printResponse(SelectedHIDBroker.send(selectedRequest(), simulatorUDID: simulatorUDID),
                verbose: selectedOutput.verbose)
            return
        }
        let logger = AxeLogger()
        try await setup(logger: logger)

        try await performGlobalSetup(logger: logger)

        if isTouchGesture {
            try await performTouchGesture(logger: logger)
            return
        }

        // A tap at a point needs nothing read first, so a broker that is already running binds the
        // screen itself. A pre-delay is waited before the screen is measured, so it keeps that route.
        if let pointX, let pointY, (preDelay ?? 0) == 0 {
            let style = resolvedTapStyle(for: TapResolution(point: (x: pointX, y: pointY), isSwitchLikeControl: false))
            if try await OrdinaryBrokerInput.performBound(
                .contact(try OrdinaryBrokerInput.tapPrimitives(style, at: (x: pointX, y: pointY))),
                simulatorUDID: simulatorUDID, postDelay: postDelay, verbose: selectedOutput.verbose) {
                logger.info().log("Tap completed successfully")
                CLIOutput.message("✓ Tap at (\(pointX), \(pointY)) completed successfully")
                return
            }
        }

        // Verified DTUHID devices use the broker's retained connection, as the Duo does, so
        // a plain tap neither opens a new guest connection nor waits to drain before exit.
        let duoContext = try await OrdinaryBrokerInput.captureRoute(
            simulatorUDID: simulatorUDID, preDelay: preDelay, logger: logger, includeVerifiedRigid: true
        )?.context
        let resolution: TapResolution
        let resolvedDescription: String

        if let pointX, let pointY {
            resolution = TapResolution(point: (x: pointX, y: pointY), isSwitchLikeControl: false)
            resolvedDescription = "(\(pointX), \(pointY))"
        } else {
            let query: AccessibilityQuery
            if let elementID {
                query = .id(elementID)
            } else if let elementLabel {
                query = .label(elementLabel)
            } else if let elementValue {
                query = .value(elementValue)
            } else {
                throw CLIError(errorDescription: "Pass -x and -y, --id, --label or --value.", code: .invalidArguments)
            }

            resolution = try await AccessibilityPoller.resolveWithPolling(
                query: query,
                simulatorUDID: simulatorUDID,
                waitTimeout: waitTimeout,
                pollInterval: pollInterval ?? 0.25,
                elementType: elementType,
                logger: logger
            )

            resolvedDescription = "resolved tap point at (\(resolution.point.x), \(resolution.point.y))"
        }

        logger.info().log("Tapping at \(resolvedDescription)")

        if let duoContext {
            try await OrdinaryBrokerInput.perform(
                at: resolution.point, style: resolvedTapStyle(for: resolution), context: duoContext,
                simulatorUDID: simulatorUDID, postDelay: postDelay, logger: logger, verbose: selectedOutput.verbose
            )
        } else {
            try await performLegacyTap(resolution: resolution, logger: logger)
        }

        logger.info().log("Tap completed successfully")
        CLIOutput.message("✓ Tap at \(resolvedDescription) completed successfully")
    }

    private var selectorQuery: AccessibilityQuery? {
        if let elementID { return .id(elementID) }
        if let elementLabel { return .label(elementLabel) }
        if let elementValue { return .value(elementValue) }
        return nil
    }

    /// A long press, double tap or two-finger tap: find the point as a tap does, then run the touch or
    /// gesture command that already sends those contacts on every simulator route.
    private func performTouchGesture(logger: AxeLogger) async throws {
        let point: (x: Double, y: Double)
        if let pointX, let pointY {
            point = (pointX, pointY)
        } else if let selectorQuery {
            point = try await AccessibilityPoller.resolveWithPolling(query: selectorQuery, simulatorUDID: simulatorUDID,
                waitTimeout: waitTimeout, pollInterval: pollInterval ?? 0.25, elementType: elementType, logger: logger).point
        } else {
            throw CLIError(errorDescription: "Pass -x and -y, --id, --label or --value.", code: .invalidArguments)
        }
        if let preDelay, preDelay > 0 { try await Task.sleep(for: .seconds(preDelay)) }
        let arguments = simulatorGestureArguments(at: point)
        logger.info().log("Tap gesture: \(arguments.joined(separator: " "))")
        if arguments[0] == "touch" {
            let command = try Touch.parse(Array(arguments.dropFirst()))
            try await command.run()
        } else {
            let command = try Gesture.parse(Array(arguments.dropFirst()))
            try await command.run()
        }
        if let postDelay, postDelay > 0 { try await Task.sleep(for: .seconds(postDelay)) }
        let kind = touches == 2 ? "Two-finger tap" : count == 2 ? "Double tap" : "Long press"
        CLIOutput.message("✓ \(kind) at (\(point.x), \(point.y)) completed successfully")
    }

    private func performLegacyTap(resolution: TapResolution, logger: AxeLogger) async throws {
        let physicalPoint = try await OrientationAwareCoordinates.translate(
            point: resolution.point,
            for: simulatorUDID,
            logger: logger
        )

        switch resolvedTapStyle(for: resolution) {
        case .physical:
            try await HIDInteractor.performPhysicalTap(
                at: physicalPoint,
                preDelay: preDelay,
                postDelay: postDelay,
                for: simulatorUDID,
                logger: logger
            )
        case .simulator:
            var events: [FBSimulatorHIDEvent] = []
            if let preDelay, preDelay > 0 {
                logger.info().log("Pre-delay: \(preDelay)s")
                events.append(.delay(preDelay))
            }
            events.append(.tapAt(x: physicalPoint.x, y: physicalPoint.y))
            if let postDelay, postDelay > 0 {
                logger.info().log("Post-delay: \(postDelay)s")
                events.append(.delay(postDelay))
            }

            let finalEvent = events.count == 1 ? events[0] : FBSimulatorHIDEvent.composite(events)
            try await HIDInteractor.performHIDEvent(finalEvent, for: simulatorUDID, logger: logger)
        case .automatic:
            throw CLIError(errorDescription: "Pass --tap-style physical or simulator.", code: .invalidArguments)
        }

    }

    private func resolvedTapStyle(for resolution: TapResolution) -> TapStyle {
        switch tapStyle ?? .automatic {
        case .automatic:
            return resolution.isSwitchLikeControl ? .physical : .simulator
        case .simulator:
            return .simulator
        case .physical:
            return .physical
        }
    }
}

/// The physical semantic press result: the switch and its value before and after.
struct SemanticPressOutput: Encodable {
    let identifier: String
    let before: Bool
    let after: Bool

    var text: String { "Switch \(identifier): \(before ? "on" : "off") -> \(after ? "on" : "off")" }
}
