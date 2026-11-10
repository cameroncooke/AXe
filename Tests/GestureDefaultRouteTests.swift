import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Gestures without selected input")
struct GestureDefaultRouteTests {
    private let udid = "00000000-0000-0000-0000-000000000001"

    @Test(arguments: [
        ["pinch", "--scale", "2"],
        ["pinch", "-x", "50", "-y", "100", "--radius", "10", "--scale", "0.5"],
        ["double-tap", "-x", "50", "-y", "100"],
        ["rotate", "-x", "50", "-y", "100", "--radius", "10", "--degrees", "90"],
        ["two-finger-tap", "-x", "40", "-y", "100", "--x2", "60", "--y2", "100"],
        ["two-finger-hold", "-x", "40", "-y", "100", "--x2", "60", "--y2", "100", "--hold", "0.5"],
        ["two-finger-swipe", "-x", "40", "-y", "100", "--x2", "60", "--y2", "100",
         "--end-x", "40", "--end-y", "50", "--end-x2", "60", "--end-y2", "50"],
    ])
    func coordinateGesturesNeedNoInputModeFlag(arguments: [String]) throws {
        let command = try Gesture.parse(arguments + ["--udid", udid])
        #expect(command.selectedInput.mode == .legacy)
    }

    @Test func pinchDefaultsToTheScreenCentreAndAQuarterOfTheShorterSide() throws {
        let command = try Gesture.parse(["pinch", "--scale", "1.5", "--udid", udid])
        let pinch = try command.selectedPinch()
        #expect(pinch.centerX == nil && pinch.centerY == nil && pinch.radius == nil)
        let resolved = try pinch.resolved(logicalSize: CGSize(width: 402, height: 874))
        #expect(resolved.centerX == 201 && resolved.centerY == 437 && resolved.radius == 100.5)
        let explicit = try Gesture.parse(["pinch", "-x", "50", "-y", "60", "--radius", "12", "--scale", "1.5", "--udid", udid])
            .selectedPinch().resolved(logicalSize: CGSize(width: 402, height: 874))
        #expect(explicit.centerX == 50 && explicit.centerY == 60 && explicit.radius == 12)
        #expect(throws: (any Error).self) { _ = try Gesture.parse(["pinch", "-x", "50", "--scale", "2", "--udid", udid]) }
        #expect(throws: (any Error).self) { _ = try Gesture.parse(["pinch", "--udid", udid]) }
    }

    @Test func defaultPinchBuildsOnTheBoundScreen() throws {
        let context = try FBSimulatorHIDDisplayContext(hidTarget: 3,
            nativePixelSize: CGSize(width: 300, height: 600), scale: 3, rotation: .rot0)
        let observation = try FBSimulatorHIDSessionObservation(simulatorUDID: udid, bootIdentity: "local-check",
            screenID: 3, screenUniqueID: "00000000-0000-0000-0000-000000000003", axDisplayID: 3,
            displayContext: context, poseRevision: "local-check")
        let event = try SelectedHIDPinch(scale: 1.5).event(observation: observation)
        guard case let .twoFingerTouch(direction, first, second)? = event.subEvents?.first else {
            Issue.record("Pinch does not start with a paired contact"); return
        }
        // A 100 x 200 screen: centre (50, 100), radius 25.
        #expect(direction == .down && first == CGPoint(x: 25, y: 100) && second == CGPoint(x: 75, y: 100))
    }

    @Test func helpNoLongerAsksForSelectedInput() async throws {
        let result = try await TestHelpers.runAxeCommand("gesture --help")
        #expect(!result.output.contains("require selected input") && !result.output.contains("requires selected input"))
        #expect(result.output.contains("axe gesture pinch --scale 2"))
    }
}
