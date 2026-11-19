import Foundation

/// Which of the connected viewer's touches have already been taken.
///
/// A down or an up arrives twice, on the reliable stream and as a datagram, and a move can arrive
/// in its own datagram and again in the history of a later one. Each is used once.
///
/// A viewer numbers its gestures from one every time it connects, so this memory belongs to one
/// connection and `forget()` is called when a viewer connects. Kept from one connection to the
/// next, it took the new viewer's first touches for repeats of the last viewer's and dropped
/// them: after 17 gestures in one connection, the first 17 of the next did nothing.
struct MirrorTouchMemory {
    /// How many downs and ups are remembered: the last 32 gestures.
    static let discreteLimit = 64
    /// How many moves are remembered before the set is emptied.
    static let moveLimit = 4096

    private var discrete: [UInt64] = []
    private var moves = Set<UInt64>()

    /// True the first time this gesture's down (or up) is seen, false for its second copy.
    mutating func takeDiscrete(gesture: UInt32, down: Bool) -> Bool {
        let key = UInt64(gesture) << 8 | UInt64(down ? 1 : 2)
        if discrete.contains(key) { return false }
        discrete.append(key)
        if discrete.count > Self.discreteLimit { discrete.removeFirst() }
        return true
    }

    /// True the first time this move is seen, false when it has already come another way.
    mutating func takeMove(gesture: UInt32, sequence: UInt32) -> Bool {
        let key = UInt64(gesture) << 32 | UInt64(sequence)
        if moves.contains(key) { return false }
        if moves.count > Self.moveLimit { moves.removeAll() }
        moves.insert(key)
        return true
    }

    /// Starts again for a new connection.
    mutating func forget() {
        discrete.removeAll()
        moves.removeAll()
    }
}
