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

    @Test("A list of simulators takes the screen only when the app is choosing or the Mac has let its simulator go")
    func lateList() {
        // Watching a simulator, and a list arrives that answers a refresh made before it was opened.
        #expect(!MirrorViewerRules.listTakesScreen(choosing: false, expected: false, showingSimulator: true))
        // At the list, on a new connection, after another device took the simulator, or with nothing shown.
        #expect(MirrorViewerRules.listTakesScreen(choosing: true, expected: false, showingSimulator: true))
        #expect(MirrorViewerRules.listTakesScreen(choosing: false, expected: true, showingSimulator: true))
        #expect(MirrorViewerRules.listTakesScreen(choosing: false, expected: false, showingSimulator: false))
    }

    @Test("The setup says the network is in the way only when no name could be reached at all")
    func setupHint() {
        // Not trusted yet: the names lead here, and the certificate is refused. Nothing to add to the steps.
        #expect(MirrorViewerRules.setupHint(for: [.serverCertificateUntrusted, .serverCertificateUntrusted, .serverCertificateUntrusted]) == nil)
        #expect(MirrorViewerRules.setupHint(for: [.cannotFindHost, .serverCertificateUntrusted]) == nil)
        #expect(MirrorViewerRules.setupHint(for: []) == nil)
        // A network that will not resolve the names to this device.
        let hint = MirrorViewerRules.setupHint(for: [.cannotFindHost, .dnsLookupFailed, .cannotConnectToHost])
        #expect(hint?.contains("network is in the way") == true)
    }

    @Test("A pong with a time that is not a number, or a round trip no connection has, is dropped")
    func pong() throws {
        let good = try #require(MirrorViewerRules.clockSample(sent: 100, hostTime: 203.52, received: 100.04))
        #expect(abs(good.roundTrip - 0.04) < 1e-9 && abs(good.offset - 103.5) < 1e-9)
        #expect(MirrorViewerRules.clockSample(sent: .nan, hostTime: 203.5, received: 100.04) == nil)
        #expect(MirrorViewerRules.clockSample(sent: 100, hostTime: .infinity, received: 100.04) == nil)
        #expect(MirrorViewerRules.clockSample(sent: 100.5, hostTime: 203.5, received: 100.04) == nil)      // answered before it was asked
        #expect(MirrorViewerRules.clockSample(sent: -1e300, hostTime: 203.5, received: 100.04) == nil)
    }

    @Test("Installing a build removes the others the device kept, and only builds")
    func tidiesBuilds() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("axe-cache-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["build-aaa.ipa", "build-bbb.ipa", "build-ccc.ipa", "notes.txt", "other.ipa"] {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }
        #expect(MirrorViewerRules.tidyBuilds(keeping: ["bbb", "ccc"], in: folder) == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["build-bbb.ipa", "build-ccc.ipa", "notes.txt", "other.ipa"])
    }

    @Test("The app waits longer for the Mac than the Mac allows itself, so the Mac's own word comes first")
    func whoSpeaksFirst() {
        #expect(Double(MirrorViewerRules.choiceAnswerSeconds) > MirrorViewerRules.macListSeconds)
    }

    @Test("The published settings are read once, and tried again only a minute after a failed read")
    func readsOnce() {
        #expect(MirrorConfig.shouldRead(loaded: false, wasRead: false, sinceLastTry: 0))
        // Read: kept for the run, however often it is asked for, even when they equal the built-in ones.
        #expect(!MirrorConfig.shouldRead(loaded: true, wasRead: true, sinceLastTry: 3_600))
        // Not readable: not again at once, but again after a minute.
        #expect(!MirrorConfig.shouldRead(loaded: true, wasRead: false, sinceLastTry: 5))
        #expect(MirrorConfig.shouldRead(loaded: true, wasRead: false, sinceLastTry: 61))
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
