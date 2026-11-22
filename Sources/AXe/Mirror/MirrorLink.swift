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

/// One viewer's place on this Mac: the iroh connection it has now, which a newer one from the same
/// viewer replaces. `MirrorEndpoint` lets connections in and the host hands each to its viewer's
/// link, so every paired viewer has one of these and any number are connected at once.
///
/// The client opens one two-way QUIC stream for control messages (first byte "C"). Video goes on
/// one-way streams this side opens. Each starts with its number, and a newer one replaces the
/// older: the old stream is reset, so whatever was queued or lost on it is never retransmitted, and
/// the new one starts with a keyframe. The client's frame reports and status come back as QUIC
/// datagrams (one type byte, then the payload).
final class MirrorLink: @unchecked Sendable {
    /// The stream protocol's name. The second is the test viewer's name for the same protocol, kept
    /// until that viewer is retired.
    static let alpns = [MirrorProtocol.stream, MirrorProtocol.legacyStream]
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var connection: Connection?
    private var control: AsyncStream<Data>.Continuation?
    private var video: AsyncStream<Data>.Continuation?
    private var backlog = 0
    private var videoNumber: UInt32 = 0
    private var videoSend: SendStream?
    private var watch: WatchHandle?
    var onPathSelected: ((Bool) -> Void)?       // on `queue`; true when the path now in use is a relay
    var onConnected: (() -> Void)?              // on `queue`
    var onMessage: ((UInt8, Data) -> Void)?     // on `queue`
    var onClosed: (() -> Void)?                 // on `queue`
    var onNote: ((String) -> Void)?
    /// The remote address of a direct path that is now in use: see `MirrorEndpoint.avoidsLocalNetwork`.
    var onDirectPath: ((String) -> Void)?
    /// Asked when a viewer arrives while a different viewer is connected and has been heard from in
    /// the last five seconds, with how long that one has been connected. True turns the newcomer
    /// away; nil or false lets it replace the other. Only a link shared by every viewer, as a demo
    /// host's is, ever meets a different viewer. A viewer returning under the same ID always
    /// replaces its own older connection.
    var turnsAwayWhileBusy: ((TimeInterval) -> Bool)?
    private var connectedAt: TimeInterval = 0
    private var connectedViewer = ""
    private var lastHeard: TimeInterval = 0
    /// The longest control message a viewer may send. Nothing the viewer sends is near this.
    static let messageLimit = 64 * 1024
    /// How long a connection has to open its control stream before it is closed.
    static let handshakeSeconds: TimeInterval = 10

    init(queue: DispatchQueue) { self.queue = queue }

    var hasViewer: Bool { lock.lock(); defer { lock.unlock() }; return connection != nil }

    /// Video messages handed over but not yet accepted by the QUIC stream.
    var videoBacklog: Int { lock.lock(); defer { lock.unlock() }; return backlog }

    /// Serves a connection the endpoint has let in, until it closes. It takes the place of the
    /// connection this link had.
    func serve(_ connection: Connection) async throws {
        let viewer = connection.remoteId().description
        /// Whether another viewer has this place now and keeps it. Asked when the connection
        /// arrives, and again once it has opened its control stream: a connection that arrived
        /// while the place was free and then waited would otherwise take it from whoever came since.
        func turnedAway() -> Bool {
            lock.lock()
            let now = ProcessInfo.processInfo.systemUptime
            let occupied = self.connection != nil && connectedViewer != viewer && now - lastHeard < MirrorDemo.presentWithin
            let occupiedFor: TimeInterval? = occupied ? now - connectedAt : nil
            lock.unlock()
            guard let occupiedFor, turnsAwayWhileBusy?(occupiedFor) == true else { return false }
            try? connection.close(errorCode: MirrorClose.busy, reason: Data("busy".utf8))
            onNote?("turned away \(viewer): another viewer is connected")
            return true
        }
        if turnedAway() { return }
        // A connection that opens no control stream is not waited on for ever.
        let slow = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.handshakeSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            try? connection.close(errorCode: MirrorClose.timeout, reason: Data("no control stream".utf8))
        }
        let controlStream: BiStream
        do {
            controlStream = try await connection.acceptBi()
            _ = try await controlStream.recv().readExact(size: 1)
            slow.cancel()
        } catch {
            slow.cancel()
            throw error
        }
        if turnedAway() { return }
        let controlSend = controlStream.send(), controlReceive = controlStream.recv()
        try? await controlSend.setPriority(p: 1)    // pongs must not wait behind video
        let (controlData, controlInput) = AsyncStream<Data>.makeStream()
        lock.lock()
        let previous = self.connection
        control?.finish()
        video?.finish()
        self.connection = connection
        let now = ProcessInfo.processInfo.systemUptime
        connectedAt = MirrorDemo.turnStart(viewer: viewer, previousViewer: connectedViewer, previousStart: connectedAt, lastHeard: lastHeard, now: now)
        connectedViewer = viewer
        lastHeard = now
        control = controlInput
        video = nil
        videoSend = nil
        backlog = 0
        lock.unlock()
        try? previous?.close(errorCode: 0, reason: Data())
        watch = connection.watchPathEvents(callback: MirrorPathLogger(log: { [weak self] text in self?.onNote?(text) }, selected: { [weak self] relay in
            self?.queue.async { if self?.isCurrent(connection) == true { self?.onPathSelected?(relay) } }
        }, direct: { [weak self] remote in self?.onDirectPath?(remote) }))
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

    /// Closes the viewer's connection, with the reason it is told: the host stopped, or its
    /// endpoint is about to be bound again. The viewer notices at once.
    func close(reason: String) {
        lock.lock(); let connection = self.connection; lock.unlock()
        try? connection?.close(errorCode: MirrorClose.stopped, reason: Data(reason.utf8))
    }
}
#endif
