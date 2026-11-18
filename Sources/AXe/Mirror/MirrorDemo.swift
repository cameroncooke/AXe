import Foundation

/// What a demo host allows. A demo host lets anyone in without pairing, so that the viewer app can
/// be tried, and reviewed by Apple, by someone with no Mac. Everything here exists to keep such a
/// visitor inside one sample app on one simulator.
enum MirrorDemo {
    /// The share of the screen's height, at the top and at the bottom, where a touch may not start.
    /// Swipes from those edges are how iOS leaves an app (Home, the app switcher, Control Centre,
    /// notifications).
    static let edge = 0.07

    /// Whether a touch that goes down at this height, a fraction of the screen from the top, is dropped.
    static func blocksTouch(downAt y: Double) -> Bool { y < edge || y > 1 - edge }

    /// A new visitor replaces the one connected only after that one has had this long.
    static let turn: TimeInterval = 180

    /// Whether a newcomer is turned away as busy, given how long the present viewer has been connected.
    static func isBusy(connectedFor seconds: TimeInterval?) -> Bool {
        guard let seconds else { return false }
        return seconds < turn
    }

    /// The most a demo stream may use, whatever the viewer asks for.
    static let megabits = 4.0
}
