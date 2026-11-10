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

@Suite("Preset geometry on the measured screen")
struct GesturePresetMeasuredScreenTests {
    private let udid = "00000000-0000-0000-0000-000000000001"

    /// The size the ordinary route passes on: the captured context's logical size.
    private func measured(pixels: CGSize, scale: Double, rotation: FBSimulatorHIDDisplayRotation) throws -> (width: Double, height: Double) {
        let display = try FBSimulatorHIDDisplayContext(hidTarget: 1, nativePixelSize: pixels, scale: scale, rotation: rotation)
        let observation = try FBSimulatorHIDSessionObservation(simulatorUDID: udid, bootIdentity: "local-check",
            screenID: 1, screenUniqueID: "00000000-0000-0000-0000-000000000003", axDisplayID: 1,
            displayContext: display, poseRevision: "local-check")
        let context = SelectedHIDContext(observation)
        return (context.logicalWidth, context.logicalHeight)
    }

    private func swipe(_ preset: GesturePreset, _ extra: [String] = [],
                       measured size: (width: Double, height: Double)?) throws -> Gesture.LegacySwipe {
        try Gesture.parse([preset.rawValue, "--udid", udid] + extra).legacySwipe(preset, measured: size)
    }

    @Test func iPadPortraitUsesTheWholeScreen() throws {
        let size = try measured(pixels: CGSize(width: 1640, height: 2360), scale: 2, rotation: .rot0)
        #expect(size == (820, 1180))
        let edge = try swipe(.swipeFromRightEdge, measured: size)
        #expect(edge.startX == 800 && edge.startY == 590 && edge.endX == 20 && edge.endY == 590)
        let scroll = try swipe(.scrollDown, measured: size)
        #expect(scroll.startX == 410 && scroll.startY == 490 && scroll.endX == 410 && scroll.endY == 690)
    }

    @Test(arguments: [FBSimulatorHIDDisplayRotation.rot90, .rot270])
    func iPadLandscapeSwapsTheAxes(rotation: FBSimulatorHIDDisplayRotation) throws {
        let size = try measured(pixels: CGSize(width: 1640, height: 2360), scale: 2, rotation: rotation)
        #expect(size == (1180, 820))
        let edge = try swipe(.swipeFromRightEdge, measured: size)
        #expect(edge.startX == 1160 && edge.startY == 410 && edge.endX == 20)
        let scroll = try swipe(.scrollDown, measured: size)
        #expect(scroll.startX == 590 && scroll.startY == 310 && scroll.endY == 510)
    }

    @Test func largeIPhoneUsesItsOwnSize() throws {
        let size = try measured(pixels: CGSize(width: 1320, height: 2868), scale: 3, rotation: .rot0)
        #expect(size == (440, 956))
        let edge = try swipe(.swipeFromBottomEdge, measured: size)
        #expect(edge.startX == 220 && edge.startY == 936 && edge.endY == 20)
    }

    @Test func explicitDimensionsOverrideTheMeasuredScreen() throws {
        let size = try measured(pixels: CGSize(width: 1640, height: 2360), scale: 2, rotation: .rot0)
        let both = try swipe(.swipeFromRightEdge, ["--screen-width", "390", "--screen-height", "844"], measured: size)
        #expect(both.width == 390 && both.height == 844 && both.startX == 370 && both.startY == 422)
        let widthOnly = try swipe(.scrollDown, ["--screen-width", "600"], measured: size)
        #expect(widthOnly.width == 600 && widthOnly.height == 1180 && widthOnly.startX == 300)
    }

    @Test func unmeasuredRouteKeeps390x844() throws {
        let edge = try swipe(.swipeFromRightEdge, measured: nil)
        #expect(edge.width == 390 && edge.height == 844 && edge.startX == 370 && edge.startY == 422)
    }
}
