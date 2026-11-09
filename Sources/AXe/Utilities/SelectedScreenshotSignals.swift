import Darwin
import Foundation
import FBSimulatorControl

/// Only selected PNG capture installs this bridge. Video and legacy capture are unchanged.
@MainActor
enum SelectedScreenshotSignals {
    static func run(operation: @escaping @MainActor () async throws -> Void) async throws {
        let owner = Owner()
        // Install before creating the operation task or starting setup/native children.
        let observer = SignalObserver(signals: [SIGINT, SIGTERM]) {
            Task { @MainActor in owner.cancel() }
        }
        defer { observer.invalidate() }
        // The error is rethrown unchanged; in particular, cleanupUnconfirmed stays an error. A
        // signal cancellation exits with 128 + the signal and prints nothing.
        try await owner.run(operation: operation)
    }

    @MainActor
    final class Owner {
        private var task: Task<Void, Error>?
        private(set) var cancellationRequested = false

        func cancel() {
            cancellationRequested = true
            task?.cancel()
        }

        func run(operation: @escaping @MainActor () async throws -> Void) async throws {
            precondition(task == nil)
            let operationTask = Task { @MainActor in
                try Task.checkCancellation()
                try await operation()
            }
            // No suspension between task creation and attachment. Both the operation and
            // signal callback use this actor; cancellation before attachment is remembered.
            task = operationTask
            if cancellationRequested { operationTask.cancel() }
            defer { task = nil }
            try await withTaskCancellationHandler {
                try await operationTask.value
            } onCancel: {
                operationTask.cancel()
            }
        }
    }
}
