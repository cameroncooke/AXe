import ArgumentParser
import Foundation

struct Slider: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Set a slider to a deterministic value from 0 to 100 using accessibility selector targeting."
    )

    private static let directDragSteps = 120
    private static let directDragDuration: TimeInterval = 2.4
    private static let directDragInitialHold: TimeInterval = 0.05
    private static let directDragFinalHold: TimeInterval = 0.2
    private static let verificationTimeout: TimeInterval = 1.5
    private static let verificationPollInterval: TimeInterval = 0.1
    private static let verificationStabilityDelay: TimeInterval = 0.3
    private static let valueTolerance = 0.0007
    private static let alreadyAtTargetTolerance = valueTolerance
    private static let lowRangeCoordinateOffset = 0.0268
    private static let highRangeCoordinateOffset = 0.0271

    @Option(name: [.customLong("id")], help: "Set the slider matching AXUniqueId (accessibilityIdentifier).")
    var elementID: String?

    @Option(name: [.customLong("label")], help: "Set the slider matching AXLabel (accessibilityLabel).")
    var elementLabel: String?

    @Option(name: [.customLong("element-type")], help: "Filter matches to this accessibility type, usually Slider.")
    var elementType: String?

    @Option(name: [.customLong("value")], help: "Target slider value as a percentage from 0 to 100.")
    var value: Double

    @Option(name: .customLong("wait-timeout"), help: "Maximum seconds to poll for the slider before failing (0 = no waiting, default).")
    var waitTimeout: Double = 0

    @Option(name: .customLong("poll-interval"), help: "Seconds between accessibility tree polls when --wait-timeout is active (default: 0.25).")
    var pollInterval: Double = 0.25

    @Option(name: .customLong("udid"), help: "The UDID of the simulator.")
    var simulatorUDID: String

    func validate() throws {
        let selectorCount = [elementID != nil, elementLabel != nil].filter { $0 }.count
        guard selectorCount == 1 else {
            throw ValidationError("Use exactly one of --id or --label to target a slider.")
        }

        if let elementID, elementID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--id must not be empty.")
        }
        if let elementLabel, elementLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--label must not be empty.")
        }

        guard value.isFinite, (0...100).contains(value) else {
            throw ValidationError("--value must be a finite number between 0 and 100.")
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

    func run() async throws {
        let logger = AxeLogger()
        try await setup(logger: logger)
        try await performGlobalSetup(logger: logger)

        let query = try accessibilityQuery()
        let targetNormalized = value / 100.0

        let match = try await AccessibilityPoller.resolveElementWithPolling(
            query: query,
            simulatorUDID: simulatorUDID,
            waitTimeout: waitTimeout,
            pollInterval: pollInterval,
            elementType: elementType,
            logger: logger
        )

        let observedValue = try await setAndVerifySliderValue(
            initialMatch: match,
            query: query,
            targetNormalized: targetNormalized,
            logger: logger
        )

        logger.info().log("Slider set completed successfully")
        print("✓ Slider set to \(formatPercent(value)) successfully (AXValue: \(observedValue))")
    }

    private func accessibilityQuery() throws -> AccessibilityQuery {
        if let elementID {
            return .id(elementID)
        }
        if let elementLabel {
            return .label(elementLabel)
        }
        throw CLIError(errorDescription: "Unexpected state: no slider selector.")
    }

    private func makeDragPlan(
        for element: AccessibilityElement,
        applicationFrame: AccessibilityElement.Frame?,
        targetNormalized: Double
    ) throws -> SliderDragPlan {
        guard element.isSliderLikeControl else {
            let typeDescription = element.type ?? element.role ?? "unknown"
            throw CLIError(errorDescription: "Matched element is not a slider (type: \(typeDescription)). Use --element-type Slider or a more specific --id/--label selector.")
        }
        guard let frame = element.frame else {
            throw ElementResolutionError.invalidFrame(reason: "Matched slider has no frame.")
        }
        guard frame.width > 0, frame.height > 0 else {
            throw ElementResolutionError.invalidFrame(reason: "Matched slider has an invalid frame size (\(frame.width)x\(frame.height)).")
        }

        let currentNormalized = try parseNormalizedAXValue(element.normalizedValue)
        let centerY = frame.y + (frame.height / 2.0)
        let commandedNormalized = Self.commandedNormalizedValue(
            currentNormalized: currentNormalized,
            targetNormalized: targetNormalized
        )
        let nominalStartX = frame.x + (frame.width * currentNormalized)
        let startX = dragStartX(
            frame: frame,
            nominalStartX: nominalStartX,
            currentNormalized: currentNormalized,
            targetNormalized: targetNormalized
        )
        let fingerOffsetFromNominalStart = startX - nominalStartX
        let rawEndX = frame.x + (frame.width * commandedNormalized) + fingerOffsetFromNominalStart
        let endX = Self.clampedDragEndX(rawEndX, applicationFrame: applicationFrame)
        return SliderDragPlan(
            logicalStart: (x: startX, y: centerY),
            logicalEnd: (x: endX, y: centerY),
            currentNormalized: currentNormalized,
            targetNormalized: targetNormalized,
            commandedNormalized: commandedNormalized
        )
    }

    private func setAndVerifySliderValue(
        initialMatch: AccessibilityMatch,
        query: AccessibilityQuery,
        targetNormalized: Double,
        logger: AxeLogger
    ) async throws -> String {
        let dragPlan = try makeDragPlan(
            for: initialMatch.element,
            applicationFrame: initialMatch.applicationFrame,
            targetNormalized: targetNormalized
        )
        logger.info().log(
            "Setting slider \(initialMatch.selectorDescription) from AXValue \(formatNormalized(dragPlan.currentNormalized)) toward \(formatNormalized(dragPlan.targetNormalized)) with low-level HID drag"
        )

        if abs(dragPlan.currentNormalized - targetNormalized) > Self.alreadyAtTargetTolerance {
            try await performSliderDrag(dragPlan, logger: logger)
        }

        let observedValue = try await pollObservedSliderValue(
            query: query,
            targetNormalized: targetNormalized,
            logger: logger
        )
        guard observedValue.isWithinTolerance else {
            throw CLIError(
                errorDescription: "Slider value did not reach requested value \(formatPercent(value)) after direct drag. Observed AXValue: \(observedValue.rawValue ?? "none")."
            )
        }
        return observedValue.rawValue ?? formatNormalized(observedValue.normalizedValue)
    }

    private func performSliderDrag(_ dragPlan: SliderDragPlan, logger: AxeLogger) async throws {
        let physicalPoints = try await OrientationAwareCoordinates.translateBatch(
            points: [dragPlan.logicalStart, dragPlan.logicalEnd],
            for: simulatorUDID,
            logger: logger
        )
        let physicalStart = physicalPoints[0]
        let physicalEnd = physicalPoints[1]

        try await HIDInteractor.performCompositeDrag(
            from: physicalStart,
            to: physicalEnd,
            duration: Self.directDragDuration,
            steps: Self.directDragSteps,
            initialHold: Self.directDragInitialHold,
            finalHold: Self.directDragFinalHold,
            for: simulatorUDID,
            logger: logger
        )
    }

    private func resolveSliderElement(query: AccessibilityQuery, logger: AxeLogger) async throws -> AccessibilityMatch {
        let roots = try await AccessibilityFetcher.fetchAccessibilityElements(for: simulatorUDID, logger: logger)
        let match = try AccessibilityTargetResolver.resolveElement(
            roots: roots,
            query: query,
            elementType: elementType
        )
        guard match.element.isSliderLikeControl else {
            throw CLIError(errorDescription: "Matched element is no longer a slider.")
        }
        return match
    }

    private func pollObservedSliderValue(
        query: AccessibilityQuery,
        targetNormalized: Double,
        logger: AxeLogger
    ) async throws -> SliderObservedValue {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(Self.verificationTimeout)
        var lastObservedValue: SliderObservedValue?

        repeat {
            let match = try await resolveSliderElement(query: query, logger: logger)
            let rawValue = match.element.normalizedValue
            let normalizedValue = try parseNormalizedAXValue(rawValue)
            let observedValue = SliderObservedValue(
                match: match,
                rawValue: rawValue,
                normalizedValue: normalizedValue,
                isWithinTolerance: abs(normalizedValue - targetNormalized) <= Self.valueTolerance
            )
            if observedValue.isWithinTolerance {
                try await Task.sleep(for: .seconds(Self.verificationStabilityDelay))
                if clock.now >= deadline {
                    return observedValue
                }
                let stableMatch = try await resolveSliderElement(query: query, logger: logger)
                let stableRawValue = stableMatch.element.normalizedValue
                let stableNormalizedValue = try parseNormalizedAXValue(stableRawValue)
                let stableObservedValue = SliderObservedValue(
                    match: stableMatch,
                    rawValue: stableRawValue,
                    normalizedValue: stableNormalizedValue,
                    isWithinTolerance: abs(stableNormalizedValue - targetNormalized) <= Self.valueTolerance
                )
                if stableObservedValue.isWithinTolerance {
                    return stableObservedValue
                }
                lastObservedValue = stableObservedValue
            } else {
                lastObservedValue = observedValue
            }

            if clock.now < deadline {
                try await Task.sleep(for: .seconds(Self.verificationPollInterval))
            }
        } while clock.now < deadline

        if let lastObservedValue {
            return lastObservedValue
        }
        throw CLIError(errorDescription: "Slider value could not be verified because AXValue was unavailable after dragging.")
    }

    private func dragStartX(
        frame: AccessibilityElement.Frame,
        nominalStartX: Double,
        currentNormalized: Double,
        targetNormalized: Double
    ) -> Double {
        guard currentNormalized >= 1.0 - Self.valueTolerance, targetNormalized < currentNormalized else {
            return nominalStartX
        }
        return nominalStartX - (frame.height / 2.0)
    }

    static func commandedNormalizedValue(currentNormalized: Double, targetNormalized: Double) -> Double {
        if abs(currentNormalized - targetNormalized) <= Self.alreadyAtTargetTolerance {
            return currentNormalized
        }
        if targetNormalized < currentNormalized {
            return targetNormalized - Self.lowRangeCoordinateOffset
        }
        return targetNormalized + Self.highRangeCoordinateOffset
    }

    static func clampedDragEndX(
        _ x: Double,
        applicationFrame: AccessibilityElement.Frame?
    ) -> Double {
        guard let applicationFrame, applicationFrame.width > 0 else {
            return x
        }
        return min(max(x, applicationFrame.x), applicationFrame.x + applicationFrame.width)
    }

    private func parseNormalizedAXValue(_ rawValue: String?) throws -> Double {
        guard let rawValue else {
            throw CLIError(errorDescription: "Matched slider does not expose a numeric AXValue, so AXe cannot deterministically set it.")
        }

        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            throw CLIError(errorDescription: "Matched slider does not expose a numeric AXValue, so AXe cannot deterministically set it.")
        }

        let isPercent = trimmedValue.hasSuffix("%")
        let numericText = trimmedValue.replacingOccurrences(of: "%", with: "")
        guard let parsedValue = Double(numericText.trimmingCharacters(in: .whitespacesAndNewlines)), parsedValue.isFinite else {
            throw CLIError(errorDescription: "Matched slider does not expose a numeric AXValue, so AXe cannot deterministically set it.")
        }

        let normalizedValue = isPercent || parsedValue > 1.0 ? parsedValue / 100.0 : parsedValue
        guard (0...1).contains(normalizedValue) else {
            throw CLIError(errorDescription: "Matched slider AXValue is outside the supported 0...100 range: \(rawValue).")
        }
        return normalizedValue
    }

    private func formatPercent(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.2f", value)
    }

    private func formatNormalized(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

private struct SliderDragPlan {
    let logicalStart: (x: Double, y: Double)
    let logicalEnd: (x: Double, y: Double)
    let currentNormalized: Double
    let targetNormalized: Double
    let commandedNormalized: Double
}

private struct SliderObservedValue {
    let match: AccessibilityMatch
    let rawValue: String?
    let normalizedValue: Double
    let isWithinTolerance: Bool
}
