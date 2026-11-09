import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl

struct Tap: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Tap a point on the screen, or locate an element by accessibility and tap its activation point."
    )

    @Flag(name: .customLong("semantic-press"), help: "Send one AXPress to an exact native CheckBox ID and confirm a Boolean value change. Simulator targets require selected AX.")
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

    @Option(name: .customLong("label-contains"), help: "Agent only: match one native label containing this case-sensitive literal substring. Cannot be combined with another target.")
    var labelContains: String?

    @Option(name: .customLong("label-regex"), help: "Agent only: match one native label with a Foundation regular expression, case-sensitive by default. Use ^/$ to anchor the match. Maximum 128 UTF-8 bytes and a shared 100 ms query budget.")
    var labelRegex: String?

    @Option(name: .customLong("frame"), help: "Agent selector only: AND-filter a complete native frame with minX, maxX, minY or maxY bounds in current logical UI points (key=value[,key=value]). Omitted edges use current screen bounds. No refs or coordinates.")
    var selectorFrame: String?

    @Option(name: [.customLong("element-type")], help: "Filter matches by exact accessibility type (e.g. Button, TextField, Switch). Selected mode: ordinary --id/--label/--value taps only.")
    var elementType: String?

    @Option(name: .customLong("pre-delay"), help: "Delay before tapping in seconds.")
    var preDelay: Double?

    @Option(name: .customLong("post-delay"), help: "Delay after tapping in seconds.")
    var postDelay: Double?

    @Option(name: .customLong("tap-style"), help: "Tap event style: automatic uses physical touch for switches/toggles and simulator tap for other targets; simulator always uses FBSimulator tapAt; physical uses touch down/up. Selected ordinary taps also accept automatic with the same switch-role policy, checked again before input. Physical taps hold for 0.1 seconds on broker input (selected, agent, Duo and other verified DTUHID devices) and 0.25 seconds on the direct legacy route; simulator taps insert no hold. Omitted style stays physical. Selected semantic press rejects explicit styles.")
    var tapStyle: TapStyle?

    @Option(name: .customLong("wait-timeout"), help: "Maximum seconds to poll for the element before failing (0 = no waiting, default). Only applies to --id/--label/--value targeting. Selected ordinary taps accept finite values up to 30 seconds; only a missing target is retried before input.")
    var waitTimeout: Double = 0

    @Option(name: .customLong("poll-interval"), help: "Seconds between accessibility tree polls when --wait-timeout is active (default: 0.25). Selected active polling accepts finite values in 0.05...30 seconds; a non-default interval requires a positive wait.")
    var pollInterval: Double = 0.25

    @Option(name: .customLong("udid"), help: "The UDID of the simulator or physical device.")
    var simulatorUDID: String


    @OptionGroup var selectedInput: SelectedInputOptions
    @OptionGroup var selectedOutput: SelectedOutputOptions
    @OptionGroup var selectedAX: SelectedAXOptions
    @OptionGroup var agentMode: AgentModeOptions

    func validate() throws {
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
        guard !semanticPress, waitTimeout == 0, pollInterval == 0.25 else {
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

    private var hasSimulatorOnlyOptions: Bool {
        PhysicalAccessibilityCommands.usesSimulatorOptions(input: selectedInput, ax: selectedAX, agent: agentMode)
            || labelContains != nil || labelRegex != nil || selectorFrame != nil
    }

    private func physicalSemanticIdentifier() throws -> String {
        guard !hasSimulatorOnlyOptions else {
            throw AutomationTarget.unsupportedOnDevice("Physical semantic press does not accept agent mode or simulator display and process options.")
        }
        guard let elementID, !elementID.isEmpty,
              elementID == elementID.trimmingCharacters(in: .whitespacesAndNewlines),
              elementID.utf8.count <= 4096 else {
            throw ValidationError("Physical --semantic-press requires one exact --id of at most 4096 UTF-8 bytes.")
        }
        guard pointX == nil, pointY == nil, elementLabel == nil, elementValue == nil, elementType == nil,
              tapStyle == nil, preDelay == nil, postDelay == nil, waitTimeout == 0, pollInterval == 0.25 else {
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
                  waitTimeout == 0, pollInterval == 0.25 else {
                throw ValidationError("Physical coordinate taps do not accept selectors or polling options.")
            }
        }
    }

    func physicalTap(on input: PhysicalDeviceInput) async throws {
        try validateDeviceTapOptions()
        if let preDelay { try await Task.sleep(for: .seconds(preDelay)) }
        if let pointX, let pointY {
            try await input.tap(at: CGPoint(x: pointX, y: pointY))
        } else {
            let query: AccessibilityQuery
            if let elementID { query = .id(elementID) }
            else if let elementLabel { query = .label(elementLabel) }
            else if let elementValue { query = .value(elementValue) }
            else { throw ValidationError("Physical tap requires coordinates or one accessibility selector.") }

            try await PhysicalAccessibilityCommands.tap(query: query, elementType: elementType,
                waitTimeout: waitTimeout, pollInterval: pollInterval, on: input)
        }
        if let postDelay { try await Task.sleep(for: .seconds(postDelay)) }
    }

    func run() async throws {
        if AutomationTarget.isPhysicalInputUDID(simulatorUDID) {
            let identifier = semanticPress ? try physicalSemanticIdentifier() : nil
            if identifier == nil { try validateDeviceTapOptions() }
            guard let device = try await AutomationTarget.physicalInputDevice(udid: simulatorUDID) else {
                throw CLIOutputFailure(code: "targetNotFound", message: "Run axe list-devices and choose a physical device UDID.")
            }
            if let identifier {
                let receipt = try await PhysicalAccessibility.semanticPress(identifier: identifier, for: device)
                try CLIOutput.writeJSON(receipt)
                guard receipt.identifier == identifier, receipt.stateBefore != receipt.stateAfter,
                      (1...4).contains(receipt.readbackCount), receipt.outcome == "switchValueChangedObserved",
                      receipt.delivery == "nativeReplyAccepted" else {
                    throw CLIOutputFailure(code: "semanticPressUnconfirmed",
                        message: "The device did not confirm a Boolean switch value change after the press. Check the current switch state before another action.")
                }
            } else {
                try await PhysicalDeviceInput.withSession(for: device) { input in
                    try await physicalTap(on: input)
                }
            }
            return
        }
        if agentMode.enabled {
            try AgentModeCommandAdapter.send(agentRequest(), simulatorUDID: simulatorUDID)
            return
        }
        if selectedInput.mode == .selected {
            let request = try selectedRequest()
            let response = try SelectedHIDBroker.send(request, simulatorUDID: simulatorUDID)
            // Report the result (or the full receipt with --verbose) before the readback check.
            try SelectedHIDBroker.printResponse(response, verbose: selectedOutput.verbose)
            if semanticPress { try requireSemanticReadback(response, request: request) }
            return
        }
        let logger = AxeLogger()
        try await setup(logger: logger)

        try await performGlobalSetup(logger: logger)

        // Verified DTUHID devices use the broker's retained connection, as the Duo does, so
        // a plain tap neither opens a new guest connection nor waits to drain before exit.
        let duoContext = try await LegacyDuoInput.captureContext(
            simulatorUDID: simulatorUDID, preDelay: preDelay, logger: logger, includeVerifiedRigid: true
        )
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

        if let duoContext {
            try await LegacyDuoInput.perform(
                at: resolution.point, style: resolvedTapStyle(for: resolution), context: duoContext,
                simulatorUDID: simulatorUDID, postDelay: postDelay, logger: logger
            )
        } else {
            try await performLegacyTap(resolution: resolution, logger: logger)
        }

        logger.info().log("Tap completed successfully")
        CLIOutput.message("✓ Tap at \(resolvedDescription) completed successfully")
    }

    private func requireSemanticReadback(_ response: SelectedHIDResponse, request: SelectedHIDRequest) throws {
        // Without --expected-pid or a screen pair the broker binds the frontmost app and the active
        // screen; the receipt then proves the target against what it bound.
        guard response.outcome == "switchValueChangedObserved", response.enqueuedEventCount == 0,
              response.cleanup == "notNeeded", let ax = response.ax, ax.kind == .semanticPress,
              let boundPID = ax.expectedPID, boundPID > 0,
              request.ax?.expectedPID == nil || request.ax?.expectedPID == boundPID, ax.failure == nil,
              let press = ax.press, press.outcome == "switchValueChangedObserved",
              press.delivery == "nativeReplyAccepted", press.failure == nil,
              press.translatorCallAttempted, press.callbackCount == 1, press.sendCount == 1,
              press.reply?.nativeResponsePresent == true, press.reply?.error == "0", press.reply?.value == true,
              let before = press.stateBefore, let after = press.stateAfter, before != after,
              let reads = press.readbackCount, (1...4).contains(reads),
              let target = press.target, target.identifier == request.ax?.selectorValue,
              target.pid == boundPID, target.contextID > 0, target.displayID > 0,
              let objectID = UInt64(target.objectID), objectID > 0, String(objectID) == target.objectID,
              let context = response.context,
              request.screenID == nil || context.screenID == request.screenID,
              request.screenUUID == nil || UUID(uuidString: context.screenUUID) == request.screenUUID,
              [target.frame.minX, target.frame.minY, target.frame.width, target.frame.height].allSatisfy(\.isFinite),
              target.frame.width > 0, target.frame.height > 0,
              CGRect(x: 0, y: 0, width: context.logicalWidth, height: context.logicalHeight).contains(target.frame) else {
            throw CLIError(errorDescription: "Semantic switch value change is unproved; --verbose prints the full receipt. No input was replayed.")
        }
        try context.validate()
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
            throw CLIError(errorDescription: "Unexpected tap style resolution.")
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
