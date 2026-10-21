import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl

struct Tap: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Tap a point on the screen, or locate an element by accessibility and tap its activation point."
    )

    @Flag(name: .customLong("semantic-press"), help: "Selected AX only: send one explicit AXPress to an exact native CheckBox ID. No HID or mouse fallback; a native reply is not effect proof.")
    var semanticPress = false

    @Option(name: .customShort("x"), help: "The X coordinate of the point to tap.")
    var pointX: Double?

    @Option(name: .customShort("y"), help: "The Y coordinate of the point to tap.")
    var pointY: Double?

    @Option(name: [.customLong("id")], help: "Tap the activation point of the element matching AXUniqueId (accessibilityIdentifier). Ignored if -x and -y are provided.")
    var elementID: String?

    @Option(name: [.customLong("label")], help: "Tap the activation point of the element matching AXLabel (accessibilityLabel). Ignored if -x and -y are provided.")
    var elementLabel: String?

    @Option(name: [.customLong("value")], help: "Tap the activation point of the element matching AXValue (the current value of a control). Ignored if -x and -y are provided.")
    var elementValue: String?

    @Option(name: [.customLong("element-type")], help: "Filter matches by exact accessibility type (e.g. Button, TextField, Switch). Selected mode: ordinary --id/--label/--value taps only.")
    var elementType: String?

    @Option(name: .customLong("pre-delay"), help: "Delay before tapping in seconds.")
    var preDelay: Double?

    @Option(name: .customLong("post-delay"), help: "Delay after tapping in seconds.")
    var postDelay: Double?

    @Option(name: .customLong("tap-style"), help: "Tap event style: automatic uses physical touch for switches/toggles and simulator tap for other targets; simulator always uses FBSimulator tapAt; physical uses touch down/up. Selected ordinary taps also accept automatic with the same switch-role policy, checked again before input; physical holds for 0.1 seconds and simulator inserts no hold. Omitted style stays physical. Selected semantic press rejects explicit styles.")
    var tapStyle: TapStyle?

    @Option(name: .customLong("wait-timeout"), help: "Maximum seconds to poll for the element before failing (0 = no waiting, default). Only applies to --id/--label/--value targeting. Selected ordinary taps accept finite values up to 30 seconds; only a missing target is retried before input.")
    var waitTimeout: Double = 0

    @Option(name: .customLong("poll-interval"), help: "Seconds between accessibility tree polls when --wait-timeout is active (default: 0.25). Selected active polling accepts finite values in 0.05...30 seconds; a non-default interval requires a positive wait.")
    var pollInterval: Double = 0.25

    @Option(name: .customLong("udid"), help: "The UDID of the simulator.")
    var simulatorUDID: String


    @OptionGroup var selectedInput: SelectedInputOptions
    @OptionGroup var selectedAX: SelectedAXOptions
    @OptionGroup var agentMode: AgentModeOptions

    func validate() throws {
        try agentMode.validate()
        if agentMode.enabled {
            try validateAgent()
            return
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
            try selectedAX.validate(required: !hasCoordinates)
        } else {
            try selectedAX.validate(required: false)
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

        if waitTimeout > 0 {
            guard pollInterval > 0 else {
                throw ValidationError("--poll-interval must be greater than 0 when --wait-timeout is active.")
            }
        }
    }

    private func validateAgent() throws {
        try AgentModeCommandAdapter.validateContext(input: selectedInput, expectedPID: selectedAX.expectedPID)
        guard !semanticPress, selectedAX.preparation == nil, waitTimeout == 0, pollInterval == 0.25 else {
            throw ValidationError("Agent tap does not accept semantic press, AX preparation or polling overrides.")
        }
        let selectors = [elementID, elementLabel, elementValue].compactMap { $0 }
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
        try AgentModeCommandAdapter.validateDelay(preDelay, name: "--pre-delay")
        try AgentModeCommandAdapter.validateDelay(postDelay, name: "--post-delay")
    }

    func agentRequest() throws -> SelectedHIDRequest {
        let selectorKind: SelectedAXRequest.SelectorKind?
        if elementID != nil { selectorKind = .id }
        else if elementLabel != nil { selectorKind = .label }
        else if elementValue != nil { selectorKind = .value }
        else { selectorKind = nil }
        let point: SelectedAXPoint?
        if let pointX, let pointY { point = SelectedAXPoint(x: pointX, y: pointY) }
        else { point = nil }
        let style: SelectedTapStyle
        switch tapStyle {
        case .physical: style = .physical
        case .simulator: style = .simulator
        case .automatic, nil: style = .automatic
        }
        return try AgentModeCommandAdapter.request(AgentModeRequest(kind: .tap,
            expectedPID: selectedAX.expectedPID, snapshotID: agentMode.snapshotID, ref: agentMode.elementRef,
            point: point, selectorKind: selectorKind, selectorValue: elementID ?? elementLabel ?? elementValue,
            elementType: elementType, preDelay: preDelay ?? 0, postDelay: postDelay ?? 0, tapStyle: style),
            input: selectedInput)
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
            guard waitTimeout == 0, pollInterval == 0.25 else {
                throw ValidationError("Selected coordinate taps and semantic press do not support polling options.")
            }
            return nil
        }
        guard waitTimeout.isFinite, waitTimeout >= 0, waitTimeout <= SelectedAXWaitPolicy.maximumTimeout else {
            throw ValidationError("Selected --wait-timeout must be finite and in 0...30 seconds.")
        }
        guard waitTimeout > 0 else {
            guard pollInterval == 0.25 else {
                throw ValidationError("Selected --poll-interval requires a positive --wait-timeout.")
            }
            return nil
        }
        let policy = SelectedAXWaitPolicy(timeoutSeconds: waitTimeout, pollIntervalSeconds: pollInterval)
        do { try policy.validate() }
        catch { throw ValidationError(error.localizedDescription) }
        return policy
    }

    func run() async throws {
        if agentMode.enabled {
            try AgentModeCommandAdapter.send(agentRequest(), simulatorUDID: simulatorUDID)
            return
        }
        if selectedInput.mode == .selected {
            try SelectedHIDBroker.printResponse(SelectedHIDBroker.send(selectedRequest(), simulatorUDID: simulatorUDID))
            return
        }
        let logger = AxeLogger()
        try await setup(logger: logger)

        try await performGlobalSetup(logger: logger)

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
                throw CLIError(errorDescription: "Unexpected state: no coordinates and no element query.")
            }

            do {
                resolution = try await AccessibilityPoller.resolveWithPolling(
                    query: query,
                    simulatorUDID: simulatorUDID,
                    waitTimeout: waitTimeout,
                    pollInterval: pollInterval,
                    elementType: elementType,
                    logger: logger
                )
            } catch let error as ElementResolutionError {
                print("Warning: \(error.localizedDescription) No tap performed.", to: &standardError)
                throw error
            }

            resolvedDescription = "resolved tap point at (\(resolution.point.x), \(resolution.point.y))"
        }

        logger.info().log("Tapping at \(resolvedDescription)")

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
            throw CLIError(errorDescription: "Unexpected tap style resolution.")
        }

        logger.info().log("Tap completed successfully")
        print("✓ Tap at \(resolvedDescription) completed successfully")
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
