import ArgumentParser
import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Selected complete gestures")
struct SelectedCompleteGestureTests {
    private let udid = "00000000-0000-0000-0000-000000000001"
    private let screen = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private var selection: [String] { ["--input-mode", "selected", "--screen-id", "3", "--screen-uuid", screen.uuidString] }
    private func args(_ name: String) -> [String] {
        switch name {
        case "double-tap": return [name, "-x", "50", "-y", "100"]
        case "rotate": return [name, "-x", "50", "-y", "100", "--radius", "10", "--degrees", "90"]
        case "two-finger-tap": return [name, "-x", "40", "-y", "100", "--x2", "60", "--y2", "100"]
        case "two-finger-hold": return [name, "-x", "40", "-y", "100", "--x2", "60", "--y2", "100", "--hold", "0.8"]
        case "pinch": return [name, "-x", "50", "-y", "100", "--radius", "10", "--scale", "2"]
        default: return [name]
        }
    }
    private func observation(_ rotation: FBSimulatorHIDDisplayRotation = .rot0) throws -> FBSimulatorHIDSessionObservation {
        let context = try FBSimulatorHIDDisplayContext(hidTarget: 3,
            nativePixelSize: CGSize(width: 300, height: 600), scale: 3, rotation: rotation)
        return try FBSimulatorHIDSessionObservation(simulatorUDID: udid, bootIdentity: "local-check",
            screenID: 3, screenUniqueID: screen.uuidString, axDisplayID: 3,
            displayContext: context, poseRevision: "local-check")
    }
    private func command(_ name: String) throws -> Gesture {
        try Gesture.parse(args(name) + ["--udid", udid] + selection)
    }
    private func request(_ value: SelectedHIDCompleteGesture) -> SelectedHIDRequest {
        SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(), screenID: 3,
            screenUUID: screen, operation: .complete, token: nil, primitives: [], gesture: value)
    }
    private func leaves(_ event: FBSimulatorHIDEvent) -> [FBSimulatorHIDEvent] {
        guard let children = event.subEvents else { return [event] }
        return children.flatMap(leaves)
    }

    @Test func requiredAndIrrelevantOptionsFail() throws {
        for tokens in [["double-tap", "-x", "50"],
                       ["rotate", "-x", "50", "-y", "100", "--radius", "10"],
                       ["two-finger-tap", "-x", "40", "-y", "100", "--x2", "60"],
                       ["two-finger-hold", "-x", "40", "-y", "100", "--x2", "60", "--y2", "100"]] {
            #expect(throws: (any Error).self) { _ = try Gesture.parse(tokens + ["--udid", udid] + selection) }
        }
        for (name, extra) in [("double-tap", ["--duration", "1"]), ("rotate", ["--hold", "1"]),
                              ("two-finger-tap", ["--interval", "0.1"]), ("two-finger-hold", ["--delta", "5"]),
                              ("scroll-up", ["--degrees", "90"]), ("pinch", ["--hold", "1"])] {
            #expect(throws: (any Error).self) { _ = try Gesture.parse(args(name) + extra + ["--udid", udid] + selection) }
        }
    }

    @Test func doubleTapHasTwoCompleteContactsAndExactRequestedDelays() throws {
        let value = SelectedHIDCompleteGesture.doubleTap(.init(point: .init(x: 50, y: 100),
            hold: 0.06, interval: 0.1, timing: .init(preDelay: 0.2, postDelay: 0.3)))
        let event = try value.event(observation: observation())
        #expect(leaves(event) == [.delay(0.2), .touch(direction: .down, x: 50, y: 100), .delay(0.06),
            .touch(direction: .up, x: 50, y: 100), .delay(0.1), .touch(direction: .down, x: 50, y: 100),
            .delay(0.06), .touch(direction: .up, x: 50, y: 100), .delay(0.3)])
        let checked = try FBSimulatorHIDSession.preflight(event, observation: observation())
        #expect(checked.primitiveCount == 4 && abs(checked.requestedDelaySeconds - 0.72) < 0.000001)
    }

    @Test(arguments: ["two-finger-tap", "two-finger-hold"])
    func pairHasOneCompleteDownHoldUp(name: String) throws {
        let parsed = try command(name)
        let event = try parsed.selectedCompleteGesture().event(observation: observation())
        let hold = name == "two-finger-tap" ? 0.1 : 0.8
        #expect(leaves(event) == [.twoFingerTouch(direction: .down, finger1: CGPoint(x: 40, y: 100), finger2: CGPoint(x: 60, y: 100)),
            .delay(hold), .twoFingerTouch(direction: .up, finger1: CGPoint(x: 40, y: 100), finger2: CGPoint(x: 60, y: 100))])
    }

    @Test func interiorRotationAndSecondContactBoundsRejectCompleteEvent() throws {
        // Start/end at y=5 fit; a half-circle passes below y=0 between them.
        let arc = SelectedHIDCompleteGesture.rotate(.init(center: .init(x: 50, y: 5), radius: 10, degrees: 180))
        #expect(throws: (any Error).self) { _ = try arc.event(observation: observation()) }
        let pair = SelectedHIDCompleteGesture.twoFingerTap(.init(first: .init(x: 40, y: 100), second: .init(x: 110, y: 100), hold: 0.1))
        #expect(throws: (any Error).self) { _ = try pair.event(observation: observation()) }
    }

    @Test func mixedPayloadsRejectBeforeCommonAdmission() throws {
        let value = try command("double-tap").selectedCompleteGesture()
        var pinch = request(value)
        pinch.pinch = .init(centerX: 50, centerY: 100, scale: 2, radius: 10)
        var path = request(value)
        path.path = .init(kind: .preset, preset: .scrollUp, duration: 0.5, delta: 25)
        var ax = request(value)
        ax.ax = .init(kind: .describe, expectedPID: 1,
            endpoint: nil, selectorKind: nil, selectorValue: nil, preDelay: 0, postDelay: 0)
        var hinge = try SelectedHingeRequest(kind: .read, expectedBootIdentity: nil,
            degrees: nil, toleranceDegrees: nil, timeoutSeconds: nil).brokerRequest()
        hinge.gesture = value
        let retained = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(), screenID: 3, screenUUID: screen,
            operation: .begin, token: nil, primitives: [], gesture: value)
        let old = SelectedHIDRequest(version: 8, requestID: UUID(), screenID: 3, screenUUID: screen,
            operation: .complete, token: nil, primitives: [], gesture: value)
        for candidate in [pinch, path, ax, hinge, retained, old] {
            var admission = SelectedHIDAdmission()
            #expect(throws: (any Error).self) { try admission.enter(candidate) }
            #expect(!admission.inFlight && admission.token == nil)
        }
    }

    @Test(arguments: [0.5, 2.0])
    func pinchHasCompleteSeparatedContactPaths(scale: Double) throws {
        let observed = try observation()
        let value = SelectedHIDPinch(centerX: 50, centerY: 100, scale: scale, radius: 10)
        let event = try value.event(observation: observed)
        let events = leaves(event)
        let expected: [FBSimulatorHIDEvent]
        if scale == 2 {
            expected = [
                .twoFingerTouch(direction: .down, finger1: CGPoint(x: 40, y: 100), finger2: CGPoint(x: 60, y: 100)), .delay(0.15),
                .twoFingerTouch(direction: .down, finger1: CGPoint(x: 35, y: 100), finger2: CGPoint(x: 65, y: 100)), .delay(0.15),
                .twoFingerTouch(direction: .down, finger1: CGPoint(x: 30, y: 100), finger2: CGPoint(x: 70, y: 100)), .delay(0.15),
                .twoFingerTouch(direction: .down, finger1: CGPoint(x: 30, y: 100), finger2: CGPoint(x: 70, y: 100)), .delay(0.15),
                .twoFingerTouch(direction: .up, finger1: CGPoint(x: 30, y: 100), finger2: CGPoint(x: 70, y: 100))
            ]
        } else {
            // Compare the contact sequence separately from fractional delay rounding.
            expected = [
                .twoFingerTouch(direction: .down, finger1: CGPoint(x: 40, y: 100), finger2: CGPoint(x: 60, y: 100)),
                .twoFingerTouch(direction: .down, finger1: CGPoint(x: 45, y: 100), finger2: CGPoint(x: 55, y: 100)),
                .twoFingerTouch(direction: .down, finger1: CGPoint(x: 45, y: 100), finger2: CGPoint(x: 55, y: 100)),
                .twoFingerTouch(direction: .up, finger1: CGPoint(x: 45, y: 100), finger2: CGPoint(x: 55, y: 100))
            ]
        }
        let contacts = events.filter { if case .delay = $0 { return false }; return true }
        #expect(scale == 2 ? events == expected : contacts == expected)
        #expect(events.count == (scale == 2 ? 9 : 7))
        let checked = try FBSimulatorHIDSession.preflight(event, observation: observed)
        #expect(abs(checked.requestedDelaySeconds - 0.6) < 0.000001)
    }

    @Test(arguments: [-90.0, 90.0])
    func rotationKeepsBothContactsOnTheCircleAndReleases(degrees: Double) throws {
        let observed = try observation()
        let value = SelectedHIDCompleteGesture.rotate(.init(
            center: .init(x: 50, y: 100), radius: 10, degrees: degrees, spacing: 10))
        let event = try value.event(observation: observed)
        let events = leaves(event)
        #expect(events.count == 9)
        #expect(events.first == .twoFingerTouch(direction: .down,
            finger1: CGPoint(x: 40, y: 100), finger2: CGPoint(x: 60, y: 100)))
        for (index, item) in events.enumerated() {
            if index % 2 == 1 {
                guard case let .delay(seconds) = item else { Issue.record("Missing motion delay"); return }
                #expect(abs(seconds - 0.15) < 0.000001)
                continue
            }
            guard case let .twoFingerTouch(direction, first, second) = item else {
                Issue.record("Missing paired contact"); return
            }
            #expect(direction == (index == events.count - 1 ? .up : .down))
            #expect(abs(hypot(first.x - 50, first.y - 100) - 10) < 0.000001)
            #expect(abs(hypot(second.x - 50, second.y - 100) - 10) < 0.000001)
            #expect(abs(first.x + second.x - 100) < 0.000001)
            #expect(abs(first.y + second.y - 200) < 0.000001)
            if index == events.count - 1 {
                #expect(abs(first.x - 50) < 0.000001 && abs(second.x - 50) < 0.000001)
                #expect(abs(first.y - (degrees > 0 ? 90 : 110)) < 0.000001)
                #expect(abs(second.y - (degrees > 0 ? 110 : 90)) < 0.000001)
            }
        }
        let checked = try FBSimulatorHIDSession.preflight(event, observation: observed)
        #expect(checked.primitiveCount == 5)
        #expect(abs(checked.requestedDelaySeconds - 0.6) < 0.000001)
    }

    @Test func overlappingContactsRejectBeforeEventReturn() throws {
        let pair = SelectedHIDCompleteGesture.PairContact(
            first: .init(x: 50, y: 100), second: .init(x: 50, y: 100), hold: 0.8)
        for value in [SelectedHIDCompleteGesture.twoFingerTap(pair), .twoFingerHold(pair)] {
            #expect(throws: (any Error).self) { _ = try value.event(observation: observation()) }
        }
    }

    @Test func pinchRejectsLaterOutOfBoundsContactBeforeEventReturn() throws {
        // Both starting contacts fit; only the second final contact leaves the display.
        let value = SelectedHIDPinch(centerX: 80, centerY: 100, scale: 3, radius: 10)
        #expect(throws: (any Error).self) { _ = try value.event(observation: observation()) }
    }
}
