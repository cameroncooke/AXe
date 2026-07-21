import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Accessibility Translation Recovery Tests")
@MainActor
struct AccessibilityTranslationRecoveryTests {
    @Test("Retries a transient missing translation without restarting the bridge")
    func retriesTransientFailureWithoutRestart() async throws {
        var operationCount = 0
        var restartCount = 0
        var waits: [Duration] = []
        let dependencies = AccessibilityRecoveryDependencies(
            runProcess: { _, _, _ in
                restartCount += 1
                return 0
            },
            wait: { waits.append($0) }
        )

        let result = try await AccessibilityFetcher.retryingAfterAccessibilityRecovery(
            simulatorUDID: "TEST-UDID",
            logger: AxeLogger(),
            dependencies: dependencies
        ) {
            operationCount += 1
            if operationCount == 1 {
                throw FBAccessibilityError.noTranslationObject
            }
            return "recovered"
        }

        #expect(result == "recovered")
        #expect(operationCount == 2)
        #expect(restartCount == 0)
        #expect(waits == [.milliseconds(100)])
    }

    @Test("Restarts only the target simulator bridge after a persistent translation failure")
    func restartsTargetSimulatorBridgeOnce() async throws {
        var operationCount = 0
        var executableURL: URL?
        var arguments: [String] = []
        var timeout: TimeInterval?
        var restartCount = 0
        var waits: [Duration] = []
        let dependencies = AccessibilityRecoveryDependencies(
            runProcess: { receivedURL, receivedArguments, receivedTimeout in
                restartCount += 1
                executableURL = receivedURL
                arguments = receivedArguments
                timeout = receivedTimeout
                return 0
            },
            wait: { waits.append($0) }
        )

        let result = try await AccessibilityFetcher.retryingAfterAccessibilityRecovery(
            simulatorUDID: "TARGET-UDID",
            logger: AxeLogger(),
            dependencies: dependencies
        ) {
            operationCount += 1
            if operationCount < 3 {
                throw FBAccessibilityError.noTranslationObject
            }
            return "recovered"
        }

        #expect(result == "recovered")
        #expect(operationCount == 3)
        #expect(restartCount == 1)
        #expect(executableURL?.path == "/usr/bin/xcrun")
        #expect(arguments == [
            "simctl",
            "spawn",
            "TARGET-UDID",
            "launchctl",
            "kickstart",
            "-k",
            "user/foreground/com.apple.CoreSimulator.bridge",
        ])
        #expect(timeout == 3)
        #expect(waits == [.milliseconds(100), .milliseconds(250)])
    }

    @Test("Reports a scoped bridge restart failure without another operation attempt")
    func reportsBridgeRestartFailure() async {
        var operationCount = 0
        var restartCount = 0
        let dependencies = AccessibilityRecoveryDependencies(
            runProcess: { _, _, _ in
                restartCount += 1
                return 13
            },
            wait: { _ in }
        )

        do {
            _ = try await AccessibilityFetcher.retryingAfterAccessibilityRecovery(
                simulatorUDID: "TARGET-UDID",
                logger: AxeLogger(),
                dependencies: dependencies
            ) {
                operationCount += 1
                throw FBAccessibilityError.noTranslationObject
            } as String
            Issue.record("Expected recovery to fail")
        } catch {
            #expect(
                String(describing: error)
                    == "AXe could not restart the CoreSimulator bridge for simulator TARGET-UDID (exit status 13). Restart the simulator and try again."
            )
        }

        #expect(operationCount == 2)
        #expect(restartCount == 1)
    }

    @Test("Bounds persistent translation recovery to one bridge restart")
    func boundsPersistentFailureRecovery() async {
        var operationCount = 0
        var restartCount = 0
        let dependencies = AccessibilityRecoveryDependencies(
            runProcess: { _, _, _ in
                restartCount += 1
                return 0
            },
            wait: { _ in }
        )

        do {
            _ = try await AccessibilityFetcher.retryingAfterAccessibilityRecovery(
                simulatorUDID: "TARGET-UDID",
                logger: AxeLogger(),
                dependencies: dependencies
            ) {
                operationCount += 1
                throw FBAccessibilityError.noTranslationObject
            } as String
            Issue.record("Expected recovery to fail")
        } catch {
            #expect(
                String(describing: error)
                    == "AXe could not obtain accessibility information for simulator TARGET-UDID after retrying and restarting its CoreSimulator bridge. Restart the simulator and try again."
            )
        }

        #expect(operationCount == 3)
        #expect(restartCount == 1)
    }

    @Test("Preserves unrelated errors at every recovery stage")
    func preservesUnrelatedErrors() async {
        var operationCount = 0
        var restartCount = 0
        let dependencies = AccessibilityRecoveryDependencies(
            runProcess: { _, _, _ in
                restartCount += 1
                return 0
            },
            wait: { _ in }
        )
        let unrelated = NSError(
            domain: "Accessibility",
            code: 99,
            userInfo: [NSLocalizedDescriptionKey: "Unrelated failure"]
        )

        do {
            _ = try await AccessibilityFetcher.retryingAfterAccessibilityRecovery(
                simulatorUDID: "TARGET-UDID",
                logger: AxeLogger(),
                dependencies: dependencies
            ) {
                operationCount += 1
                throw unrelated
            } as String
            Issue.record("Expected the operation to fail")
        } catch {
            #expect(error.localizedDescription == "Unrelated failure")
        }

        #expect(operationCount == 1)
        #expect(restartCount == 0)
    }
}
