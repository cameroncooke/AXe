@testable import FBSimulatorControl
import Foundation
import Testing

/// A read that times out after the hinge write sends nothing, so the operation reads again
/// within its own deadline instead of reporting uncertain delivery.
@Suite("Hinge set readback")
struct FBSimulatorHingeOperationTests {
  @Test func timedOutReadAfterDispatchIsReadAgain() async throws {
    let backend = ScriptedHingeBackend(script: [.sample(0), .timeout, .sample(180), .sample(180)])
    let request = try FBSimulatorHingeRequest(degrees: 180, expectedBootIdentity: "boot", toleranceDegrees: 0.1)
    let receipt = try await FBSimulatorHingeOperation(backend: backend).set(request)
    #expect(receipt.matchingSamples.count == 2)
    #expect(await backend.dispatches == [180])
  }

  @Test func timedOutReadBeforeDispatchReportsNoDelivery() async throws {
    let backend = ScriptedHingeBackend(script: [.timeout])
    let request = try FBSimulatorHingeRequest(degrees: 180, expectedBootIdentity: "boot", toleranceDegrees: 0.1)
    do {
      _ = try await FBSimulatorHingeOperation(backend: backend).set(request)
      Issue.record("A timed-out first read must fail the operation")
    } catch let failure as FBSimulatorHingeFailure {
      #expect(failure.delivery == .notDispatched)
    }
    #expect(await backend.dispatches.isEmpty)
  }
}

private actor ScriptedHingeBackend: FBSimulatorHingeBackend {
  enum Step { case sample(Double), timeout }
  private var script: [Step]
  private(set) var dispatches: [Double] = []
  init(script: [Step]) { self.script = script }

  func validate(expectedBoot: String) async throws {}
  func sample() async throws -> FBSimulatorHingeSample {
    guard !script.isEmpty else { throw FBSimulatorHingeReadTimeout() }
    switch script.removeFirst() {
    case .timeout: throw FBSimulatorHingeReadTimeout()
    case .sample(let degrees):
      let now = ProcessInfo.processInfo.systemUptime
      return FBSimulatorHingeSample(mechanicalDegrees: degrees, sensedDegrees: degrees, velocityDegreesPerSecond: 0,
        minimumDegrees: 0, maximumDegrees: 180, timestampUptime: now, receivedUptime: now)
    }
  }
  func dispatch(degrees: Double) async throws { dispatches.append(degrees) }
  func close() async {}
}
