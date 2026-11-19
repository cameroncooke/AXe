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
