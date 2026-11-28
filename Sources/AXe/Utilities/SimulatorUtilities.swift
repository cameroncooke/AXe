import Foundation
import FBControlCore
import FBSimulatorControl

// MARK: - Utility Functions
func getSimulatorSet(
    deviceSetPath: String?,
    logger: AxeLogger,
    reporter: FBEventReporter
) async throws -> FBSimulatorSet {
    let configuration = FBSimulatorControlConfiguration(
        deviceSetPath: try deviceSetPath ?? SimulatorDeviceSet.path(),
        logger: logger,
        reporter: reporter
    )

    do {
        let controlSet = try FBSimulatorControl.withConfiguration(configuration)
        return controlSet.set
    } catch {
        logger.info().log("FBSimulatorControl failed to initialize.")
        throw error
    }
} 
