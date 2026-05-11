import Testing
import Foundation
@testable import AXe

@Suite("Slider Command Surface Tests")
struct SliderCommandSurfaceTests {
    @Test("Slider help includes selector and value options")
    func sliderHelpIncludesSelectorAndValueOptions() async throws {
        let result = try await TestHelpers.runAxeCommand("slider --help")

        #expect(result.output.contains("--id"))
        #expect(result.output.contains("--label"))
        #expect(result.output.contains("--value"))
        #expect(result.output.contains("--element-type"))
    }

    @Test("Invalid slider value fails validation")
    func invalidSliderValueFailsValidation() async throws {
        let result = try await TestHelpers.runAxeCommandAllowFailure("slider --id slider-value-slider --value 101 --udid invalid")

        #expect(result.exitCode != 0)
        #expect(result.output.contains("--value must be a finite number between 0 and 100."))
    }

    @Test("Missing slider selector fails validation")
    func missingSliderSelectorFailsValidation() async throws {
        let result = try await TestHelpers.runAxeCommandAllowFailure("slider --value 75 --udid invalid")

        #expect(result.exitCode != 0)
        #expect(result.output.contains("Use exactly one of --id or --label to target a slider."))
    }

    @Test("Slider drag endpoints stay within the application frame")
    func sliderDragEndpointsStayWithinApplicationFrame() {
        let applicationFrame = AccessibilityElement.Frame(x: 0, y: 0, width: 390, height: 844)

        #expect(Slider.clampedDragEndX(-12, applicationFrame: applicationFrame) == 0)
        #expect(Slider.clampedDragEndX(402, applicationFrame: applicationFrame) == 390)
        #expect(Slider.clampedDragEndX(120, applicationFrame: applicationFrame) == 120)
    }

    @Test("Slider command skips overdrive when already within verification tolerance")
    func sliderCommandSkipsOverdriveWhenAlreadyWithinVerificationTolerance() {
        #expect(Slider.commandedNormalizedValue(currentNormalized: 0.3994, targetNormalized: 0.4) == 0.3994)
        #expect(Slider.commandedNormalizedValue(currentNormalized: 0.4006, targetNormalized: 0.4) == 0.4006)
        #expect(Slider.commandedNormalizedValue(currentNormalized: 0.398, targetNormalized: 0.4) > 0.4)
    }
}

@Suite("Slider Command Tests", .serialized, .enabled(if: isE2EEnabled))
struct SliderTests {
    private let observableValueTolerance = 0.0007

    @Test("Slider command reaches observable AXValue tolerance with one command execution", arguments: [
        0.0,
        0.1,
        1.50,
        40.0,
        75.0,
        78.25,
        100.0
    ])
    func sliderCommandReachesObservableAXValueToleranceWithOneCommand(requestedPercent: Double) async throws {
        try await TestHelpers.launchPlaygroundApp(to: "slider-value-test")

        _ = try await TestHelpers.runAxeCommand(
            "slider --id slider-value-slider --value \(formatCommandValue(requestedPercent)) --element-type Slider",
            simulatorUDID: defaultSimulatorUDID
        )

        let state = try await waitForSliderState(requestedPercent: requestedPercent)
        #expect(state.slider.type == "Slider")
    }

    @Test("Slider command sets value by accessibility label")
    func sliderCommandSetsValueByAccessibilityLabel() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "slider-value-test")

        try await TestHelpers.runAxeCommand(
            "slider --label 'Slider Value Slider' --value 40 --element-type Slider",
            simulatorUDID: defaultSimulatorUDID
        )

        let state = try await waitForSliderState(requestedPercent: 40)
        #expect(state.slider.type == "Slider")
    }

    @Test("Slider command reaches observable AXValue tolerance across sequential moves")
    func sliderCommandReachesObservableAXValueToleranceAcrossSequentialMoves() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "slider-value-test")

        for requestedPercent in [0.0, 0.1, 1.50, 100.0, 78.25, 40.0, 75.0] {
            try await TestHelpers.runAxeCommand(
                "slider --id slider-value-slider --value \(formatCommandValue(requestedPercent)) --element-type Slider",
                simulatorUDID: defaultSimulatorUDID
            )

            let state = try await waitForSliderState(requestedPercent: requestedPercent)
            #expect(state.slider.type == "Slider")
        }
    }

    private func waitForSliderState(requestedPercent: Double) async throws -> SliderVerificationState {
        let expectedNormalizedValue = requestedPercent / 100.0
        let deadline = Date().addingTimeInterval(3)
        var lastPercentText: String?
        var lastExactText: String?
        var lastSliderValue: String?

        while Date() < deadline {
            let uiState = try await TestHelpers.getUIState()
            let percentElement = UIStateParser.findElement(in: uiState, withIdentifier: "slider-percent-state")
            let exactElement = UIStateParser.findElement(in: uiState, withIdentifier: "slider-exact-value-state")
            let slider = UIStateParser.findElement(in: uiState, withIdentifier: "slider-value-slider")

            lastPercentText = percentElement?.label
            lastExactText = exactElement?.label
            lastSliderValue = slider?.value

            if let slider,
               let observedSliderValue = normalizedSliderValue(slider.value),
               let observedPercent = numericLabelValue(percentElement?.label, prefix: "Slider Percent State:"),
               let observedExactValue = numericLabelValue(exactElement?.label, prefix: "Slider Exact Value:"),
               abs(observedSliderValue - expectedNormalizedValue) <= observableValueTolerance,
               abs(observedExactValue - expectedNormalizedValue) <= observableValueTolerance,
               abs((observedPercent / 100.0) - expectedNormalizedValue) <= observableValueTolerance {
                return SliderVerificationState(
                    slider: slider,
                    observedNormalizedValue: observedSliderValue,
                    observedExactValue: observedExactValue,
                    observedPercent: observedPercent
                )
            }

            try await Task.sleep(nanoseconds: 200_000_000)
        }

        throw TestError.unexpectedState(
            "Timed out waiting for requested slider target \(formatCommandValue(requestedPercent))% (normalized \(formatNormalized(expectedNormalizedValue))). Last percent text: \(lastPercentText ?? "none"), last exact text: \(lastExactText ?? "none"), last AXValue: \(lastSliderValue ?? "none")"
        )
    }

    private func normalizedSliderValue(_ rawValue: String?) -> Double? {
        guard let rawValue else { return nil }

        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let isPercent = trimmedValue.hasSuffix("%")
        let numericText = trimmedValue.replacingOccurrences(of: "%", with: "")
        guard let parsedValue = Double(numericText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }

        return isPercent || parsedValue > 1.0 ? parsedValue / 100.0 : parsedValue
    }

    private func numericLabelValue(_ label: String?, prefix: String) -> Double? {
        guard let label, label.hasPrefix(prefix) else { return nil }
        return Double(label.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func formatCommandValue(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private func formatNormalized(_ value: Double) -> String {
        String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

private struct SliderVerificationState {
    let slider: UIElement
    let observedNormalizedValue: Double
    let observedExactValue: Double
    let observedPercent: Double
}
