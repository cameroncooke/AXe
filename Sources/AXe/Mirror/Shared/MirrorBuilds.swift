import Foundation

/// App builds the Mac offers a viewer to install on the viewer's own iPhone or iPad.
///
/// The Mac says which builds there are over the connection the viewer is paired on, so the app can
/// list them and offer Install, and the build itself comes the same way, in pieces. An app cannot
/// install another app: iOS's own installer downloads a build, over HTTPS, from a name whose
/// certificate the device trusts. So the viewer keeps the file and serves it to iOS from the
/// device itself (see `MirrorInstallIdentity`). No other network or server is in the download.
extension MirrorMessage {
    /// Host to viewer: the builds on offer, a `MirrorBuildList`. Sent when the viewer asks and
    /// whenever the builds change after that.
    static let builds: UInt8 = 47
    /// Viewer to host: send the builds. No payload.
    static let listBuilds: UInt8 = 48
    /// Viewer to host: the person tapped Install on this build, a `MirrorBuildInstall`. The host
    /// prints it; whether iOS then installed the build is not something either end can see.
    static let installing: UInt8 = 49
    /// Viewer to host: send the certificate this viewer's own build server is to use. No payload.
    static let installIdentityRequest: UInt8 = 50
    /// Host to viewer: that certificate, a `MirrorInstallIdentity`.
    static let installIdentity: UInt8 = 51
    /// Viewer to host: send a piece of a build the host holds, a `MirrorBuildFetch`.
    static let fetchBuild: UInt8 = 52
    /// Host to viewer: the piece asked for, as `MirrorBuildPiece.encoded` lays it out.
    static let buildPiece: UInt8 = 53
    /// Host to viewer: a piece could not be sent, a `MirrorBuildFetchFailure`.
    static let fetchFailed: UInt8 = 54
}

/// The certificate a viewer serves builds to iOS with, from the device itself.
///
/// iOS's installer downloads a build over HTTPS and nothing else, from a name whose certificate
/// the device trusts. Measured on an iPhone Duo with iOS 27.3 (21 November 2026): it will download
/// from the device's own address when that is given as a real name that resolves to 127.0.0.1,
/// and the certificate is one the person has installed and switched on under Certificate Trust
/// Settings; given `localhost` or `127.0.0.1` it does not connect at all. So the build goes to the
/// viewer over the paired connection, direct or relayed, and the viewer hands it to iOS itself: no
/// other network, no server of ours in the download.
///
/// The host makes the certificate, one authority and one certificate signed by it for the names in
/// `names`, and throws the authority's key away at once. The authority's own certificate limits
/// it to those names (`MirrorCertificateLimits`), which the viewer checks before it offers it to
/// be trusted: nothing signed by it for any other site is accepted by iOS, whoever holds its key.
/// `authority` is the authority's certificate (DER), which the person installs and trusts once;
/// `identity` is the signed certificate with its key (PKCS #12, opened with `password`).
struct MirrorInstallIdentity: Codable, Equatable, Sendable {
    var authority: Data
    var identity: Data
    var password: String
    var names: [String]
    var expires: Double
    /// What the authority is called under Certificate Trust Settings, for the instructions.
    var authorityName: String?

    /// Names that resolve to 127.0.0.1, most wanted first: AXe's own, then two public ones that
    /// have long done so. The viewer uses the first that reaches its own server.
    static let loopbackNames = ["local.axe-cli.com", "localtest.me", "lvh.me"]
}

struct MirrorBuildFetch: Codable, Equatable, Sendable {
    var id: String
    var offset: Int
    var length: Int

    /// The most one piece may hold.
    static let largest = 512 * 1024

    /// Whether the host takes a request for a piece now. A viewer asks for the next piece when it
    /// has the last, so the host never has more than one in hand; a viewer that asks faster than
    /// it reads would otherwise have the host read the file into memory piece after piece.
    /// `reading` is whether a piece is being read from the disk, and `queued` the bytes handed to
    /// the connection and not yet taken by it.
    static func accepted(reading: Bool, queued: Int) -> Bool { !reading && queued < largest }
}

struct MirrorBuildFetchFailure: Codable, Equatable, Sendable {
    var id: String
    var message: String
}

/// A piece of a build's file: its ID's length in one byte, the ID, the offset in eight bytes
/// (little-endian), then the bytes.
struct MirrorBuildPiece: Equatable, Sendable {
    var id: String
    var offset: Int
    var bytes: Data

    var encoded: Data {
        let name = Data(id.utf8)
        var data = Data(capacity: name.count + 9 + bytes.count)
        data.append(UInt8(min(name.count, 255)))
        data.append(name.prefix(255))
        var place = UInt64(offset).littleEndian
        withUnsafeBytes(of: &place) { data.append(contentsOf: $0) }
        data.append(bytes)
        return data
    }

    init(id: String, offset: Int, bytes: Data) {
        self.id = id
        self.offset = offset
        self.bytes = bytes
    }

    init?(_ data: Data) {
        guard let length = data.first.map(Int.init), data.count >= 1 + length + 8 else { return nil }
        let start = data.startIndex + 1
        id = String(decoding: data[start..<(start + length)], as: UTF8.self)
        var place: UInt64 = 0
        for (index, byte) in data[(start + length)..<(start + length + 8)].enumerated() { place |= UInt64(byte) << (8 * UInt64(index)) }
        offset = Int(place)
        bytes = Data(data[(start + length + 8)...])
    }
}

/// One build of an app, which the Mac holds. `published` and `expires` are seconds since 1970; a
/// build's signing profile stops working at `expires`. `sha256` is the digest of the build's file,
/// in hex, which the viewer checks once it has fetched it.
struct MirrorBuild: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var bundleID: String
    var version: String
    var build: String
    var notes: String?
    var published: Double?
    var expires: Double?
    var size: Int?
    var minimumOS: String?
    var sha256: String?
    /// How many registered devices the build is signed for. Whether this device is one of them
    /// neither end can tell: iOS does not let an app read its own device identifier.
    var devices: Int?

    func isExpired(at now: Date = Date()) -> Bool {
        expires.map { $0 <= now.timeIntervalSince1970 } ?? false
    }

    /// "1.2 (7)".
    var versionText: String { build.isEmpty ? version : "\(version) (\(build))" }

    /// The `itms-services` link for a manifest's address, with the address escaped as iOS expects.
    static func installURL(manifest: String) -> String? {
        var plain = CharacterSet.alphanumerics
        plain.insert(charactersIn: "-._~")
        guard let escaped = manifest.addingPercentEncoding(withAllowedCharacters: plain) else { return nil }
        return "itms-services://?action=download-manifest&url=" + escaped
    }
}

struct MirrorBuildList: Codable, Equatable, Sendable {
    var builds: [MirrorBuild]
}

struct MirrorBuildInstall: Codable, Equatable, Sendable {
    var id: String
}
