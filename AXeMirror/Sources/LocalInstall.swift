import CryptoKit
import Foundation
import Network
import Security

/// Serves builds to iOS's installer from this device itself.
///
/// The Mac sends a build over the paired connection, and iOS will only install what it downloads
/// itself over HTTPS. So this app keeps the file and is the HTTPS server iOS downloads it from, at
/// a name that resolves to this device (see `MirrorInstallIdentity`). The certificate comes from
/// the Mac; the person installs its authority once and switches it on under Certificate Trust
/// Settings, as for any tool that makes its own.
///
///     HTTPS  /healthz                     this app's own check that the certificate is trusted
///            /b/<build>/manifest.plist    what iOS asks for first
///            /b/<build>/app.ipa           the build, whole or a byte range of it
///     HTTP   /authority.cer               the authority's certificate, for Safari to install
final class LocalInstallServer: @unchecked Sendable {
    struct Served {
        var file: URL
        var bundleID: String
        var buildNumber: String
        var title: String
        var host: String
    }

    private let queue = DispatchQueue(label: "axemirror.install")
    private let authority: Data
    private var secure: NWListener?
    private var plain: NWListener?
    private var builds: [String: Served] = [:]
    /// Called on the main queue when iOS's installer has fetched something: "manifest", "package".
    var onFetched: ((_ build: String, _ what: String) -> Void)?

    private(set) var securePort: UInt16 = 0
    private(set) var plainPort: UInt16 = 0

    /// Starts both listeners on ports the system picks. Nil when the certificate cannot be used.
    init?(identity: MirrorInstallIdentity) {
        authority = identity.authority
        var items: CFArray?
        guard SecPKCS12Import(identity.identity as CFData, [kSecImportExportPassphrase as String: identity.password] as CFDictionary, &items) == errSecSuccess,
              let first = (items as? [[String: Any]])?.first, let found = first[kSecImportItemIdentity as String],
              let local = sec_identity_create(found as! SecIdentity) else { return nil }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, local)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        guard let secure = try? NWListener(using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options())),
              let plain = try? NWListener(using: .tcp) else { return nil }
        self.secure = secure
        self.plain = plain
        let ready = DispatchGroup()
        for (listener, isSecure) in [(secure, true), (plain, false)] {
            ready.enter()
            var entered = true
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready, .failed, .cancelled:
                    if entered { entered = false; ready.leave() }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                connection.start(queue: self.queue)
                self.read(connection, so: Data(), secure: isSecure)
            }
            listener.start(queue: queue)
        }
        guard ready.wait(timeout: .now() + 3) == .success, let securePort = secure.port?.rawValue, let plainPort = plain.port?.rawValue else {
            secure.cancel(); plain.cancel()
            return nil
        }
        self.securePort = securePort
        self.plainPort = plainPort
    }

    func stop() {
        secure?.cancel()
        plain?.cancel()
    }

    /// Whether the server still takes connections. iOS closes an app's listeners when it suspends
    /// the app, as it may while the person is in Settings, and they do not come back by themselves.
    func isAlive() async -> Bool {
        guard let port = NWEndpoint.Port(rawValue: securePort) else { return false }
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        return await withCheckedContinuation { continuation in
            let answered = Answered()
            let finish: @Sendable (Bool) -> Void = { alive in
                guard answered.first() else { return }
                connection.cancel()
                continuation.resume(returning: alive)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .waiting, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 1.5) { finish(false) }
        }
    }

    /// True once, for the first of several callers.
    private final class Answered: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func first() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
    }

    /// Offers a downloaded build to iOS. Returns the address of its manifest.
    func serve(_ id: String, _ build: Served) -> String {
        queue.sync { builds[id] = build }
        return "https://\(build.host):\(securePort)/b/\(id)/manifest.plist"
    }

    private func read(_ connection: NWConnection, so far: Data, secure: Bool) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, finished, error in
            guard let self, error == nil else { connection.cancel(); return }
            var received = far
            if let data { received.append(data) }
            if let end = received.range(of: Data("\r\n\r\n".utf8)) {
                self.answer(connection, head: String(decoding: received[..<end.lowerBound], as: UTF8.self), secure: secure)
            } else if finished || received.count > 16 * 1024 {
                connection.cancel()
            } else {
                self.read(connection, so: received, secure: secure)
            }
        }
    }

    private func answer(_ connection: NWConnection, head: String, secure: Bool) {
        let lines = head.components(separatedBy: "\r\n")
        let request = (lines.first ?? "").split(separator: " ")
        guard request.count == 3, request[0] == "GET" || request[0] == "HEAD" else { connection.cancel(); return }
        let bodiless = request[0] == "HEAD"
        let path = String(request[1])
        var range: String?
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "range" { range = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        guard secure else {
            // Safari fetches the authority's certificate over plain HTTP: until it is installed, nothing else is trusted.
            if path == "/authority.cer" {
                send(connection, status: "200 OK", type: "application/x-x509-ca-cert", body: authority, bodiless: bodiless)
            } else {
                send(connection, status: "404 Not Found", type: "text/plain", body: Data(), bodiless: bodiless)
            }
            return
        }
        if path == "/healthz" {
            send(connection, status: "200 OK", type: "text/plain", body: Data("ok".utf8), bodiless: bodiless)
            return
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[0].isEmpty, parts[1] == "b", let build = builds[parts[2]] else {
            send(connection, status: "404 Not Found", type: "text/plain", body: Data(), bodiless: bodiless)
            return
        }
        switch parts[3] {
        case "manifest.plist":
            let manifest: [String: Any] = ["items": [[
                "assets": [["kind": "software-package", "url": "https://\(build.host):\(securePort)/b/\(parts[2])/app.ipa"]],
                "metadata": ["bundle-identifier": build.bundleID, "bundle-version": build.buildNumber, "kind": "software", "title": build.title],
            ]]]
            let body = (try? PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)) ?? Data()
            send(connection, status: "200 OK", type: "application/xml", body: body, bodiless: bodiless)
            if !bodiless { fetched(parts[2], "manifest") }
        case "app.ipa":
            sendPackage(connection, id: parts[2], file: build.file, range: bodiless ? nil : range, bodiless: bodiless)
        default:
            send(connection, status: "404 Not Found", type: "text/plain", body: Data(), bodiless: bodiless)
        }
    }

    private func fetched(_ id: String, _ what: String) {
        DispatchQueue.main.async { [weak self] in self?.onFetched?(id, what) }
    }

    private func sendPackage(_ connection: NWConnection, id: String, file: URL, range header: String?, bodiless: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: file), let size = try? handle.seekToEnd(), size > 0 else {
            send(connection, status: "404 Not Found", type: "text/plain", body: Data(), bodiless: bodiless)
            return
        }
        var first = 0, last = Int(size) - 1
        var status = "200 OK"
        var extra = ["Accept-Ranges: bytes"]
        if let header, header.hasPrefix("bytes="), !header.contains(",") {
            let ends = header.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            if ends.count == 2, let from = Int(ends[0]), from < Int(size) {
                first = from
                last = ends[1].isEmpty ? last : max(first, min(Int(ends[1]) ?? last, last))
                status = "206 Partial Content"
                extra.append("Content-Range: bytes \(first)-\(last)/\(size)")
            }
        }
        let total = last - first + 1
        connection.send(content: Self.head(status: status, type: "application/octet-stream", length: total, extra: extra), completion: .contentProcessed { [weak self] error in
            guard error == nil, !bodiless, let self else { try? handle.close(); connection.cancel(); return }
            try? handle.seek(toOffset: UInt64(first))
            self.pump(connection, id: id, from: handle, left: total, whole: first == 0 && last == Int(size) - 1)
        })
    }

    private func pump(_ connection: NWConnection, id: String, from handle: FileHandle, left: Int, whole: Bool) {
        guard left > 0, let piece = try? handle.read(upToCount: min(left, 256 * 1024)), !piece.isEmpty else {
            try? handle.close()
            if whole { fetched(id, "package") }
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        connection.send(content: piece, completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else { try? handle.close(); connection.cancel(); return }
            self.pump(connection, id: id, from: handle, left: left - piece.count, whole: whole)
        })
    }

    private static func head(status: String, type: String, length: Int, extra: [String] = []) -> Data {
        let lines = ["HTTP/1.1 \(status)", "Content-Type: \(type)", "Content-Length: \(length)", "Cache-Control: no-store", "Connection: close"] + extra
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    private func send(_ connection: NWConnection, status: String, type: String, body: Data, bodiless: Bool) {
        var message = Self.head(status: status, type: type, length: body.count)
        if !bodiless { message.append(body) }
        connection.send(content: message, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// The SHA-256 of a file, in hex, read a megabyte at a time.
    static func digest(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
