import ArgumentParser
import Foundation
import AppKit
import FBControlCore // Ensure FBControlCore is imported for AxeLogger if it's defined there
import Darwin // For Darwin.exit()

// MARK: - Main Entry Point
@main
struct Axe: AsyncParsableCommand {
    // Static stored properties are lazily initialized, and a `main() async throws`
    // signature overloads (not overrides) the protocol extension's `main() async`.
    // Startup side effects must therefore live in this exact signature.
    static func main() async {
        UncaughtExceptionGuard.install()
        do {
            var command = try parseAsRoot()
            if var asyncCommand = command as? AsyncParsableCommand {
                command = asyncCommand
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch {
            exit(withError: error)
        }
    }

    static let _ensureSharedApp = NSApplication.shared
    static let axeLogger = AxeLogger() // Corrected initializer

    static let configuration = CommandConfiguration(
        abstract: "A utility to interact with iOS Simulators and extract accessibility information.",
        version: VERSION,
        subcommands: [
            DescribeUI.self,
            ListSimulators.self,
            Init.self,
            Tap.self,
            Slider.self,
            Type.self,
            Swipe.self,
            Drag.self,
            Button.self,
            Key.self,
            KeySequence.self,
            KeyCombo.self,
            Touch.self,
            Gesture.self,
            StreamVideo.self,
            RecordVideo.self,
            Screenshot.self,
            Batch.self,
            HIDBrokerCommand.self
        ]
    )
}
