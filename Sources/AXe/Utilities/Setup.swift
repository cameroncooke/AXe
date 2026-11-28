import FBControlCore
import FBSimulatorControl

// MARK: - Simulator Setup Utility

/// Centralized function to obtain and configure an FBSimulatorSet.
/// This ensures that the necessary configurations, logging, and event reporting are set up consistently.
@MainActor
func getSimulatorSet(deviceSetPath: String?, logger: FBControlCoreLogger, reporter: FBEventReporter) async throws -> FBSimulatorSet {
    let controlConfig = FBSimulatorControlConfiguration(
        deviceSetPath: try deviceSetPath ?? SimulatorDeviceSet.path(),
        logger: logger, // Pass logger to specific configuration
        reporter: reporter
    )

    // Set the global logger. This might be crucial for some internal FBSimulatorControl/CoreSimulator
    // mechanisms to correctly identify the client or enable certain behaviors, including HID event handling.
    // This was present in earlier versions and its absence might be related to the 'clientClass' issue.
    FBControlCoreGlobalConfiguration.defaultLogger = logger

    // Initialize FBSimulatorControl with the set configuration
    let control = try FBSimulatorControl.withConfiguration(controlConfig)
    
    // Return the FBSimulatorSet from the control object
    return control.set
}

// MARK: - Empty Event Reporter (Placeholder)

// ... (rest of the file, including EmptyEventReporter, remains unchanged) 