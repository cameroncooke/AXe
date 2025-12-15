import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl

struct DescribeUI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Describes the UI hierarchy of a booted simulator using accessibility information."
    )

    @Option(name: .customLong("udid"), help: "The UDID of the simulator.")
    var simulatorUDID: String

    func run() async throws {
        let logger = AxeLogger()
        
        try await performGlobalSetup(logger: logger)

        // Check Xcode availability
        do {
            let isXcodeAvailable: NSString = try await FutureBridge.value(FBXcodeDirectory.xcodeSelectDeveloperDirectory())
            if isXcodeAvailable.length == 0 {
                logger.error().log("Xcode is not available, idb will not be able to use Simulators")
                throw CLIError(errorDescription: "Xcode is not available, idb will not be able to use Simulators")
            }
        } catch {
            logger.error().log("Xcode is not available, idb will not be able to use Simulators: \(error.localizedDescription)")
            throw CLIError(errorDescription: "Xcode is not available, idb will not be able to use Simulators")
        }
        
        // Load essential frameworks
        do {
            try FBSimulatorControlFrameworkLoader.essentialFrameworks.loadPrivateFrameworks(logger)
        } catch {
            logger.info().log("Essential private frameworks failed to loaded.")
            throw error
        }
        
        // Fetch accessibility information
        let jsonData = try await AccessibilityFetcher.fetchAccessibilityInfoJSONData(for: simulatorUDID, logger: logger)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw CLIError(errorDescription: "Failed to convert accessibility info to JSON string.")
        }
        print(jsonString)
    }
} 
