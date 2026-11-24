import FBSimulatorControl
import Foundation
import Testing
@testable import AXe

/// The owner decides success: its reply carries an error when its own result misses the contract.
@Suite("Selected owner result contract", .serialized)
@MainActor
struct SelectedHIDContractTests {
    private final class State { var calls = 0 }
    private let screen = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    private func request(_ ax: SelectedAXRequest) throws -> SelectedHIDRequest {
        let request = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(), screenID: 3,
            screenUUID: screen, operation: .complete, token: nil, payload: .ax(ax))
        try request.validate()
        return request
    }

    /// An owner whose AX operation returns `outcome` with no error and no native evidence.
    private func owner(outcome: String, state: State) -> SelectedHIDOwner {
        let dependencies = SelectedAXDependencies(execute: { request, _, broker, _, _ in
            state.calls += 1
            var response = SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: request.requestID,
                brokerID: broker, outcome: outcome, token: nil, enqueuedEventCount: 0, cleanup: "notNeeded",
                error: nil, context: nil)
            response.ax = request.ax.map { SelectedAXResult(kind: $0.kind, expectedPID: 42) }
            return response
        }, persist: { _, _, _ in Issue.record("No quarantine expected") }, now: { 0 })
        return SelectedHIDOwner(simulatorUDID: UUID().uuidString, logger: AxeLogger(), dependencies: dependencies)
    }

    @Test func semanticPressWithoutConfirmedPressFails() async throws {
        let state = State()
        let ax = SelectedAXRequest(kind: .semanticPress, expectedPID: 42, endpoint: nil, selectorKind: .id,
            selectorValue: "feature.switch", preDelay: 0, postDelay: 0)
        let result = await owner(outcome: "switchValueChangedObserved", state: state).perform(try request(ax))
        #expect(state.calls == 1)
        #expect(result.errorCode == "semanticPressUnconfirmed" && result.error != nil)
        #expect(SelectedInputOutput.failure(result).code == "semanticPressUnconfirmed")
    }

    /// The result check's error code for a confirmed Button press after `change`.
    private func buttonPressFailure(_ change: (inout FBSimulatorAXPressReceipt) -> Void = { _ in }) throws -> String? {
        let request = try request(SelectedAXRequest(kind: .semanticPress, expectedPID: 42, endpoint: nil,
            selectorKind: .id, selectorValue: "row", preDelay: 0, postDelay: 0))
        var press = try JSONDecoder().decode(FBSimulatorAXPressReceipt.self, from: Data("""
            {"outcome": "buttonPressAccepted", "delivery": "nativeReplyAccepted", "targetRole": "Button",
             "translatorCallAttempted": true, "callbackCount": 1, "sendCount": 1,
             "reply": {"nativeResponsePresent": true, "error": "0", "valueKind": "boolean", "value": true},
             "target": {"identifier": "row", "pid": 42, "objectID": "9", "frame": [[0, 0], [1, 1]],
                        "contextID": 1, "displayID": 1}}
            """.utf8))
        change(&press)
        var response = SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: request.requestID,
            brokerID: UUID(), outcome: "buttonPressAccepted", token: nil, enqueuedEventCount: 0,
            cleanup: "notNeeded", error: nil, context: nil)
        response.ax = SelectedAXResult(kind: .semanticPress, expectedPID: 42)
        response.ax?.press = press
        return SelectedHIDContract.failure(response, for: request)?.code
    }

    @Test func buttonPressIsConfirmedByItsAcceptedReplyAlone() throws {
        #expect(try buttonPressFailure() == nil)
        // A press must name its role, and a Button has no value to report.
        #expect(try buttonPressFailure { $0.targetRole = nil } == "semanticPressUnconfirmed")
        #expect(try buttonPressFailure { $0.stateBefore = false } == "semanticPressUnconfirmed")
    }

    @Test func sliderEndpointWithoutItsResultFails() async throws {
        let state = State()
        let ax = SelectedAXRequest(kind: .sliderEndpoint, expectedPID: 42, endpoint: .minimum, selectorKind: .id,
            selectorValue: "feature.slider", preDelay: 0, postDelay: 0)
        let result = await owner(outcome: "endpointObserved", state: state).perform(try request(ax))
        #expect(state.calls == 1 && result.errorCode == "sliderFailed")
    }

    @Test func otherResultsAndExistingFailuresAreUnchanged() throws {
        let tap = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(), screenID: 3,
            screenUUID: screen, operation: .complete, token: nil,
            payload: .contact([.touch(.down, x: 1, y: 1), .touch(.up, x: 1, y: 1)]))
        let clean = SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: tap.requestID,
            brokerID: UUID(), outcome: "enqueuedAndDrained", token: nil, enqueuedEventCount: 2, cleanup: "notNeeded",
            error: nil, context: nil)
        #expect(SelectedHIDContract.failure(clean, for: tap) == nil)
        var failed = clean
        failed.error = "Fresh hit rejected"
        let button = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(), screenID: 3,
            screenUUID: screen, operation: .complete, token: nil,
            payload: .button(SelectedButtonRequest(kind: .home, duration: nil, expectedBoot: nil)))
        let unchanged = SelectedHIDContract.checked(failed, for: button)
        #expect(unchanged.error == "Fresh hit rejected" && unchanged.errorCode == nil)
        #expect(SelectedHIDContract.checked(clean, for: button).errorCode == "inputFailed")
    }
}
