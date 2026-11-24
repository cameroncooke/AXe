import Foundation

/// Why a viewer cannot reach a host, as far as the viewer can tell from where it stands. The app
/// shows the reason with what to do about it, instead of a spinner that never ends.
enum MirrorUnreachable: String, Equatable {
    /// This device has no network at all.
    case offline
    /// None of the relays answers: this network blocks them, or the relay service is down. Every
    /// connection starts through a relay, so nothing can be reached without one.
    case relay
    /// The relays answer and the Mac does not: it is asleep, offline or not running `axe remote`.
    case host

    /// The reason, from the two things a viewer can check itself. A host with no relays of ours is
    /// dialled through iroh's public ones, which cannot be asked, so they count as answering.
    static func reason(hasNetwork: Bool, relays: Int, answering: Int) -> MirrorUnreachable {
        if !hasNetwork { return .offline }
        return relays > 0 && answering == 0 ? .relay : .host
    }
}

/// How a viewer keeps trying a host that does not answer, by how long it has been without a
/// connection. One try can itself take most of a minute when a host has several relays, so what
/// the screen says goes by the clock and not by how many tries have failed.
enum MirrorRetry {
    /// Seconds with only "Connecting" or "Reconnecting" on screen. Long enough that a brief drop
    /// on a working connection does not flash an error.
    static let explainAfter: TimeInterval = 10
    /// Seconds after which the app stops trying by itself and says so; the person starts it again.
    /// A host that is started within this time is found without anyone touching the phone.
    static let giveUpAfter: TimeInterval = 120

    enum Phase: Equatable {
        case quiet          // still only connecting
        case explaining     // the reason is on screen, and the app is still trying
        case stopped        // the reason is on screen, and the app has stopped trying
    }

    static func phase(elapsed: TimeInterval) -> Phase {
        elapsed >= giveUpAfter ? .stopped : elapsed >= explainAfter ? .explaining : .quiet
    }

    /// The pause before the next try, after this many failures in a row.
    static func pause(afterFailures failures: Int) -> TimeInterval { failures <= 1 ? 1 : 5 }
}
