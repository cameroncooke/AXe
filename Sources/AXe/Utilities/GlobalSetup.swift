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
            let errorMessage = "AXe could not find an active Xcode installation. Select Xcode with `xcode-select` or set `DEVELOPER_DIR`, then try again."
            logger.error().log(errorMessage)
            throw CLIError(errorDescription: errorMessage)
        }
        logger.info().log("Xcode is available at: \(xcodePath)")
    } catch let error as CLIError {
        throw error
    } catch {
        let errorMessage = "AXe could not resolve the active Xcode installation: \(error.localizedDescription)"
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
        let errorMessage = "AXe could not load simulator support from the selected Xcode installation: \(error.localizedDescription)"
        logger.error().log(errorMessage)
        throw CLIError(errorDescription: errorMessage)
    }
    logger.info().log("Global setup complete.")
} 
