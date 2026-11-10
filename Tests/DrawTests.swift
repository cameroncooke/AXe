import ArgumentParser
import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Draw command and one-finger strokes")
struct DrawTests {
    private let udid = "00000000-0000-0000-0000-000000000001"
    private let screen = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    private func draw(_ arguments: [String]) throws -> Draw {
        try Draw.parse(arguments + ["--udid", udid])
    }

    private func refusal(_ arguments: [String]) -> String {
        do {
            _ = try draw(arguments)
            return ""
        } catch {
            return Draw.message(for: error)
        }
    }

    /// Splits primitives into touches and the delays between them.
    private func touches(_ primitives: [SelectedHIDPrimitive]) -> [SelectedHIDPrimitive] {
        primitives.filter { $0.kind != .delay }
    }

    private func observation() throws -> FBSimulatorHIDSessionObservation {
        let context = try FBSimulatorHIDDisplayContext(hidTarget: 3,
            nativePixelSize: CGSize(width: 300, height: 600), scale: 3, rotation: .rot0)
        return try FBSimulatorHIDSessionObservation(simulatorUDID: udid, bootIdentity: "local-check",
            screenID: 3, screenUniqueID: screen.uuidString, axDisplayID: 3,
            displayContext: context, poseRevision: "local-check")
    }

    @Test func pointsParseAsXCommaY() throws {
        let command = try draw(["100,200", "300.5, 400", "0,0"])
        #expect(command.strokePoints == [CGPoint(x: 100, y: 200), CGPoint(x: 300.5, y: 400), .zero])
        #expect(command.duration == 1 && !command.close)
        for bad in ["100", "a,b", "1,2,3", "1,", ",2"] {
            #expect(throws: (any Error).self) { _ = try draw(["10,10", bad]) }
        }
    }

    @Test func pointCountCoordinatesAndTimingAreChecked() throws {
        #expect(refusal(["10,10"]).contains("Draw takes 2 to 1000 points"))
        let many = (0..<1_001).map { "\($0 % 300),\($0 % 2 == 0 ? 10 : 20)" }
        #expect(refusal(many).contains("Draw takes 2 to 1000 points"))
        _ = try draw(Array(many.prefix(1_000)) + ["--close"])
        #expect(refusal(["10,10", "10,10"]).contains("Stroke point 2 repeats the point before it"))
        #expect(refusal(["10,10", "nan,5"]).contains("Point 2 must have finite, non-negative coordinates"))
        #expect(refusal(["10,10", "20,20", "--duration", "0"]).contains("at most 30 seconds"))
        #expect(refusal(["10,10", "20,20", "--duration", "30.5"]).contains("at most 30 seconds"))
        _ = try draw(["10,10", "20,20", "--duration", "30"])
        #expect(refusal(["10,10", "20,20", "--pre-delay", "11"]).contains("Pre-delay"))
        #expect(refusal(["10,10", "20,20", "--agent"]).contains("Draw does not support --agent"))
    }

    @Test func closeReturnsToTheFirstPointOnce() throws {
        #expect(try draw(["10,10", "50,10", "30,40", "--close"]).strokePoints
            == [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 10), CGPoint(x: 30, y: 40), CGPoint(x: 10, y: 10)])
        #expect(try draw(["10,10", "50,10", "10,10", "--close"]).strokePoints.count == 3)
    }

    @Test func timeIsSpreadByArcLengthAndCornersAreExact() {
        // 300 points along x, then 100 down: three quarters of the time on the first leg.
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 300, y: 0), CGPoint(x: 300, y: 100)]
        let primitives = TouchStroke.primitives(through: points, duration: 1, moves: 40,
            initialHold: 0.05, finalHold: 0.05)
        var elapsed = 0.0
        var reachedCorner: Double?
        for (index, primitive) in primitives.enumerated() {
            elapsed += primitive.duration ?? 0
            if primitive.kind == .down, primitive.x == 300, primitive.y == 0, index > 0 { reachedCorner = elapsed }
        }
        #expect(abs(elapsed - 1.1) < 1e-9)
        #expect(abs((reachedCorner ?? 0) - 0.8) < 1e-9)
        let contacts = touches(primitives)
        #expect(contacts.count == 1 + 30 + 10 + 1)
        // Equal spacing in time means equal spacing in distance on both legs.
        let xs = contacts.prefix(31).compactMap(\.x)
        #expect(zip(xs, xs.dropFirst()).allSatisfy { abs($1 - $0 - 10) < 1e-9 })
        #expect(TouchStroke.moveCount(duration: 1) == 50)
        #expect(TouchStroke.moveCount(duration: 30) == 1_000)
        #expect(TouchStroke.moveCount(duration: 0.001) == 1)
    }

    @Test @MainActor func outsidePointIsNamedBeforeInput() throws {
        let points = [CGPoint(x: 10, y: 10), CGPoint(x: 100, y: 200), CGPoint(x: 101, y: 50), CGPoint(x: 500, y: 5)]
        #expect(TouchStroke.outsidePoint(points, width: 100, height: 200) == "Point 3 (101,50) is outside the 100x200 screen")
        #expect(TouchStroke.outsidePoint(Array(points.prefix(2)), width: 100, height: 200) == nil)
        let path = try draw(["10,10", "100,200", "101,50"]).selectedPath
        do {
            _ = try path.primitives(logicalSize: CGSize(width: 100, height: 200))
            Issue.record("An outside point did not fail")
        } catch {
            let failure = CLIErrorMapping.failure(for: error)
            #expect(failure.code == "invalidArguments")
            #expect(failure.message == "Point 3 (101,50) is outside the 100x200 screen. No input was sent.")
        }
        var legacy = try draw(["10,10", "100,250"]).selectedPath
        legacy.generator = .ordinary
        #expect(throws: (any Error).self) { _ = try legacy.event(logicalSize: CGSize(width: 100, height: 200)) }
    }

    @Test func brokerRefusalKeepsItsCode() {
        var response = SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: UUID(), brokerID: UUID(),
            outcome: "failedNoReplay", token: nil, enqueuedEventCount: 0, cleanup: "notNeeded",
            error: "Point 2 (500,500) is outside the 402x874 screen", context: nil)
        response.errorCode = "invalidArguments"
        let failure = SelectedInputOutput.failure(response)
        #expect(failure.code == "invalidArguments")
        #expect(failure.message == "Point 2 (500,500) is outside the 402x874 screen. No input was sent.")
    }

    @Test func selectedRouteSendsOneDownMovesInOrderAndOneUp() throws {
        let command = try draw(["10,10", "50,10", "30,40", "--close", "--duration", "0.5",
            "--pre-delay", "0.2", "--post-delay", "0.3"])
        let primitives = try command.selectedPath.primitives(logicalSize: CGSize(width: 100, height: 200))
        #expect(primitives.first?.kind == .delay && primitives.first?.duration == 0.2)
        #expect(primitives.last?.kind == .delay && primitives.last?.duration == 0.3)
        let contacts = touches(primitives)
        #expect(contacts.first?.kind == .down && contacts.last?.kind == .up)
        #expect(contacts.filter { $0.kind == .up }.count == 1)
        #expect(contacts.first?.point == CGPoint(x: 10, y: 10) && contacts.last?.point == CGPoint(x: 10, y: 10))
        // The moves pass every corner in order.
        let corners = [CGPoint(x: 50, y: 10), CGPoint(x: 30, y: 40), CGPoint(x: 10, y: 10)]
        let indices = corners.map { corner in contacts.dropFirst().firstIndex { $0.point == corner } ?? -1 }
        #expect(indices.allSatisfy { $0 > 0 } && indices == indices.sorted())
        let checked = try FBSimulatorHIDSession.preflight(.composite(primitives.map(\.event)), observation: observation())
        #expect(abs(checked.requestedDelaySeconds - (0.2 + 0.05 + 0.5 + 0.05 + 0.3)) < 1e-9)
    }

    @Test @MainActor func ordinaryAndDirectRoutesBuildTheSameStroke() throws {
        let command = try draw(["10,10", "50,10", "30,40"])
        var ordinary = command.selectedPath
        ordinary.generator = .ordinary
        let legacy = try ordinary.event(logicalSize: CGSize(width: 100, height: 200))
        let direct = command.directEvent(through: command.strokePoints)
        let selected = try command.selectedPath.primitives(logicalSize: CGSize(width: 100, height: 200)).map(\.event)
        #expect(legacy.subEvents == selected && direct.subEvents == selected)
        let downs = selected.filter { if case .touch(.down, _, _) = $0 { return true }; return false }
        let ups = selected.filter { if case .touch(.up, _, _) = $0 { return true }; return false }
        #expect(downs.count == 1 + 50 && ups == [.touch(direction: .up, x: 30, y: 40)])
    }

    @Test func physicalRouteHasOneDownMovesAndOneUp() throws {
        let command = try draw(["10,10", "50,10", "30,40"])
        var path = command.selectedPath
        path.preDelay = 0
        path.postDelay = 0
        let steps = PhysicalDeviceGestures.touchSteps(try path.primitives(logicalSize: CGSize(width: 100, height: 200)), edge: .none)
        #expect(steps.first?.phase == .down && steps.last?.phase == .up)
        #expect(steps.dropFirst().dropLast().allSatisfy { $0.phase == .move })
        #expect(steps.first?.points == [CGPoint(x: 10, y: 10)] && steps.last?.points == [CGPoint(x: 30, y: 40)])
        #expect(abs(steps.reduce(0) { $0 + $1.delayAfter } - 1.1) < 1e-9)
    }

    @Test func drawPathRoundTripsOnTheWire() throws {
        let command = try draw(["10,10", "50,10", "30,40", "--input-mode", "selected"])
        let request = try command.selectedRequest()
        #expect(request.activeDisplay == true && request.path?.kind == .draw)
        let decoded = try JSONDecoder().decode(SelectedHIDRequest.self, from: JSONEncoder().encode(request))
        try decoded.validate()
        #expect(decoded.path?.strokePoints == command.strokePoints)
        #expect(decoded.version == SelectedHIDRequest.version)

        let context = try JSONDecoder().decode(SelectedHIDContext.self, from: Data(
            #"{"bootIdentity":"1:2:3","screenID":3,"screenUUID":"00000000-0000-0000-0000-000000000003","logicalWidth":100,"logicalHeight":200,"rotationDegrees":0,"nativePixelWidth":300,"nativePixelHeight":600,"scale":3,"poseRevision":"static"}"#.utf8))
        var ordinaryPath = command.selectedPath
        ordinaryPath.generator = .ordinary
        let ordinary = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(), screenID: 3,
            screenUUID: screen, operation: .complete, token: nil, payload: .path(ordinaryPath),
            expectedContext: context)
        let back = try JSONDecoder().decode(SelectedHIDRequest.self, from: JSONEncoder().encode(ordinary))
        try back.validate()
        #expect(back.path?.generator == .ordinary && back.path?.points?.map(\.cgPoint) == command.strokePoints)
        // An ordinary path needs the measured context, and a selected path refuses it.
        var unbound = ordinary
        unbound.expectedContext = nil
        #expect(throws: (any Error).self) { try unbound.validate() }
        var selectedBound = ordinary
        var selectedPath = try #require(ordinary.path)
        selectedPath.generator = .selected
        selectedBound.payload = .path(selectedPath)
        #expect(throws: (any Error).self) { try selectedBound.validate() }

        // A draw needs its point list, and only a draw carries one.
        var missing = command.selectedPath
        missing.points = nil
        #expect(throws: (any Error).self) { try missing.validate() }
        var dragWithPoints = SelectedHIDPath(kind: .drag, startX: 1, startY: 1, endX: 5, endY: 5, duration: 1, steps: 4)
        dragWithPoints.points = [.init(x: 1, y: 1), .init(x: 5, y: 5)]
        #expect(throws: (any Error).self) { try dragWithPoints.validate() }
        var long = command.selectedPath
        long = SelectedHIDPath(kind: .draw, duration: 31, points: long.points)
        #expect(throws: (any Error).self) { try long.validate() }
    }

    @Test @MainActor func batchStepsParseOnEveryRoute() async throws {
        #expect(BatchStepKind(rawValue: "draw") == .draw)
        let selected = try SelectedInputOptions.parse(["--input-mode", "selected"])
        let step = try SelectedBatchStep.request(["draw", "10,10", "50,10", "--close"], input: selected, simulatorUDID: udid)
        #expect(step.path?.kind == .draw && step.path?.strokePoints.count == 3)
        #expect(throws: (any Error).self) {
            _ = try SelectedBatchStep.request(["draw", "10,10", "--duration", "1"], input: selected, simulatorUDID: udid)
        }
        let primitives = try await draw(["10,10", "50,10", "--pre-delay", "0.2"])
            .toBatchPrimitives(context: duoContext(), logger: AxeLogger())
        #expect(primitives.count == 3)
        guard case .hostSleep(let pre) = primitives[0], case .hidBarrier(let event) = primitives[1] else {
            Issue.record("Draw batch step is not one stroke between its delays"); return
        }
        #expect(pre == 0.2 && event.subEvents?.first == .touch(direction: .down, x: 10, y: 10))
        await #expect(throws: (any Error).self) {
            _ = try await draw(["10,10", "150,10"]).toBatchPrimitives(context: duoContext(), logger: AxeLogger())
        }
    }

    @MainActor
    private func duoContext() -> BatchContext {
        BatchContext(simulatorUDID: udid, axCachePolicy: .perBatch, typeSubmissionMode: .chunked, typeChunkSize: 200,
            duoOwner: SelectedHIDOwner(simulatorUDID: udid, logger: AxeLogger()), duoLogicalSize: (100, 200))
    }

    @Test func drawHelpIsShortWithThreeExamples() async throws {
        let result = try await TestHelpers.runAxeCommand("draw --help")
        #expect(result.output.contains("Move one finger through a list of points"))
        #expect(result.output.components(separatedBy: "axe draw ").count - 1 >= 3)
        #expect(result.output.contains("--close"))
    }
}
