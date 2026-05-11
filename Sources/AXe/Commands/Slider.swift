import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl

struct Slider: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Set a slider to a deterministic value from 0 to 100 using accessibility selector targeting."
    )

    private static let dragDuration = 0.6
    private static let dragStepDelta = 2.0
    private static let dragInitialHold: TimeInterval = 0.05
    private static let dragFinalHold: TimeInterval = 0.2
    private static let verificationTimeout: TimeInterval = 1.5
    private static let verificationPollInterval: TimeInterval = 0.1
    private static let verificationStabilityDelay: TimeInterval = 0.3
    private static let maxAdjustmentAttempts = 8
    private static let valueTolerance = 0.004
    private static let minimumCorrectionStep = 0.005

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

    private func makeAdjustment(
        for element: AccessibilityElement,
        targetNormalized: Double
    ) throws -> SliderAdjustment {
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
        let thumbCenterRange = thumbCenterRange(for: frame)
        return SliderAdjustment(
            logicalStart: (x: frame.x + (frame.width * currentNormalized), y: centerY),
            logicalEnd: (x: thumbCenterRange.x(for: targetNormalized), y: centerY),
            currentNormalized: currentNormalized,
            targetNormalized: targetNormalized
        )
    }

    private func setAndVerifySliderValue(
        initialMatch: AccessibilityMatch,
        query: AccessibilityQuery,
        targetNormalized: Double,
        logger: AxeLogger
    ) async throws -> String {
        var match = initialMatch
        let initialNormalized = try parseNormalizedAXValue(match.element.normalizedValue)
        var commandedNormalized = initialCommandedNormalized(currentNormalized: initialNormalized, targetNormalized: targetNormalized)
        var lastRawValue = match.element.normalizedValue
        var lowerBound = initialNormalized < targetNormalized ? SliderCommandObservation(commanded: initialNormalized, observed: initialNormalized) : nil
        var upperBound = initialNormalized > targetNormalized ? SliderCommandObservation(commanded: initialNormalized, observed: initialNormalized) : nil

        for attempt in 1...Self.maxAdjustmentAttempts {
            let adjustment = try makeAdjustment(for: match.element, targetNormalized: commandedNormalized)
            lastRawValue = match.element.normalizedValue

            logger.info().log(
                "Setting slider \(match.selectorDescription) attempt \(attempt) from AXValue \(formatNormalized(adjustment.currentNormalized)) toward \(formatNormalized(targetNormalized))"
            )

            try await performSliderDrag(adjustment, logger: logger)

            let observedValue = try await pollObservedSliderValue(
                query: query,
                targetNormalized: targetNormalized,
                logger: logger
            )
            match = observedValue.match
            lastRawValue = observedValue.rawValue

            if observedValue.isWithinTolerance {
                return lastRawValue ?? formatNormalized(observedValue.normalizedValue)
            }

            let observedNormalized = observedValue.normalizedValue

            let observation = SliderCommandObservation(commanded: commandedNormalized, observed: observedNormalized)
            if observedNormalized < targetNormalized {
                lowerBound = observation
            } else {
                upperBound = observation
            }
            commandedNormalized = nextCommandedNormalized(
                targetNormalized: targetNormalized,
                currentCommandedNormalized: commandedNormalized,
                observedNormalized: observedNormalized,
                lowerBound: lowerBound,
                upperBound: upperBound
            )
        }

        throw CLIError(
            errorDescription: "Slider value did not reach requested value \(formatPercent(value)). Observed AXValue: \(lastRawValue ?? "none")."
        )
    }

    private func performSliderDrag(_ adjustment: SliderAdjustment, logger: AxeLogger) async throws {
        let physicalPoints = try await OrientationAwareCoordinates.translateBatch(
            points: [adjustment.logicalStart, adjustment.logicalEnd],
            for: simulatorUDID,
            logger: logger
        )
        let physicalStart = physicalPoints[0]
        let physicalEnd = physicalPoints[1]

        let distance = hypot(physicalEnd.x - physicalStart.x, physicalEnd.y - physicalStart.y)
        let steps = max(1, Int(ceil(distance / Self.dragStepDelta)))
        let stepDelay = Self.dragDuration / Double(steps)

        var events: [FBSimulatorHIDEvent] = [
            .touchDownAt(x: physicalStart.x, y: physicalStart.y),
            .delay(Self.dragInitialHold)
        ]

        for step in 1...steps {
            let progress = Double(step) / Double(steps)
            let x = physicalStart.x + ((physicalEnd.x - physicalStart.x) * progress)
            let y = physicalStart.y + ((physicalEnd.y - physicalStart.y) * progress)
            events.append(.touchDownAt(x: x, y: y))
            events.append(.delay(stepDelay))
        }

        events.append(.delay(Self.dragFinalHold))
        events.append(.touchUpAt(x: physicalEnd.x, y: physicalEnd.y))

        try await HIDInteractor.performHIDEvent(FBSimulatorHIDEvent(events: events), for: simulatorUDID, logger: logger)
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

    private func initialCommandedNormalized(currentNormalized: Double, targetNormalized: Double) -> Double {
        let distance = targetNormalized - currentNormalized
        guard abs(distance) > 0.25 else {
            return targetNormalized
        }
        return clampedNormalized(targetNormalized - (distance * 0.1))
    }

    private func nextCommandedNormalized(
        targetNormalized: Double,
        currentCommandedNormalized: Double,
        observedNormalized: Double,
        lowerBound: SliderCommandObservation?,
        upperBound: SliderCommandObservation?
    ) -> Double {
        let correction = targetNormalized - observedNormalized

        if let lowerBound,
           let upperBound,
           abs(upperBound.observed - lowerBound.observed) > .ulpOfOne {
            let observedRange = upperBound.observed - lowerBound.observed
            let commandedRange = upperBound.commanded - lowerBound.commanded
            let interpolated = lowerBound.commanded + ((targetNormalized - lowerBound.observed) * commandedRange / observedRange)
            if interpolated.isFinite {
                return clampedNormalized(interpolated)
            }
        }

        if observedNormalized < targetNormalized {
            let corrected = max(currentCommandedNormalized + correction, currentCommandedNormalized + Self.minimumCorrectionStep)
            return clampedNormalized(min(corrected, upperBound?.commanded ?? 1.0))
        }

        let corrected = min(currentCommandedNormalized + correction, currentCommandedNormalized - Self.minimumCorrectionStep)
        return clampedNormalized(max(corrected, lowerBound?.commanded ?? 0.0))
    }

    private func thumbCenterRange(for frame: AccessibilityElement.Frame) -> SliderThumbCenterRange {
        let thumbRadius = frame.height / 2.0
        return SliderThumbCenterRange(
            minX: frame.x - thumbRadius,
            maxX: frame.x + frame.width + thumbRadius
        )
    }

    private func clampedNormalized(_ value: Double) -> Double {
        min(max(value, 0.0), 1.0)
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

private struct SliderThumbCenterRange {
    let minX: Double
    let maxX: Double

    func x(for normalizedValue: Double) -> Double {
        minX + ((maxX - minX) * normalizedValue)
    }
}

private struct SliderAdjustment {
    let logicalStart: (x: Double, y: Double)
    let logicalEnd: (x: Double, y: Double)
    let currentNormalized: Double
    let targetNormalized: Double
}

private struct SliderCommandObservation {
    let commanded: Double
    let observed: Double
}

private struct SliderObservedValue {
    let match: AccessibilityMatch
    let rawValue: String?
    let normalizedValue: Double
    let isWithinTolerance: Bool
}
