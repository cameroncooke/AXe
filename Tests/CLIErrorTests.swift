import Foundation
import Testing
import ArgumentParser
import FBSimulatorControl
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
        #expect(CLIErrorMapping.failure(for: error).code == "targetNotFound")
    }

    private struct OpaqueFailure: Error { let receipt = [1, 2, 3] }

    @Test("Every error becomes one code and a sentence, never a Swift value dump")
    func errorsMapToCodedSentences() {
        let cases: [(Error, String)] = [
            (CancellationError(), "interrupted"),
            (CLIError(errorDescription: "Not booted.", code: .notBooted), "notBooted"),
            (ValidationError("Bad value."), "invalidArguments"),
            (TextToHIDEvents.TextConversionError.unsupportedCharacter("£"), "invalidArguments"),
            (SelectedHIDFailure.busy, "busy"),
            (SelectedHIDFailure.invalid("Measured context changed before input"), "rejectedBeforeInput"),
            (FBSimulatorContextError.unavailable("Unsupported guest rotation"), "displayUnavailable"),
            (FBSimulatorContextError.changedDuringRead, "screensDidNotSettle"),
            (FBSimulatorSelectedScreenshotError.changedContext, "screenChanged"),
            (ActivePanelReadError(childFailure: .cancelled), "interrupted"),
            (ActivePanelReadError(childFailure: .deadline), "timeout"),
            (FBSimulatorHIDSessionError.interrupted(reason: .staleContext, cleanup: .notNeeded), "screenChanged"),
            (FBSimulatorHIDSessionError.interrupted(reason: .cancelled, cleanup: .uncertain), "cleanupUncertain"),
            (ElementResolutionError.notFound(kind: "id", value: "x"), "elementNotFound"),
            (OpaqueFailure(), "commandFailed"),
        ]
        for (error, code) in cases {
            let failure = CLIErrorMapping.failure(for: error)
            #expect(failure.code == code, "\(error)")
            #expect(!failure.message.isEmpty && !failure.message.contains("("), "\(failure.message)")
        }
        #expect(CLIErrorMapping.failure(for: OpaqueFailure()).message == "The command failed unexpectedly.")
        #expect(CLIErrorMapping.failure(for: SelectedHIDFailure.invalid("Context changed")).message
            == "Context changed. No input was sent.")
    }

    /// The early-boot display read failures that once printed `Error: ActivePanelReadError(…)`.
    static let displayReadFailures: [Error] = [
        ActivePanelReadError(childFailure: nil, validationFailure: .missingActiveFlag),
        ActivePanelReadError(childFailure: nil, validationFailure: .activeStateUnavailable(2)),
        ActivePanelReadError(childFailure: nil, validationFailure: .invalidDisplayCount),
        ActivePanelReadError(childFailure: .nonzeroExit),
        ActivePanelReadError(childFailure: .missingJSON),
        ActivePanelValidationError.invalidGeometry(3),
        ActivePanelValidationError.catalogMismatch,
    ]

    @Test("A displays read failure is a sentence and displayUnavailable in text and JSON")
    func displayReadFailuresAreCodedSentences() throws {
        // `displays` (with or without --verbose) lets these errors reach main unchanged; text
        // output prints `fullMessage` of the mapped failure, --output renders it into the envelope.
        for error in Self.displayReadFailures {
            let failure = CLIErrorMapping.failure(for: error)
            #expect(failure.code == "displayUnavailable", "\(error)")
            let text = Axe.fullMessage(for: failure)
            #expect(text == "Error: " + failure.message && !text.contains("ActivePanel") && !text.contains("("), "\(text)")
            #expect(text.hasSuffix(".") && Axe.exitCode(for: failure) == .failure)
            for format in [CLIOutputFormat.json, .text] {
                let context = CLIOutputContext(format: format, command: "displays", agent: false)
                let rendered = String(decoding: try CLIOutput.rendered(context, failure: failure), as: UTF8.self)
                #expect(!rendered.contains("ActivePanel") && !rendered.contains("Optional"), "\(rendered)")
                if format == .json {
                    let envelope = try JSONDecoder().decode(DisplayFailureEnvelope.self, from: Data(rendered.utf8))
                    #expect(envelope.command == "displays" && envelope.didError)
                    #expect(envelope.error.code == "displayUnavailable" && envelope.error.message == failure.message)
                } else {
                    #expect(rendered.contains(failure.message))
                }
            }
        }
    }

    private struct DisplayFailureEnvelope: Decodable {
        struct Failure: Decodable { let code: String; let message: String }
        let command: String
        let didError: Bool
        let error: Failure
    }

    @Test("Broker details that are Swift value dumps stay out of messages")
    func readableFiltersValueDumps() {
        #expect(CLIErrorMapping.readable("busy") == nil)
        #expect(CLIErrorMapping.readable("interrupted(reason: staleContext, cleanup: notNeeded)") == nil)
        #expect(CLIErrorMapping.readable(" ") == nil)
        // Foundation's text for an error that has no description of its own.
        #expect(CLIErrorMapping.readable("The operation couldn\u{2019}t be completed. (AXe.SelectedAXWaitFailure error 1.)") == nil)
        #expect(CLIErrorMapping.readable("Target moved") == "Target moved.")
        #expect(CLIErrorMapping.readable("Selected siri boot identity differs; no input") == "Selected siri boot identity differs; no input.")
    }

    @Test("The envelope names the full command path", arguments: [
        (["hinge", "set", "open", "--udid", "4A4D3F14-5E8B-4C5B-9D1E-4F2A5B6C7D8E"], "hinge set"),
        (["settings", "status-bar", "show", "--udid", "4A4D3F14-5E8B-4C5B-9D1E-4F2A5B6C7D8E"], "settings status-bar show"),
        (["clipboard", "copy", "--stdin", "--udid", "4A4D3F14-5E8B-4C5B-9D1E-4F2A5B6C7D8E"], "clipboard copy"),
        (["list-simulators"], "list-simulators"),
    ])
    func commandPathNamesSubcommands(arguments: [String], expected: String) throws {
        #expect(Axe.commandPath(of: try Axe.parseAsRoot(arguments)) == expected)
    }
}

@Suite("Output selection")
struct CLIOutputInvocationTests {
    @Test("Root and leaf --output select the format; media --output stays a path; -- ends options")
    func selection() {
        let root = CLIOutputInvocation(arguments: ["--output", "json", "hinge", "read", "--udid", "U"])
        #expect(root.format == .json && root.command == "hinge" && root.arguments == ["hinge", "read", "--udid", "U"])
        let leaf = CLIOutputInvocation(arguments: ["describe-ui", "--udid", "U", "--output=text"])
        #expect(leaf.format == .text && leaf.arguments == ["describe-ui", "--udid", "U"])
        let media = CLIOutputInvocation(arguments: ["screenshot", "--udid", "U", "--output", "a.png"])
        #expect(media.format == nil && media.arguments == ["screenshot", "--udid", "U", "--output", "a.png"])
        let mediaJSON = CLIOutputInvocation(arguments: ["--output", "json", "screenshot", "--output", "a.png"])
        #expect(mediaJSON.format == .json && mediaJSON.arguments == ["screenshot", "--output", "a.png"])
        let terminated = CLIOutputInvocation(arguments: ["type", "--udid", "U", "--", "--output", "json"])
        #expect(terminated.format == nil && terminated.arguments.suffix(3) == ["--", "--output", "json"])
        #expect(CLIOutputInvocation(arguments: ["--output", "yaml", "tap"]).selectionError == "--output must be text or json.")
        #expect(CLIOutputInvocation(arguments: ["tap", "--agent", "--udid", "U"]).format == .json)
    }
}

@Suite("Command path of an unparsed command line")
struct CommandPathSpellingTests {
    @Test func leadingSubcommandWordsNameThePath() {
        #expect(Axe.commandPath(spelledBy: ["hinge", "set", "200", "--udid", "U"]) == "hinge set")
        #expect(Axe.commandPath(spelledBy: ["settings", "status-bar", "bogus"]) == "settings status-bar")
        #expect(Axe.commandPath(spelledBy: ["tap", "set"]) == "tap")
        #expect(Axe.commandPath(spelledBy: ["--udid", "U", "tap"]) == nil)
    }
}
