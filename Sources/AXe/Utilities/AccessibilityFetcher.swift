import Foundation
import FBControlCore
import FBSimulatorControl

struct AccessibilityPoint: Equatable {
    let x: Double
    let y: Double

    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}

// MARK: - Accessibility Fetcher
@MainActor
struct AccessibilityFetcher {
    static func fetchAccessibilityInfoJSONData(
        for simulatorUDID: String,
        point: AccessibilityPoint? = nil,
        logger: AxeLogger
    ) async throws -> Data {
        let simulatorSet = try await getSimulatorSet(deviceSetPath: nil, logger: logger, reporter: EmptyEventReporter.shared)
        
        guard let target = simulatorSet.allSimulators.first(where: { $0.udid == simulatorUDID }) else {
            throw CLIError(errorDescription: "Simulator with UDID \(simulatorUDID) not found in set.")
        }

        // FBSimulator conforms to FBAccessibilityCommands.
        let accessibilityInfoFuture: FBFuture<AnyObject>
        if let point {
            accessibilityInfoFuture = target.accessibilityElement(at: point.cgPoint, nestedFormat: true)
        } else {
            accessibilityInfoFuture = target.accessibilityElements(withNestedFormat: true)
        }

        let infoAnyObject: AnyObject = try await FutureBridge.value(accessibilityInfoFuture)
        return try serializeAccessibilityInfo(infoAnyObject)
    }

    static func fetchAccessibilityElements(for simulatorUDID: String, logger: AxeLogger) async throws -> [AccessibilityElement] {
        let jsonData = try await fetchAccessibilityInfoJSONData(for: simulatorUDID, point: nil, logger: logger)
        let decoder = JSONDecoder()
        
        if let roots = try? decoder.decode([AccessibilityElement].self, from: jsonData) {
            return roots
        }
        
        let root = try decoder.decode(AccessibilityElement.self, from: jsonData)
        return [root]
    }

    private static func serializeAccessibilityInfo(_ accessibilityInfo: AnyObject) throws -> Data {
        if let nsDict = accessibilityInfo as? NSDictionary {
            return try JSONSerialization.data(withJSONObject: nsDict, options: [.prettyPrinted])
        }
        if let nsArray = accessibilityInfo as? NSArray {
            return try JSONSerialization.data(withJSONObject: nsArray, options: [.prettyPrinted])
        }
        
        throw CLIError(errorDescription: "Accessibility info was not a dictionary or array as expected.")
    }
} 
