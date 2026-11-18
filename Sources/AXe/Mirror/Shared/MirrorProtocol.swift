import Foundation
// Shared with the AXe Mirror app: this file is compiled into the Mac's `axe` and into the viewer.

/// The names the two sides agree a protocol by when they connect.
enum MirrorProtocol {
    /// The stream: video one way, touches and buttons the other.
    static let stream = Data("axe-mirror/1".utf8)
    /// The test viewer's name for the same stream, accepted until that viewer is retired.
    static let legacyStream = Data("mirror-probe/1".utf8)
}

/// Why the host closed a connection, as the QUIC application error code the viewer receives.
enum MirrorClose {
    static let stopped: Int64 = 0       // the host was stopped, or a newer connection replaced this one
    static let protocolError: Int64 = 1
    static let notPaired: Int64 = 2         // the viewer is not on this Mac's list; it must pair first
    static let pairingRefused: Int64 = 3    // the pairing code was wrong, expired or already used
    static let busy: Int64 = 4
    static let timeout: Int64 = 5
    static let internalError: Int64 = 6
}
