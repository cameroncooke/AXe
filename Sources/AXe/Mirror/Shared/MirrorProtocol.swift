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

/// What a viewer does about its lasting key when it looks for it in the Keychain. The key is this
/// device's identity to every Mac it is paired with, so a new one unpairs them all.
enum MirrorViewerKey: Equatable {
    /// The key that was found.
    case use(Data)
    /// There is none, or what is there is not a key: make one and keep it.
    case create
    /// The Keychain could not be read just now, as before a device's first unlock after a
    /// restart. The key may well be there: use a key for this run only, and leave it alone.
    case temporary

    /// `status` and `found` are what the Keychain answered. Only "there is no such item" means
    /// there is none. Every other failure used to be taken for that too, and the key replaced.
    static func decide(status: Int32, found: Data?, missing: Int32) -> MirrorViewerKey {
        if status == 0 { return found?.count == 32 ? .use(found ?? Data()) : .create }
        return status == missing ? .create : .temporary
    }
}
