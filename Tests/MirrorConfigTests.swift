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

    @Test("A demo visitor who connects again carries on with the turn it had, and a new visitor starts one")
    func demoTurn() {
        // Connected at 100, last heard from at 250, connecting again at 252: the turn still began at 100,
        // so at 280 it is over and a newcomer is let in.
        let again = MirrorDemo.turnStart(viewer: "a", previousViewer: "a", previousStart: 100, lastHeard: 250, now: 252)
        #expect(again == 100 && !MirrorDemo.isBusy(connectedFor: 281 - again))
        // Another visitor, or the same one back after being gone, starts a turn of its own.
        #expect(MirrorDemo.turnStart(viewer: "b", previousViewer: "a", previousStart: 100, lastHeard: 250, now: 252) == 252)
        #expect(MirrorDemo.turnStart(viewer: "a", previousViewer: "a", previousStart: 100, lastHeard: 200, now: 252) == 252)
    }

    @Test("The demo's lock passes touches on only while the sample app is in front")
    func demoLock() {
        var state = MirrorDemo.LockState()
        let front = MirrorDemo.lockStep(inFront: true, state: &state)
        #expect(front.allowsInput)
        #expect(!front.pullBack)

        // Another app in front: touches are dropped at once and the sample app is brought back,
        // again once a second for as long as it lasts.
        let first = MirrorDemo.lockStep(inFront: false, state: &state)
        #expect(!first.allowsInput)
        #expect(first.pullBack)
        var pulls = 1
        var open = false
        for _ in 2...MirrorDemo.stuckAfter {
            let step = MirrorDemo.lockStep(inFront: false, state: &state)
            if step.pullBack { pulls += 1 }
            if step.allowsInput { open = true }
        }
        #expect(!open)
        #expect(pulls == 3)
        // Three seconds of bringing it back without success: something the app cannot cover is in
        // front, and the touch that dismisses it is let through.
        let stuck = MirrorDemo.lockStep(inFront: false, state: &state)
        #expect(stuck.allowsInput)

        // Back in front: everything starts again.
        let back = MirrorDemo.lockStep(inFront: true, state: &state)
        let away = MirrorDemo.lockStep(inFront: false, state: &state)
        #expect(back.allowsInput)
        #expect(state == MirrorDemo.LockState(away: 1, unknown: 0))
        #expect(!away.allowsInput)
    }

    @Test("A look that cannot tell which app is in front leaves input open and brings the app back every five seconds")
    func demoLockUnknown() {
        var state = MirrorDemo.LockState()
        var pulls = 0
        var closed = false
        for _ in 1...40 {
            let step = MirrorDemo.lockStep(inFront: nil, state: &state)
            if step.pullBack { pulls += 1 }
            if !step.allowsInput { closed = true }
        }
        #expect(!closed)
        #expect(pulls == 2)
    }

    @Test("The sample app's process is read from what simctl launch prints")
    func demoProcessID() {
        let plain = MirrorDemo.processID(inLaunchOutput: "com.example.app: 12345\n")
        let none = MirrorDemo.processID(inLaunchOutput: "")
        let words = MirrorDemo.processID(inLaunchOutput: "An error was encountered")
        #expect(plain == 12345)
        #expect(none == nil)
        #expect(words == nil)
        #expect(MirrorDemo.launchArguments == ["--launch-arg", "demo=1"])
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
