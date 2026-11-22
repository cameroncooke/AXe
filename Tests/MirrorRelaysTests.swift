import Foundation
import Testing
@testable import AXe

@Suite("Mirror relay list")
struct MirrorRelaysTests {
    private let eu1 = "https://eu1.relay.axe-cli.com"
    private let eu2 = "https://eu2.relay.axe-cli.com"
    private let us1 = "https://us1.relay.axe-cli.com"

    @Test("A record lists our relays in order and says whether the public ones are allowed")
    func parsesRecord() {
        #expect(MirrorRelays.parse("v=1 \(eu1) \(us1) public") == .init(own: [eu1, us1], allowsPublic: true))
        #expect(MirrorRelays.parse("v=1 \(eu1)") == .init(own: [eu1], allowsPublic: false))
        #expect(MirrorRelays.parse("v=1 public") == .init(own: [], allowsPublic: true))
    }

    @Test("Extra spaces, repeated relays and unknown words are tolerated")
    func parsesLooseRecord() {
        #expect(MirrorRelays.parse("v=1   \(eu1)\t\(eu1) weight=3 http://plain.example.com https:// public")
            == .init(own: [eu1], allowsPublic: true))
    }

    @Test("Other records at the same name are not relay lists", arguments: [
        "", "v=2 https://eu1.relay.axe-cli.com", "v=spf1 include:example.com ~all", "https://eu1.relay.axe-cli.com", "v=1", "v=1 weight=3",
    ])
    func rejectsRecord(_ record: String) {
        #expect(MirrorRelays.parse(record) == nil)
    }

    @Test("The built-in list names a relay and allows the public ones")
    func builtInList() {
        #expect(MirrorRelays.builtIn.own == [eu1])
        #expect(MirrorRelays.builtIn.allowsPublic)
    }

    @Test("The nearest relay comes first and the further ones follow, nearest first")
    func ordersByLatency() {
        #expect(MirrorRelays.order([us1, eu1, eu2], latency: [us1: 0.120, eu1: 0.030, eu2: 0.060]) == [eu1, eu2, us1])
    }

    @Test("Of relays that are equally near, only one is offered, and a host always takes the same one")
    func oneOfTheNearRelays() {
        let latency = [eu1: 0.030, eu2: 0.040, us1: 0.120]
        let first = MirrorRelays.order([eu1, eu2, us1], latency: latency, seed: "host a")
        #expect(first.count == 2 && [eu1, eu2].contains(first[0]) && first[1] == us1)
        for _ in 0..<20 { #expect(MirrorRelays.order([eu2, us1, eu1], latency: latency, seed: "host a") == first) }
    }

    @Test("Equally near relays share the hosts about evenly")
    func sharesHosts() {
        let latency = [eu1: 0.030, eu2: 0.034]
        let onFirst = (0..<1000).filter { MirrorRelays.order([eu1, eu2], latency: latency, seed: "host \($0)") == [eu1] }.count
        #expect((400...600).contains(onFirst))
    }

    @Test("A relay added to a region takes its share and moves no other host")
    func addedRelay() {
        let eu3 = "https://eu3.relay.axe-cli.com"
        let before = [eu1: 0.030, eu2: 0.034], after = [eu1: 0.030, eu2: 0.034, eu3: 0.032]
        var moved = 0
        for host in 0..<900 {
            let was = MirrorRelays.order([eu1, eu2], latency: before, seed: "host \(host)")[0]
            let now = MirrorRelays.order([eu1, eu2, eu3], latency: after, seed: "host \(host)")[0]
            if now != was { #expect(now == eu3); moved += 1 }
        }
        #expect((220...380).contains(moved))
    }

    @Test("A relay that did not answer is left out")
    func leavesOutSilentRelays() {
        #expect(MirrorRelays.order([eu1, eu2, us1], latency: [us1: 0.120]) == [us1])
        #expect(MirrorRelays.order([eu1, eu2], latency: [:]) == [])
        #expect(MirrorRelays.order([], latency: [:]) == [])
    }

    @Test("The seed differs between keys, is the same for one key and does not contain the key")
    func seedFromKey() {
        let key = Data(repeating: 7, count: 32), other = Data(repeating: 8, count: 32)
        #expect(MirrorRelays.seed(for: key) == MirrorRelays.seed(for: key))
        #expect(MirrorRelays.seed(for: key) != MirrorRelays.seed(for: other))
        #expect(MirrorRelays.seed(for: key).count == 64)
        #expect(!MirrorRelays.seed(for: key).contains("0707"))
    }

    @Test("A host chooses again when its relay has not answered twice in a row, not after once")
    func checksWhenRelayIsLost() {
        #expect(!MirrorRelays.checkDue(onOwn: true, missed: 1, sinceCheck: 600))
        #expect(MirrorRelays.checkDue(onOwn: true, missed: 2, sinceCheck: 30))
        #expect(MirrorRelays.checkDue(onOwn: true, missed: 5, sinceCheck: 30))
    }

    @Test("A host on the public relays looks for ours every two minutes, a healthy host every half hour")
    func checksOnASchedule() {
        #expect(!MirrorRelays.checkDue(onOwn: false, missed: 0, sinceCheck: 119))
        #expect(MirrorRelays.checkDue(onOwn: false, missed: 0, sinceCheck: 120))
        #expect(!MirrorRelays.checkDue(onOwn: true, missed: 0, sinceCheck: 1799))
        #expect(MirrorRelays.checkDue(onOwn: true, missed: 0, sinceCheck: 1800))
    }

    @Test("A list given in place of the published one is used; with nothing answering it falls to the public relays only if allowed")
    func givenList() async {
        let dead = "https://relay.invalid"
        let allowed = await MirrorRelays.choose(explicit: nil, record: "v=1 \(dead) public")
        #expect(allowed.relays == [] && allowed.source == "--relay-list, none of ours answered, public relays")
        // A viewer looking for a Mac to pair with still tries ours, then the public ones.
        #expect(allowed.pairingRelays(public: ["https://public.example"]) == [dead, "https://public.example"])
        let refused = await MirrorRelays.choose(explicit: nil, record: "v=1 \(dead)")
        #expect(refused.relays == [dead] && refused.source == "--relay-list, none answered")
        #expect(refused.pairingRelays(public: ["https://public.example"]) == [dead])
    }

    @Test("The printed event names the relays, or says public")
    func event() {
        #expect(MirrorRelays.Choice(relays: [eu1, us1], source: "published list").event
            == ["event": "relays", "source": "published list", "relays": "\(eu1) \(us1)"])
        #expect(MirrorRelays.Choice(relays: [], source: "x").event["relays"] == "public")
    }

    @Test("A relay named on the command line is used alone, without a lookup")
    func explicitRelay() async {
        let choice = await MirrorRelays.choose(explicit: "https://relay.example.com")
        #expect(choice.relays == ["https://relay.example.com"] && choice.source == "--relay-url" && choice.isNamed)
        #expect(choice.pairingRelays(public: ["https://public.example"]) == ["https://relay.example.com"])
    }

    @Test("A viewer looks for a Mac showing a code on every relay it could be on, not only its own pick")
    func pairingLooksEverywhere() {
        // Two equally near relays: this side's seed kept eu1, and the Mac's may have kept eu2.
        let choice = MirrorRelays.Choice(relays: [eu1, us1], source: "published list", everyRelay: [eu1, "https://eu2.relay.axe-cli.com", us1], allowsPublic: true)
        #expect(choice.pairingRelays(public: ["https://public.example"]) == [eu1, "https://eu2.relay.axe-cli.com", us1, "https://public.example"])
        // A relay the scanned code named is tried first, and listed once.
        #expect(choice.pairingRelays(first: us1, public: []) == [us1, eu1, "https://eu2.relay.axe-cli.com"])
    }

    @Test("The first dial to get through is used at once, and one that gets through later is closed")
    func firstOfSeveral() async {
        final class Late: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [Int] = []
            func add(_ value: Int) { lock.withLock { values.append(value) } }
            var all: [Int] { lock.withLock { values } }
        }
        let late = Late()
        let start = ProcessInfo.processInfo.systemUptime
        let first = await MirrorTimeout.first(of: [
            { try? await Task.sleep(nanoseconds: 2_000_000_000); return nil },      // a relay the Mac is not on: times out
            { try? await Task.sleep(nanoseconds: 100_000_000); return 2 },          // the Mac's relay
            { try? await Task.sleep(nanoseconds: 400_000_000); return 3 },
        ] as [@Sendable () async -> Int?]) { late.add($0) }
        #expect(first == 2 && ProcessInfo.processInfo.systemUptime - start < 1)
        try? await Task.sleep(nanoseconds: 600_000_000)
        #expect(late.all == [3])
        // Nobody anywhere: the answer is nil, once every dial has given up.
        #expect(await MirrorTimeout.first(of: [{ nil }, { nil }] as [@Sendable () async -> Int?]) == nil)
    }
}
