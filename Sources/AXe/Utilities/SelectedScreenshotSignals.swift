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
        do {
            try await owner.run(operation: operation)
        } catch {
            if owner.cancellationRequested && isCancellation(error) {
                FileHandle.standardError.write(Data(
                    "Selected screenshot cancelled; awaited operation returned.\n".utf8))
            }
            // In particular, keep cleanupUnconfirmed and guestCleanupUnconfirmed intact.
            throw error
        }
    }

    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? ActivePanelReadError)?.childFailure == .cancelled
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
