#if AXE_MIRROR
import Foundation
import IrohLib

/// The Mac's iroh endpoint: the one address every paired viewer connects to. It lets a connection
/// in when the viewer is paired and hands it on (`onViewer`) to be served by that viewer's own
/// `MirrorLink`. Any number of viewers may be connected at once.
final class MirrorEndpoint: @unchecked Sendable {
    private let queue = DispatchQueue(label: "axe.mirror.endpoint")
    private let lock = NSLock()
    private var endpoint: Endpoint?
    private var homeWatch: WatchHandle?
    private var relays: [String] = []           // what the endpoint was last given; empty means iroh's public relays
    private var secret = Data()
    private var relayOnlyAsked = false          // asked for at start: the endpoint never leaves the relay
    private var relayOnlyNow = false            // how the endpoint is bound at present
    private var rebinding = false
    private var idleCount = 0                   // goes up each time a viewer leaves
    private var closing = false                 // the host is stopping: an endpoint that closes now has not failed
    /// Set when macOS keeps this process off the local network (see `MirrorLocalNetwork`). A viewer
    /// on one of this Mac's own networks then cannot hold a direct path, and trying costs it the
    /// stream: paths open, are chosen for the video and die. iroh offers no way to refuse one
    /// address, so when such a path is chosen, the endpoint is closed and bound again on the relay
    /// alone. A path that opens and is never chosen does no harm and is left alone: the host also
    /// tries a distant viewer's private address, which can look like one of this Mac's own. Every
    /// viewer reconnects by itself within a few seconds and stays on the relay. A minute after the
    /// last viewer has gone the endpoint allows direct paths again, so a viewer somewhere else,
    /// whom this process can reach, still gets one.
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
    var onNote: ((String) -> Void)?
    /// The endpoint cannot listen, and will not by itself: the host must stop and say why. A
    /// host that went on running with no listener looked alive to whatever watches it, and no
    /// viewer could connect.
    var onFailed: ((String) -> Void)?
    /// Something a person should know while the host carries on: a code and a sentence.
    var onWarning: ((String, String) -> Void)?
    /// How long the endpoint may take to reach a relay before the host says it has not.
    static let onlineWithin: TimeInterval = 20
    /// How many times in a row binding again is tried before the host gives up.
    static let bindAttempts = 3
    /// Asked for every incoming connection with the viewer's endpoint ID, which iroh has verified.
    /// Nil lets every viewer in.
    var allows: ((String) -> Bool)?
    var onRefused: ((String) -> Void)?
    /// A connection that was let in, with the viewer's endpoint ID. It returns when the connection
    /// has closed.
    var onViewer: ((Connection, String) async throws -> Void)?
    /// Whether any viewer is connected now.
    var hasViewers: (() -> Bool)?
    /// Closes every viewer's connection with this reason: the endpoint is about to be bound again.
    var closeViewers: ((String) -> Void)?

    /// `relayURLs` are our relays in order of preference; empty means iroh's public relays.
    func start(secret: Data, relayOnly: Bool = false, relayURLs: [String] = []) {
        lock.lock(); self.secret = secret; relayOnlyAsked = relayOnly; relayOnlyNow = relayOnly; relays = relayURLs; lock.unlock()
        Task { await listen(first: true) }
    }

    /// Binds the endpoint and lets viewers in until it is closed. `first` is false when the endpoint
    /// is bound again while the host runs; the notes then differ, so that the host reports its ID
    /// and that it is ready once only.
    private func listen(first: Bool, attempt: Int = 1) async {
        lock.lock(); let secret = self.secret, relayOnly = relayOnlyNow, relayURLs = relays; lock.unlock()
        do {
            let preset: Preset = relayOnly ? MirrorRelayOnlyPreset(relayURLs: relayURLs) : relayURLs.isEmpty ? presetN0() : MirrorOwnRelayPreset(relayURLs: relayURLs)
            let endpoint = try await Endpoint.bind(options: EndpointOptions(preset: preset, secretKey: secret, alpns: MirrorLink.alpns))
            lock.lock(); self.endpoint = endpoint; rebinding = false; lock.unlock()
            if first { onNote?("iroh endpoint \(endpoint.id().description)") }
            // Until a relay answers, no viewer can find this Mac. That is said, not waited out in silence.
            if await MirrorTimeout.finishes(within: Self.onlineWithin, { await endpoint.online() }) == nil {
                let relay = relayURLs.isEmpty ? "iroh's public relays" : relayURLs.joined(separator: ", ")
                onWarning?("relayUnreachable", "No relay has answered in \(Int(Self.onlineWithin)) seconds (\(relay)), so viewers cannot find this Mac yet. Check its internet connection. The host keeps trying.")
                await endpoint.online()
            }
            let home = endpoint.addr().relayUrl() ?? "none"
            onNote?(first ? "iroh online, home relay \(home)" : "listening again, \(relayOnly ? "on the relay only" : "direct paths allowed"), home relay \(home)")
            // For the log only. iroh did not report a stopped relay here within two minutes, so the
            // host's relay watch asks the relay itself.
            // The callback also fires when only a relay's connection state changes, so repeats are dropped.
            let last = MirrorLastValue()
            homeWatch = endpoint.watchHomeRelay(callback: MirrorHomeRelayWatcher { [weak self] urls in
                guard last.changed(to: urls) else { return }
                self?.onNote?(urls.isEmpty ? "home relay: none" : "home relay: \(urls.joined(separator: " "))")
            })
            while let incoming = await endpoint.acceptNext() {
                Task {
                    do { try await self.admit(try await incoming.accept().connect()) } catch { self.onNote?("iroh connection failed: \(error)") }
                }
            }
            // The endpoint takes no more connections. That is expected when the host closed it,
            // to stop or to bind again; otherwise it is a failure nobody would hear of.
            lock.lock(); let unexpected = self.endpoint === endpoint && !closing; lock.unlock()
            if unexpected { onFailed?("The host stopped listening for viewers: its endpoint closed.") }
        } catch {
            lock.lock(); rebinding = false; let closing = self.closing; lock.unlock()
            onNote?("iroh failed: \(error)")
            guard !closing else { return }
            if !first, attempt < Self.bindAttempts {
                // Bound again while running, for a viewer on this Mac's own network: worth another go.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await listen(first: false, attempt: attempt + 1)
                return
            }
            onFailed?("The host could not listen for viewers: \(error)")
        }
    }

    /// Lets a paired viewer's connection in and hands it on, until it closes.
    private func admit(_ connection: Connection) async throws {
        let viewer = connection.remoteId().description
        if let allows, !allows(viewer) {
            // Closed before any stream is accepted: an unpaired viewer gets no video and can send no touch.
            try? connection.close(errorCode: MirrorClose.notPaired, reason: Data("not paired".utf8))
            onNote?("refused unpaired viewer \(viewer)")
            onRefused?(viewer)
            return
        }
        try await onViewer?(connection, viewer)
        allowDirectAgainLater()
    }

    /// Closes the endpoint and binds it again, on the relay alone or with direct paths allowed.
    /// Connected viewers are dropped and reconnect by themselves.
    private func rebind(relayOnly: Bool, why: String) {
        lock.lock()
        guard !rebinding, relayOnlyNow != relayOnly, relayOnly || !relayOnlyAsked, let endpoint = self.endpoint else { lock.unlock(); return }
        rebinding = true
        relayOnlyNow = relayOnly
        self.endpoint = nil
        lock.unlock()
        onNote?(why)
        Task {
            self.closeViewers?("listening again")
            try? await endpoint.close()
            await self.listen(first: false)
        }
    }

    /// A direct path to `remote` is now in use by a viewer. See `avoidsLocalNetwork`.
    func directPathSelected(_ remote: String) {
        lock.lock(); let avoiding = avoidsLocalNetwork; lock.unlock()
        guard avoiding, MirrorLocalNetwork.isLocal(remote, networks: MirrorLocalNetwork.networks()) else { return }
        if localNetworkCheck() == .allowed {
            lock.lock(); avoidsLocalNetwork = false; lock.unlock()
            onNote?("macOS now lets this process onto the local network: keeping direct paths for viewers on it")
            return
        }
        rebind(relayOnly: true, why: "a viewer is on this Mac's own network, which macOS closes to this process: moving to the relay only")
    }

    /// A viewer has gone. If the endpoint moved to the relay, direct paths are allowed again once
    /// no viewer has been connected for `directAgainAfter`.
    private func allowDirectAgainLater() {
        lock.lock()
        idleCount += 1
        let count = idleCount, wanted = relayOnlyNow && !relayOnlyAsked
        lock.unlock()
        guard wanted else { return }
        queue.asyncAfter(deadline: .now() + Self.directAgainAfter) { [weak self] in
            guard let self else { return }
            self.lock.lock(); let unchanged = self.idleCount == count; self.lock.unlock()
            if unchanged, self.hasViewers?() != true { self.rebind(relayOnly: false, why: "no viewer for a minute: allowing direct paths again") }
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

    /// Closes the endpoint, waiting briefly for the viewers' goodbyes to leave. The host closes
    /// each viewer's connection first, so that each is told why.
    func closeAndWait() {
        lock.lock(); closing = true; let endpoint = self.endpoint; lock.unlock()
        let done = DispatchSemaphore(value: 0)
        Task {
            try? await endpoint?.close()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
    }
}
#endif
