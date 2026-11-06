import Darwin
import Foundation
import FBSimulatorControl
@preconcurrency import FBControlCore

/// One operation owner; the common input lease covers only capture and validation.
@MainActor
final class SelectedMediaCapture {
    private(set) var stopRequested = false
    private var captureTask: Task<FBSimulatorSelectedScreenshot, Error>?

    static func run(operation: @escaping @MainActor (SelectedMediaCapture) async throws -> Void) async throws {
        let owner = SelectedMediaCapture()
        // Install before setup or capture can start a child. No await during attachment.
        let signals = SignalObserver(signals: [SIGINT, SIGTERM]) {
            Task { @MainActor in owner.requestStop() }
        }
        defer { signals.invalidate() }
        let task = Task { @MainActor in
            try Task.checkCancellation()
            try await operation(owner)
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            // Parent cancellation is fatal; OS signals only request a normal media stop.
            task.cancel()
        }
    }

    private func requestStop() {
        stopRequested = true
        captureTask?.cancel()
    }

    static func requireSameFrame(initial: FBSimulatorHIDSessionObservation,
                                 before: FBSimulatorHIDSessionObservation,
                                 after: FBSimulatorHIDSessionObservation) throws {
        guard initial == before, initial == after else {
            throw FBSimulatorSelectedScreenshotError.changedContext
        }
    }

    /// A cancellation error is normal only after this owner's signal stop request.
    /// Missing/uncertain child cleanup and all other errors remain fatal.
    private static func confirmedCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        guard let error = error as? ActivePanelReadError,
              error.childFailure == .cancelled, error.validationFailure == nil else { return false }
        guard let receipt = error.receipt else {
            // ActivePanelReader's entry cancellation check runs before child construction.
            return true
        }
        return receipt.exitConfirmed || !receipt.launchAttempted
    }

    func capture(simulator: FBSimulator, screenID: UInt32,
                 screenUUID: UUID, expectedBoot: String?,
                 initial: FBSimulatorHIDSessionObservation?) async throws -> FBSimulatorSelectedScreenshot? {
        try await captureOwned(simulator: simulator) {
            let frame = try await FBSimulatorSelectedScreenshotCapture.png(for: simulator,
                screenID: screenID, screenUniqueID: screenUUID,
                expectedBootIdentity: expectedBoot)
            let before = try frame.before.observation.sessionObservation()
            let after = try frame.after.observation.sessionObservation()
            try Self.requireSameFrame(initial: initial ?? before, before: before, after: after)
            return frame
        }
    }

    /// Discovery and this one frame share the lease. A later frame can use a new active panel.
    func captureActive(simulator: FBSimulator,
                       expectedBoot: String?) async throws -> FBSimulatorSelectedScreenshot? {
        try await captureOwned(simulator: simulator) {
            let discovery = try await ActivePanelReader.discoverWithMetadata(for: simulator)
            if let expectedBoot, discovery.bootIdentity != expectedBoot {
                throw CLIError(errorDescription: "Follow-active recording stopped: simulator boot changed")
            }
            let panel = discovery.readback.snapshot.activePanel.identity
            let frame = try await FBSimulatorSelectedScreenshotCapture.png(for: simulator,
                screenID: panel.displayID, screenUniqueID: panel.uniqueID,
                expectedBootIdentity: discovery.bootIdentity)
            let before = try frame.before.observation.sessionObservation()
            let after = try frame.after.observation.sessionObservation()
            try Self.requireSameFrame(initial: before, before: before, after: after)
            return frame
        }
    }

    private func captureOwned(simulator: FBSimulator,
                              operation: @escaping @MainActor () async throws -> FBSimulatorSelectedScreenshot)
        async throws -> FBSimulatorSelectedScreenshot? {
        try Task.checkCancellation()
        guard !stopRequested else { return nil }
        precondition(captureTask == nil)
        let task = Task { @MainActor in
            try Task.checkCancellation()
            let lease = try HIDInputLease.acquire(simulatorUDID: simulator.udid)
            defer { withExtendedLifetime(lease) {} }
            let frame = try await operation()
            try Task.checkCancellation()
            return frame
        }
        captureTask = task
        defer { captureTask = nil }
        do {
            let frame = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            try Task.checkCancellation()
            return frame
        } catch {
            // Awaiting task.value above includes PNG feed close and owned child cleanup.
            // Do not turn stale context or guest cleanup errors into an ordinary stop.
            if stopRequested, !Task.isCancelled, Self.confirmedCancellation(error) { return nil }
            throw error
        }
    }

}
