import Foundation
import FBControlCore
import FBSimulatorControl

// MARK: - HID Interactor
@MainActor
struct HIDInteractor {
    
    // Dedicated serial queue for HID operations (matching CompanionLib pattern)
    private static let hidQueue = DispatchQueue(label: "com.axe.hid_operations", qos: .userInitiated)
    
    // Cache for HID connections per simulator
    private static var hidConnections: [String: FBSimulatorHID] = [:]
    
    /// Configurable stabilization delay to ensure HID events are fully processed
    /// Can be set via AXE_HID_STABILIZATION_MS environment variable
    private static var stabilizationDelayMs: UInt64 {
        if let envValue = ProcessInfo.processInfo.environment["AXE_HID_STABILIZATION_MS"],
           let milliseconds = UInt64(envValue) {
            return min(milliseconds, 1000) // Cap at 1 second
        }
        return 25 // Default 25ms - much faster than before
    }
    
    static func performHIDEvent(_ event: FBSimulatorHIDEvent, for simulatorUDID: String, logger: AxeLogger) async throws {
        
        // Load private frameworks first (matching CompanionLib behavior)
        logger.info().log("Loading private frameworks for HID operations...")
        let frameworkLoader = FBSimulatorControlFrameworkLoader.xcodeFrameworks
        do {
            try frameworkLoader.loadPrivateFrameworks(logger)
            logger.info().log("Private frameworks loaded successfully.")
        } catch {
            logger.error().log("Failed to load private frameworks: \(error)")
            throw CLIError(errorDescription: "SimulatorKit is required for HID interactions. Error: \(error)")
        }

        let simulatorSet = try await getSimulatorSet(deviceSetPath: nil, logger: logger, reporter: EmptyEventReporter.shared)
        logger.info().log("FBSimulatorSet obtained.")

        guard let simulator = simulatorSet.allSimulators.first(where: { $0.udid == simulatorUDID }) else {
            throw CLIError(errorDescription: "Simulator with UDID \(simulatorUDID) not found in set.")
        }
        logger.info().log("Target (FBSimulator) obtained: \(simulator.udid)")
        logger.info().log("Simulator name: \(simulator.name)")
        
        // Check if simulator is booted
        guard simulator.state == .booted else {
            throw CLIError(errorDescription: "Simulator with UDID \(simulatorUDID) is not booted. Current state: \(simulator.state)")
        }
        logger.info().log("Simulator state verified: booted")
        

        logger.info().log("Getting HID connection...")
        
        // Get or create cached HID connection (matching CompanionLib's connectToHID pattern)
        let hid = try await getOrCreateHIDConnection(for: simulator, logger: logger)
        
        // Perform HID event on dedicated serial queue (matching CompanionLib synchronization)
        logger.info().log("Performing HID event on serial queue...")
        
        // Perform the HID event directly (the simulator's work queue handles synchronization)
        let eventFuture = event.perform(on: hid)
        _ = try await FutureBridge.value(eventFuture)
        logger.info().log("HID event performed successfully.")
        
        // Add small stabilization delay to ensure event is fully processed
        if stabilizationDelayMs > 0 {
            logger.info().log("Applying stabilization delay of \(stabilizationDelayMs)ms...")
            try await Task.sleep(nanoseconds: stabilizationDelayMs * 1_000_000)
        }

    }
    
    // Get or create a cached HID connection (matching CompanionLib's connectToHID behavior)
    private static func getOrCreateHIDConnection(for simulator: FBSimulator, logger: AxeLogger) async throws -> FBSimulatorHID {
        // Check if we already have a connection
        if let existingHID = hidConnections[simulator.udid] {
            logger.info().log("Using existing HID connection for simulator \(simulator.udid)")
            return existingHID
        }
        
        // Create new connection on the simulator's work queue
        logger.info().log("Creating new HID connection for simulator \(simulator.udid)...")
        let hidFuture = simulator.connectToHID()
        let hid = try await FutureBridge.value(hidFuture)
        
        // Cache the connection
        hidConnections[simulator.udid] = hid
        logger.info().log("HID connection created and cached for simulator \(simulator.udid)")
        
        return hid
    }
    
    // Clean up cached connections when needed
    static func clearHIDConnections() {
        hidConnections.removeAll()
    }
} 
