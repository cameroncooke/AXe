import Foundation
// Shared with the AXe Mirror app: this file is compiled into the Mac's `axe` and into the viewer.

/// What an authority's certificate may vouch for, read from the certificate itself.
///
/// To install a build, a person trusts an authority the Mac made (see `MirrorInstallIdentity`). An
/// authority trusted like that can vouch for any site unless its own certificate says otherwise,
/// and the device cannot see whether the Mac threw the authority's key away. So the authority is
/// made with name constraints, the part of a certificate that says which names it may sign for:
/// the names that point at the device itself, and no address. iOS refuses anything else signed by
/// it. The viewer reads the constraints here before it offers the certificate to be trusted, and
/// offers none that is not limited to those names, so the limit does not rest on the Mac's word.
enum MirrorCertificateLimits {
    struct Limits: Equatable, Sendable {
        /// The DNS names the authority may sign for. A name covers the names under it.
        var names: [String]
        /// Whether it may sign for no IP address at all.
        var refusesAddresses: Bool
    }

    /// The limits in an authority's certificate (DER). Nil when it has none, when they are not
    /// marked critical, when they allow anything that is not a DNS name, or when the certificate
    /// cannot be read.
    static func limits(ofAuthority certificate: Data) -> Limits? {
        // Certificate ::= SEQUENCE { tbsCertificate SEQUENCE { ..., extensions [3] }, ... }
        guard let whole = children(of: [UInt8](certificate)), whole.count == 1, whole[0].tag == 0x30,
              let parts = children(of: whole[0].body), let signed = parts.first, signed.tag == 0x30,
              let fields = children(of: signed.body), let wrapper = fields.first(where: { $0.tag == 0xA3 }),
              let list = children(of: wrapper.body), list.count == 1, list[0].tag == 0x30,
              let extensions = children(of: list[0].body) else { return nil }
        for one in extensions {
            // Extension ::= SEQUENCE { id OID, critical BOOLEAN DEFAULT FALSE, value OCTET STRING }
            guard one.tag == 0x30, let inside = children(of: one.body), let id = inside.first, id.tag == 0x06 else { return nil }
            guard id.body == [0x55, 0x1D, 0x1E] else { continue }       // 2.5.29.30, nameConstraints
            guard inside.count == 3, inside[1].tag == 0x01, inside[1].body == [0xFF], inside[2].tag == 0x04,
                  let value = children(of: inside[2].body), value.count == 1, value[0].tag == 0x30,
                  let trees = children(of: value[0].body) else { return nil }
            // NameConstraints ::= SEQUENCE { permitted [0] GeneralSubtrees, excluded [1] GeneralSubtrees }
            guard let permitted = trees.first(where: { $0.tag == 0xA0 }), let allowed = names(in: permitted.body), !allowed.isEmpty else { return nil }
            var names: [String] = []
            for name in allowed {
                // Only DNS names ([2]) may be allowed: anything else would be a way round the limit.
                guard name.tag == 0x82, let text = String(bytes: name.body, encoding: .ascii), !text.isEmpty else { return nil }
                names.append(text.lowercased())
            }
            let excluded = trees.first(where: { $0.tag == 0xA1 }).flatMap { self.names(in: $0.body) } ?? []
            // An address and its mask, all zero: every IPv4 address, and every IPv6 one.
            let refuses = [8, 32].allSatisfy { size in excluded.contains { $0.tag == 0x87 && $0.body == [UInt8](repeating: 0, count: size) } }
            return Limits(names: names, refusesAddresses: refuses)
        }
        return nil
    }

    /// Whether the authority can vouch for these names and for nothing else that iOS connects to:
    /// no other name, and no address.
    static func isLimited(_ certificate: Data, to names: [String]) -> Bool {
        guard let limits = limits(ofAuthority: certificate) else { return false }
        return limits.refusesAddresses && Set(limits.names).isSubset(of: Set(names.map { $0.lowercased() }))
    }

    // MARK: Reading DER

    private struct Piece {
        var tag: UInt8
        var body: [UInt8]
    }

    /// The base name of each GeneralSubtree in a list of them.
    private static func names(in trees: [UInt8]) -> [Piece]? {
        guard let list = children(of: trees) else { return nil }
        var found: [Piece] = []
        for tree in list {
            guard tree.tag == 0x30, let inside = children(of: tree.body), let base = inside.first else { return nil }
            found.append(base)
        }
        return found
    }

    /// The pieces laid end to end in `bytes`, each a tag, a length and a body. Nil when they do
    /// not fill it exactly.
    private static func children(of bytes: [UInt8]) -> [Piece]? {
        var pieces: [Piece] = []
        var at = 0
        while at < bytes.count {
            guard at + 2 <= bytes.count else { return nil }
            let tag = bytes[at]
            var length = Int(bytes[at + 1])
            at += 2
            if length & 0x80 != 0 {
                let count = length & 0x7F
                guard (1...4).contains(count), at + count <= bytes.count else { return nil }
                length = 0
                for _ in 0..<count { length = length << 8 | Int(bytes[at]); at += 1 }
            }
            guard length >= 0, at + length <= bytes.count else { return nil }
            pieces.append(Piece(tag: tag, body: Array(bytes[at..<(at + length)])))
            at += length
        }
        return pieces
    }
}
