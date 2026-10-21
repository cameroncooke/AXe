import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Selected rotation admission")
struct SelectedRotationTests {
    private func request() -> SelectedHIDRequest {
        SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
            screenID: 3, screenUUID: UUID(), operation: .complete, token: nil, primitives: [],
            rotation: SelectedRotationRequest(direction: .right, expectedBootIdentity: "123:456:789", timeoutSeconds: 8))
    }

    @Test func rotationCannotBecomeAnEmptyTouchEvent() throws {
        let request = request()
        try request.validate()
        #expect(throws: (any Error).self) {
            try request.completeEvent(logicalSize: CGSize(width: 600, height: 900))
        }
        var mixed = request
        mixed.hinge = SelectedHingeRequest(kind: .read, expectedBootIdentity: nil,
            degrees: nil, toleranceDegrees: nil, timeoutSeconds: nil)
        #expect(throws: (any Error).self) { try mixed.validate() }
    }

    @Test func heldTouchAndInFlightActionRejectRotation() throws {
        let rotation = request()
        let begin = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
            screenID: rotation.screenID, screenUUID: rotation.screenUUID, operation: .begin,
            token: nil, primitives: [.touch(.down, x: 40, y: 80)])
        var owner = SelectedHIDAdmission()
        try owner.enter(begin)
        #expect(throws: (any Error).self) { try owner.enter(rotation) }
        let token = UUID()
        owner.retain(begin, token: token)
        owner.finish()
        #expect(throws: (any Error).self) { try owner.enter(rotation) }
        #expect(owner.token == token)
        #expect(!owner.inFlight)
    }

    @Test func invalidBootAndTimeoutRejectBeforeSend() throws {
        for boot in ["", "123", "1:2:x", "1:2:3:4"] {
            #expect(throws: (any Error).self) {
                try SelectedRotationRequest(direction: .left, expectedBootIdentity: boot, timeoutSeconds: 8).validate()
            }
        }
        for timeout in [Double.nan, Double.infinity, 0, 0.49, 15.01] {
            #expect(throws: (any Error).self) {
                try SelectedRotationRequest(direction: .left, expectedBootIdentity: "1:2:3", timeoutSeconds: timeout).validate()
            }
        }
    }
}
