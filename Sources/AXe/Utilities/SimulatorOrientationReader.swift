import Foundation
import FBSimulatorControl

@MainActor
struct SimulatorOrientationReader {
    static func currentOrientation(
        simulatorUDID: String,
        logger: AxeLogger
    ) async -> SimulatorOrientation? {
        do {
            let frameworkLoader = FBSimulatorControlFrameworkLoader.xcodeFrameworks
            try frameworkLoader.loadPrivateFrameworks(logger)

            let simulatorSet = try await getSimulatorSet(
                deviceSetPath: nil,
                logger: logger,
                reporter: EmptyEventReporter.shared
            )

            guard let simulator = simulatorSet.allSimulators.first(where: { $0.udid == simulatorUDID }) else {
                logger.info().log("Orientation probe: simulator \(simulatorUDID) not found")
                return nil
            }

            // The built-in screen's properties, read through the runtime's screen adapter. This
            // must not create a SimulatorKit.SimDeviceScreen: that registers screen callbacks which
            // outlive this process in the simulator's render server (#106).
            guard let rawOrientation = try await FBSimulatorDisplayDiscovery.rawUIOrientation(
                for: simulator,
                screenID: builtInScreenID
            ) else {
                logger.info().log("Orientation probe: uiOrientation unavailable")
                return nil
            }

            logger.info().log("Orientation probe: uiOrientation=\(rawOrientation)")
            return mapUIOrientation(rawOrientation)
        } catch {
            logger.info().log("Orientation probe failed: \(error)")
            return nil
        }
    }

    /// The host screen ID of the simulator's built-in display.
    private static let builtInScreenID: UInt32 = 1

    private static func mapUIOrientation(_ rawOrientation: UInt32) -> SimulatorOrientation? {
        switch rawOrientation {
        case 1:
            return .portrait
        case 2:
            return .portraitUpsideDown
        case 3:
            return .landscape
        case 4:
            return .landscapeFlipped
        default:
            return nil
        }
    }
}
