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

    // MARK: The lock on the sample app (see `MirrorDemoLock`)

    /// What the sample app is started with, so that it can show only what suits a visitor.
    static let launchArguments = ["--launch-arg", "demo=1"]

    /// What the lock remembers between looks.
    struct LockState: Equatable {
        var away = 0        // looks in a row that found another app in front
        var unknown = 0     // looks in a row that could not tell
    }

    /// The pause between two looks at which app is in front.
    static let lookEvery: TimeInterval = 0.25

    /// Looks in a row at another app after which touches are let through again. Bringing the sample
    /// app back has then failed for three seconds, which means something it cannot cover is in
    /// front, a system alert for one, and the visitor's touch is the only thing that can dismiss it.
    static let stuckAfter = 12

    /// What the lock does after one look at which app is in front: true for the sample app, false
    /// for another, nil when the simulator could not say. Touches are let through for the sample
    /// app, dropped for another, and let through when the answer is unknown: a look that fails must
    /// not leave an honest visitor with a dead screen, and the sample app's own demo mode has
    /// already removed the ways out. The sample app is brought back once a second while another
    /// app is in front, and every five seconds while the answer is unknown.
    static func lockStep(inFront: Bool?, state: inout LockState) -> (allowsInput: Bool, pullBack: Bool) {
        switch inFront {
        case true?:
            state = LockState()
            return (true, false)
        case false?:
            state.unknown = 0
            state.away += 1
            return (state.away > stuckAfter, state.away % 4 == 1)
        case nil:
            state.away = 0
            state.unknown += 1
            return (true, state.unknown % 20 == 0)
        }
    }

    /// The process ID in what `simctl launch` prints: "com.example.app: 12345".
    static func processID(inLaunchOutput output: String) -> Int32? {
        guard let last = output.split(whereSeparator: { $0 == ":" || $0.isWhitespace }).last, let pid = Int32(last), pid > 0 else { return nil }
        return pid
    }
}
