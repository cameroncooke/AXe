import ArgumentParser
import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@MainActor
@Suite("Agent swipe path")
struct AgentSwipePathTests {
    @Test("The public coordinate agent swipe keeps its native swipe path")
    func coordinateAgentSwipeRetainsPathKind() throws {
        let command = try Swipe.parse(["--agent", "--udid", "00000000-0000-0000-0000-000000000001",
            "--snapshot-id", UUID().uuidString, "--start-x", "200", "--start-y", "600",
            "--end-x", "200", "--end-y", "200"])
        try command.validate()
        let request = try command.agentRequest()
        try request.validate()
        #expect(request.agent?.kind == .complete && request.path?.kind == .swipe)
        #expect(request.path?.endsAtRest == true)
    }

    @Test("A raw coordinate swipe keeps its linear release")
    func rawSwipeStaysLinear() throws {
        let command = try Swipe.parse(["--udid", "00000000-0000-0000-0000-000000000001",
            "--start-x", "200", "--start-y", "600", "--end-x", "200", "--end-y", "200"])
        try command.validate()
        #expect(command.selectedPath.endsAtRest == nil)
    }

    @Test("An agent swipe slows to rest with the same events and endpoints")
    func restingSwipeEasesOut() throws {
        var path = SelectedHIDPath(kind: .swipe, startX: 200, startY: 600, endX: 200, endY: 200,
            duration: 1, delta: 50)
        let linear = try path.primitives(logicalSize: CGSize(width: 402, height: 874))
        path.endsAtRest = true
        let resting = try path.primitives(logicalSize: CGSize(width: 402, height: 874))
        #expect(resting.map(\.kind) == linear.map(\.kind))
        #expect(resting.compactMap(\.duration) == linear.compactMap(\.duration))
        let y = resting.filter { $0.kind != .delay }.compactMap(\.y)
        let linearY = linear.filter { $0.kind != .delay }.compactMap(\.y)
        #expect(y.first == 600 && y.last == 200 && linearY.first == 600 && linearY.last == 200)
        let steps = zip(y, y.dropFirst()).map { $0 - $1 }.dropLast() // the final UP does not move
        let linearSteps = zip(linearY, linearY.dropFirst()).map { $0 - $1 }.dropLast()
        #expect(steps.allSatisfy { $0 >= 0 } && zip(steps, steps.dropFirst()).allSatisfy { $0 >= $1 })
        // Linear moves 50 points per step to the end; at rest the last step is under one point.
        #expect(linearSteps.allSatisfy { $0 == 50 })
        #expect(steps.last! < 1 && steps.first! > 50)
    }

    @Test("A scroll-until step on a one-event route ends at rest with at least eight moves")
    func restingSwipeOnOrdinaryRoutes() throws {
        // A 200-point scroll with the default 50-point delta would ease over four moves only.
        let resting = SelectedHIDPath.restingSwipe(from: CGPoint(x: 200, y: 600), to: CGPoint(x: 200, y: 400),
            duration: 0.5, delta: 50)
        let y = resting.filter { $0.kind != .delay }.compactMap(\.y)
        #expect(y.count == 10 && y.first == 600 && y.last == 400)
        #expect(resting.first?.kind == .down && resting.last?.kind == .up)
        let moves = zip(y, y.dropFirst()).map { $0 - $1 }.dropLast()
        #expect(moves.count == 8 && moves.first! > 25 && moves.last! < 1)
        #expect(abs(resting.compactMap(\.duration).reduce(0, +) - 0.5) < 0.0001)
        // A long path keeps a move per delta.
        #expect(SelectedHIDPath.restingSwipe(from: .zero, to: CGPoint(x: 0, y: 600), duration: 1, delta: 50)
            .filter { $0.kind != .delay }.count == 14)

        var ordinary = SelectedHIDPath(kind: .swipe, startX: 200, startY: 600, endX: 200, endY: 400,
            duration: 0.5, delta: 50, generator: .ordinary)
        try ordinary.validate()
        ordinary.endsAtRest = true
        try ordinary.validate()
        var preset = SelectedHIDPath(kind: .preset, preset: .scrollUp, duration: 0.5, delta: 50)
        preset.endsAtRest = true
        try preset.validate()
        #expect(try preset.primitives(logicalSize: CGSize(width: 402, height: 874)).last?.kind == .up)
    }

    @Test("A scroll-until step on a device has at least eight moves, however short the swipe")
    func restingPathHasEnoughMoves() throws {
        let short = try Swipe.parse(["--udid", "00008140-000415942291401C",
            "--start-x", "206", "--start-y", "912", "--end-x", "114", "--end-y", "912", "--until-label", "Watercolor"])
        let moves = try short.restingPath.primitives(logicalSize: CGSize(width: 440, height: 956))
            .filter { $0.kind != .delay }.count - 2
        #expect(moves == 8 && short.restingPath.endsAtRest == true)
        let long = try Swipe.parse(["--udid", "00008140-000415942291401C",
            "--start-x", "200", "--start-y", "800", "--end-x", "200", "--end-y", "200", "--until-label", "Privacy"])
        #expect(long.restingPath.delta == 50)
    }

    @Test("Only a swipe may end at rest")
    func onlySwipeEndsAtRest() throws {
        var drag = SelectedHIDPath(kind: .drag, startX: 10, startY: 10, endX: 100, endY: 100,
            duration: 1, steps: 10)
        try drag.validate()
        drag.endsAtRest = true
        #expect(throws: SelectedHIDFailure.self) { try drag.validate() }
    }
}
