import Foundation
import FBControlCore
import FBSimulatorControl

@MainActor
func performGlobalSetup(logger: AxeLogger) async throws {
    logger.info().log("Performing global setup...")

    // Check Xcode availability
    logger.info().log("Checking Xcode availability...")
    do {
        let xcodePath = try FBXcodeDirectory.resolveDeveloperDirectory()
        if xcodePath.isEmpty {
            let errorMessage = "Xcode is not available (xcode-select path is empty). FBSimulatorControl may not function correctly."
            logger.error().log(errorMessage)
            throw CLIError(errorDescription: errorMessage)
        }
        logger.info().log("Xcode is available at: \(xcodePath)")
    } catch {
        let errorMessage = "Failed to check Xcode availability: \(error.localizedDescription)"
        logger.error().log(errorMessage)
        throw CLIError(errorDescription: errorMessage)
    }

    // Load essential private frameworks
    logger.info().log("Loading essential private frameworks via FBSimulatorControlFrameworkLoader...")
    do {
        try FBSimulatorControlFrameworkLoader.essentialFrameworks.loadPrivateFrameworks(logger)
        logger.info().log("Successfully loaded essential private frameworks (according to FBSimulatorControlFrameworkLoader).")

        // Load Xcode frameworks (including SimulatorKit)
        logger.info().log("Loading Xcode frameworks (including SimulatorKit)...")
        try FBSimulatorControlFrameworkLoader.xcodeFrameworks.loadPrivateFrameworks(logger)
        logger.info().log("Successfully loaded Xcode frameworks.")
    } catch {
        let errorMessage = "Failed to load essential private frameworks: \(error.localizedDescription)"
        logger.error().log(errorMessage)
        throw CLIError(errorDescription: errorMessage)
    }
    logger.info().log("Global setup complete.")
} 
