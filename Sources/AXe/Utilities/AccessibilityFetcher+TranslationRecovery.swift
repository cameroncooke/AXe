import Foundation
import FBSimulatorControl

extension AccessibilityFetcher {
    nonisolated static let translationReadinessPollIntervals = Array(
        repeating: Duration.milliseconds(500),
        count: 16
    )

    static func retryingAfterAccessibilityRecovery<T>(
        simulatorUDID: String,
        logger: AxeLogger,
        dependencies: AccessibilityRecoveryDependencies,
        allowsCoreSimulatorBridgeRecovery: Bool = true,
        readinessPollIntervals: [Duration] = translationReadinessPollIntervals,
        lockAcquirer: AccessibilityRecoveryLock.Acquirer = AccessibilityRecoveryLock.acquire,
        generationReader: AccessibilityRecoveryLock.GenerationReader = AccessibilityRecoveryLock.currentGeneration,
        operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        var didRecoverTestManagerDaemon = false

        let operationWithTestManagerRecovery: @MainActor () async throws -> T = {
            do {
                return try await operation()
            } catch {
                if shouldRecoverTestManagerDaemon(from: error), !didRecoverTestManagerDaemon {
                    didRecoverTestManagerDaemon = true
                    logger.info().log(
                        "Accessibility transport failed; restarting testmanagerd and retrying once"
                    )
                    try await recoverTestManagerDaemon(
                        simulatorUDID: simulatorUDID,
                        dependencies: dependencies
                    )
                    return try await operation()
                }
                throw error
            }
        }

        guard allowsCoreSimulatorBridgeRecovery else {
            return try await operationWithTestManagerRecovery()
        }

        let observedGeneration = try generationReader(simulatorUDID)
        let preRecoveryResult = try await pollForAccessibilityTranslation(
            intervals: readinessPollIntervals,
            wait: dependencies.wait,
            operation: operationWithTestManagerRecovery
        )
        if case let .available(value) = preRecoveryResult {
            return value
        }

        let recoveryLease = try await lockAcquirer(simulatorUDID)
        defer { recoveryLease.release() }

        do {
            return try await operationWithTestManagerRecovery()
        } catch {
            guard shouldRecoverCoreSimulatorBridge(from: error) else {
                throw error
            }
        }

        guard recoveryLease.generation == observedGeneration else {
            throw persistentTranslationError(simulatorUDID: simulatorUDID)
        }

        logger.info().log(
            "Accessibility translation remained unavailable after the readiness window; restarting the CoreSimulator bridge for simulator \(simulatorUDID)"
        )
        let postRecoveryResult: AccessibilityTranslationPollResult<T>
        do {
            try await recoverCoreSimulatorBridge(
                simulatorUDID: simulatorUDID,
                dependencies: dependencies
            )
            postRecoveryResult = try await pollForAccessibilityTranslation(
                intervals: readinessPollIntervals,
                wait: dependencies.wait,
                operation: operationWithTestManagerRecovery
            )
        } catch {
            try recoveryLease.markRecoveryCompleted()
            throw error
        }
        try recoveryLease.markRecoveryCompleted()

        if case let .available(value) = postRecoveryResult {
            return value
        }

        throw persistentTranslationError(simulatorUDID: simulatorUDID)
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
    }

    private static func pollForAccessibilityTranslation<T>(
        intervals: [Duration],
        wait: AccessibilityRecoveryDependencies.Waiter,
        operation: @MainActor () async throws -> T
    ) async throws -> AccessibilityTranslationPollResult<T> {
        do {
            return .available(try await operation())
        } catch {
            guard shouldRecoverCoreSimulatorBridge(from: error) else {
                throw error
            }
        }

        for interval in intervals {
            try await wait(interval)
            do {
                return .available(try await operation())
            } catch {
                guard shouldRecoverCoreSimulatorBridge(from: error) else {
                    throw error
                }
            }
        }

        return .unavailable
    }

    private static func persistentTranslationError(simulatorUDID: String) -> CLIError {
        CLIError(
            errorDescription: "AXe could not obtain accessibility information for simulator \(simulatorUDID) after retrying and restarting its CoreSimulator bridge. Restart the simulator and try again."
        )
    }
}

private enum AccessibilityTranslationPollResult<T> {
    case available(T)
    case unavailable
}
