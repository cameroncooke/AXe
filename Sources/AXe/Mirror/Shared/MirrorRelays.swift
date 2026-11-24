import CryptoKit
import Darwin
import dnssd
import Foundation
// Shared with the AXe Mirror app: this file is compiled into the Mac's `axe` and into the viewer.

/// Which relays `axe remote` may use, and how one is chosen.
///
/// A relay introduces the two devices to each other and carries their traffic when they cannot
/// connect directly. The list of relays is published as a DNS TXT record, so that one can be added
/// or retired without a new AXe release:
///
///     _relays.axe-cli.com  TXT  "v=1 https://eu1.relay.axe-cli.com https://us1.relay.axe-cli.com public"
///
/// `v=1` names the format. Each `https://` word is a relay of ours. The word `public` allows iroh's
/// public relays as a last resort, when none of ours answers. Words this version does not know are
/// skipped, so later versions can add to the record.
enum MirrorRelays {
    static let recordName = "_relays.axe-cli.com"

    struct List: Equatable, Sendable {
        var own: [String]
        var allowsPublic: Bool
    }

    /// Used when the record cannot be read.
    static let builtIn = List(own: ["https://eu1.relay.axe-cli.com"], allowsPublic: true)

    /// What a session will use, and where that came from, for the log.
    struct Choice: Equatable, Sendable {
        /// Our relays in order of preference. Empty means iroh's public relays.
        var relays: [String]
        var source: String
        /// Every relay of ours the other side of a pairing may be listening on: the ones that
        /// answer, nearest first, then the rest. `relays` keeps one of each group of equally near
        /// relays, chosen by this side's own seed, and the other side's seed may choose another of
        /// that group. Whoever looks for the other side must look on all of them.
        var everyRelay: [String] = []
        /// Whether the other side may be on iroh's public relays instead, as it is when none of
        /// ours answered it.
        var allowsPublic = true

        /// True when the relay was named on the command line, and so is on no list a viewer has.
        var isNamed: Bool { source == "--relay-url" }

        /// Where a viewer looks for a Mac that is showing a pairing code: `first`, when the code
        /// came with a relay of its own, then every relay of ours, then the public ones.
        func pairingRelays(first: String? = nil, public publicRelays: [String]) -> [String] {
            var seen = Set<String>()
            return ([first].compactMap { $0 } + everyRelay + relays + (allowsPublic ? publicRelays : [])).filter { seen.insert($0).inserted }
        }

        /// The line `axe remote` prints for it.
        var event: [String: String] {
            ["event": "relays", "source": source, "relays": relays.isEmpty ? "public" : relays.joined(separator: " ")]
        }
    }

    /// A value that differs from one host to the next and stays the same for one host, made from the
    /// host's key without revealing it. It decides which of several equally near relays a host uses.
    static func seed(for secret: Data) -> String {
        SHA256.hash(data: Data("axe mirror relay choice".utf8) + secret).map { String(format: "%02x", $0) }.joined()
    }

    /// Reads one published record. Nil when it is not a version 1 record or names no relay.
    static func parse(_ record: String) -> List? {
        let words = record.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard words.first == "v=1" else { return nil }
        var list = List(own: [], allowsPublic: false)
        for word in words.dropFirst() {
            if word == "public" {
                list.allowsPublic = true
            } else if word.hasPrefix("https://"), let url = URL(string: word), let host = url.host, !host.isEmpty, !list.own.contains(word) {
                list.own.append(word)
            }
        }
        return list.own.isEmpty && !list.allowsPublic ? nil : list
    }

    /// Orders our relays for one host from the round trip to each; a relay that did not answer is
    /// left out.
    ///
    /// Relays within `near` of the quickest count as equally near. Each host takes one of them by
    /// its `seed`, so that several relays in one region share the hosts evenly, one host always
    /// makes the same choice, and a relay added to the region takes its share from the others
    /// without moving any other host. iroh itself always prefers the nearest relay it is given, so
    /// the rest of that group is not offered to it. The relays further away follow, nearest first,
    /// for iroh to move to if the first stops answering.
    static func order(_ own: [String], latency: [String: TimeInterval], seed: String = "", near: TimeInterval = 0.015) -> [String] {
        let answering = own.filter { latency[$0] != nil }
        guard let quickest = answering.compactMap({ latency[$0] }).min() else { return [] }
        let nearGroup = answering.filter { (latency[$0] ?? .infinity) <= quickest + near }
        guard let chosen = nearGroup.max(by: { score(seed, $0) < score(seed, $1) }) else { return [] }
        let further = answering.filter { !nearGroup.contains($0) }.sorted { (latency[$0] ?? 0) < (latency[$1] ?? 0) }
        return [chosen] + further
    }

    /// How strongly the host with this seed prefers this relay; the highest wins.
    private static func score(_ seed: String, _ relay: String) -> UInt64 {
        SHA256.hash(data: Data((seed + "\n" + relay).utf8)).prefix(8).reduce(0) { $0 << 8 | UInt64($1) }
    }

    /// The relays for one host: the one named on the command line, or the published list (the
    /// built-in list when it cannot be read) ordered by `order`. When none of ours answers and the
    /// list allows it, iroh's public relays are used. `record` stands in for the published record.
    static func choose(explicit: String?, seed: String = "", record: String? = nil) async -> Choice {
        if let explicit, !explicit.isEmpty { return Choice(relays: [explicit], source: "--relay-url", everyRelay: [explicit], allowsPublic: false) }
        var list = builtIn
        var source = "built-in list"
        if let record {
            if let given = parse(record) { list = given; source = "--relay-list" }
        } else if let published = lookup(recordName).compactMap(parse).first {
            list = published
            source = "published list"
        }
        let latency = await measure(list.own)
        let ordered = order(list.own, latency: latency, seed: seed)
        let every = list.own.filter { latency[$0] != nil }.sorted { (latency[$0] ?? 0) < (latency[$1] ?? 0) } + list.own.filter { latency[$0] == nil }
        if !ordered.isEmpty { return Choice(relays: ordered, source: source, everyRelay: every, allowsPublic: list.allowsPublic) }
        if list.allowsPublic { return Choice(relays: [], source: source + ", none of ours answered, public relays", everyRelay: every, allowsPublic: true) }
        // Nothing answered and the public relays are not allowed: offer ours anyway, in case they return.
        return Choice(relays: list.own, source: source + ", none answered", everyRelay: every, allowsPublic: false)
    }

    /// Whether a running host with no viewer connected should choose its relays again now.
    ///
    /// The host asks its relay every half minute whether it is there; `missed` counts the times in
    /// a row it did not answer. After two the host chooses again. A host on the public relays looks
    /// every two minutes for ours to return. Otherwise it looks every half hour, which is how a
    /// relay added to or taken off the published list reaches hosts that never restart.
    static func checkDue(onOwn: Bool, missed: Int, sinceCheck: TimeInterval) -> Bool {
        if onOwn, missed >= 2 { return true }
        return sinceCheck >= (onOwn ? 1800 : 120)
    }

    /// The round trip to each relay in seconds; a relay that does not answer within the limit is
    /// missing from the result.
    ///
    /// Each relay is asked twice at `/ping`, which every iroh relay answers with an empty reply. The
    /// first request pays for the name lookup and the TLS handshake. The second goes over the same
    /// connection and is the one timed, so the figure is one round trip and relays can be compared.
    static func measure(_ relays: [String], limit: TimeInterval = 2.5) async -> [String: TimeInterval] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = limit
        configuration.timeoutIntervalForResource = limit
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        return await withTaskGroup(of: (String, TimeInterval?).self) { group in
            for relay in relays {
                group.addTask {
                    guard let url = URL(string: relay)?.appendingPathComponent("ping") else { return (relay, nil) }
                    func answers() async -> Bool {
                        guard let (_, response) = try? await session.data(from: url),
                              let status = (response as? HTTPURLResponse)?.statusCode else { return false }
                        return (200..<500).contains(status)
                    }
                    guard await answers() else { return (relay, nil) }
                    let start = ProcessInfo.processInfo.systemUptime
                    guard await answers() else { return (relay, nil) }
                    return (relay, ProcessInfo.processInfo.systemUptime - start)
                }
            }
            var result: [String: TimeInterval] = [:]
            for await (relay, time) in group { if let time { result[relay] = time } }
            return result
        }
    }

    /// The TXT records at `name`, each with its strings joined. Empty when the lookup fails or takes
    /// longer than `limit`.
    ///
    /// "No such record" is not taken as final at once. The system resolver can give that answer from
    /// its memory and the record itself a moment later, as it did for half an hour after this record
    /// was first published. So the lookup waits `patience` longer for a record to follow.
    static func lookup(_ name: String, limit: TimeInterval = 2, patience: TimeInterval = 0.75) -> [String] {
        final class Answers { var texts: [String] = []; var finished = false; var refused: TimeInterval? }
        let answers = Answers()
        let reply: DNSServiceQueryRecordReply = { _, flags, _, error, _, _, _, length, data, _, context in
            guard let context else { return }
            let answers = Unmanaged<Answers>.fromOpaque(context).takeUnretainedValue()
            if error == kDNSServiceErr_NoError, let data, flags & kDNSServiceFlagsAdd != 0 {
                // A TXT record is a run of strings, each with its length in the byte before it.
                let bytes = [UInt8](UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: Int(length)))
                var text = "", index = 0
                while index < bytes.count {
                    let end = min(bytes.count, index + 1 + Int(bytes[index]))
                    text += String(decoding: bytes[(index + 1)..<end], as: UTF8.self)
                    index = end
                }
                answers.texts.append(text)
            }
            if error == kDNSServiceErr_NoSuchRecord {
                if answers.refused == nil { answers.refused = ProcessInfo.processInfo.systemUptime }
            } else if error != kDNSServiceErr_NoError || flags & kDNSServiceFlagsMoreComing == 0 {
                answers.finished = true
            }
        }
        var service: DNSServiceRef?
        let started = DNSServiceQueryRecord(&service, kDNSServiceFlagsTimeout, 0, name, UInt16(kDNSServiceType_TXT), UInt16(kDNSServiceClass_IN),
                                            reply, Unmanaged.passUnretained(answers).toOpaque())
        guard started == kDNSServiceErr_NoError, let service else { return [] }
        defer { DNSServiceRefDeallocate(service) }
        let deadline = ProcessInfo.processInfo.systemUptime + limit
        while !answers.finished {
            let remaining = min(deadline, answers.refused.map { $0 + patience } ?? deadline) - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { break }
            var descriptor = pollfd(fd: DNSServiceRefSockFD(service), events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, Int32(remaining * 1000)) > 0, DNSServiceProcessResult(service) == kDNSServiceErr_NoError else { break }
        }
        return answers.texts
    }
}
