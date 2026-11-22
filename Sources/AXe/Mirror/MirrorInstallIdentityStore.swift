#if AXE_MIRROR
import Darwin
import Foundation

/// Makes and keeps the certificate this host's viewers serve builds to iOS with: see
/// `MirrorInstallIdentity`. One for the host, so a viewer sets it up once for each Mac. It is made
/// with the system's own openssl, lasts 820 days (iOS accepts no server certificate longer than
/// 825), and is made again when it has under a month left.
///
/// The authority a person trusts for it can vouch only for the names that point at the device
/// itself (`MirrorCertificateLimits`). One kept from before that was so is made again, and the
/// viewer asks its person to trust the new one.
struct MirrorInstallIdentityStore {
    let folder: URL

    static var standard: MirrorInstallIdentityStore {
        MirrorInstallIdentityStore(folder: MirrorIdentity.keyURL.deletingLastPathComponent().appendingPathComponent("install-identity", isDirectory: true))
    }

    static let days = 820
    static let password = "axe-mirror"

    private var file: URL { folder.appendingPathComponent("identity.json") }

    /// The certificate, made now if there is none worth keeping. One caller at a time, in this
    /// process and any other: two viewers that ask together, the first time, must be given the
    /// same one, or one of them sets its device up for an authority this Mac has already replaced.
    func load(macName: String = Host.current().localizedName ?? "this Mac", now: Date = Date()) throws -> MirrorInstallIdentity {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // The folder itself is what is locked, so nothing is kept in it but the certificate.
        let lock = open(folder.path, O_RDONLY | O_CLOEXEC)
        guard lock >= 0, flock(lock, LOCK_EX) == 0 else {
            if lock >= 0 { close(lock) }
            throw CLIError(errorDescription: "The certificate for installs could not be read: \(folder.path) cannot be locked.", code: .commandFailed)
        }
        defer { flock(lock, LOCK_UN); close(lock) }
        if let data = try? Data(contentsOf: file), let kept = try? JSONDecoder().decode(MirrorInstallIdentity.self, from: data),
           kept.expires - now.timeIntervalSince1970 > 30 * 86_400, kept.names == MirrorInstallIdentity.loopbackNames,
           MirrorCertificateLimits.isLimited(kept.authority, to: MirrorInstallIdentity.loopbackNames) {
            return kept
        }
        let made = try Self.make(macName: macName, now: now)
        try JSONEncoder().encode(made).write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return made
    }

    /// One authority and one certificate signed by it. The authority's key exists only inside the
    /// scratch folder this makes and removes.
    static func make(macName: String, now: Date = Date()) throws -> MirrorInstallIdentity {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("axe-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        func path(_ name: String) -> String { scratch.appendingPathComponent(name).path }
        let names = MirrorInstallIdentity.loopbackNames
        // A name a person will recognise under Certificate Trust Settings; no characters openssl's file reads specially.
        let owner = macName.filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" }.prefix(40)
        try authorityConfiguration(owner: String(owner), names: names).write(toFile: path("authority.cnf"), atomically: true, encoding: .utf8)
        try """
        subjectAltName = \(names.map { "DNS:" + $0 }.joined(separator: ","))
        extendedKeyUsage = serverAuth
        keyUsage = critical,digitalSignature,keyEncipherment
        basicConstraints = CA:FALSE
        """.write(toFile: path("leaf.ext"), atomically: true, encoding: .utf8)
        let days = String(days)
        try openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", path("authority.key"), "-out", path("authority.pem"),
                     "-days", days, "-sha256", "-config", path("authority.cnf")])
        try openssl(["req", "-newkey", "rsa:2048", "-nodes", "-keyout", path("leaf.key"), "-out", path("leaf.csr"), "-subj", "/CN=\(names[0])"])
        try openssl(["x509", "-req", "-in", path("leaf.csr"), "-CA", path("authority.pem"), "-CAkey", path("authority.key"), "-CAcreateserial",
                     "-out", path("leaf.pem"), "-days", days, "-sha256", "-extfile", path("leaf.ext")])
        try openssl(["pkcs12", "-export", "-inkey", path("leaf.key"), "-in", path("leaf.pem"), "-out", path("identity.p12"),
                     "-passout", "pass:" + password, "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1"])
        try openssl(["x509", "-in", path("authority.pem"), "-outform", "der", "-out", path("authority.cer")])
        return MirrorInstallIdentity(authority: try Data(contentsOf: URL(fileURLWithPath: path("authority.cer"))),
                                     identity: try Data(contentsOf: URL(fileURLWithPath: path("identity.p12"))),
                                     password: password, names: names, expires: now.timeIntervalSince1970 + Double(self.days) * 86_400,
                                     authorityName: "AXe Mirror installs from \(owner)")
    }

    /// What openssl makes the authority from. It may sign for `names` and the names under them and
    /// for nothing else: no other name, no IP address, no further authority (`pathlen:0`), and
    /// only certificates for servers. A person switches on full trust for this authority, so
    /// without the limits whoever held its key could pass for any site to that device.
    static func authorityConfiguration(owner: String, names: [String]) -> String {
        """
        [req]
        distinguished_name = dn
        x509_extensions = v3
        prompt = no
        [dn]
        CN = AXe Mirror installs from \(owner)
        [v3]
        basicConstraints = critical,CA:TRUE,pathlen:0
        keyUsage = critical,keyCertSign
        subjectKeyIdentifier = hash
        nameConstraints = critical,\(names.map { "permitted;DNS:" + $0 }.joined(separator: ",")),excluded;IP:0.0.0.0/0.0.0.0,excluded;IP:0:0:0:0:0:0:0:0/0:0:0:0:0:0:0:0
        extendedKeyUsage = serverAuth
        """
    }

    private static func openssl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            throw CLIError(errorDescription: "The certificate for installs could not be made: /usr/bin/openssl did not run.", code: .commandFailed)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CLIError(errorDescription: "The certificate for installs could not be made: openssl \(arguments.first ?? "") failed.", code: .commandFailed)
        }
    }
}
#endif
