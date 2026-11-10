import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Selected input boundaries")
struct SelectedInputBoundaryTests {
    @Test func logicalPointsMapToNativePanelForEveryQuarterTurn() throws {
        let cases: [(FBSimulatorHIDDisplayRotation, CGSize, CGPoint)] = [
            (.rot0, CGSize(width: 200, height: 400), CGPoint(x: 0.2, y: 0.2)),
            (.rot90, CGSize(width: 400, height: 200), CGPoint(x: 0.4, y: 0.9)),
            (.rot180, CGSize(width: 200, height: 400), CGPoint(x: 0.8, y: 0.8)),
            (.rot270, CGSize(width: 400, height: 200), CGPoint(x: 0.6, y: 0.1))
        ]
        for (rotation, size, expected) in cases {
            let context = try FBSimulatorHIDDisplayContext(
                hidTarget: 3, nativePixelSize: CGSize(width: 600, height: 1200),
                scale: 3, rotation: rotation)
            #expect(context.logicalSize == size)
            let actual = try context.normalizedPoint(from: CGPoint(x: 40, y: 80))
            #expect(abs(actual.x - expected.x) < 0.000001)
            #expect(abs(actual.y - expected.y) < 0.000001)
        }
    }

    @Test func rotatedBoundsRejectPointsInsteadOfClamping() throws {
        let context = try FBSimulatorHIDDisplayContext(
            hidTarget: 1, nativePixelSize: CGSize(width: 600, height: 1200),
            scale: 3, rotation: .rot90)
        for point in [CGPoint(x: -1, y: 20), CGPoint(x: 401, y: 20),
                      CGPoint(x: 20, y: 201), CGPoint(x: CGFloat.nan, y: 20)] {
            do {
                _ = try context.normalizedPoint(from: point)
                Issue.record("Invalid point reached the selected display")
            } catch FBSimulatorHIDDisplayContextError.pointOutsideDisplay {
                // Expected: the input is rejected without clamping.
            }
        }
        #expect(try context.normalizedPoint(from: CGPoint(x: 400, y: 200)) == CGPoint(x: 1, y: 0))
    }

    @Test func retainedContactRejectsChangedSelectionAndExpiredToken() throws {
        let screen = UUID(), token = UUID()
        func request(_ operation: SelectedHIDRequest.Operation, token: UUID? = nil,
                     screenID: UInt32 = 3, screenUUID: UUID? = nil) -> SelectedHIDRequest {
            SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
                screenID: screenID, screenUUID: screenUUID ?? screen,
                operation: operation, token: token, payload: .contact([.touch(.down, x: 40, y: 80)]))
        }
        var admission = SelectedHIDAdmission()
        let begin = request(.begin)
        try admission.enter(begin)
        admission.retain(begin, token: token)
        admission.finish()
        for changed in [request(.move, token: token, screenID: 1),
                        request(.move, token: token, screenUUID: UUID()),
                        request(.move, token: UUID())] {
            #expect(throws: (any Error).self) { try admission.enter(changed) }
            #expect(!admission.inFlight)
            #expect(admission.token == token)
            #expect(admission.screenID == 3)
            #expect(admission.screenUUID == screen)
        }
        try admission.enter(request(.move, token: token))
        admission.finish()
        admission.clear()
        #expect(throws: (any Error).self) { try admission.enter(request(.end, token: token)) }
        #expect(!admission.inFlight)
    }
}
