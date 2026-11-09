import Darwin
import Foundation

/// SIGINT and SIGTERM cancel the operation. The saved dispositions are restored only after the
/// operation has finished, including its input and host-read cleanup.
@MainActor
enum SignalScope {
    struct Outcome<Value: Sendable> {
        let result: Result<Value, Error>
        let interrupted: Bool
        let restored: Bool
    }

    /// Nil when the current dispositions cannot be read; the operation has not started.
    static func run<Value: Sendable>(
        _ operation: @escaping @MainActor () async throws -> Value
    ) async -> Outcome<Value>? {
        var previousINT = sigaction()
        var previousTERM = sigaction()
        guard sigaction(SIGINT, nil, &previousINT) == 0,
              sigaction(SIGTERM, nil, &previousTERM) == 0 else { return nil }
        let task = Task { @MainActor in try await operation() }
        var observer: SignalObserver? = SignalObserver(signals: [SIGINT, SIGTERM]) { task.cancel() }
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
        }
        let interrupted = task.isCancelled || Task.isCancelled
        observer?.invalidate()
        observer = nil // Deinit resets defaults; restore saved dispositions only after it.
        let restoredINT = sigaction(SIGINT, &previousINT, nil) == 0
        let restoredTERM = sigaction(SIGTERM, &previousTERM, nil) == 0
        return Outcome(result: result, interrupted: interrupted, restored: restoredINT && restoredTERM)
    }

    /// Throws the operation's error, or CancellationError after a signal.
    static func cancellingOnSignal(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        guard let outcome = await run(operation) else {
            throw CLIError(errorDescription: "Could not read input signal dispositions.")
        }
        guard outcome.restored else {
            throw CLIError(errorDescription: "Could not restore input signal dispositions.")
        }
        try outcome.result.get()
        if outcome.interrupted { throw CancellationError() }
    }
}
