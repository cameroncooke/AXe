import Foundation
import FBControlCore
import FBSimulatorControl

// MARK: - Accessibility Fetcher
@MainActor
struct AccessibilityFetcher {
    static func fetchAccessibilityInfoJSONData(for simulatorUDID: String, logger: AxeLogger) async throws -> Data {
        let simulatorSet = try await getSimulatorSet(deviceSetPath: nil, logger: logger, reporter: EmptyEventReporter.shared)
        
        guard let target = simulatorSet.allSimulators.first(where: { $0.udid == simulatorUDID }) else {
            throw CLIError(errorDescription: "Simulator with UDID \(simulatorUDID) not found in set.")
        }

        // FBSimulator conforms to FBAccessibilityCommands.
        let accessibilityInfoFuture: FBFuture<AnyObject> = target.accessibilityElements(withNestedFormat: true)
        let infoAnyObject: AnyObject = try await FutureBridge.value(accessibilityInfoFuture)

        if let nsDict = infoAnyObject as? NSDictionary {
            return try JSONSerialization.data(withJSONObject: nsDict, options: [.prettyPrinted])
        }
        if let nsArray = infoAnyObject as? NSArray {
            return try JSONSerialization.data(withJSONObject: nsArray, options: [.prettyPrinted])
        }
        
        throw CLIError(errorDescription: "Accessibility info was not a dictionary or array as expected.")
    }
    
    static func fetchAccessibilityElements(for simulatorUDID: String, logger: AxeLogger) async throws -> [AccessibilityElement] {
        let jsonData = try await fetchAccessibilityInfoJSONData(for: simulatorUDID, logger: logger)
        let decoder = JSONDecoder()
        
        if let roots = try? decoder.decode([AccessibilityElement].self, from: jsonData) {
            return roots
        }
        
        let root = try decoder.decode(AccessibilityElement.self, from: jsonData)
        return [root]
    }
} 
