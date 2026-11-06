import Foundation
import Testing
@testable import FBSimulatorControl

@Suite("Bounded read-only accessibility readiness")
struct FBSimulatorAXAcquisitionPolicyTests {
  @Test func existingDefaultsAndSingleAttemptInputPolicyStayUnchanged() throws {
    let defaults = try FBSimulatorAXAcquisitionPolicy()
    #expect(defaults.timeoutSeconds == 8)
    #expect(defaults.maximumAttempts == 4)
    #expect(defaults.retryDelaySeconds == 0)
    let input = try FBSimulatorAXAcquisitionPolicy(timeoutSeconds: 8, maximumAttempts: 1)
    #expect(input.maximumAttempts == 1)
    #expect(input.retryDelaySeconds == 0)
    let description = try FBSimulatorAXAcquisitionPolicy(timeoutSeconds: 8,
      maximumAttempts: 8, retryDelaySeconds: 0.5)
    #expect(description.timeoutSeconds == defaults.timeoutSeconds)
    #expect(description.maximumAttempts == 8)
    #expect(description.retryDelaySeconds == 0.5)
  }

  @Test func policyRejectsUnboundedAttemptsAndInvalidDelays() {
    for count in [0, 9, Int.max] {
      #expect(throws: FBSimulatorAXSnapshotError.self) {
        _ = try FBSimulatorAXAcquisitionPolicy(maximumAttempts: count)
      }
    }
    for delay in [-0.01, Double.nan, Double.infinity, 8.01] {
      #expect(throws: FBSimulatorAXSnapshotError.self) {
        _ = try FBSimulatorAXAcquisitionPolicy(timeoutSeconds: 8,
          maximumAttempts: 8, retryDelaySeconds: delay)
      }
    }
  }

  @Test func aReadinessWaitCannotExtendTheOriginalDeadline() async throws {
    let budget = FBAXAcquisitionBudget(seconds: 0.02)
    let started = DispatchTime.now().uptimeNanoseconds
    do {
      try await budget.waitForReadiness(seconds: 0.5)
      Issue.record("The readiness wait outlived its deadline without failing.")
    } catch let stop as FBAXAcquisitionStop {
      #expect(stop.outcome == .deadlineExceeded)
    }
    // This distinguishes the original deadline from sleeping the full retry delay.
    #expect(DispatchTime.now().uptimeNanoseconds - started < 400_000_000)
  }

  @Test func cancellationInterruptsAReadinessWait() async throws {
    let budget = FBAXAcquisitionBudget(seconds: 8)
    let waiting = Task { try await budget.waitForReadiness(seconds: 0.5) }
    try await Task.sleep(nanoseconds: 20_000_000)
    let cancelled = DispatchTime.now().uptimeNanoseconds
    waiting.cancel()
    switch await waiting.result {
    case .success:
      Issue.record("A cancelled readiness wait reported success.")
    case .failure(let error):
      #expect(error is CancellationError)
    }
    #expect(DispatchTime.now().uptimeNanoseconds - cancelled < 400_000_000)
  }

  @Test func terminalContextOrProcessFailuresDoNotStartAnotherWait() async throws {
    let outcomes: [FBSimulatorAXAcquisitionOutcome] = [.contextChanged, .processChanged, .cancelled]
    for outcome in outcomes {
      let budget = FBAXAcquisitionBudget(seconds: 8)
      budget.stop(outcome)
      do {
        try await budget.waitForReadiness(seconds: 0.5)
        Issue.record("A stopped acquisition entered another readiness wait.")
      } catch let stop as FBAXAcquisitionStop {
        #expect(stop.outcome == outcome)
      }
    }
  }
}
