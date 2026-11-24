#if AXE_MIRROR
@preconcurrency import FBControlCore
import FBSimulatorControl
import Foundation
import IrohLib

/// The mirror host: one endpoint for every paired viewer, and a session for each of them.
///
/// A viewer's session is made the first time it connects and kept while the host runs, so each
/// viewer has its own simulator, its own picture and its own list of builds, and a viewer that
/// connects does not take another's place. The session is found by the viewer's endpoint ID, which
/// iroh proves on every connection, so a viewer that comes back gets its own session again.
///
/// A demo host is the exception: its visitors are strangers who are shown one simulator, one at a
/// time, so they share one session (see `MirrorDemo`).
///
/// What belongs to the Mac and not to a viewer is here: the endpoint and its relays, the probe of
/// the Mac's own network link, and how busy the Mac is.
final class MirrorHostSessions: @unchecked Sendable {
    private let simulator: FBSimulator?
    private let secret: Data
    private let lock = NSLock()
    private var settings: MirrorSession.Settings           // under `lock`
    private var sessions: [String: MirrorSession] = [:]    // under `lock`; by viewer, or "" for a demo's one session
    private var stopped = false                             // under `lock`
    private let endpoint = MirrorEndpoint()
    private let health = MirrorLinkHealth()
    private let queue = DispatchQueue(label: "axe.mirror.host")
    /// How busy this Mac is, sampled once a second on `queue`; see `sampleLoad`.
    private var sampler = MirrorHostSampler()
    private var busyJudge = MirrorBusyJudge()
    private var hostLoad = MirrorHostLoad(busy: false, load: 0, cpu: 0)    // under `lock`
    private var loadTimer: DispatchSourceTimer?
    private var relayWatch: Task<Void, Never>?
    private var viewersChanged: Date?                       // on `queue`: the list of paired viewers as last looked at
    /// One event for the command to print: a name and its fields. An event that comes from a
    /// viewer's session carries that viewer's ID as `viewer`, as `paired` and `refused` do, and
    /// the name it was paired under as `viewerName`.
    var onEvent: (([String: String]) -> Void)?
    /// The host cannot go on: the message says why.
    var onFatal: ((String) -> Void)?

    /// `simulator` is nil on a host that lets its viewers choose.
    init(simulator: FBSimulator?, secret: Data, settings: MirrorSession.Settings) {
        self.simulator = simulator
        self.secret = secret
        self.settings = settings
    }

    func start() {
        let settings = lock.withLock { self.settings }
        health.onReport = { line, _ in mirrorNote(line) }
        health.isWanted = { [weak self] in self?.hasViewer ?? false }
        health.start()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.sampleLoad()
            self?.dropUnpaired()
        }
        timer.resume()
        loadTimer = timer
        let startedWith = simulator?.udid
        endpoint.onNote = { [weak self] text in
            mirrorNote(text)
            if text.hasPrefix("iroh endpoint "), let self {
                self.onEvent?(["event": "endpoint", "hostID": String(text.dropFirst("iroh endpoint ".count))])
            } else if text.hasPrefix("iroh online, home relay "), let self {
                // A host that lets the viewer choose has no simulator to name yet.
                var ready = ["event": "ready", "relay": String(text.dropFirst("iroh online, home relay ".count))]
                if let startedWith { ready["udid"] = startedWith }
                self.onEvent?(ready)
            }
        }
        endpoint.onFailed = { [weak self] message in self?.onFatal?(message) }
        endpoint.onWarning = { [weak self] code, message in
            mirrorNote("Warning: " + message)
            self?.onEvent?(["event": "warning", "code": code, "message": message])
        }
        if let viewers = settings.viewers {
            endpoint.allows = { viewers.allows($0) }
            endpoint.onRefused = { [weak self] viewer in self?.onEvent?(["event": "refused", "viewer": viewer, "reason": "not paired"]) }
        }
        endpoint.avoidsLocalNetwork = settings.avoidLocalNetwork
        if settings.assumeLocalNetworkBlocked { endpoint.localNetworkCheck = { .blocked } }
        endpoint.hasViewers = { [weak self] in self?.hasViewer ?? false }
        endpoint.closeViewers = { [weak self] reason in
            for session in self?.all() ?? [] { session.link.close(reason: reason) }
        }
        endpoint.onViewer = { [weak self] connection, viewer in
            guard let self, let session = self.session(for: viewer) else {
                try? connection.close(errorCode: MirrorClose.stopped, reason: Data("host stopped".utf8))
                return
            }
            try await session.link.serve(connection)
        }
        // A demo's one session is there before its first visitor, so that the sample app is put in
        // front, and a missing one found, as the host starts.
        if settings.demo { _ = session(for: "") }
        endpoint.start(secret: secret, relayOnly: settings.relayOnly, relayURLs: settings.relayURLs)
        if settings.watchRelays { watchRelays() }
    }

    /// Stops every session and closes the endpoint, so that each viewer notices at once. Returns
    /// the last lines worth printing.
    func stop() -> [String] {
        relayWatch?.cancel()
        queue.sync {
            loadTimer?.cancel()
            loadTimer = nil
        }
        let last: [MirrorSession] = lock.withLock {
            stopped = true
            return Array(sessions.values)
        }
        health.stop()
        for session in last { session.stop() }
        endpoint.closeAndWait()
        return health.summary()
    }

    private func all() -> [MirrorSession] { lock.withLock { Array(sessions.values) } }

    private var hasViewer: Bool { all().contains { $0.hasViewer } }

    /// The viewer's session, made now if this is the first time it has connected. Nil once the
    /// host has stopped.
    private func session(for viewer: String) -> MirrorSession? {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return nil }
        let key = settings.demo ? "" : viewer
        if let existing = sessions[key] { return existing }
        // Each session reads the simulator's screen through a framebuffer of its own.
        var framebuffer: FBFramebuffer?
        if let simulator {
            do { framebuffer = try MirrorHost.framebuffer(of: simulator) } catch {
                mirrorNote("the simulator's screen could not be read for a viewer: \(CLIErrorMapping.failure(for: error).message)")
                return nil
            }
        }
        let session = MirrorSession(simulator: simulator, framebuffer: framebuffer, settings: settings)
        // The name the viewer was paired under, for whoever reads the events: with several viewers
        // connected, an event alone does not say whose it is.
        let name = key.isEmpty ? nil : (try? settings.viewers?.all())?.first { $0.id == viewer }?.name
        session.onEvent = { [weak self] event in
            var event = event
            if !key.isEmpty {
                event["viewer"] = viewer
                if let name { event["viewerName"] = name }
            }
            self?.onEvent?(event)
        }
        session.onFatal = { [weak self] in self?.onFatal?($0) }
        // Two viewers may be watching one simulator: what one does to it, the other is told.
        session.onManaging = { [weak self, weak session] udid, action, done in
            for other in self?.all() ?? [] where other !== session { other.simulatorManagedElsewhere(udid: udid, action: action, done: done) }
        }
        session.link.onDirectPath = { [weak self] remote in self?.endpoint.directPathSelected(remote) }
        session.start()
        session.hostLoadChanged(hostLoad, tell: false)
        sessions[key] = session
        if !key.isEmpty { mirrorNote("a session for \(name ?? viewer): \(sessions.count) viewer\(sessions.count == 1 ? "" : "s") known") }
        return session
    }

    /// Ends the session of every viewer that has been removed from the list of paired viewers, so
    /// that `axe remote unpair` takes a device's access away at once and not when its connection
    /// next happens to drop: a paired viewer can delete simulators. Looked at once a second, and
    /// the list is read only when its file has changed.
    private func dropUnpaired() {
        guard let viewers = lock.withLock({ settings.demo ? nil : settings.viewers }) else { return }
        let changed = viewers.changed
        guard changed != viewersChanged else { return }
        viewersChanged = changed
        let known = lock.withLock { Array(sessions.keys) }
        for viewer in viewers.removed(among: known) {
            guard let session = lock.withLock({ sessions.removeValue(forKey: viewer) }) else { continue }
            mirrorNote("\(viewer) is no longer paired: closing its session")
            session.stop(reason: "not paired", code: MirrorClose.notPaired)
            onEvent?(["event": "unpaired", "viewer": viewer])
        }
    }

    /// Keeps a long-running host on a relay that works. Every half minute, while no viewer is
    /// connected, the host asks its relay whether it is there. When `MirrorRelays.checkDue` says so,
    /// the relays are chosen again; if the choice differs, the endpoint is given the new ones.
    private func watchRelays() {
        let (seed, record) = lock.withLock { (settings.relaySeed, settings.relayRecord) }
        relayWatch = Task { [weak self] in
            var lastCheck = ProcessInfo.processInfo.systemUptime
            var missed = 0
            while true {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled, let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let current = self.lock.withLock { self.settings.relayURLs }
                guard !self.hasViewer else { missed = 0; continue }
                if let home = current.first { missed = await MirrorRelays.measure([home]).isEmpty ? missed + 1 : 0 }
                guard MirrorRelays.checkDue(onOwn: !current.isEmpty, missed: missed, sinceCheck: now - lastCheck) else { continue }
                lastCheck = now
                let choice = await MirrorRelays.choose(explicit: nil, seed: seed, record: record)
                guard choice.relays != current, !Task.isCancelled, !self.hasViewer else { continue }
                self.lock.withLock { self.settings.relayURLs = choice.relays }
                await self.endpoint.useRelays(choice.relays)
                self.onEvent?(choice.event)
            }
        }
    }

    /// Samples the Mac's processor use and load once a second. When it becomes busy, or stops being
    /// busy, every viewer is told and an event is printed.
    private func sampleLoad() {
        let (cpu, load) = sampler.sample()
        let changed = busyJudge.sample(cpu: cpu, loadPerCore: load)
        let busy = busyJudge.busy
        let now: MirrorHostLoad = lock.withLock {
            hostLoad.cpu = cpu
            hostLoad.load = load
            if changed { hostLoad.busy = busy }
            return hostLoad
        }
        if changed {
            let figures = String(format: "load %.1f per core, %.0f%% processor use", load, cpu * 100)
            mirrorNote(now.busy ? "this Mac is very busy: \(figures)" : "this Mac is no longer busy: \(figures)")
            onEvent?(["event": now.busy ? "macBusy" : "macNotBusy", "load": String(format: "%.1f", load), "cpu": String(format: "%.2f", cpu)])
        }
        for session in all() { session.hostLoadChanged(now, tell: changed) }
    }
}
#endif
