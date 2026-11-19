#if AXE_MIRROR
import Foundation
import IrohLib

/// The n0 set-up with both sockets bound to loopback. The relay connection still works (it is an
/// outgoing HTTPS connection), but no peer can reach this endpoint directly, so iroh stays on the relay.
final class MirrorRelayOnlyPreset: Preset {
    let relayURLs: [String]
    init(relayURLs: [String] = []) { self.relayURLs = relayURLs }
    func apply(builder: EndpointBuilder) {
        builder.applyN0()
        if !relayURLs.isEmpty, let mode = try? RelayMode.customFromUrls(urls: relayURLs) { builder.relayMode(mode: mode) }
        do {
            try builder.bindAddr(addr: "127.0.0.1:0")
            try builder.bindAddr(addr: "[::1]:0")
        } catch {
            mirrorNote("could not bind to loopback: \(error)")
        }
    }
}

/// The n0 set-up with our own relays in place of the public ones. iroh uses the nearest that
/// answers as its home relay and moves to another if it stops answering. Direct paths still open.
final class MirrorOwnRelayPreset: Preset {
    let relayURLs: [String]
    init(relayURLs: [String]) { self.relayURLs = relayURLs }
    func apply(builder: EndpointBuilder) {
        builder.applyN0()
        if let mode = try? RelayMode.customFromUrls(urls: relayURLs) { builder.relayMode(mode: mode) } else { mirrorNote("bad relay address in \(relayURLs)") }
    }
}

final class MirrorHomeRelayWatcher: HomeRelayCallback {
    let changed: ([String]) -> Void
    init(changed: @escaping ([String]) -> Void) { self.changed = changed }
    func onChange(relayUrls: [String]) async throws { changed(relayUrls) }
}

/// Remembers the last list it was shown and says whether a new one differs.
final class MirrorLastValue: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String]?
    var current: [String]? { lock.withLock { value } }
    func changed(to new: [String]) -> Bool {
        lock.withLock {
            defer { value = new }
            return value != new
        }
    }
}

final class MirrorPathLogger: PathEventCallback {
    let log: (String) -> Void
    let selected: (Bool) -> Void    // whether the path now in use is a relay
    let direct: (String) -> Void    // the remote address of a direct path that is now in use
    init(log: @escaping (String) -> Void, selected: @escaping (Bool) -> Void, direct: @escaping (String) -> Void = { _ in }) {
        self.log = log; self.selected = selected; self.direct = direct
    }
    func onEvent(event: PathEvent) async throws {
        // A direct path is logged with its address and what kind of network that address is on, so that a
        // session can be checked afterwards for having run over a VPN (Tailscale uses 100.64/10 and fd7a:115c:a1e0::/48).
        func kind(_ address: String) -> String {
            if address.hasPrefix("http") { return "relay" }
            let host = address.hasPrefix("[") ? String(address.dropFirst().prefix { $0 != "]" }).lowercased() : String(address.prefix { $0 != ":" })
            let parts = host.split(separator: ".").compactMap { Int($0) }
            let network: String
            if parts.count == 4 {
                network = parts[0] == 100 && (64...127).contains(parts[1]) ? "tailscale"
                    : parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 169 && parts[1] == 254) ? "lan"
                    : parts[0] == 127 ? "loopback" : "internet"
            } else {
                // A global IPv6 address is usually the phone's own address on the same network, so it is not called "internet".
                network = host.hasPrefix("fd7a:115c:a1e0") ? "tailscale" : host.hasPrefix("fe80") || host.hasPrefix("fc") || host.hasPrefix("fd") ? "lan" : host == "::1" ? "loopback" : "ipv6"
            }
            return "direct \(network) \(address)"
        }
        switch event {
        case .opened(_, let remote, _): log("path opened \(kind(remote))")
        case .closed(_, let remote, _, _): log("path closed \(kind(remote))")
        case .selected(_, let remote, _):
            log("path selected \(kind(remote))")
            selected(remote.hasPrefix("http"))
            if !remote.hasPrefix("http") { direct(remote) }
        case .lagged: break
        }
    }
}

/// The Mac's side of one iroh connection. The client opens one two-way QUIC stream for control
/// messages (first byte "C"). Video goes on one-way streams this side opens. Each starts with its
/// number, and a newer one replaces the older: the old stream is reset, so whatever was queued or
/// lost on it is never retransmitted, and the new one starts with a keyframe. The client's frame
/// reports and status come back as QUIC datagrams (one type byte, then the payload).
final class MirrorLink {
    /// The stream protocol's name. The second is the test viewer's name for the same protocol, kept
    /// until that viewer is retired.
    static let alpns = [MirrorProtocol.stream, MirrorProtocol.legacyStream]
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var endpoint: Endpoint?
    private var connection: Connection?
    private var control: AsyncStream<Data>.Continuation?
    private var video: AsyncStream<Data>.Continuation?
    private var backlog = 0
    private var videoNumber: UInt32 = 0
    private var videoSend: SendStream?
    private var watch: WatchHandle?
    private var homeWatch: WatchHandle?
    private var relays: [String] = []           // what the endpoint was last given; empty means iroh's public relays
    private var secret = Data()
    private var relayOnlyAsked = false          // asked for at start: the endpoint never leaves the relay
    private var relayOnlyNow = false            // how the endpoint is bound at present
    private var rebinding = false
    private var idleCount = 0                   // goes up each time a viewer leaves
    /// Set when macOS keeps this process off the local network (see `MirrorLocalNetwork`). A viewer
    /// on one of this Mac's own networks then cannot hold a direct path, and trying costs it the
    /// stream: paths open, are chosen for the video and die. iroh offers no way to refuse one
    /// address, so when such a path is chosen, the endpoint is closed and bound again on the relay
    /// alone. A path that opens and is never chosen does no harm and is left alone: the host also
    /// tries a distant viewer's private address, which can look like one of this Mac's own. The viewer reconnects by itself within a few seconds and stays on the
    /// relay. A minute after the last viewer has gone the endpoint allows direct paths again, so a
    /// viewer somewhere else, whom this process can reach, still gets one.
    ///
    /// What was found at the start is not trusted for the life of the host: the user may allow the
    /// permission while it runs, and the first start after the program file is replaced has been
    /// seen to report "blocked" when a later one did not. So the question is asked again each time
    /// a path on this Mac's own network is chosen, and the host stops avoiding them once the answer
    /// is that it is allowed.
    var avoidsLocalNetwork = false
    /// Asks macOS again. Tests replace it.
    var localNetworkCheck: () -> MirrorLocalNetwork.Access = { MirrorLocalNetwork.check() }
    static let directAgainAfter: TimeInterval = 60
    var onPathSelected: ((Bool) -> Void)?       // on `queue`; true when the path now in use is a relay
    var onConnected: (() -> Void)?              // on `queue`
    var onMessage: ((UInt8, Data) -> Void)?     // on `queue`
    var onClosed: (() -> Void)?                 // on `queue`
    var onNote: ((String) -> Void)?
    /// Asked for every incoming connection with the viewer's endpoint ID, which iroh has verified.
    /// Nil lets every viewer in.
    var allows: ((String) -> Bool)?
    var onRefused: ((String) -> Void)?
    /// Asked when a viewer arrives while a different viewer is connected and has been heard from in
    /// the last five seconds, with how long that one has been connected. True turns the newcomer
    /// away; nil or false lets it replace the other. A viewer returning under the same ID always
    /// replaces its own older connection.
    var turnsAwayWhileBusy: ((TimeInterval) -> Bool)?
    private var connectedAt: TimeInterval = 0
    private var connectedViewer = ""
    private var lastHeard: TimeInterval = 0
    /// The longest control message a viewer may send. Nothing the viewer sends is near this.
    static let messageLimit = 64 * 1024

    init(queue: DispatchQueue) { self.queue = queue }

    var hasViewer: Bool { lock.lock(); defer { lock.unlock() }; return connection != nil }

    /// Video messages handed over but not yet accepted by the QUIC stream.
    var videoBacklog: Int { lock.lock(); defer { lock.unlock() }; return backlog }

    /// `relayURLs` are our relays in order of preference; empty means iroh's public relays.
    func start(secret: Data, relayOnly: Bool = false, relayURLs: [String] = []) {
        lock.lock(); self.secret = secret; relayOnlyAsked = relayOnly; relayOnlyNow = relayOnly; relays = relayURLs; lock.unlock()
        Task { await listen(first: true) }
    }

    /// Binds the endpoint and serves viewers until it is closed. `first` is false when the endpoint
    /// is bound again while the host runs; the notes then differ, so that the host reports its ID
    /// and that it is ready once only.
    private func listen(first: Bool) async {
        lock.lock(); let secret = self.secret, relayOnly = relayOnlyNow, relayURLs = relays; lock.unlock()
        do {
            let preset: Preset = relayOnly ? MirrorRelayOnlyPreset(relayURLs: relayURLs) : relayURLs.isEmpty ? presetN0() : MirrorOwnRelayPreset(relayURLs: relayURLs)
            let endpoint = try await Endpoint.bind(options: EndpointOptions(preset: preset, secretKey: secret, alpns: Self.alpns))
            lock.lock(); self.endpoint = endpoint; rebinding = false; lock.unlock()
            if first { onNote?("iroh endpoint \(endpoint.id().description)") }
            await endpoint.online()
            let home = endpoint.addr().relayUrl() ?? "none"
            onNote?(first ? "iroh online, home relay \(home)" : "listening again, \(relayOnly ? "on the relay only" : "direct paths allowed"), home relay \(home)")
            // For the log only. iroh did not report a stopped relay here within two minutes, so the
            // session's relay watch asks the relay itself.
            // The callback also fires when only a relay's connection state changes, so repeats are dropped.
            let last = MirrorLastValue()
            homeWatch = endpoint.watchHomeRelay(callback: MirrorHomeRelayWatcher { [weak self] urls in
                guard last.changed(to: urls) else { return }
                self?.onNote?(urls.isEmpty ? "home relay: none" : "home relay: \(urls.joined(separator: " "))")
            })
            while let incoming = await endpoint.acceptNext() {
                Task {
                    do { try await self.serve(try await incoming.accept().connect()) } catch { self.onNote?("iroh connection failed: \(error)") }
                }
            }
        } catch {
            lock.lock(); rebinding = false; lock.unlock()
            onNote?("iroh failed: \(error)")
        }
    }

    /// Closes the endpoint and binds it again, on the relay alone or with direct paths allowed. A
    /// connected viewer is dropped and reconnects by itself.
    private func rebind(relayOnly: Bool, why: String) {
        lock.lock()
        guard !rebinding, relayOnlyNow != relayOnly, relayOnly || !relayOnlyAsked, let endpoint = self.endpoint else { lock.unlock(); return }
        rebinding = true
        relayOnlyNow = relayOnly
        let connection = self.connection
        self.endpoint = nil
        lock.unlock()
        onNote?(why)
        Task {
            try? connection?.close(errorCode: 0, reason: Data("listening again".utf8))
            try? await endpoint.close()
            await self.listen(first: false)
        }
    }

    /// A direct path to `remote` is now in use. See `avoidsLocalNetwork`.
    private func directPathSelected(_ remote: String) {
        lock.lock(); let avoiding = avoidsLocalNetwork; lock.unlock()
        guard avoiding, MirrorLocalNetwork.isLocal(remote, networks: MirrorLocalNetwork.networks()) else { return }
        if localNetworkCheck() == .allowed {
            lock.lock(); avoidsLocalNetwork = false; lock.unlock()
            onNote?("macOS now lets this process onto the local network: keeping direct paths for viewers on it")
            return
        }
        rebind(relayOnly: true, why: "the viewer is on this Mac's own network, which macOS closes to this process: moving to the relay only")
    }

    /// Called on `queue` when a viewer has gone. If the endpoint moved to the relay for it, direct
    /// paths are allowed again once no viewer has been connected for `directAgainAfter`.
    private func allowDirectAgainLater() {
        lock.lock()
        idleCount += 1
        let count = idleCount, wanted = relayOnlyNow && !relayOnlyAsked
        lock.unlock()
        guard wanted else { return }
        queue.asyncAfter(deadline: .now() + Self.directAgainAfter) { [weak self] in
            guard let self else { return }
            self.lock.lock(); let idle = self.connection == nil && self.idleCount == count; self.lock.unlock()
            if idle { self.rebind(relayOnly: false, why: "no viewer for a minute: allowing direct paths again") }
        }
    }

    /// Gives the running endpoint other relays without closing it, so a viewer on a direct path is
    /// not disturbed. Empty means iroh's public relays.
    func useRelays(_ urls: [String]) async {
        func map(_ urls: [String]) -> RelayMap? { urls.isEmpty ? RelayMode.defaultMode().relayMap() : try? RelayMap.fromUrls(urls: urls) }
        lock.lock(); let endpoint = self.endpoint, old = relays; lock.unlock()
        guard let endpoint, let wanted = map(urls), let had = map(old) else { onNote?("bad relay address in \(urls)"); return }
        lock.lock(); relays = urls; lock.unlock()
        for url in wanted.urls() where (try? had.contains(url: url)) != true {
            guard let config = try? wanted.get(url: url) else { continue }
            do { try await endpoint.insertRelay(config: config) } catch { onNote?("could not add relay \(url): \(error)") }
        }
        for url in had.urls() where (try? wanted.contains(url: url)) != true { _ = try? await endpoint.removeRelay(url: url) }
    }

    private func serve(_ connection: Connection) async throws {
        let viewer = connection.remoteId().description
        if let allows, !allows(viewer) {
            // Closed before any stream is accepted: an unpaired viewer gets no video and can send no touch.
            try? connection.close(errorCode: MirrorClose.notPaired, reason: Data("not paired".utf8))
            onNote?("refused unpaired viewer \(viewer)")
            onRefused?(viewer)
            return
        }
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        let occupied = self.connection != nil && connectedViewer != viewer && now - lastHeard < 5
        let occupiedFor: TimeInterval? = occupied ? now - connectedAt : nil
        lock.unlock()
        if let occupiedFor, turnsAwayWhileBusy?(occupiedFor) == true {
            try? connection.close(errorCode: MirrorClose.busy, reason: Data("busy".utf8))
            onNote?("turned away \(viewer): another viewer is connected")
            return
        }
        let controlStream = try await connection.acceptBi()
        _ = try await controlStream.recv().readExact(size: 1)
        let controlSend = controlStream.send(), controlReceive = controlStream.recv()
        try? await controlSend.setPriority(p: 1)    // pongs must not wait behind video
        let (controlData, controlInput) = AsyncStream<Data>.makeStream()
        lock.lock()
        let previous = self.connection
        control?.finish()
        video?.finish()
        self.connection = connection
        connectedAt = ProcessInfo.processInfo.systemUptime
        connectedViewer = viewer
        lastHeard = connectedAt
        control = controlInput
        video = nil
        videoSend = nil
        backlog = 0
        lock.unlock()
        try? previous?.close(errorCode: 0, reason: Data())
        watch = connection.watchPathEvents(callback: MirrorPathLogger(log: { [weak self] text in self?.onNote?(text) }, selected: { [weak self] relay in
            self?.queue.async { if self?.isCurrent(connection) == true { self?.onPathSelected?(relay) } }
        }, direct: { [weak self] remote in self?.directPathSelected(remote) }))
        queue.async { self.onConnected?() }

        Task { for await data in controlData { do { try await controlSend.writeAll(buf: data) } catch { break } } }
        // The client's per-frame reports arrive as datagrams: a report stuck behind a lost one on a
        // reliable stream would make this side think the client is behind when it is not.
        Task {
            while let datagram = try? await connection.readDatagram() {
                guard let type = datagram.first else { continue }
                let payload = Data(datagram.dropFirst())
                self.queue.async { if self.isCurrent(connection) { self.onMessage?(type, payload) } }
            }
        }
        Task {
            do {
                while true {
                    let head = try await controlReceive.readExact(size: 4)
                    let length = head.read(UInt32.self, at: 0)
                    guard length <= Self.messageLimit else {
                        try? connection.close(errorCode: MirrorClose.protocolError, reason: Data("message too long".utf8))
                        break
                    }
                    let body = try await controlReceive.readExact(size: length)
                    guard let type = body.first else { continue }
                    let payload = Data(body.dropFirst())
                    self.queue.async { if self.isCurrent(connection) { self.onMessage?(type, payload) } }
                }
            } catch {}
        }
        let reason = await connection.closed()
        onNote?("iroh connection closed: \(reason)")
        queue.async {
            guard self.isCurrent(connection) else { return }
            self.lock.lock()
            self.connection = nil
            self.control?.finish(); self.control = nil
            self.video?.finish(); self.video = nil
            self.videoSend = nil
            self.lock.unlock()
            self.onClosed?()
            self.allowDirectAgainLater()
        }
    }

    /// Whether this is the connection in use. Asked for every message that arrives, so it also
    /// notes that the viewer was just heard from.
    private func isCurrent(_ connection: Connection) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard self.connection === connection else { return false }
        lastHeard = ProcessInfo.processInfo.systemUptime
        return true
    }

    func sendControl(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        control?.yield(data)
    }

    func sendVideo(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard let video else { return }
        backlog += 1
        video.yield(data)
    }

    /// Abandons the current video stream and opens the next one. Messages handed over from now on
    /// go to the new stream; the caller must make the first of them a keyframe.
    func restartVideo() {
        lock.lock()
        guard let connection else { lock.unlock(); return }
        video?.finish()
        videoNumber += 1
        let number = videoNumber
        let (data, input) = AsyncStream<Data>.makeStream()
        video = input
        backlog = 0
        let old = videoSend
        videoSend = nil
        lock.unlock()
        Task {
            try? await old?.reset(errorCode: 1)
            do {
                let stream = try await connection.openUni()
                self.lock.lock()
                let current = number == self.videoNumber
                if current { self.videoSend = stream }
                self.lock.unlock()
                guard current else { try? await stream.reset(errorCode: 1); return }
                var head = Data()
                head.put(number)
                try await stream.writeAll(buf: head)
                for await chunk in data {
                    try await stream.writeAll(buf: chunk)
                    self.lock.lock()
                    if number == self.videoNumber { self.backlog -= 1 }
                    self.lock.unlock()
                }
            } catch {}
        }
    }

    /// The connection's paths as libiroh reports them: which is in use, relayed or direct, and its health.
    func snapshot() -> [String: Any]? {
        lock.lock(); let connection = self.connection; lock.unlock()
        guard let connection else { return nil }
        let paths: [[String: Any]] = connection.paths().map { path in
            ["selected": path.isSelected, "relay": path.isRelay, "rttMs": Int(path.rttMs), "cwnd": Int(path.stats.cwnd),
             "lost": Int(path.stats.lostPackets), "congestionEvents": Int(path.stats.congestionEvents),
             "mtu": Int(path.stats.currentMtu), "txBytes": Int(path.stats.udpTxBytes)]
        }
        let totals = connection.stats()
        return ["paths": paths, "rttMs": Int(connection.rtt() ?? 0), "lostPackets": Int(totals.lostPackets),
                "txBytes": Int(totals.udpTxBytes), "backlog": videoBacklog]
    }

    /// Closes the connection and the endpoint so the client notices at once, waiting briefly for the goodbye to leave.
    func closeAndWait() {
        lock.lock(); let connection = self.connection, endpoint = self.endpoint; lock.unlock()
        let done = DispatchSemaphore(value: 0)
        Task {
            try? connection?.close(errorCode: 0, reason: Data("host stopped".utf8))
            try? await endpoint?.close()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
    }
}
#endif
