import Foundation
import Testing
@testable import AXe

@Suite("Accessibility Recovery Lock Tests")
@MainActor
struct AccessibilityRecoveryLockTests {
    @Test("A second lease for one simulator waits for the first lease")
    func serializesSameSimulatorRecovery() async throws {
        let simulatorUDID = UUID().uuidString
        let firstLease = try await AccessibilityRecoveryLock.acquire(simulatorUDID: simulatorUDID)
        var secondLeaseWasAcquired = false
        let secondTask = Task { @MainActor in
            let lease = try await AccessibilityRecoveryLock.acquire(simulatorUDID: simulatorUDID)
            secondLeaseWasAcquired = true
            return lease
        }

        try await Task.sleep(for: .milliseconds(150))
        #expect(!secondLeaseWasAcquired)

        firstLease.release()
        let secondLease = try await secondTask.value
        #expect(secondLeaseWasAcquired)
        secondLease.release()
    }

    @Test("Cancelling a lock waiter does not retain its descriptor")
    func cancellationReleasesWaitingDescriptor() async throws {
        let simulatorUDID = UUID().uuidString
        let firstLease = try await AccessibilityRecoveryLock.acquire(simulatorUDID: simulatorUDID)
        let cancelledTask = Task { @MainActor in
            try await AccessibilityRecoveryLock.acquire(simulatorUDID: simulatorUDID)
        }

        try await Task.sleep(for: .milliseconds(150))
        cancelledTask.cancel()
        do {
            _ = try await cancelledTask.value
            Issue.record("Expected the waiting lock acquisition to be cancelled")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, received \(error)")
        }

        firstLease.release()
        let replacementLease = try await AccessibilityRecoveryLock.acquire(
            simulatorUDID: simulatorUDID
        )
        replacementLease.release()
    }
}
