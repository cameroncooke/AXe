import Foundation
import Testing
import FBSimulatorControl
@testable import AXe

@Suite("Selected screenshot task ownership")
@MainActor
struct SelectedScreenshotSignalTests {
    @Test func cancellationBeforeAttachmentPreventsOperation() async {
        let owner = SelectedScreenshotSignals.Owner()
        var entered = false
        owner.cancel()
        do {
            try await owner.run { entered = true }
            Issue.record("Cancelled owner returned success")
        } catch { #expect(error is CancellationError) }
        #expect(!entered)
    }

    @Test(arguments: [false, true])
    func cancellationAwaitsOperationCleanup(cancelCaller: Bool) async {
        let owner = SelectedScreenshotSignals.Owner()
        var entered = false
        var cleanupEntered = false
        var returned = false
        var finishCleanup: CheckedContinuation<Void, Never>?
        let waiter = Task { @MainActor in
            defer { returned = true }
            do {
                try await owner.run {
                    entered = true
                    do { try await Task.sleep(for: .seconds(60)) }
                    catch {
                        cleanupEntered = true
                        await withCheckedContinuation { finishCleanup = $0 }
                        throw error
                    }
                }
                Issue.record("Cancelled operation returned success")
            } catch { #expect(error is CancellationError) }
        }
        while !entered { await Task.yield() }
        if cancelCaller { waiter.cancel() } else { owner.cancel() }
        while !cleanupEntered { await Task.yield() }
        #expect(!returned)
        finishCleanup?.resume()
        await waiter.value
        #expect(returned)
    }

    @Test func uncertainCleanupIsNotReportedAsCancellation() {
        #expect(SelectedScreenshotSignals.isCancellation(CancellationError()))
        #expect(SelectedScreenshotSignals.isCancellation(ActivePanelReadError(childFailure: .cancelled)))
        #expect(!SelectedScreenshotSignals.isCancellation(ActivePanelReadError(childFailure: .cleanupUnconfirmed)))
        #expect(!SelectedScreenshotSignals.isCancellation(FBSimulatorContextError.guestCleanupUnconfirmed("late owner")))
    }
}
