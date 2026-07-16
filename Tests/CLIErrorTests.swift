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
        #expect(
            HIDBrokerNotReadyError().localizedDescription
                == "AXe could not establish simulator input. Wait for the simulator to finish booting and try again."
        )
    }

    @Test("Broker responses expose only curated errors")
    func brokerResponsesAreUserFacing() {
        let curatedError = CLIError(errorDescription: "A useful recovery message.")
        let frameworkError = NSError(
            domain: "PrivateFramework",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Internal transport implementation detail"]
        )

        #expect(HIDBroker.brokerResponseDescription(for: curatedError) == "A useful recovery message.")
        #expect(HIDBroker.brokerResponseDescription(for: frameworkError) == HIDBroker.inputDeliveryFailureDescription)
        #expect(!HIDBroker.brokerResponseDescription(for: frameworkError).contains("implementation detail"))
    }

    @Test("Missing simulator errors use public terminology and provide recovery guidance")
    func missingSimulatorErrorIsActionable() {
        let error = CLIError.simulatorNotFound(udid: "EXAMPLE-UDID")

        #expect(error.description == "No simulator with UDID EXAMPLE-UDID was found. Run `axe list-simulators` to see available simulators.")
        #expect(!error.description.contains("set"))
    }

}
