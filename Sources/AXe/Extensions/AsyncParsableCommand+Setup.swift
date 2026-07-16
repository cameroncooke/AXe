import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl

extension AsyncParsableCommand {
    func setup(logger: AxeLogger) async throws {
        // Check Xcode availability
        do {
            let developerDirectory = try FBXcodeDirectory.resolveDeveloperDirectory()
            if developerDirectory.isEmpty {
                logger.error().log("No active Xcode developer directory was found")
                throw CLIError(
                    errorDescription: "AXe could not find an active Xcode installation. Select Xcode with `xcode-select` or set `DEVELOPER_DIR`, then try again."
                )
            }
        } catch let error as CLIError {
            throw error
        } catch {
            logger.error().log("Failed to resolve the active Xcode installation: \(error.localizedDescription)")
            throw CLIError(
                errorDescription: "AXe could not find an active Xcode installation. Select Xcode with `xcode-select` or set `DEVELOPER_DIR`, then try again."
            )
        }
        
        // Load essential frameworks
        do {
            try FBSimulatorControlFrameworkLoader.essentialFrameworks.loadPrivateFrameworks(logger)
        } catch {
            logger.error().log("Failed to load simulator support: \(error.localizedDescription)")
            throw CLIError(
                errorDescription: "AXe could not load simulator support from the selected Xcode installation. Confirm Xcode 26 or later is selected and try again."
            )
        }
    }
}
