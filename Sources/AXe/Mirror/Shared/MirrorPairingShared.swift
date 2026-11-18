import CommonCrypto
import Foundation
import Security
// Shared with the AXe Mirror app: this file is compiled into the Mac's `axe` and into the viewer.
#if AXE_MIRROR
import IrohLib
#endif

// Pairing puts one viewer on this Mac's list (`MirrorViewers`) and tells the viewer this Mac's ID.
//
// `axe mirror pair` shows a one-time code, as text and as a QR code. Both sides turn the code into
// the same temporary iroh key. The Mac listens with that key on a relay; the viewer works out the
// key's public ID and dials it through the same relay. Nothing has to be looked up anywhere, so
// pairing needs no server beyond the relay. Inside that connection the viewer sends the code, iroh
// tells the Mac the viewer's lasting ID, and the Mac answers with its own.
//
// Reviewed with a second model on 18 November 2026; the points that shaped this file:
// - Anyone who sees the temporary ID (the relay does) can test guesses of the code without
//   connecting, by deriving the ID each guess would give. So the code is stretched: one guess costs
//   about a tenth of a second of processor time, and 50 bits of code cost millions of processor
//   years. The temporary endpoint is also never announced to a discovery service.
// - The code is single use: the first viewer to present it is the only one accepted.
// - The viewer is written to the list before it is told it succeeded.

/// The one-time code a viewer types or scans.
enum MirrorPairingCode {
    /// Crockford's alphabet: no I, L, O or U, so a code read aloud or copied by hand survives.
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    static let length = 10                  // 50 bits
    static let lifetime: TimeInterval = 600
    static let stretchRounds: UInt32 = 600_000

    static func random() -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] })
    }

    /// A typed or scanned code in its one true spelling, or nil if it cannot be a code. Case, spaces
    /// and dashes do not matter, and the letters people mistake for digits are read as the digits.
    static func normalise(_ text: String) -> String? {
        var code = ""
        for character in text.uppercased() {
            switch character {
            case " ", "-", "\n", "\t": continue
            case "O": code.append("0")
            case "I", "L": code.append("1")
            default:
                guard alphabet.contains(character) else { return nil }
                code.append(character)
            }
        }
        return code.count == length ? code : nil
    }

    /// The code as shown to people: two groups of five.
    static func display(_ code: String) -> String {
        "\(code.prefix(length / 2))-\(code.suffix(length - length / 2))"
    }

    /// What the QR code holds. The part after `#` never reaches a web server, and the address lets
    /// the phone's own camera lead to the app once the site is set up for it.
    static func link(_ code: String) -> String { "https://axe-cli.com/pair#\(code)" }

    /// The code out of a scanned link, or out of plain text.
    static func fromScan(_ text: String) -> String? {
        normalise(text.split(separator: "#", maxSplits: 1).count == 2 ? String(text.split(separator: "#", maxSplits: 1)[1]) : text)
    }

    /// The 32-byte key of the temporary endpoint both sides derive from a normalised code. Slow on
    /// purpose (PBKDF2, HMAC-SHA256, `stretchRounds` rounds).
    static func endpointSecret(for code: String, rounds: UInt32 = stretchRounds) -> Data {
        let password = Array(code.utf8), salt = Array("axe-mirror-pair/1/endpoint-key".utf8)
        var key = [UInt8](repeating: 0, count: 32)
        let status = password.withUnsafeBufferPointer { passwordBytes in
            passwordBytes.withMemoryRebound(to: CChar.self) { characters in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), characters.baseAddress, password.count, salt, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &key, key.count)
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 failed")
        return Data(key)
    }
}

/// What the viewer sends on the pairing connection.
struct MirrorPairRequest: Codable, Equatable {
    var v = 1
    var requestId: String       // random; a viewer repeating a request whose answer was lost sends the same one
    var code: String
    var name: String
}

/// What the Mac answers.
struct MirrorPairReply: Codable, Equatable {
    var v = 1
    var requestId: String
    var hostId: String
    var name: String
    var homeRelay: String       // where this Mac listens now; empty when on iroh's public relays
    var relays: [String]        // our relays this Mac may move to
    var mode = "paired"
}

/// The pairing connection's messages: a four-byte little-endian length, then JSON, at most 4 KiB.
enum MirrorPairWire {
    static let alpn = Data("axe-mirror-pair/1".utf8)
    static let limit = 4096
    struct TooLong: Error {}

    static func frame<Message: Encodable>(_ message: Message) throws -> Data {
        let body = try JSONEncoder().encode(message)
        guard body.count <= limit else { throw TooLong() }
        var data = Data()
        withUnsafeBytes(of: UInt32(body.count).littleEndian) { data.append(contentsOf: $0) }
        return data + body
    }

    /// The body length a four-byte header announces, or nil when it is empty or over the limit.
    static func length(header: Data) -> Int? {
        guard header.count == 4 else { return nil }
        let count = header.enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        return (1...limit).contains(count) ? count : nil
    }
}

/// One showing of a code: who may use it and what they are told. No networking, so it can be tested.
struct MirrorInvitation {
    let code: String
    let expires: Date
    private(set) var acceptedViewer: String?
    private(set) var reply: MirrorPairReply?

    enum Refusal: Error, Equatable { case malformed, wrongCode, expired, used }

    init(code: String, expires: Date) {
        self.code = code
        self.expires = expires
    }

    /// Decides one request. `viewer` is the ID iroh verified for the connection. On success the
    /// caller must store the viewer before sending the reply. The first viewer to present the code
    /// owns it: the same viewer may ask again and gets the same answer, anyone else is refused.
    mutating func accept(_ request: MirrorPairRequest, from viewer: String, now: Date = Date(),
                         answer: (MirrorPairRequest) -> MirrorPairReply) -> Result<MirrorPairReply, Refusal> {
        guard request.v == 1, !request.requestId.isEmpty, request.requestId.count <= 64 else { return .failure(.malformed) }
        guard let given = MirrorPairingCode.normalise(request.code), Self.same(given, code) else { return .failure(.wrongCode) }
        if let acceptedViewer {
            guard acceptedViewer == viewer, let reply else { return .failure(.used) }
            return .success(reply)
        }
        guard now < expires else { return .failure(.expired) }
        let made = answer(request)
        acceptedViewer = viewer
        reply = made
        return .success(made)
    }

    /// Compares without stopping at the first difference, so timing says nothing about the code.
    static func same(_ left: String, _ right: String) -> Bool {
        let a = Array(left.utf8), b = Array(right.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

#if AXE_MIRROR
/// The n0 set-up without its discovery service: the endpoint is reachable only by someone who
/// already knows its ID and its relay. `relayURLs` empty means iroh's public relays.
final class MirrorUnannouncedPreset: Preset {
    let relayURLs: [String]
    init(relayURLs: [String]) { self.relayURLs = relayURLs }
    func apply(builder: EndpointBuilder) {
        builder.applyMinimal()
        if relayURLs.isEmpty {
            builder.relayMode(mode: RelayMode.defaultMode())
        } else if let mode = try? RelayMode.customFromUrls(urls: relayURLs) {
            builder.relayMode(mode: mode)
        }
    }
}

/// The viewer's half of pairing, as the viewer app must do it. Here it serves the tests and the
/// hidden `axe mirror test-pair` command.
enum MirrorPairClient {
    enum Failure: Error, Equatable { case badCode, notFound, refused, badReply }

    /// Presents `text` (a typed code or a scanned link) as the viewer whose key is `viewerSecret`.
    /// `relays` are tried in turn: the Mac is on one of them.
    static func pair(code text: String, name: String, viewerSecret: Data, relays: [String], dialSeconds: TimeInterval = 10) async -> Result<MirrorPairReply, Failure> {
        guard let code = MirrorPairingCode.fromScan(text),
              let target = try? SecretKey.fromBytes(bytes: MirrorPairingCode.endpointSecret(for: code)).public() else { return .failure(.badCode) }
        let candidates = relays.isEmpty ? RelayMode.defaultMode().relayMap().urls() : relays
        guard let endpoint = try? await Endpoint.bind(options: EndpointOptions(
            preset: MirrorUnannouncedPreset(relayURLs: relays), secretKey: viewerSecret, alpns: [])) else { return .failure(.notFound) }
        defer { Task { try? await endpoint.close() } }
        let request = MirrorPairRequest(requestId: UUID().uuidString, code: code, name: name)
        for relay in candidates {
            let address = EndpointAddr(id: target, relayUrl: relay, addresses: [])
            guard let connection = await MirrorTimeout.finishes(within: dialSeconds, { try? await endpoint.connect(addr: address, alpn: MirrorPairWire.alpn) }) ?? nil else { continue }
            let reply = await MirrorTimeout.finishes(within: 10) { () -> MirrorPairReply? in
                guard let stream = try? await connection.openBi(), let frame = try? MirrorPairWire.frame(request),
                      (try? await stream.send().writeAll(buf: frame)) != nil,
                      let header = try? await stream.recv().readExact(size: 4), let length = MirrorPairWire.length(header: header),
                      let body = try? await stream.recv().readExact(size: UInt32(length)) else { return nil }
                return try? JSONDecoder().decode(MirrorPairReply.self, from: body)
            } ?? nil
            try? connection.close(errorCode: MirrorClose.stopped, reason: Data())
            // Reaching the endpoint proves the code named a pairing in progress; no answer means the Mac said no.
            guard let reply else { return .failure(.refused) }
            return reply.v == 1 && reply.requestId == request.requestId && !reply.hostId.isEmpty ? .success(reply) : .failure(.badReply)
        }
        return .failure(.notFound)
    }
}

/// Bounds work that has no time limit of its own.
enum MirrorTimeout {
    /// The work's result, or nil if it takes longer than `seconds`. iroh's calls do not stop when
    /// their task is cancelled, so the work is left running and its late result is dropped; closing
    /// the endpoint or the connection is what ends it.
    static func finishes<Value: Sendable>(within seconds: TimeInterval, _ work: @escaping @Sendable () async -> Value) async -> Value? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
            let first = FirstResult(continuation)
            Task { first.give(await work()) }
            Task { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); first.give(nil) }
        }
    }

    private final class FirstResult<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value?, Never>?
        init(_ continuation: CheckedContinuation<Value?, Never>) { self.continuation = continuation }
        func give(_ value: Value?) {
            let waiting = lock.withLock { () -> CheckedContinuation<Value?, Never>? in
                defer { continuation = nil }
                return continuation
            }
            waiting?.resume(returning: value)
        }
    }
}
#endif
