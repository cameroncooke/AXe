import Darwin
import Foundation

struct SelectedBatchHostWaitReceipt: Encodable, Sendable {
    enum Outcome: String, Encodable, Sendable { case completed, interrupted, failed }
    let requestedSeconds: Double
    let elapsedSeconds: Double
    let outcome: Outcome
    let error: String?
}

/// Host time only: no simulator connection, broker request or input lease.
@MainActor
enum SelectedBatchHostWait {
    static func wait(seconds: Double) async -> SelectedBatchHostWaitReceipt {
        let clock = ContinuousClock()
        let start = clock.now
        func receipt(_ outcome: SelectedBatchHostWaitReceipt.Outcome,
                     error: String? = nil) -> SelectedBatchHostWaitReceipt {
            let elapsed = start.duration(to: clock.now).components
            return .init(requestedSeconds: seconds,
                elapsedSeconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
                outcome: outcome, error: error)
        }
        guard seconds.isFinite, seconds >= 0 else {
            return receipt(.failed, error: "Host wait duration must be finite and non-negative.")
        }
        do {
            while true {
                try Task.checkCancellation()
                let elapsed = receipt(.completed).elapsedSeconds
                if elapsed >= seconds { return receipt(.completed) }
                // Convert only bounded intervals to Duration. No total duration cap or
                // huge absolute deadline, and no repeated subtraction from a huge Double.
                try await Task.sleep(for: .seconds(min(60, seconds - elapsed)))
            }
        } catch {
            return receipt(.interrupted, error: String(describing: error))
        }
    }

    /// Observe signals only while waiting. Await the owned task before restoring handlers.
    /// No child can start within this scope, and no whole-batch signal guarantee is made.
    static func runWithSignals(seconds: Double) async -> SelectedBatchHostWaitReceipt {
        var previousINT = sigaction()
        var previousTERM = sigaction()
        guard sigaction(SIGINT, nil, &previousINT) == 0,
              sigaction(SIGTERM, nil, &previousTERM) == 0 else {
            return .init(requestedSeconds: seconds, elapsedSeconds: 0, outcome: .failed,
                         error: "Could not read host-wait signal dispositions.")
        }
        let task = Task { @MainActor in await wait(seconds: seconds) }
        var observer: SignalObserver? = SignalObserver(signals: [SIGINT, SIGTERM]) { task.cancel() }
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        let interrupted = task.isCancelled || Task.isCancelled
        observer?.invalidate()
        observer = nil // Deinit resets defaults; restore saved dispositions only after it.
        let restoredINT = sigaction(SIGINT, &previousINT, nil) == 0
        let restoredTERM = sigaction(SIGTERM, &previousTERM, nil) == 0
        guard restoredINT && restoredTERM else {
            return .init(requestedSeconds: seconds, elapsedSeconds: result.elapsedSeconds, outcome: .failed,
                         error: "Could not restore host-wait signal dispositions.")
        }
        if interrupted && result.outcome == .completed {
            return .init(requestedSeconds: seconds, elapsedSeconds: result.elapsedSeconds, outcome: .interrupted,
                         error: "The host wait was cancelled.")
        }
        return result
    }
}
