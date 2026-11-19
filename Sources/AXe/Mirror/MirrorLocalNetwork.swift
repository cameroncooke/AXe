import Darwin
import Foundation

/// Finds out whether macOS lets this process talk to devices on the local network, and which
/// addresses are on it.
///
/// macOS asks the user to allow each app, and a command inherits the answer of the terminal it runs
/// in. A process without the permission (a terminal that was never allowed, a launch agent) can
/// still reach the router and the internet, so `axe mirror` comes online and looks healthy, but
/// every packet to a device on the same network is refused with "No route to host". A viewer on
/// the same network then cannot hold a direct path: it flaps between half-open paths and the
/// relay, and the stream is slow and laggy. Measured on 19 November 2026 with a demo host run by a
/// launch agent. Apple's technote TN3179 lists what is exempt: daemons, programs run as root, and
/// commands run from Terminal or over SSH. Launch agents and other terminal apps are not.
///
/// Only the local network is closed to such a process: a viewer somewhere else can still be
/// reached directly. So the host keeps direct paths, and `MirrorLink` moves to the relay alone
/// only while a viewer on one of this Mac's own networks is connected (see `isLocal`).
enum MirrorLocalNetwork {
    enum Access: Equatable { case allowed, blocked, unknown }

    /// One of this Mac's IPv4 addresses with its network mask, both in host byte order.
    struct Interface: Equatable {
        var address: UInt32
        var mask: UInt32
    }

    /// An address on the same network to try: a neighbour of our own that is not us, not the
    /// network's first or last address, and not where a router usually sits (.1 and .254), because
    /// the router is reachable even when the rest of the network is not. Nil when the network is
    /// too small to have one.
    static func neighbour(of interface: Interface) -> UInt32? {
        let network = interface.address & interface.mask
        let last = network | ~interface.mask
        guard last - network >= 7 else { return nil }
        for offset in [1, 2, 3, 4, 5, 6] as [UInt32] {
            for candidate in [interface.address &+ offset, interface.address &- offset] {
                let host = candidate & 0xFF
                if candidate > network, candidate < last, candidate != interface.address, host != 1, host != 254 { return candidate }
            }
        }
        return nil
    }

    /// What one attempt to send says: refused with "No route to host" is the mark of the missing
    /// permission; a packet that leaves is allowed; anything else decides nothing.
    static func access(sent: Int, error: Int32) -> Access {
        if sent >= 0 { return .allowed }
        return error == EHOSTUNREACH ? .blocked : .unknown
    }

    /// This Mac's active IPv4 interfaces, leaving out loopback and point-to-point links such as VPNs.
    static func interfaces() -> [Interface] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result: [Interface] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, flags & IFF_POINTOPOINT == 0,
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  let mask = entry.pointee.ifa_netmask else { continue }
            let host = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let bits = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            // Link-local addresses (169.254.x.x) say nothing about the real network.
            guard host >> 16 != 0xA9FE else { continue }
            result.append(Interface(address: host, mask: bits))
        }
        return result
    }

    /// One of this Mac's networks: an address on it (4 bytes for IPv4, 16 for IPv6) and how many of
    /// its leading bits name the network.
    struct Network: Equatable {
        var address: [UInt8]
        var prefix: Int
    }

    /// This Mac's IPv4 and IPv6 networks, leaving out loopback and point-to-point links such as VPNs.
    static func networks() -> [Network] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        func bytes(_ address: UnsafeMutablePointer<sockaddr>) -> [UInt8]? {
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) } }
            case AF_INET6:
                return address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) } }
            default:
                return nil
            }
        }
        var result: [Network] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, flags & IFF_POINTOPOINT == 0,
                  let address = entry.pointee.ifa_addr, let mask = entry.pointee.ifa_netmask,
                  let host = bytes(address), let bits = bytes(mask), host.count == bits.count else { continue }
            let network = Network(address: host, prefix: bits.reduce(0) { $0 + $1.nonzeroBitCount })
            if !result.contains(network) { result.append(network) }
        }
        return result
    }

    /// The address in the name iroh gives a direct path, "192.168.4.45:55612" or
    /// "[2001:db8::1496]:59808", as bytes. Nil for a relay's address and for anything else.
    static func addressBytes(ofPath remote: String) -> [UInt8]? {
        var host: String
        var family = AF_INET
        if remote.hasPrefix("[") {
            host = String(remote.dropFirst().prefix { $0 != "]" })
            if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
            family = AF_INET6
        } else {
            guard let colon = remote.lastIndex(of: ":") else { return nil }
            host = String(remote[..<colon])
        }
        var bytes = [UInt8](repeating: 0, count: family == AF_INET ? 4 : 16)
        guard inet_pton(family, host, &bytes) == 1 else { return nil }
        // An IPv4 address written as IPv6 (::ffff:a.b.c.d) is the IPv4 address.
        if bytes.count == 16, bytes[..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF { return Array(bytes[12...]) }
        return bytes
    }

    /// Whether a direct path's remote address is on one of these networks, which are this Mac's
    /// own: the addresses macOS closes to a process without the permission. A phone on the same
    /// Wi-Fi usually shows up under a global IPv6 address that shares this Mac's prefix, so the
    /// kind of address says nothing; the networks decide. Link-local addresses are always local.
    static func isLocal(_ remote: String, networks: [Network]) -> Bool {
        guard let bytes = addressBytes(ofPath: remote) else { return false }
        if bytes.count == 4, bytes[0] == 169, bytes[1] == 254 { return true }
        if bytes.count == 16, bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return true }
        return networks.contains { network in
            guard network.address.count == bytes.count, network.prefix > 0, network.prefix <= bytes.count * 8 else { return false }
            let whole = network.prefix / 8, rest = network.prefix % 8
            guard Array(network.address[..<whole]) == Array(bytes[..<whole]) else { return false }
            guard rest > 0 else { return true }
            let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - rest))
            return network.address[whole] & mask == bytes[whole] & mask
        }
    }

    /// Sends one small UDP packet to the discard port of a neighbouring address on each network.
    /// Nothing answers it and nothing needs to: only whether macOS lets it leave is of interest.
    static func check() -> Access {
        var result = Access.unknown
        for interface in interfaces() {
            guard let target = neighbour(of: interface) else { continue }
            let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
            guard descriptor >= 0 else { continue }
            defer { close(descriptor) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(9).bigEndian
            address.sin_addr.s_addr = target.bigEndian
            let byte: [UInt8] = [0]
            let sent = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(descriptor, byte, 1, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            switch access(sent: sent, error: errno) {
            case .blocked: return .blocked
            case .allowed: result = .allowed
            case .unknown: continue
            }
        }
        return result
    }

    static let advice = """
    macOS is not letting this process talk to devices on your local network, so a viewer on the same \
    network cannot connect directly: it will go through the relay, which is slower. Allow the app you run \
    axe from (your terminal) in System Settings > Privacy & Security > Local Network; axe mirror notices \
    when the next viewer on your network connects.
    """
}
