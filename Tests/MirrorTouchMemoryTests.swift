import Foundation
import Testing
@testable import AXe

@Suite("Mirror: which of a viewer's touches have already been taken")
struct MirrorTouchMemoryTests {
    @Test("A down and an up are each taken once, however many copies arrive")
    func discreteOnce() {
        var memory = MirrorTouchMemory()
        let down = memory.takeDiscrete(gesture: 1, down: true)
        let downAgain = memory.takeDiscrete(gesture: 1, down: true)
        let up = memory.takeDiscrete(gesture: 1, down: false)
        let upAgain = memory.takeDiscrete(gesture: 1, down: false)
        #expect(down)
        #expect(!downAgain)
        #expect(up)
        #expect(!upAgain)
    }

    @Test("A move is taken once, from its own message or from a later one's history")
    func moveOnce() {
        var memory = MirrorTouchMemory()
        let first = memory.takeMove(gesture: 3, sequence: 7)
        let again = memory.takeMove(gesture: 3, sequence: 7)
        let next = memory.takeMove(gesture: 3, sequence: 8)
        let otherGesture = memory.takeMove(gesture: 4, sequence: 7)
        #expect(first)
        #expect(!again)
        #expect(next)
        #expect(otherGesture)
    }

    @Test("A viewer that connects again numbers its gestures from one, and they are all taken")
    func newConnectionStartsClean() {
        var memory = MirrorTouchMemory()
        // One connection: 17 taps, and a drag.
        for gesture in UInt32(1)...17 {
            _ = memory.takeDiscrete(gesture: gesture, down: true)
            _ = memory.takeDiscrete(gesture: gesture, down: false)
        }
        _ = memory.takeMove(gesture: 17, sequence: 1)

        // Without forgetting, the next connection's first touches look like repeats.
        var kept = memory
        let droppedDown = !kept.takeDiscrete(gesture: 1, down: true)
        let droppedMove = !kept.takeMove(gesture: 17, sequence: 1)
        #expect(droppedDown)
        #expect(droppedMove)

        memory.forget()
        var taken = 0
        for gesture in UInt32(1)...17 {
            if memory.takeDiscrete(gesture: gesture, down: true) { taken += 1 }
            if memory.takeDiscrete(gesture: gesture, down: false) { taken += 1 }
        }
        let move = memory.takeMove(gesture: 17, sequence: 1)
        #expect(taken == 34)
        #expect(move)
    }

    @Test("Only the last 32 gestures are remembered")
    func limit() {
        var memory = MirrorTouchMemory()
        for gesture in UInt32(1)...40 {
            _ = memory.takeDiscrete(gesture: gesture, down: true)
            _ = memory.takeDiscrete(gesture: gesture, down: false)
        }
        let old = memory.takeDiscrete(gesture: 8, down: true)       // fallen out of the memory
        let recent = memory.takeDiscrete(gesture: 40, down: false)
        #expect(old)
        #expect(!recent)
    }
}

#if AXE_MIRROR
@Suite("Mirror touches on a turned screen")
struct MirrorRotationTouchTests {
    @Test("A touch on the upright picture lands where the turned simulator shows it")
    func landscapeLeft() {
        // Measured on an iPad simulator (820 x 1180 points) turned to landscape left: a tap at panel
        // point (205, 236) arrived in the app at (944, 205) of its 1180 x 820 landscape screen.
        let panel = MirrorInput.panelShare(x: 944.0 / 1180, y: 205.0 / 820, rotation: 90)
        #expect(abs(panel.x - 205.0 / 820) < 0.0001)
        #expect(abs(panel.y - 236.0 / 1180) < 0.0001)
    }

    @Test("Each turn and its opposite come back to the same point, and no turn leaves it alone")
    func roundTrips() {
        let point = (x: 0.3, y: 0.7)
        #expect(MirrorInput.panelShare(x: point.x, y: point.y, rotation: 0) == point)
        let right = MirrorInput.panelShare(x: point.x, y: point.y, rotation: 270)
        let left = MirrorInput.panelShare(x: point.x, y: point.y, rotation: 90)
        #expect(right.x != point.x || right.y != point.y)
        // A quarter turn one way, then the other, is no turn.
        let back = MirrorInput.panelShare(x: left.x, y: left.y, rotation: 270)
        #expect(abs(back.x - point.x) < 0.0001 && abs(back.y - point.y) < 0.0001)
        let half = MirrorInput.panelShare(x: point.x, y: point.y, rotation: 180)
        #expect(abs(half.x - 0.7) < 0.0001 && abs(half.y - 0.3) < 0.0001)
    }
}
#endif
