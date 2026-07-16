import Foundation
import Testing
@testable import AXe

@Suite("CLI Error Tests")
struct CLIErrorTests {
    @Test("String description contains only the user-facing message")
    func stringDescriptionIsUserFacing() {
        let error = CLIError(errorDescription: "Simulator not found.")

        #expect(String(describing: error) == "Simulator not found.")
    }

    @Test("AXe runtime error types provide user-facing descriptions")
    func axeRuntimeErrorsAreUserFacing() {
        #expect(
            String(describing: TextToHIDEvents.TextConversionError.unsupportedCharacter("💥"))
                == "No keycode found for character: '💥'"
        )
        #expect(
            String(describing: ShellTokenizer.TokenizerError.danglingEscape)
                == "Dangling escape sequence in batch step."
        )
        #expect(
            String(describing: VideoProcessingError.failedToDecodeImage)
                == "AXe could not decode a simulator video frame."
        )
        #expect(
            VideoProcessingError.failedToDecodeImage.localizedDescription
                == "AXe could not decode a simulator video frame."
        )
        #expect(
            String(describing: HIDBrokerNotReadyError())
                == "AXe could not establish simulator input. Wait for the simulator to finish booting and try again."
        )
    }

    @Test("Missing simulator errors use public terminology and provide recovery guidance")
    func missingSimulatorErrorIsActionable() {
        let error = CLIError.simulatorNotFound(udid: "EXAMPLE-UDID")

        #expect(error.description == "No simulator with UDID EXAMPLE-UDID was found. Run `axe list-simulators` to see available simulators.")
        #expect(!error.description.contains("set"))
    }

}
