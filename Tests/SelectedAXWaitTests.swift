import ArgumentParser
import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Selected tap polling")
@MainActor
struct SelectedAXWaitTests {
    private let udid = "00000000-0000-0000-0000-000000000001"
    private let screen = "00000000-0000-0000-0000-000000000003"
    private var selection: [String] {
        ["--input-mode", "selected", "--screen-id", "3", "--screen-uuid", screen]
    }
    private func command(_ arguments: [String]) throws -> Tap {
        try Tap.parse(["--udid", udid] + selection + arguments)
    }
    private final class Clock {
        var uptime = 0.0
    }

    @Test(arguments: ["--id", "--label", "--value"], ["physical", "simulator", "automatic"])
    func waitPolicyReachesWireAndBatchWithoutChangingSelectors(option: String, style: String) throws {
        let arguments = [option, " Ready ", "--expected-pid", "42", "--element-type", "Button",
            "--tap-style", style, "--wait-timeout", "30", "--poll-interval", "0.05"]
        let direct = try command(arguments).selectedRequest()
        let batch = try SelectedBatchStep.request(["tap"] + arguments,
            input: SelectedInputOptions.parse(selection), simulatorUDID: udid)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(direct.ax) == encoder.encode(batch.ax))
        let decoded = try JSONDecoder().decode(SelectedHIDRequest.self, from: encoder.encode(direct))
        try decoded.validate()
        #expect(decoded.version == SelectedHIDRequest.version)
        #expect(decoded.ax?.selectorValue == " Ready " && decoded.ax?.elementType == "Button")
        #expect(decoded.ax?.waitPolicy == .init(timeoutSeconds: 30, pollIntervalSeconds: 0.05))
    }

    @Test func zeroWaitKeepsPolicyAbsentAndBatchLevelOptionsReject() throws {
        let request = try command(["--id", "target", "--expected-pid", "42"]).selectedRequest()
        #expect(request.ax?.waitPolicy == nil)
        #expect(!String(decoding: try JSONEncoder().encode(request.ax), as: UTF8.self).contains("waitPolicy"))
        for extra in [["--wait-timeout", "1"], ["--poll-interval", "0.1"]] {
            #expect(throws: (any Error).self) {
                _ = try Batch.parse(["--udid", udid] + selection + extra + ["--step", "sleep 0"])
            }
        }
    }

    @Test(arguments: [
        ["--wait-timeout", "nan"], ["--wait-timeout", "inf"], ["--wait-timeout", "-1"],
        ["--wait-timeout", "30.001"], ["--poll-interval", "0.1"],
        ["--wait-timeout", "1", "--poll-interval", "nan"],
        ["--wait-timeout", "1", "--poll-interval", "inf"],
        ["--wait-timeout", "1", "--poll-interval", "0"],
        ["--wait-timeout", "1", "--poll-interval", "0.049"],
        ["--wait-timeout", "1", "--poll-interval", "30.001"]
    ])
    func invalidPolicyRejectsBeforeSend(extra: [String]) throws {
        #expect(throws: (any Error).self) {
            _ = try command(["--id", "target", "--expected-pid", "42"] + extra)
        }
    }

    @Test(arguments: [["-x", "1", "-y", "2"], ["--id", "target", "--expected-pid", "42", "--semantic-press"]],
          [["--wait-timeout", "1"], ["--poll-interval", "0.1"]])
    func coordinatesAndSemanticPressKeepPollingRejection(target: [String], extra: [String]) throws {
        #expect(throws: (any Error).self) { _ = try command(target + extra) }
    }

    @Test(arguments: [SelectedAXRequest.Kind.describe, .describePoint, .sliderEndpoint, .semanticPress])
    func waitCannotEnterOtherAXKinds(kind: SelectedAXRequest.Kind) throws {
        let ax = SelectedAXRequest(kind: kind, expectedPID: 42,
            endpoint: kind == .sliderEndpoint ? .minimum : nil,
            selectorKind: kind == .sliderEndpoint || kind == .semanticPress ? .id : nil,
            selectorValue: kind == .sliderEndpoint || kind == .semanticPress ? "target" : nil,
            preDelay: 0, postDelay: 0, point: kind == .describePoint ? .init(x: 1, y: 2) : nil,
            waitPolicy: .init(timeoutSeconds: 1, pollIntervalSeconds: 0.25))
        #expect(throws: (any Error).self) { try ax.validate() }
    }

    @Test func oldWireRejectsWaitBeforeOwnership() throws {
        let current = try command(["--id", "target", "--expected-pid", "42", "--wait-timeout", "1"]).selectedRequest()
        let old = SelectedHIDRequest(version: 27, requestID: current.requestID,
            screenID: current.screenID, screenUUID: current.screenUUID, operation: .complete,
            token: nil, primitives: [], ax: current.ax)
        var admission = SelectedHIDAdmission()
        #expect(throws: (any Error).self) { try admission.enter(old) }
        #expect(!admission.inFlight)
    }

    @Test func onlyMissingTargetRetriesWithRemainingBudget() async throws {
        let clock = Clock()
        var budgets: [Double] = []
        var sleeps: [Double] = []
        let result = try await SelectedAXWait.run(policy: .init(timeoutSeconds: 1, pollIntervalSeconds: 0.25),
            now: { clock.uptime }, sleep: { seconds in
                sleeps.append(seconds)
                clock.uptime += seconds
            }, probe: { budget in
                budgets.append(budget)
                if budgets.count < 3 { throw FBSimulatorAXSnapshotError.notFound }
            })
        #expect(result.outcome == .matched && result.attempts == 3 && result.elapsedSeconds == 0.5)
        #expect(budgets == [1, 0.75, 0.5] && sleeps == [0.25, 0.25])
    }

    @Test(arguments: [FBSimulatorAXSnapshotError.ambiguous(count: 2), .staleContext, .invalidSelection])
    func fatalSelectorOrContextFailureDoesNotSleepOrRetry(cause: FBSimulatorAXSnapshotError) async throws {
        var calls = 0
        var sleeps = 0
        do {
            _ = try await SelectedAXWait.run(policy: .init(timeoutSeconds: 1, pollIntervalSeconds: 0.25),
                sleep: { _ in sleeps += 1 }, probe: { _ in calls += 1; throw cause })
            Issue.record("Fatal probe failure was accepted")
        } catch let failure as SelectedAXWaitFailure {
            #expect(failure.receipt.outcome == .failed && failure.receipt.attempts == 1)
            #expect(failure.cause is FBSimulatorAXSnapshotError)
        }
        #expect(calls == 1 && sleeps == 0)
    }

    @Test func timeoutBoundsTheLastSleepAndNeverStartsAnotherProbe() async throws {
        let clock = Clock()
        var sleeps: [Double] = []
        do {
            _ = try await SelectedAXWait.run(policy: .init(timeoutSeconds: 0.5, pollIntervalSeconds: 0.3),
                now: { clock.uptime }, sleep: { seconds in
                    sleeps.append(seconds)
                    clock.uptime += seconds
                }, probe: { _ in throw FBSimulatorAXSnapshotError.notFound })
            Issue.record("Missing target was accepted")
        } catch let failure as SelectedAXWaitFailure {
            #expect(failure.receipt.outcome == .timedOut && failure.receipt.attempts == 2)
            #expect(failure.receipt.elapsedSeconds == 0.5)
            // The printed text is a sentence for the reader, not Foundation's rendering of the type.
            #expect(failure.localizedDescription == "The control did not become ready before the wait ended")
        }
        #expect(sleeps == [0.3, 0.2])
    }

    @Test func lateProbeCannotAdmitATargetAndNativeBudgetStaysEightSeconds() async throws {
        let clock = Clock()
        var budgets: [Double] = []
        do {
            _ = try await SelectedAXWait.run(policy: .init(timeoutSeconds: 30, pollIntervalSeconds: 0.25),
                now: { clock.uptime }, probe: { budget in budgets.append(budget); clock.uptime = 30 })
            Issue.record("A target after the deadline was accepted")
        } catch let failure as SelectedAXWaitFailure {
            #expect(failure.receipt.outcome == .timedOut && failure.receipt.attempts == 1)
        }
        #expect(budgets == [8])
    }

    @Test func cancellationDuringSleepStopsBeforeAnotherProbe() async throws {
        var pending: Task<SelectedAXWaitReceipt, any Error>?
        await withCheckedContinuation { started in
            pending = Task { @MainActor in
                try await SelectedAXWait.run(policy: .init(timeoutSeconds: 30, pollIntervalSeconds: 30),
                    sleep: { _ in
                        started.resume()
                        try await Task.sleep(for: .seconds(30))
                    }, probe: { _ in throw FBSimulatorAXSnapshotError.notFound })
            }
        }
        let task = try #require(pending)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled wait was accepted")
        } catch let failure as SelectedAXWaitFailure {
            #expect(failure.receipt.outcome == .cancelled && failure.receipt.attempts == 1)
        }
    }
}
