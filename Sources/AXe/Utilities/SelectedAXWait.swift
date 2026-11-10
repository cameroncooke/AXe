import Foundation
import FBSimulatorControl

struct SelectedAXWaitPolicy: Codable, Sendable, Equatable {
    static let maximumTimeout = 30.0
    static let minimumPollInterval = 0.05
    static let maximumPollInterval = 30.0

    let timeoutSeconds: Double
    let pollIntervalSeconds: Double

    func validate() throws {
        guard timeoutSeconds.isFinite, timeoutSeconds > 0, timeoutSeconds <= Self.maximumTimeout else {
            throw SelectedHIDFailure.invalid("Selected --wait-timeout must be finite, greater than 0 and at most 30 seconds")
        }
        guard pollIntervalSeconds.isFinite,
              (Self.minimumPollInterval...Self.maximumPollInterval).contains(pollIntervalSeconds) else {
            throw SelectedHIDFailure.invalid("Selected --poll-interval must be finite and in 0.05...30 seconds")
        }
    }
}

struct SelectedAXWaitReceipt: Codable, Sendable {
    enum Outcome: String, Codable, Sendable { case matched, timedOut, cancelled, failed }
    let attempts: Int
    let elapsedSeconds: Double
    let outcome: Outcome
}

struct SelectedAXWaitFailure: Error, CustomStringConvertible {
    let receipt: SelectedAXWaitReceipt
    let cause: any Error
    var description: String {
        "Selected AX wait \(receipt.outcome.rawValue) after \(receipt.attempts) probes: \(String(reflecting: cause))"
    }
}

extension SelectedAXWaitFailure: LocalizedError {
    /// What a selected command prints. The probe count and the cause stay in `description`.
    var errorDescription: String? {
        switch receipt.outcome {
        case .timedOut: "The control did not become ready before the wait ended"
        case .cancelled: "The wait for the control was cancelled"
        case .failed, .matched:
            (cause as? LocalizedError)?.errorDescription ?? "AXe could not read the app's accessibility tree"
        }
    }
}

struct SelectedAXWaitAcquisitionFailure: Error, CustomStringConvertible {
    let acquisition: FBSimulatorAXAcquisition
    var description: String {
        "Selected AX acquisition ended with \(acquisition.outcome.rawValue): \(acquisition.failureDescription ?? "No further detail")"
    }
}

private enum SelectedAXWaitTimeout: Error { case expired }

/// Read-only probes stop at the first exact match. Final target admission and input
/// stay outside this loop and must never be retried by this owner.
@MainActor
enum SelectedAXWait {
    static func run(
        policy: SelectedAXWaitPolicy,
        now: () -> Double = { ProcessInfo.processInfo.systemUptime },
        sleep: (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        probe: (Double) async throws -> Void
    ) async throws -> SelectedAXWaitReceipt {
        try policy.validate()
        let started = now()
        var attempts = 0

        func receipt(_ outcome: SelectedAXWaitReceipt.Outcome) -> SelectedAXWaitReceipt {
            SelectedAXWaitReceipt(attempts: attempts, elapsedSeconds: max(0, now() - started), outcome: outcome)
        }

        do {
            while true {
                try Task.checkCancellation()
                let remaining = policy.timeoutSeconds - (now() - started)
                guard remaining > 0 else { throw SelectedAXWaitTimeout.expired }
                attempts += 1
                do {
                    // Each native acquisition keeps its existing eight-second maximum.
                    try await probe(min(8, remaining))
                    try Task.checkCancellation()
                    guard now() - started < policy.timeoutSeconds else { throw SelectedAXWaitTimeout.expired }
                    return receipt(.matched)
                } catch FBSimulatorAXSnapshotError.notFound {
                    try Task.checkCancellation()
                    let remaining = policy.timeoutSeconds - (now() - started)
                    guard remaining > 0 else { throw SelectedAXWaitTimeout.expired }
                    try await sleep(min(policy.pollIntervalSeconds, remaining))
                }
            }
        } catch {
            let outcome: SelectedAXWaitReceipt.Outcome
            if error is CancellationError {
                outcome = .cancelled
            } else if error is SelectedAXWaitTimeout {
                outcome = .timedOut
            } else if let failure = error as? SelectedAXWaitAcquisitionFailure,
                      failure.acquisition.outcome == .deadlineExceeded,
                      now() - started >= policy.timeoutSeconds {
                outcome = .timedOut
            } else {
                outcome = .failed
            }
            throw SelectedAXWaitFailure(receipt: receipt(outcome), cause: error)
        }
    }
}
