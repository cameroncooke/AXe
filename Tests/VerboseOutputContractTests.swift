import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

/// `--verbose` may only add detail: exit status and error codes match the plain command.
@Suite("Verbose output contract")
@MainActor
struct VerboseOutputContractTests {
    private func response(outcome: String = "failedNoReplay", events: Int = 0, cleanup: String = "notNeeded",
                          error: String? = nil) -> SelectedHIDResponse {
        SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: UUID(), brokerID: UUID(),
            outcome: outcome, token: nil, enqueuedEventCount: events, cleanup: cleanup, error: error, context: nil)
    }

    private var quarantined: SelectedHIDResponse {
        var value = response(outcome: "rejectedBeforeInput")
        value.quarantine = SelectedHIDQuarantine(recordPath: "/tmp/q.json", persisted: true, error: nil)
        return value
    }

    /// Runs `body` with captured output and returns the failure code it threw, or nil on success.
    private func code(_ body: () throws -> Void) -> (code: String?, values: Int) {
        let context = CLIOutputContext(format: .json, command: "test", agent: false)
        let code: String? = CLIOutput.$context.withValue(context) {
            do { try body(); return nil }
            catch let failure as CLIOutputFailure { return failure.code }
            catch { return "uncoded: \(error)" }
        }
        return (code, context.content().values.count)
    }

    @Test func selectedInputFailsTheSameWayWithVerbose() {
        let replies = [quarantined, response(outcome: "enqueuedAndDrained", events: 2, cleanup: "uncertain"),
            response(events: 1, error: "Context changed"), response(error: String(describing: SelectedHIDFailure.busy))]
        for reply in replies {
            let plain = code { try SelectedHIDBroker.printResponse(reply, verbose: false) }
            let verbose = code { try SelectedHIDBroker.printResponse(reply, verbose: true) }
            #expect(plain.code != nil)
            #expect(verbose.code == plain.code)
            #expect(verbose.values == 1, "The receipt is still printed before the failure")
        }
        #expect(code { try SelectedHIDBroker.printResponse(quarantined, verbose: true) }.code == "quarantined")
        let success = response(outcome: "enqueuedAndDrained", events: 2)
        #expect(code { try SelectedHIDBroker.printResponse(success, verbose: true) }.code == nil)
        #expect(code { try SelectedHIDBroker.printResponse(success, verbose: false) }.code == nil)
    }

    @Test func hingeKeepsItsCodesWithVerbose() throws {
        var noHinge = response(error: "No hinge")
        noHinge.hinge = SelectedHingeResult(SelectedHingeRequest(kind: .read, expectedBootIdentity: nil,
            degrees: nil, toleranceDegrees: nil, timeoutSeconds: nil))
        noHinge.hinge?.failure = try JSONDecoder().decode(SelectedHingeFailure.self, from: Data("""
            {"reason":"unsupported","detail":"No hinge","detailTruncated":false,"delivery":"notDispatched","latestSampleOmitted":false}
            """.utf8))
        let busy = response(error: String(describing: SelectedHIDFailure.busy))
        let expected: [(SelectedHIDResponse, String)] = [(noHinge, "noHinge"), (quarantined, "quarantined"), (busy, "busy")]
        for (reply, expectedCode) in expected {
            for verbose in [false, true] {
                #expect(code { try Hinge.Read.report(reply, udid: "U", verbose: verbose) }.code == expectedCode)
                #expect(code { _ = try Hinge.Set.receipt(from: reply, verbose: verbose) }.code == expectedCode)
            }
        }
    }

    @Test func rotateKeepsItsCodesWithVerbose() {
        var failed = response(error: "Rotation failed")
        failed.rotation = SelectedRotationResult(direction: .left,
            failure: FBSimulatorRotationFailure(detail: "Not settled", delivery: .notDispatched, before: nil))
        let expected: [(SelectedHIDResponse, String)] = [(failed, "rotationFailed"), (quarantined, "quarantined")]
        for (reply, expectedCode) in expected {
            for verbose in [false, true] {
                #expect(code { _ = try Rotate.receipt(from: reply, verbose: verbose) }.code == expectedCode)
            }
        }
    }

    @Test func plainJSONSummaryOmitsTransportDetail() throws {
        let summary = SelectedInputSummary(response(outcome: "switchValueChangedObserved", events: 4))
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(summary)) as? [String: Any])
        #expect(object["outcome"] as? String == "completed")
        #expect(object["events"] == nil)
    }
}
