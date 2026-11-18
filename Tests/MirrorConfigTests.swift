import Foundation
import Testing
@testable import AXe

@Suite("Mirror configuration and demo rules")
struct MirrorConfigTests {
    private let host = "e2c0ec426e54de19c6db5c74a68871cfec4e7663d9905c0982543a5f2470d7c0"

    @Test("The published record is read as written")
    func parsesPublishedRecord() {
        let config = MirrorConfig.parse("v=1 min=1 demo=\(host) demo-relay=https://eu1.relay.axe-cli.com")
        #expect(config == MirrorConfig(minimumBuild: 1, demoHost: host, demoRelay: "https://eu1.relay.axe-cli.com"))
    }

    @Test("A record with nothing but its version forbids nothing and offers no demo")
    func emptyRecord() {
        #expect(MirrorConfig.parse("v=1") == MirrorConfig.builtIn)
        #expect(MirrorConfig.builtIn.demoHost == nil)
        #expect(MirrorConfig.builtIn.minimumBuild == 0)
    }

    @Test("Unknown words and bad values are skipped, the rest is kept")
    func skipsWhatItDoesNotKnow() {
        let config = MirrorConfig.parse("v=1  future=thing min=abc demo=NOTHEX demo-relay=http://plain.example.com min=7 lonely")
        #expect(config == MirrorConfig(minimumBuild: 7, demoHost: nil, demoRelay: nil))
        #expect(MirrorConfig.parse("v=1 demo=\(host.uppercased())")?.demoHost == nil)
        #expect(MirrorConfig.parse("v=1 demo=\(host.dropLast())")?.demoHost == nil)
    }

    @Test("Other records are not configuration", arguments: ["", "v=2 min=1", "v=spf1 include:example.com ~all", "min=1"])
    func rejects(_ record: String) {
        #expect(MirrorConfig.parse(record) == nil)
    }

    @Test("A demo drops touches that start at the top or bottom edge, and only those")
    func demoEdges() {
        #expect(MirrorDemo.blocksTouch(downAt: 0.0))
        #expect(MirrorDemo.blocksTouch(downAt: 0.05))
        #expect(MirrorDemo.blocksTouch(downAt: 0.97))
        #expect(MirrorDemo.blocksTouch(downAt: 1.0))
        #expect(!MirrorDemo.blocksTouch(downAt: 0.08))
        #expect(!MirrorDemo.blocksTouch(downAt: 0.5))
        #expect(!MirrorDemo.blocksTouch(downAt: 0.92))
    }

    @Test("A demo visitor keeps the demo for three minutes, then a newcomer may take over")
    func demoTurns() {
        #expect(!MirrorDemo.isBusy(connectedFor: nil))
        #expect(MirrorDemo.isBusy(connectedFor: 0))
        #expect(MirrorDemo.isBusy(connectedFor: 179))
        #expect(!MirrorDemo.isBusy(connectedFor: 180))
    }

    @Test("The stream is called axe-mirror/1, pairing axe-mirror-pair/1, and the close codes are fixed")
    func frozenNames() {
        #expect(MirrorProtocol.stream == Data("axe-mirror/1".utf8))
        #expect(MirrorPairWire.alpn == Data("axe-mirror-pair/1".utf8))
        #expect([MirrorClose.stopped, MirrorClose.protocolError, MirrorClose.notPaired, MirrorClose.pairingRefused, MirrorClose.busy,
                 MirrorClose.timeout, MirrorClose.internalError] == [0, 1, 2, 3, 4, 5, 6])
    }
}
