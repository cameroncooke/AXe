import Foundation
import FBSimulatorControl

extension AccessibilityFetcher {
    static func retryingAfterAccessibilityRecovery<T>(
        simulatorUDID: String,
        logger: AxeLogger,
        dependencies: AccessibilityRecoveryDependencies,
        operation: @MainActor () async throws -> T
    ) async throws -> T {
        var didRecoverTestManagerDaemon = false
        var didRetryMissingTranslation = false
        var didRecoverCoreSimulatorBridge = false

        while true {
            do {
                return try await operation()
            } catch {
                if shouldRecoverTestManagerDaemon(from: error), !didRecoverTestManagerDaemon {
                    didRecoverTestManagerDaemon = true
                    logger.info().log("Accessibility transport failed; restarting testmanagerd and retrying once")
                    try await recoverTestManagerDaemon(
                        simulatorUDID: simulatorUDID,
                        dependencies: dependencies
                    )
                    continue
                }

                guard shouldRecoverCoreSimulatorBridge(from: error) else {
                    throw error
                }

                if !didRetryMissingTranslation {
                    didRetryMissingTranslation = true
                    logger.info().log("Accessibility translation returned no object; retrying before recovery")
                    try await dependencies.wait(.milliseconds(100))
                    continue
                }

                if !didRecoverCoreSimulatorBridge {
                    didRecoverCoreSimulatorBridge = true
                    logger.info().log(
                        "Accessibility translation remained unavailable; restarting the CoreSimulator bridge for simulator \(simulatorUDID) and retrying once"
                    )
                    try await recoverCoreSimulatorBridge(
                        simulatorUDID: simulatorUDID,
                        dependencies: dependencies
                    )
                    continue
                }

                throw CLIError(
                    errorDescription: "AXe could not obtain accessibility information for simulator \(simulatorUDID) after retrying and restarting its CoreSimulator bridge. Restart the simulator and try again."
                )
            }
        }
    }

    static func shouldRecoverCoreSimulatorBridge(from error: Error) -> Bool {
        if let accessibilityError = error as? FBAccessibilityError,
           case .noTranslationObject = accessibilityError {
            return true
        }

        return errorChain(from: error).contains { error in
            error.localizedDescription.localizedCaseInsensitiveContains(
                "no translation object returned for simulator"
            )
        }
    }

    static func recoverCoreSimulatorBridge(
        simulatorUDID: String,
        dependencies: AccessibilityRecoveryDependencies
    ) async throws {
        let arguments = [
            "simctl",
            "spawn",
            simulatorUDID,
            "launchctl",
            "kickstart",
            "-k",
            "user/foreground/com.apple.CoreSimulator.bridge",
        ]
        let status = try await dependencies.runProcess(
            URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments,
            3
        )
        guard status == 0 else {
            throw CLIError(
                errorDescription: "AXe could not restart the CoreSimulator bridge for simulator \(simulatorUDID) (exit status \(status)). Restart the simulator and try again."
            )
        }
        try await dependencies.wait(.milliseconds(250))
    }
}
