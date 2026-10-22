import Darwin
import Foundation

/// Own signals until the batch action has joined all input and host-read cleanup.
@MainActor
enum LegacyDuoBatchLifetime {
    static func run(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        var previousINT = sigaction()
        var previousTERM = sigaction()
        guard sigaction(SIGINT, nil, &previousINT) == 0,
              sigaction(SIGTERM, nil, &previousTERM) == 0 else {
            throw CLIError(errorDescription: "Could not read Duo batch signal dispositions.")
        }
        let task = Task { @MainActor in try await operation() }
        var observer: SignalObserver? = SignalObserver(signals: [SIGINT, SIGTERM]) { task.cancel() }
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
        }
        let interrupted = task.isCancelled || Task.isCancelled
        observer?.invalidate()
        observer = nil
        let restoredINT = sigaction(SIGINT, &previousINT, nil) == 0
        let restoredTERM = sigaction(SIGTERM, &previousTERM, nil) == 0
        guard restoredINT && restoredTERM else {
            throw CLIError(errorDescription: "Could not restore Duo batch signal dispositions.")
        }
        try result.get()
        if interrupted { throw CancellationError() }
    }
}
