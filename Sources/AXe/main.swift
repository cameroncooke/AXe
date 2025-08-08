import ArgumentParser
import Foundation
import AppKit
import FBControlCore // Ensure FBControlCore is imported for AxeLogger if it's defined there
import Darwin // For Darwin.exit()

// MARK: - Main Entry Point
@main
struct Axe: AsyncParsableCommand {
    static let _ensureSharedApp = NSApplication.shared
    static let axeLogger = AxeLogger() // Corrected initializer

    static let configuration = CommandConfiguration(
        abstract: "A utility to interact with iOS Simulators and extract accessibility information.",
        version: VERSION,
        subcommands: [
            DescribeUI.self, 
            ListSimulators.self, 
            Tap.self, 
            Type.self, 
            Swipe.self, 
            Button.self, 
            Key.self, 
            KeySequence.self, 
            Touch.self,
            Gesture.self,
            StreamVideo.self
        ]
    )
}
