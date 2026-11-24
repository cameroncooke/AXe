#if AXE_MIRROR
import Foundation
import Testing
@testable import AXe

/// Pairs a viewer with a host through the real relay, the way the AXe Mirror app and `axe remote
/// pair` do. It needs the network, so it runs only when asked for:
///
///     AXE_MIRROR_E2E=1 swift test --filter MirrorPairingRelayTests
@Suite("Mirror pairing through the relay", .enabled(if: ProcessInfo.processInfo.environment["AXE_MIRROR_E2E"] != nil))
struct MirrorPairingRelayTests {
    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value?
        func set(_ new: Value) { lock.withLock { value = new } }
        func get() -> Value? { lock.withLock { value } }
    }

    private func key() -> Data { Data((0..<32).map { _ in UInt8.random(in: 0...255) }) }

    @Test("A viewer with the code is paired and stored; the code then works for nobody else")
    func pairsOnce() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("axe-mirror-e2e-\(UUID().uuidString)")
        let viewers = MirrorViewers(url: folder.appendingPathComponent("viewers.json"))
        let relays = await MirrorRelays.choose(explicit: nil)
        let shown = Box<MirrorPairHost.Shown>()
        let hostSecret = key()
        async let paired = MirrorPairHost.run(hostSecret: hostSecret, relays: relays, viewers: viewers, hostName: "Test Mac", lifetime: 60) { shown.set($0) }

        var waited = 0.0
        while shown.get() == nil, waited < 30 {
            try await Task.sleep(nanoseconds: 200_000_000)
            waited += 0.2
        }
        let code = try #require(shown.get())
        #expect(MirrorPairingCode.fromScan(code.link) == code.code)

        // A viewer with a wrong code finds nobody.
        let wrong = await MirrorPairClient.pair(code: "00000-00000", name: "Stranger", viewerSecret: key(), relays: relays.relays, dialSeconds: 4)
        #expect(wrong == .failure(.notFound))

        // The viewer with the scanned link is paired and told who the Mac is.
        let reply = try await MirrorPairClient.pair(code: code.link, name: "Test viewer", viewerSecret: key(), relays: relays.relays).get()
        #expect(reply.name == "Test Mac")
        #expect(reply.hostId.count == 64)
        let viewer = try await paired
        #expect(viewer.name == "Test viewer")
        #expect(viewers.allows(viewer.id))
        #expect(try viewers.all().count == 1)

        // The code has been used: a second viewer gets nowhere, and the list is unchanged.
        let late = await MirrorPairClient.pair(code: code.code, name: "Late viewer", viewerSecret: key(), relays: relays.relays, dialSeconds: 4)
        #expect(late != .success(reply))
        #expect(try viewers.all().count == 1)
    }
}
#endif
