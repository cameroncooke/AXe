import Foundation
// Shared with the AXe Mirror app: this file is compiled into the Mac's `axe` and into the viewer.

/// Settings the viewer app reads when it starts, published as a DNS TXT record so that they can be
/// changed without an app update:
///
///     _mirror.axe-cli.com  TXT  "v=1 min=1 demo=<host ID> demo-relay=https://eu1.relay.axe-cli.com"
///
/// `v=1` names the format. `min` is the lowest app build that may still connect; an older build
/// asks its user to update. `demo` is the ID of the demo host behind the app's "Try the demo"
/// button, and `demo-relay` the relay it listens on; with no `demo` the button is hidden. Words
/// this version does not know are skipped.
struct MirrorConfig: Equatable, Sendable {
    var minimumBuild = 0
    var demoHost: String?
    var demoRelay: String?

    static let recordName = "_mirror.axe-cli.com"

    /// Used when the record cannot be read: no demo, nothing forbidden.
    static let builtIn = MirrorConfig()

    /// Reads one published record. Nil when it is not a version 1 record.
    static func parse(_ record: String) -> MirrorConfig? {
        let words = record.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard words.first == "v=1" else { return nil }
        var config = MirrorConfig()
        for word in words.dropFirst() {
            let parts = word.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "min":
                if let build = Int(parts[1]), build >= 0 { config.minimumBuild = build }
            case "demo":
                // An endpoint ID is 32 bytes as 64 lowercase hexadecimal digits.
                if parts[1].count == 64, parts[1].allSatisfy({ $0.isHexDigit && !$0.isUppercase }) { config.demoHost = parts[1] }
            case "demo-relay":
                if parts[1].hasPrefix("https://"), let host = URL(string: parts[1])?.host, !host.isEmpty { config.demoRelay = parts[1] }
            default:
                continue
            }
        }
        return config
    }

    /// The published settings, or nil when the record cannot be read.
    static func published() -> MirrorConfig? {
        MirrorRelays.lookup(recordName).compactMap(parse).first
    }

    /// The published settings, or the built-in ones when the record cannot be read.
    static func load() -> MirrorConfig { published() ?? builtIn }

    /// Whether to read the settings now. Once they have been read they are kept for the run. If
    /// the record could not be read, it is tried again, but no more than once in `retryAfter`: it
    /// used to be read again on every call for as long as the settings equalled the built-in
    /// ones, which they also do when that is what is published, so every pairing and every return
    /// to the list of Macs paid for a DNS lookup and a round of relay timings.
    static func shouldRead(loaded: Bool, wasRead: Bool, sinceLastTry: TimeInterval) -> Bool {
        !loaded || (!wasRead && sinceLastTry >= retryAfter)
    }
    static let retryAfter: TimeInterval = 60
}
