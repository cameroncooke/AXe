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
            throw CLIError(errorDescription: "Essential private frameworks failed to loaded.")
        }
    }
}
