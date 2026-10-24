import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Selected keyboard delay bounds")
struct SelectedKeyboardDelayBoundsTests {
    private func request(_ events: [SelectedKeyboardPrimitive]) -> SelectedHIDRequest {
        SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(), screenID: 3,
            screenUUID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            operation: .complete, token: nil, primitives: [],
            keyboard: SelectedKeyboardRequest(expectedPID: 123, focusID: "field", events: events))
    }

    @Test("The maximum twenty seconds of requested delay passes balanced input admission")
    func maximumTotalDelayIsAccepted() throws {
        let value = request([.down(4), .up(4), .delay(10), .down(5), .up(5), .delay(10), .down(6), .up(6)])
        var admission = SelectedHIDAdmission()
        try admission.enter(value)
        #expect(admission.inFlight && admission.token == nil)
        #expect(value.keyboard?.events.count == 8)
    }

    @Test("A delay above ten seconds or an invalid delay cannot enter the input owner")
    func invalidSingleDelayIsRejected() throws {
        for seconds in [10.0001, -0.0001, Double.infinity, -Double.infinity, Double.nan] {
            var admission = SelectedHIDAdmission()
            #expect(throws: (any Error).self) {
                try admission.enter(request([.down(4), .up(4), .delay(seconds), .down(5), .up(5)]))
            }
            #expect(!admission.inFlight && admission.token == nil)
        }
    }

    @Test("A total just above twenty seconds fails before any input owner admission")
    func excessiveTotalDelayIsRejected() throws {
        var admission = SelectedHIDAdmission()
        #expect(throws: (any Error).self) {
            try admission.enter(request([.down(4), .up(4), .delay(10), .delay(10), .delay(0.0001), .down(5), .up(5)]))
        }
        #expect(!admission.inFlight && admission.token == nil)
    }
}
