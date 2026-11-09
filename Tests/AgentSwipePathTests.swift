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

    @Test("Only a swipe may end at rest")
    func onlySwipeEndsAtRest() throws {
        var drag = SelectedHIDPath(kind: .drag, startX: 10, startY: 10, endX: 100, endY: 100,
            duration: 1, steps: 10)
        try drag.validate()
        drag.endsAtRest = true
        #expect(throws: SelectedHIDFailure.self) { try drag.validate() }
    }
}
