import Darwin
import Foundation
import Testing
@testable import AXe

@Suite("Mirror local network check")
struct MirrorLocalNetworkTests {
    private func address(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> UInt32 { a << 24 | b << 16 | c << 8 | d }

    @Test("The address tried is a neighbour on the same network: not this Mac, not the router's usual place")
    func picksNeighbour() {
        let mask24 = address(255, 255, 255, 0)
        #expect(MirrorLocalNetwork.neighbour(of: .init(address: address(192, 168, 4, 101), mask: mask24)) == address(192, 168, 4, 102))
        // Next to the router: the router's address is skipped.
        #expect(MirrorLocalNetwork.neighbour(of: .init(address: address(192, 168, 4, 2), mask: mask24)) == address(192, 168, 4, 3))
        #expect(MirrorLocalNetwork.neighbour(of: .init(address: address(10, 0, 0, 253), mask: mask24)) == address(10, 0, 0, 252))
        // At the top of the network: the last address is the broadcast address and is not used.
        #expect(MirrorLocalNetwork.neighbour(of: .init(address: address(10, 0, 0, 254), mask: mask24)) == address(10, 0, 0, 253))
    }

    @Test("A wider network still yields a neighbour inside it")
    func widerNetwork() {
        let interface = MirrorLocalNetwork.Interface(address: address(192, 168, 4, 101), mask: address(255, 255, 252, 0))
        let neighbour = MirrorLocalNetwork.neighbour(of: interface)
        #expect(neighbour == address(192, 168, 4, 102))
        #expect(neighbour.map { $0 & interface.mask } == interface.address & interface.mask)
    }

    @Test("A network of a few addresses has no neighbour worth trying")
    func tinyNetwork() {
        #expect(MirrorLocalNetwork.neighbour(of: .init(address: address(10, 0, 0, 1), mask: address(255, 255, 255, 252))) == nil)
        #expect(MirrorLocalNetwork.neighbour(of: .init(address: address(10, 0, 0, 1), mask: address(255, 255, 255, 255))) == nil)
    }

    @Test("Only 'No route to host' means blocked; a packet that leaves means allowed; other errors decide nothing")
    func readsTheAnswer() {
        #expect(MirrorLocalNetwork.access(sent: 1, error: 0) == .allowed)
        #expect(MirrorLocalNetwork.access(sent: -1, error: EHOSTUNREACH) == .blocked)
        #expect(MirrorLocalNetwork.access(sent: -1, error: ENETDOWN) == .unknown)
        #expect(MirrorLocalNetwork.access(sent: -1, error: ENOBUFS) == .unknown)
    }

    @Test("An address is local when it is on one of this Mac's networks, whatever kind of address it is")
    func localAddresses() {
        // The shape of the network the fault was found on: a /22 and a global IPv6 prefix.
        let networks = [
            MirrorLocalNetwork.Network(address: [192, 168, 4, 101], prefix: 22),
            MirrorLocalNetwork.Network(address: [0x20, 0x01, 0x0D, 0xB8, 0x00, 0x56, 0, 0, 0x41, 0, 0, 0, 0, 0, 0, 1], prefix: 64),
        ]
        let phoneOnLan = MirrorLocalNetwork.isLocal("192.168.4.45:55612", networks: networks)
        let widerLan = MirrorLocalNetwork.isLocal("192.168.7.200:1", networks: networks)
        let nextNetwork = MirrorLocalNetwork.isLocal("192.168.8.1:1", networks: networks)
        let phoneGlobal = MirrorLocalNetwork.isLocal("[2001:db8:56:0:1c2d:3e4f:5a6b:7c8d]:59808", networks: networks)
        let otherPrefix = MirrorLocalNetwork.isLocal("[2001:db8:57:0:1c2d:3e4f:5a6b:7c8d]:59808", networks: networks)
        let internet = MirrorLocalNetwork.isLocal("203.0.113.9:4433", networks: networks)
        let linkLocal = MirrorLocalNetwork.isLocal("[fe80::1c2d:3e4f%en0]:1", networks: [])
        let mapped = MirrorLocalNetwork.isLocal("[::ffff:192.168.4.45]:55612", networks: networks)
        let relay = MirrorLocalNetwork.isLocal("https://eu1.relay.example./", networks: networks)
        let loopback = MirrorLocalNetwork.isLocal("127.0.0.1:9", networks: networks)
        #expect(phoneOnLan)
        #expect(widerLan)
        #expect(!nextNetwork)
        #expect(phoneGlobal)
        #expect(!otherPrefix)
        #expect(!internet)
        #expect(linkLocal)
        #expect(mapped)
        #expect(!relay)
        #expect(!loopback)
    }

    @Test("This Mac's networks are read without loopback, and each has a sensible prefix")
    func readsNetworks() {
        let networks = MirrorLocalNetwork.networks()
        let sound = networks.allSatisfy { ($0.address.count == 4 || $0.address.count == 16) && $0.prefix >= 0 && $0.prefix <= $0.address.count * 8 }
        let loopback = networks.contains { $0.address.first == 127 }
        #expect(sound)
        #expect(!loopback)
    }

    @Test("The check runs and never crashes, whatever this machine's network is")
    func runs() {
        let result = MirrorLocalNetwork.check()
        #expect([.allowed, .blocked, .unknown].contains(result))
        #expect(MirrorLocalNetwork.advice.contains("Local Network"))
    }
}
