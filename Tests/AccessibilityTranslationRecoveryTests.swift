import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Accessibility Translation Recovery Tests")
@MainActor
struct AccessibilityTranslationRecoveryTests {
    private let readinessIntervals = AccessibilityFetcher.translationReadinessPollIntervals

    @Test("Accepts translation that becomes ready at the end of the initial window")
    func acceptsLatePreRecoverySuccess() async throws {
        var operationCount = 0
        var restartCount = 0
        var lockCount = 0
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
            dependencies: dependencies,
            lockAcquirer: { _ in
                lockCount += 1
                return AccessibilityRecoveryLockLease {}
            },
            generationReader: missingGeneration
        ) {
            operationCount += 1
            guard operationCount == 17 else {
                throw FBAccessibilityError.noTranslationObject
            }
            return "ready"
        }

        #expect(result == "ready")
        #expect(operationCount == 17)
        #expect(restartCount == 0)
        #expect(lockCount == 0)
        #expect(waits == readinessIntervals)
        #expect(waits.reduce(.zero, +) == .seconds(8))
    }

    @Test("Restarts only after the full readiness window")
    func restartsAfterReadinessWindow() async throws {
        var operationCount = 0
        var restartCount = 0
        var didRestart = false
        var executableURL: URL?
        var arguments: [String] = []
        var timeout: TimeInterval?
        var waits: [Duration] = []
        let dependencies = AccessibilityRecoveryDependencies(
            runProcess: { receivedURL, receivedArguments, receivedTimeout in
                restartCount += 1
                didRestart = true
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
            dependencies: dependencies,
            lockAcquirer: immediateLock,
            generationReader: missingGeneration
        ) {
            operationCount += 1
            guard didRestart else {
                throw FBAccessibilityError.noTranslationObject
            }
            return "recovered"
        }

        #expect(result == "recovered")
        #expect(operationCount == 19)
        #expect(restartCount == 1)
        #expect(waits == readinessIntervals)
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
    }

    @Test("Accepts translation that becomes ready at the end of the post-restart window")
    func acceptsLatePostRecoverySuccess() async throws {
        var preRestartOperationCount = 0
        var postRestartOperationCount = 0
        var didRestart = false
        var waits: [Duration] = []
        let dependencies = AccessibilityRecoveryDependencies(
            runProcess: { _, _, _ in
                didRestart = true
                return 0
            },
            wait: { waits.append($0) }
        )

        let result = try await AccessibilityFetcher.retryingAfterAccessibilityRecovery(
            simulatorUDID: "TARGET-UDID",
            logger: AxeLogger(),
            dependencies: dependencies,
            lockAcquirer: immediateLock,
            generationReader: missingGeneration
        ) {
            if didRestart {
                postRestartOperationCount += 1
                guard postRestartOperationCount == 17 else {
                    throw FBAccessibilityError.noTranslationObject
                }
                return "recovered"
            }
            preRestartOperationCount += 1
            throw FBAccessibilityError.noTranslationObject
        }

        #expect(result == "recovered")
        #expect(preRestartOperationCount == 18)
        #expect(postRestartOperationCount == 17)
        #expect(waits == readinessIntervals + readinessIntervals)
        #expect(waits.reduce(.zero, +) == .seconds(16))
    }

    @Test("Bounds persistent translation recovery to one restart and two readiness windows")
    func boundsPersistentFailureRecovery() async {
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

        do {
            _ = try await AccessibilityFetcher.retryingAfterAccessibilityRecovery(
                simulatorUDID: "TARGET-UDID",
                logger: AxeLogger(),
                dependencies: dependencies,
                lockAcquirer: immediateLock,
                generationReader: missingGeneration
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

        #expect(operationCount == 35)
        #expect(restartCount == 1)
        #expect(waits == readinessIntervals + readinessIntervals)
    }

    @Test("Does not mutate simulator state for point queries")
    func pointQueryPreservesMissingTranslationError() async {
        var operationCount = 0
        var restartCount = 0
        var lockCount = 0
        var waitCount = 0
        let dependencies = AccessibilityRecoveryDependencies(
            runProcess: { _, _, _ in
                restartCount += 1
                return 0
            },
            wait: { _ in waitCount += 1 }
        )

        do {
            _ = try await AccessibilityFetcher.retryingAfterAccessibilityRecovery(
                simulatorUDID: "TARGET-UDID",
                logger: AxeLogger(),
                dependencies: dependencies,
                allowsCoreSimulatorBridgeRecovery: false,
                lockAcquirer: { _ in
                    lockCount += 1
                    return AccessibilityRecoveryLockLease {}
                }
            ) {
                operationCount += 1
                throw FBAccessibilityError.noTranslationObject
            } as String
            Issue.record("Expected point query to preserve the translation error")
        } catch let error as FBAccessibilityError {
            guard case .noTranslationObject = error else {
                Issue.record("Expected noTranslationObject, received \(error)")
                return
            }
        } catch {
            Issue.record("Expected FBAccessibilityError, received \(error)")
        }

        #expect(operationCount == 1)
        #expect(restartCount == 0)
        #expect(lockCount == 0)
        #expect(waitCount == 0)
    }

    @Test("Concurrent requests for one simulator coalesce to one bridge restart")
    func concurrentRequestsRestartOnce() async throws {
        let coordinator = TestRecoveryCoordinator()
        var bridgeIsReady = false
        var restartCount = 0
        let dependencies = AccessibilityRecoveryDependencies(
            runProcess: { _, _, _ in
                while coordinator.waitingCount == 0 {
                    await Task.yield()
                }
                restartCount += 1
                bridgeIsReady = true
                return 0
            },
            wait: { _ in }
        )
        let operation: @MainActor () async throws -> String = {
            guard bridgeIsReady else {
                throw FBAccessibilityError.noTranslationObject
            }
            return "ready"
        }

        let first = Task { @MainActor in
            try await AccessibilityFetcher.retryingAfterAccessibilityRecovery(
                simulatorUDID: "TARGET-UDID",
                logger: AxeLogger(),
                dependencies: dependencies,
                readinessPollIntervals: [],
                lockAcquirer: coordinator.acquire,
                generationReader: coordinator.readGeneration,
                operation: operation
            )
        }
        let second = Task { @MainActor in
            try await AccessibilityFetcher.retryingAfterAccessibilityRecovery(
                simulatorUDID: "TARGET-UDID",
                logger: AxeLogger(),
                dependencies: dependencies,
                readinessPollIntervals: [],
                lockAcquirer: coordinator.acquire,
                generationReader: coordinator.readGeneration,
                operation: operation
            )
        }

        let results = try await [first.value, second.value]
        #expect(results == ["ready", "ready"])
        #expect(restartCount == 1)
        #expect(coordinator.acquisitionCount == 2)
    }

    @Test("Concurrent persistent failures share one attempt while a later request may retry")
    func concurrentPersistentFailuresShareAttempt() async {
        let coordinator = TestRecoveryCoordinator()
        var restartCount = 0
        let dependencies = AccessibilityRecoveryDependencies(
            runProcess: { _, _, _ in
                if restartCount == 0 {
                    while coordinator.waitingCount == 0 {
                        await Task.yield()
                    }
                }
                restartCount += 1
                return 0
            },
            wait: { _ in }
        )
        let request: @MainActor () async -> String = {
            do {
                _ = try await AccessibilityFetcher.retryingAfterAccessibilityRecovery(
                    simulatorUDID: "TARGET-UDID",
                    logger: AxeLogger(),
                    dependencies: dependencies,
                    readinessPollIntervals: [],
                    lockAcquirer: coordinator.acquire,
                    generationReader: coordinator.readGeneration
                ) {
                    throw FBAccessibilityError.noTranslationObject
                } as String
                return "unexpected success"
            } catch {
                return String(describing: error)
            }
        }

        let first = Task { @MainActor in await request() }
        let second = Task { @MainActor in await request() }
        let concurrentResults = await [first.value, second.value]
        let expectedError =
            "AXe could not obtain accessibility information for simulator TARGET-UDID after retrying and restarting its CoreSimulator bridge. Restart the simulator and try again."

        #expect(concurrentResults == [expectedError, expectedError])
        #expect(restartCount == 1)

        let laterResult = await request()
        #expect(laterResult == expectedError)
        #expect(restartCount == 2)
    }

    @Test("Reports a scoped bridge restart failure")
    func reportsBridgeRestartFailure() async {
        var operationCount = 0
        let dependencies = AccessibilityRecoveryDependencies(
            runProcess: { _, _, _ in 13 },
            wait: { _ in }
        )

        do {
            _ = try await AccessibilityFetcher.retryingAfterAccessibilityRecovery(
                simulatorUDID: "TARGET-UDID",
                logger: AxeLogger(),
                dependencies: dependencies,
                readinessPollIntervals: [],
                lockAcquirer: immediateLock,
                generationReader: missingGeneration
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
    }

    @Test("Preserves unrelated errors without recovery")
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
                dependencies: dependencies,
                lockAcquirer: immediateLock,
                generationReader: missingGeneration
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

    private func immediateLock(_: String) async throws -> AccessibilityRecoveryLockLease {
        AccessibilityRecoveryLockLease {}
    }

    private func missingGeneration(_: String) throws -> AccessibilityRecoveryGeneration {
        .initial
    }
}

@MainActor
private final class TestRecoveryCoordinator {
    private var generation = AccessibilityRecoveryGeneration.initial
    private var isHeld = false
    private var waiters: [CheckedContinuation<AccessibilityRecoveryLockLease, Never>] = []
    private(set) var acquisitionCount = 0

    var waitingCount: Int {
        waiters.count
    }

    func readGeneration(_: String) -> AccessibilityRecoveryGeneration {
        generation
    }

    func acquire(_: String) async -> AccessibilityRecoveryLockLease {
        acquisitionCount += 1
        if !isHeld {
            isHeld = true
            return makeLease()
        }

        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func makeLease() -> AccessibilityRecoveryLockLease {
        AccessibilityRecoveryLockLease(
            generation: generation,
            markRecoveryCompletedHandler: { [weak self] in
                guard let self else {
                    return
                }
                self.generation = AccessibilityRecoveryGeneration(value: self.generation.value + 1)
            },
            releaseHandler: { [weak self] in
                self?.release()
            }
        )
    }

    private func release() {
        guard !waiters.isEmpty else {
            isHeld = false
            return
        }

        let continuation = waiters.removeFirst()
        continuation.resume(returning: makeLease())
    }
}
