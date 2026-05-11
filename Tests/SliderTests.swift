import Testing
import Foundation

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
}

@Suite("Slider Command Tests", .serialized, .enabled(if: isE2EEnabled))
struct SliderTests {
    private let exactValueTolerance = 0.004

    @Test("Slider command sets value by accessibility identifier")
    func sliderCommandSetsValueByAccessibilityIdentifier() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "slider-value-test")

        let initial = try await TestHelpers.waitForLabel(containing: "Slider Position:", timeout: 3) {
            $0 == "Slider Position: 0.25"
        }
        #expect(initial == "Slider Position: 0.25")

        try await TestHelpers.runAxeCommand(
            "slider --id slider-value-slider --value 75 --element-type Slider",
            simulatorUDID: defaultSimulatorUDID
        )

        let slider = try await waitForSliderState(expectedLabel: "Slider Position: 0.75", expectedNormalizedValue: 0.75)
        #expect(slider.type == "Slider")
    }

    @Test("Slider command sets value by accessibility label")
    func sliderCommandSetsValueByAccessibilityLabel() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "slider-value-test")

        try await TestHelpers.runAxeCommand(
            "slider --label 'Slider Value Slider' --value 40 --element-type Slider",
            simulatorUDID: defaultSimulatorUDID
        )

        let slider = try await waitForSliderState(expectedLabel: "Slider Position: 0.40", expectedNormalizedValue: 0.40)
        #expect(slider.type == "Slider")
    }

    private func waitForSliderState(expectedLabel: String, expectedNormalizedValue: Double) async throws -> UIElement {
        let deadline = Date().addingTimeInterval(3)
        var lastLabel: String?
        var lastSliderValue: String?

        while Date() < deadline {
            let uiState = try await TestHelpers.getUIState()
            let positionLabel = UIStateParser.findElementByLabel(in: uiState, label: expectedLabel)?.label
            lastLabel = UIStateParser.findElementContainingLabel(in: uiState, containing: "Slider Position:")?.label

            if let slider = UIStateParser.findElement(in: uiState, withIdentifier: "slider-value-slider") {
                lastSliderValue = slider.value
                if positionLabel == expectedLabel,
                   let observedValue = normalizedSliderValue(slider.value),
                   abs(observedValue - expectedNormalizedValue) <= exactValueTolerance {
                    return slider
                }
            }

            try await Task.sleep(nanoseconds: 200_000_000)
        }

        throw TestError.unexpectedState(
            "Timed out waiting for \(expectedLabel) and slider AXValue near \(expectedNormalizedValue). Last label: \(lastLabel ?? "none"), last AXValue: \(lastSliderValue ?? "none")"
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
}
