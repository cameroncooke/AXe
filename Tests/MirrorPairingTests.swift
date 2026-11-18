import Foundation
import Testing
@testable import AXe

@Suite("Mirror pairing")
struct MirrorPairingTests {
    private let phone = "0bd9d09127260d1753ccbbdc356e10a8c0f86e72cb57262d00552713de12dcb7"
    private let other = "76214ba38cc330df78edae2f8726378cae285fc75881cea0f3084476ebd402a9"
    private let code = "7K3QM9XW2B"

    private func invitation(expiresIn seconds: TimeInterval = 600) -> MirrorInvitation {
        MirrorInvitation(code: code, expires: Date(timeIntervalSince1970: 1_000 + seconds))
    }

    private func request(_ code: String, id: String = "request-1") -> MirrorPairRequest {
        MirrorPairRequest(requestId: id, code: code, name: "Phone")
    }

    private func answer(_ request: MirrorPairRequest) -> MirrorPairReply {
        MirrorPairReply(requestId: request.requestId, hostId: "host", name: "Mac", homeRelay: "https://relay.example.com/", relays: [])
    }

    private let now = Date(timeIntervalSince1970: 1_000)

    @Test("A new code has ten symbols from the alphabet, and two codes differ")
    func randomCode() {
        let codes = Set((0..<200).map { _ in MirrorPairingCode.random() })
        #expect(codes.count == 200)
        #expect(codes.allSatisfy { $0.count == 10 && $0.allSatisfy(MirrorPairingCode.alphabet.contains) })
        #expect(MirrorPairingCode.alphabet.count == 32)
        #expect(!MirrorPairingCode.alphabet.contains { "ILOU".contains($0) })
    }

    @Test("Case, spaces and dashes do not matter, and O, I and L are read as the digits they resemble", arguments: [
        ("7K3QM-9XW2B", "7K3QM9XW2B"), ("7k3qm 9xw2b", "7K3QM9XW2B"), (" 7K3Q-M9XW-2B\n", "7K3QM9XW2B"),
        ("OIL0123456", "0110123456"), ("oil0123456", "0110123456"),
    ])
    func normalises(_ typed: String, _ expected: String) {
        #expect(MirrorPairingCode.normalise(typed) == expected)
    }

    @Test("Text that cannot be a code is not one", arguments: ["", "7K3QM", "7K3QM9XW2B7", "7K3QM9XW2U", "7K3QM9XW2!", "not a code"])
    func rejects(_ typed: String) {
        #expect(MirrorPairingCode.normalise(typed) == nil)
    }

    @Test("The code is shown in two groups and scanned back out of its link")
    func displayAndLink() {
        #expect(MirrorPairingCode.display(code) == "7K3QM-9XW2B")
        #expect(MirrorPairingCode.link(code) == "https://axe-cli.com/pair#7K3QM9XW2B")
        #expect(MirrorPairingCode.fromScan(MirrorPairingCode.link(code)) == code)
        #expect(MirrorPairingCode.fromScan("7k3qm-9xw2b") == code)
        #expect(MirrorPairingCode.fromScan("https://example.com/#nothing") == nil)
    }

    @Test("Both sides derive the same key from a code, and another code gives another key")
    func derivesKey() {
        let key = MirrorPairingCode.endpointSecret(for: code, rounds: 1_000)
        #expect(key.count == 32)
        #expect(key == MirrorPairingCode.endpointSecret(for: code, rounds: 1_000))
        #expect(key != MirrorPairingCode.endpointSecret(for: "7K3QM9XW2C", rounds: 1_000))
        #expect(key != MirrorPairingCode.endpointSecret(for: code, rounds: 1_001))
        // PBKDF2-HMAC-SHA256 of this code and the fixed salt, one round, from an independent implementation.
        #expect(MirrorPairingCode.endpointSecret(for: "0000000000", rounds: 1).map { String(format: "%02x", $0) }.joined()
            == "a6f5488d58ea1bfda947764ddd9cdd79d0a4426fc65ab3d97cfbc4b45cb235fc")
    }

    @Test("Deriving the real key is slow on purpose, and not too slow to use")
    func stretchCost() {
        let start = Date()
        _ = MirrorPairingCode.endpointSecret(for: code)
        let taken = Date().timeIntervalSince(start)
        #expect(taken > 0.02)
        #expect(taken < 2)
    }

    @Test("The first viewer with the right code is accepted")
    func accepts() {
        var invitation = invitation()
        #expect(invitation.accept(request("7k3qm-9xw2b"), from: phone, now: now, answer: answer) == .success(answer(request(""))))
        #expect(invitation.acceptedViewer == phone)
    }

    @Test("A wrong code, a malformed request and a late one are refused, and the code stays usable")
    func refuses() {
        var invitation = invitation(expiresIn: 60)
        #expect(invitation.accept(request("7K3QM9XW2C"), from: phone, now: now, answer: answer) == .failure(.wrongCode))
        #expect(invitation.accept(request("junk"), from: phone, now: now, answer: answer) == .failure(.wrongCode))
        var wrongVersion = request(code); wrongVersion.v = 2
        #expect(invitation.accept(wrongVersion, from: phone, now: now, answer: answer) == .failure(.malformed))
        #expect(invitation.accept(request(code, id: ""), from: phone, now: now, answer: answer) == .failure(.malformed))
        #expect(invitation.accept(request(code), from: phone, now: now.addingTimeInterval(61), answer: answer) == .failure(.expired))
        #expect(invitation.acceptedViewer == nil)
        #expect(invitation.accept(request(code), from: phone, now: now, answer: answer) == .success(answer(request(code))))
    }

    @Test("A code works for one viewer: a second is refused, the first may ask again and gets the same answer")
    func singleUse() {
        var invitation = invitation(expiresIn: 60)
        let first = invitation.accept(request(code), from: phone, now: now, answer: answer)
        #expect(invitation.accept(request(code), from: other, now: now, answer: answer) == .failure(.used))
        var calls = 0
        let again = invitation.accept(request(code, id: "request-2"), from: phone, now: now.addingTimeInterval(120)) { calls += 1; return self.answer($0) }
        #expect(again == first)
        #expect(calls == 0)
    }

    @Test("Messages are framed with their length and capped at 4 KiB")
    func framing() throws {
        let frame = try MirrorPairWire.frame(request(code))
        #expect(MirrorPairWire.length(header: frame.prefix(4)) == frame.count - 4)
        #expect(try JSONDecoder().decode(MirrorPairRequest.self, from: frame.dropFirst(4)) == request(code))
        #expect(MirrorPairWire.length(header: Data([0, 0, 0, 0])) == nil)
        #expect(MirrorPairWire.length(header: Data([1, 16, 0, 0])) == nil)      // 4097
        #expect(MirrorPairWire.length(header: Data([0, 16, 0, 0])) == 4096)
        #expect(MirrorPairWire.length(header: Data([1, 2, 3])) == nil)
        #expect(throws: MirrorPairWire.TooLong.self) { try MirrorPairWire.frame(MirrorPairRequest(requestId: "r", code: self.code, name: String(repeating: "n", count: 5000))) }
    }

    @Test("Codes are compared in full")
    func comparesCodes() {
        #expect(MirrorInvitation.same("ABC", "ABC"))
        #expect(!MirrorInvitation.same("ABC", "ABD"))
        #expect(!MirrorInvitation.same("ABC", "ABCD"))
    }

    @Test("A key that cannot be read is reported and left alone; a missing one is created once")
    func hostKey() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("axe-mirror-key-\(UUID().uuidString)")
        let url = folder.appendingPathComponent("host.key")
        let key = try MirrorIdentity.secret(at: url)
        #expect(key.count == 32)
        #expect(try MirrorIdentity.secret(at: url) == key)
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try Data("short".utf8).write(to: url)
        #expect(throws: CLIError.self) { try MirrorIdentity.secret(at: url) }
        #expect(try Data(contentsOf: url) == Data("short".utf8))
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)      // unreadable as a file
        #expect(throws: CLIError.self) { try MirrorIdentity.secret(at: url) }
    }

    @Test("Commands that first need the key at the same moment all get the same one")
    func hostKeyRace() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("axe-mirror-key-\(UUID().uuidString)/host.key")
        let keys = await withTaskGroup(of: Data?.self) { group -> Set<Data> in
            for _ in 0..<24 { group.addTask { try? MirrorIdentity.secret(at: url) } }
            var seen = Set<Data>()
            for await key in group { if let key { seen.insert(key) } }
            return seen
        }
        #expect(keys.count == 1)
    }
}
