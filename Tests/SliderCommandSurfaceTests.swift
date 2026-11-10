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
