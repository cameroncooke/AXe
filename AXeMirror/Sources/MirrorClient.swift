import AVFoundation
import CoreMedia
import Foundation
import IrohLib
import Network
import VideoToolbox

/// One connection to a Mac running `axe mirror`: it receives the simulator's screen as video and
/// sends touches and button presses back.
///
/// The Mac is dialled by its ID through a relay. iroh starts the connection there and moves it to a
/// direct path when the two devices can reach each other. Video arrives on one-way streams; the Mac
/// replaces the stream with a new one, starting at a keyframe, whenever this side has fallen behind.
///
/// A Mac started with `axe mirror` and no `--udid` shows no simulator until this side chooses one:
/// it sends its list (`onSimulators`), and `choose` opens, boots or creates one. See
/// `MirrorSimulatorList`.
/// Everything here runs on one private queue; the callbacks are delivered on the main queue.
final class MirrorClient: @unchecked Sendable {
    /// Where to find the Mac: its ID and the relays to try, most likely first.
    struct Target: Equatable {
        var hostID: String
        var relays: [String]
    }

    enum State: Equatable {
        case connecting
        case connected
        /// The connection was lost, or has not been made after `attempts` tries; still trying.
        case reconnecting(attempts: Int)
        /// The Mac cannot be reached, for this reason. `retrying` is false once the app has stopped
        /// trying by itself; `retry()` starts it again.
        case unreachable(MirrorUnreachable, retrying: Bool)
        /// The Mac said no, and trying again will not help.
        case refused(Refusal)
    }

    enum Refusal: Equatable { case notPaired, busy }

    struct Stats: Equatable {
        var framesPerSecond = 0
        var megabits = 0.0
        var route = ""              // "Direct" or "Relay"
        var roundTripMs = 0
        var width = 0, height = 0
    }

    /// The simulator the Mac is showing, as it says when a stream starts. A Mac with an AXe from
    /// before the list existed names no simulator, and `udid` is then empty.
    struct Showing: Equatable {
        var udid: String
        var name: String
        var canChoose: Bool         // the Mac lets this viewer go back to its list of simulators
        var model = ""              // the kind of device, such as "iPad Air 11-inch (M4)"; empty from an older Mac
        var canRotate = false       // the Mac turns the simulator when asked
        var hasHinge = false        // an iPhone Duo: the Mac folds it when asked and says which screen is shown
        var isIPad: Bool { model.hasPrefix("iPad") }
    }

    var onState: ((State) -> Void)?
    var onStats: ((Stats) -> Void)?
    var onVideoSize: ((CGSize) -> Void)?
    var onShowing: ((Showing) -> Void)?
    /// The Mac's simulators: it is waiting for this viewer to choose one.
    var onSimulators: ((MirrorSimulatorList) -> Void)?
    var onProgress: ((MirrorSimulatorProgress) -> Void)?
    /// Which screen the picture is and how far the hinge is open.
    var onScreen: ((MirrorScreenState) -> Void)?
    /// Whether the simulator is answering the Mac.
    var onHealth: ((MirrorSimulatorHealth) -> Void)?
    /// How busy the Mac is.
    var onHostLoad: ((MirrorHostLoad) -> Void)?
    /// The app builds the Mac offers to install on this device.
    var onBuilds: (([MirrorBuild]) -> Void)?
    /// The certificate this device serves builds to iOS with, from the Mac.
    var onInstallIdentity: ((MirrorInstallIdentity) -> Void)?
    /// The Mac could not make that certificate, and why.
    var onInstallIdentityFailed: ((String) -> Void)?
    /// A piece of a build asked for with `fetchBuild`, or why it could not be sent.
    var onBuildPiece: ((MirrorBuildPiece) -> Void)?
    var onFetchFailed: ((MirrorBuildFetchFailure) -> Void)?

    private let queue = DispatchQueue(label: "axemirror.client")
    private let target: Target
    private let identity: Data
    private let ownRelays: [String]
    private let renderer: AVSampleBufferVideoRenderer
    /// More renderers that get every frame too: the halves of the 3D Duo while it is being folded,
    /// so the picture on them stays live. Empty the rest of the time, when they cost nothing.
    private var mirrors: [AVSampleBufferVideoRenderer] = []
    /// The frame on screen now. A still screen sends no frames, so a renderer that starts
    /// mirroring is given this one at once.
    private var lastImage: CVImageBuffer?
    private var generation = 0
    private var stopped = false
    private var attempts = 0
    private var tryingSince: TimeInterval?      // since when there has been no connection; nil while connected or stopped
    private var lastDiagnosis = 0.0
    private var gaveUp = false                  // stopped trying by itself; `retry()` starts again
    private var timer: DispatchSourceTimer?
    private var tick = 0
    /// When the Mac last sent anything. It answers a ping twice a second, so a quiet connection is a
    /// dead one: a Mac that stopped without closing it, or a network that went away.
    private var lastHeard = 0.0
    /// How long the Mac may say nothing before the connection is dropped and made again. Left to
    /// itself the connection takes about half a minute to notice, and all that time the app would
    /// look connected while nothing it sent arrived.
    static let silenceLimit = 15.0

    private var endpoint: Endpoint?
    private var connection: Connection?
    private var control: AsyncStream<Data>.Continuation?
    private var videoStreamNumber: UInt32 = 0
    private var videoStream: RecvStream?

    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var waitingForKey = true
    private var lastKeyRequest = 0.0
    private var lastFrameID: UInt64?
    private var videoSize = CGSize.zero

    private var clockSamples: [(roundTrip: Double, offset: Double)] = []
    private var offset = 0.0
    private var roundTrip = 0.0
    private var paneSize = CGSize.zero
    private var displayHertz = 60
    private var appState = "active"
    private var network = "unknown"
    private let pathMonitor = NWPathMonitor()
    private var decodedInWindow = 0
    private var bytesInWindow = 0

    private var gesture: UInt32 = 0
    private var touchSequence: UInt32 = 0
    private var recentMoves: [(fractions: [CGPoint], time: TimeInterval)] = []
    /// The UDID of the simulator being watched. A connection that drops and comes back names it,
    /// so the Mac carries on with it instead of sending its list again.
    private var watching: String?

    /// `ownRelays` are the relays this device itself listens on; empty means iroh's public relays.
    init(target: Target, identity: Data, ownRelays: [String], renderer: AVSampleBufferVideoRenderer) {
        self.target = target
        self.identity = identity
        self.ownRelays = ownRelays
        self.renderer = renderer
    }

    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: Starting and stopping

    func start() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let had = self.network
            self.network = path.usesInterfaceType(.wifi) ? "wifi" : path.usesInterfaceType(.cellular) ? "cellular"
                : path.status == .satisfied ? "other" : "none"
            // A network that has come back is worth one more run of tries without being asked.
            if had == "none", self.network != "none", self.gaveUp { self.retry() }
        }
        pathMonitor.start(queue: queue)
        queue.async { [self] in
            tryingSince = Self.now()
            report(.connecting)
            connect()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
            timer.setEventHandler { [weak self] in self?.periodic() }
            timer.resume()
            self.timer = timer
        }
    }

    /// Ends the connection for good. The Mac sees the viewer leave at once.
    func stop() {
        queue.async { [self] in
            stopped = true
            generation += 1
            timer?.cancel()
            timer = nil
            pathMonitor.cancel()
            control?.finish()
            control = nil
            try? connection?.close(errorCode: MirrorClose.stopped, reason: Data("viewer closed".utf8))
            connection = nil
            let endpoint = self.endpoint
            self.endpoint = nil
            Task { try? await endpoint?.close() }
        }
    }

    // MARK: Calls from the main thread

    /// Also shows every frame on these renderers, until it is called again; an empty list stops it.
    /// Each is flushed when it is dropped, so it does not hold a stale picture.
    func mirror(to renderers: [AVSampleBufferVideoRenderer]) {
        queue.async { [self] in
            for old in mirrors where !renderers.contains(where: { $0 === old }) { old.flush(removingDisplayedImage: true, completionHandler: nil) }
            let added = renderers.filter { new in !mirrors.contains(where: { $0 === new }) }
            mirrors = renderers
            if let lastImage, let sample = Self.sample(of: lastImage) { for renderer in added { renderer.enqueue(sample) } }
        }
    }

    /// The size, in pixels, of the area the picture is shown in. The Mac sizes the video to fit it.
    func setPane(_ size: CGSize, displayHertz: Int) {
        queue.async { [self] in
            self.displayHertz = displayHertz
            guard size != paneSize else { return }
            paneSize = size
            sendInfo()
        }
    }

    /// Sends one touch. `points` are in the picture view's coordinates and `viewSize` is that view's
    /// size; the view shows exactly the picture, so a point's share of the view is its share of the
    /// simulator's screen. Kinds: 1 down, 2 up, 3 cancel, 4 move, 5 a second finger joining the first.
    func touch(kind: UInt8, points: [CGPoint], in viewSize: CGSize, at time: TimeInterval) {
        queue.async { [self] in
            guard viewSize.width > 0, viewSize.height > 0, !points.isEmpty else { return }
            let fractions = points.prefix(2).map { point in
                CGPoint(x: min(1, max(0, point.x / viewSize.width)), y: min(1, max(0, point.y / viewSize.height)))
            }
            sendTouch(kind: kind, fractions: fractions, at: time)
        }
    }

    /// Presses one of the simulator's hardware buttons: 2 Home, 3 Lock. Two Home presses in one
    /// message open the app switcher.
    func pressButton(_ button: UInt8, count: UInt8 = 1) {
        queue.async { [self] in send(43, Data([button, count])) }
    }

    // MARK: Choosing a simulator

    /// Asks the Mac for its list of simulators again.
    func requestSimulators() {
        queue.async { [self] in send(MirrorMessage.list, Data()) }
    }

    /// Asks the Mac for the builds it offers; it sends them again whenever they change. A Mac
    /// that knows nothing of builds ignores this.
    func requestBuilds() {
        queue.async { [self] in send(MirrorMessage.listBuilds, Data()) }
    }

    /// Asks the Mac for the certificate this device serves builds to iOS with.
    func requestInstallIdentity() {
        queue.async { [self] in send(MirrorMessage.installIdentityRequest, Data()) }
    }

    /// Asks the Mac for one piece of a build's file. The piece comes back through `onBuildPiece`.
    func fetchBuild(_ id: String, offset: Int) {
        queue.async { [self] in
            guard let data = try? JSONEncoder().encode(MirrorBuildFetch(id: id, offset: offset, length: MirrorBuildFetch.largest)) else { return }
            send(MirrorMessage.fetchBuild, data)
        }
    }

    /// Tells the Mac that Install was tapped on a build, so whoever published it can see that.
    func reportInstall(_ id: String) {
        queue.async { [self] in
            guard let data = try? JSONEncoder().encode(MirrorBuildInstall(id: id)) else { return }
            send(MirrorMessage.installing, data)
        }
    }

    /// Opens a simulator, or creates one; the Mac boots it first if it has to. The stream starting
    /// says it worked, and `onProgress` says how far the Mac has got or why it failed.
    func choose(_ choice: MirrorSimulatorChoice) {
        queue.async { [self] in
            guard let data = try? JSONEncoder().encode(choice) else { return }
            forgetPicture()
            send(MirrorMessage.choose, data)
        }
    }

    /// Turns the simulator: `MirrorRotationRequest.left` or `.right` for a quarter turn, `.landscape`
    /// or `.portrait` to make it so. The picture changes shape when the screen has turned.
    func rotate(_ to: String) {
        queue.async { [self] in
            guard let data = try? JSONEncoder().encode(MirrorRotationRequest(to: to)) else { return }
            send(MirrorMessage.rotate, data)
        }
    }

    /// Folds an iPhone Duo simulator. The picture, and `onScreen`, show what happened.
    func fold(_ request: MirrorFoldRequest) {
        queue.async { [self] in
            guard let data = try? JSONEncoder().encode(request) else { return }
            send(MirrorMessage.fold, data)
        }
    }

    /// Stops watching the simulator and goes back to the Mac's list. The simulator stays booted.
    func leaveSimulator() {
        queue.async { [self] in
            forgetPicture()
            send(MirrorMessage.leave, Data())
        }
    }

    /// Shuts a simulator down or deletes it on the Mac. The Mac answers with its list as it then
    /// is. Naming the simulator on screen leaves it first.
    func manage(_ action: MirrorSimulatorAction) {
        queue.async { [self] in
            guard let data = try? JSONEncoder().encode(action) else { return }
            if let watching, UUID(uuidString: watching) == UUID(uuidString: action.udid) { forgetPicture() }
            send(MirrorMessage.manage, data)
        }
    }

    /// The picture on screen belongs to a simulator that is no longer watched: clear it, and count
    /// no frame of it towards the next one's frame rate.
    private func forgetPicture() {
        watching = nil
        waitingForKey = true
        decodedInWindow = 0
        bytesInWindow = 0
        lastImage = nil
        renderer.flush(removingDisplayedImage: true, completionHandler: nil)
        for mirror in mirrors { mirror.flush(removingDisplayedImage: true, completionHandler: nil) }
    }

    func enteredBackground() {
        queue.async { [self] in
            appState = "background"
            sendInfo()
        }
    }

    /// A decoder session does not survive the background, so the picture restarts from a keyframe.
    func enteredForeground() {
        queue.async { [self] in
            appState = "active"
            lastHeard = Self.now()      // nothing was read while in the background
            session = nil
            waitingForKey = true
            renderer.flush()
            sendInfo()
            requestKeyframe()
        }
    }

    // MARK: Connection

    private func report(_ state: State) {
        DispatchQueue.main.async { [weak self] in self?.onState?(state) }
    }

    private func connect() {
        guard !stopped else { return }
        generation += 1
        let current = generation
        connection = nil
        control = nil
        videoStream = nil
        videoStreamNumber = 0
        waitingForKey = true
        lastFrameID = nil
        clockSamples = []
        Task { [self] in
            var refusal: Refusal?
            do {
                let endpoint: Endpoint
                if let existing = queue.sync(execute: { self.endpoint }) {
                    endpoint = existing
                } else {
                    endpoint = try await Endpoint.bind(options: EndpointOptions(
                        preset: MirrorUnannouncedPreset(relayURLs: ownRelays), secretKey: identity, alpns: []))
                    queue.sync { self.endpoint = endpoint }
                }
                let id = try EndpointId.fromString(s: target.hostID)
                var connected: Connection?
                for relay in target.relays where connected == nil {
                    guard queue.sync(execute: { current == generation }) else { return }
                    let address = EndpointAddr(id: id, relayUrl: relay, addresses: [])
                    connected = await MirrorTimeout.finishes(within: 8) { try? await endpoint.connect(addr: address, alpn: MirrorProtocol.stream) } ?? nil
                }
                guard let connection = connected else { throw CancellationError() }
                let stream = try await connection.openBi()
                let controlSend = stream.send(), controlReceive = stream.recv()
                try await controlSend.writeAll(buf: Data([0x43]))
                let (outgoing, input) = AsyncStream<Data>.makeStream()
                let accepted: Bool = queue.sync {
                    guard current == generation, !stopped else { return false }
                    self.connection = connection
                    control = input
                    attempts = 0
                    tryingSince = nil
                    lastHeard = Self.now()
                    report(.connected)
                    sendInfo()
                    return true
                }
                guard accepted else {
                    try? connection.close(errorCode: MirrorClose.stopped, reason: Data())
                    return
                }
                Task { for await data in outgoing { do { try await controlSend.writeAll(buf: data) } catch { break } } }
                Task { await self.readMessages(from: controlReceive, generation: current) }
                Task { await self.acceptVideo(on: connection, generation: current) }
                let reason = await connection.closed()
                // The Mac names its reason when it turns a viewer away.
                if reason.contains("not paired") { refusal = .notPaired }
                if reason.contains("busy") { refusal = .busy }
            } catch {}
            queue.async { [self] in
                guard current == generation, !stopped else { return }
                connection = nil
                control = nil
                if let refusal {
                    tryingSince = nil       // a refusal is an answer: nothing is unreachable
                    report(.refused(refusal))
                    return
                }
                attempts += 1
                if tryingSince == nil { tryingSince = Self.now() }      // a working connection has just dropped
                // Once the reason is on screen it stays there; `watchForNoConnection` keeps it current.
                if MirrorRetry.phase(elapsed: Self.now() - (tryingSince ?? Self.now())) == .quiet { report(.reconnecting(attempts: attempts)) }
                queue.asyncAfter(deadline: .now() + MirrorRetry.pause(afterFailures: attempts)) { [self] in
                    guard current == generation else { return }
                    connect()
                }
            }
        }
    }

    /// Called twice a second. With no connection for ten seconds it works out why and reports it,
    /// and again every ten seconds in case the reason has changed; after two minutes it stops the
    /// tries and reports that too.
    private func watchForNoConnection() {
        guard connection == nil, !stopped, !gaveUp, let since = tryingSince else { return }
        let time = Self.now()
        switch MirrorRetry.phase(elapsed: time - since) {
        case .quiet:
            return
        case .explaining:
            guard time - lastDiagnosis >= 10 else { return }
            lastDiagnosis = time
            diagnose(retrying: true)
        case .stopped:
            gaveUp = true
            tryingSince = nil
            generation += 1         // the try under way, and the one waiting to start, no longer count
            diagnose(retrying: false)
        }
    }

    /// Finds out why the Mac cannot be reached, from what this device can check: its own network,
    /// then whether the relays answer.
    private func diagnose(retrying: Bool) {
        let hasNetwork = network != "none", relays = target.relays
        Task { [self] in
            let answering = hasNetwork && !relays.isEmpty ? await MirrorRelays.measure(relays).count : 0
            queue.async { [self] in
                guard connection == nil, !stopped, gaveUp != retrying else { return }
                report(.unreachable(MirrorUnreachable.reason(hasNetwork: hasNetwork, relays: relays.count, answering: answering), retrying: retrying))
            }
        }
    }

    /// Tries again after a refusal, for example once the user has paired or the demo is free.
    func retry() {
        queue.async { [self] in
            guard !stopped else { return }
            attempts = 0
            gaveUp = false
            tryingSince = Self.now()
            lastDiagnosis = 0
            report(.connecting)
            connect()
        }
    }

    private func acceptVideo(on connection: Connection, generation current: Int) async {
        while let stream = try? await connection.acceptUni() {
            guard let head = try? await stream.readExact(size: 4), head.count == 4 else { continue }
            let number = head.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            var replaced: RecvStream?
            let accepted: Bool = queue.sync {
                guard current == generation, number > videoStreamNumber else { return false }
                replaced = videoStream
                videoStreamNumber = number
                videoStream = stream
                waitingForKey = true
                lastFrameID = nil
                return true
            }
            if accepted {
                if let replaced { Task { try? await replaced.stop(errorCode: 1) } }
                Task { await self.readMessages(from: stream, generation: current, video: number) }
            } else {
                try? await stream.stop(errorCode: 1)
            }
        }
    }

    /// The longest message the Mac may send: one video frame. A keyframe of a large screen is a few
    /// hundred kilobytes.
    private static let messageLimit: UInt32 = 8 * 1024 * 1024
    /// The most of one message read in one go: see `readMessages`.
    private static let readAtOnce: UInt32 = 32 * 1024

    private func readMessages(from stream: RecvStream, generation current: Int, video number: UInt32? = nil) async {
        do {
            while true {
                let head = try await stream.readExact(size: 4)
                let length = head.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
                guard length >= 1, length <= Self.messageLimit else { break }
                // A long message, a piece of a build above all, is read a part at a time, and each
                // part that arrives says the Mac is there. Read whole, a 512 KiB piece on a link
                // slower than about 280 kbit/s took over `silenceLimit` to arrive, and a connection
                // that was working was dropped as dead, again and again.
                var body = Data(capacity: Int(length))
                while body.count < Int(length) {
                    body.append(try await stream.readExact(size: min(length - UInt32(body.count), Self.readAtOnce)))
                    if body.count < Int(length) {
                        let heard = Self.now()
                        queue.async { [self] in if current == generation { lastHeard = max(lastHeard, heard) } }
                    }
                }
                let received = Self.now()
                guard let type = body.first else { continue }
                let payload = Data(body.dropFirst())
                queue.async { [self] in
                    guard current == generation, number == nil || number == videoStreamNumber else { return }
                    lastHeard = received
                    switch type {
                    case 1: configure(payload)
                    case 2: decode(payload, received: received)
                    case 3: pong(payload)
                    case 23: showing(payload)
                    case MirrorMessage.simulators: simulators(payload)
                    case MirrorMessage.progress:
                        guard let progress = try? JSONDecoder().decode(MirrorSimulatorProgress.self, from: payload) else { return }
                        DispatchQueue.main.async { [weak self] in self?.onProgress?(progress) }
                    case MirrorMessage.screen:
                        guard let screen = try? JSONDecoder().decode(MirrorScreenState.self, from: payload) else { return }
                        DispatchQueue.main.async { [weak self] in self?.onScreen?(screen) }
                    case MirrorMessage.health:
                        guard let health = try? JSONDecoder().decode(MirrorSimulatorHealth.self, from: payload) else { return }
                        DispatchQueue.main.async { [weak self] in self?.onHealth?(health) }
                    case MirrorMessage.hostLoad:
                        guard let load = try? JSONDecoder().decode(MirrorHostLoad.self, from: payload) else { return }
                        DispatchQueue.main.async { [weak self] in self?.onHostLoad?(load) }
                    case MirrorMessage.builds:
                        guard let list = try? JSONDecoder().decode(MirrorBuildList.self, from: payload) else { return }
                        DispatchQueue.main.async { [weak self] in self?.onBuilds?(list.builds) }
                    case MirrorMessage.installIdentity:
                        guard let identity = try? JSONDecoder().decode(MirrorInstallIdentity.self, from: payload) else { return }
                        DispatchQueue.main.async { [weak self] in self?.onInstallIdentity?(identity) }
                    case MirrorMessage.installIdentityFailed:
                        guard let failure = try? JSONDecoder().decode(MirrorBuildFetchFailure.self, from: payload) else { return }
                        DispatchQueue.main.async { [weak self] in self?.onInstallIdentityFailed?(failure.message) }
                    case MirrorMessage.buildPiece:
                        guard let piece = MirrorBuildPiece(payload) else { return }
                        DispatchQueue.main.async { [weak self] in self?.onBuildPiece?(piece) }
                    case MirrorMessage.fetchFailed:
                        guard let failure = try? JSONDecoder().decode(MirrorBuildFetchFailure.self, from: payload) else { return }
                        DispatchQueue.main.async { [weak self] in self?.onFetchFailed?(failure) }
                    default: break
                    }
                }
            }
        } catch {}
    }

    /// A stream is starting, and the Mac says which simulator it shows.
    private func showing(_ payload: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return }
        let showing = Showing(udid: json["udid"] as? String ?? "", name: json["name"] as? String ?? "",
                              canChoose: json["chooser"] as? Bool ?? false, model: json["model"] as? String ?? "",
                              canRotate: json["rotates"] as? Bool ?? false, hasHinge: json["hinge"] as? Bool ?? false)
        watching = showing.udid.isEmpty ? nil : showing.udid
        decodedInWindow = 0
        bytesInWindow = 0
        DispatchQueue.main.async { [weak self] in self?.onShowing?(showing) }
    }

    /// The Mac's list of simulators. Whether it means the Mac is waiting for a choice, or only
    /// answers a question asked before a simulator was opened, is for the session to say: it
    /// calls `stoppedWatching()` when it is the first.
    private func simulators(_ payload: Data) {
        guard let list = try? JSONDecoder().decode(MirrorSimulatorList.self, from: payload) else { return }
        DispatchQueue.main.async { [weak self] in self?.onSimulators?(list) }
    }

    /// No simulator is being watched any more: a connection made again will not name one.
    func stoppedWatching() {
        queue.async { [self] in watching = nil }
    }

    private func send(_ type: UInt8, _ payload: Data, timely: Bool = false) {
        if timely, let connection {
            var datagram = Data(capacity: payload.count + 1)
            datagram.append(type)
            datagram.append(payload)
            try? connection.sendDatagram(data: datagram)
        } else if let control {
            var message = Data(capacity: payload.count + 5)
            message.put(UInt32(payload.count + 1))
            message.append(type)
            message.append(payload)
            control.yield(message)
        }
    }

    // MARK: Clock and reports

    private func periodic() {
        watchForNoConnection()
        guard let connection else { return }
        if appState == "active", Self.now() - lastHeard > Self.silenceLimit {
            // Closing it ends the wait in `connect`, which reports that it is reconnecting and tries again.
            lastHeard = Self.now()
            try? connection.close(errorCode: MirrorClose.timeout, reason: Data("no answer from the Mac".utf8))
            return
        }
        tick += 1
        var ping = Data()
        ping.put(Self.now())
        send(10, ping)
        guard tick % 2 == 0 else { return }
        sendInfo(timely: true)
        let path = connection.paths().first(where: { $0.isSelected })
        let stats = Stats(framesPerSecond: decodedInWindow, megabits: Double(bytesInWindow) * 8 / 1_000_000,
                          route: path.map { $0.isRelay ? "Relay" : "Direct" } ?? "",
                          roundTripMs: Int((roundTrip * 1000).rounded()), width: Int(videoSize.width), height: Int(videoSize.height))
        decodedInWindow = 0
        bytesInWindow = 0
        DispatchQueue.main.async { [weak self] in self?.onStats?(stats) }
    }

    private func pong(_ payload: Data) {
        guard payload.count >= 16 else { return }
        let sent = payload.read(Double.self, at: 0), hostTime = payload.read(Double.self, at: 8)
        let received = Self.now()
        // The Mac echoes the time this device sent, and adds its own. Numbers that are not
        // numbers, or a round trip no connection has, are dropped: turned into a whole number of
        // milliseconds for the figures on screen, one of them stopped the app.
        guard sent.isFinite, hostTime.isFinite, (0...60).contains(received - sent) else { return }
        clockSamples.append((received - sent, hostTime - (sent + received) / 2))
        if clockSamples.count > 20 { clockSamples.removeFirst() }
        if let best = clockSamples.min(by: { $0.roundTrip < $1.roundTrip }) {
            offset = best.offset
            roundTrip = best.roundTrip
        }
    }

    private func sendInfo(timely: Bool = false) {
        var info: [String: Any] = [
            "paneWidth": paneSize.width, "paneHeight": paneSize.height,
            "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "state": appState, "roundTripMs": roundTrip * 1000, "network": network, "displayHz": displayHertz,
            "chooser": true,        // this app can show the Mac's list of simulators
        ]
        if let watching { info["resume"] = watching }
        if let path = connection?.paths().first(where: { $0.isSelected }) {
            info["path"] = path.isRelay ? "relay" : "direct"
            info["pathRttMs"] = Int(path.rttMs)
        }
        if let data = try? JSONSerialization.data(withJSONObject: info) { send(13, data, timely: timely) }
    }

    private func requestKeyframe() {
        guard Self.now() - lastKeyRequest > 0.5 else { return }
        lastKeyRequest = Self.now()
        send(12, Data())
    }

    // MARK: Touch

    private func sendTouch(kind: UInt8, fractions: [CGPoint], at time: TimeInterval) {
        if kind == 1 || kind == 5 { gesture &+= 1; touchSequence = 0; recentMoves = [] }
        touchSequence &+= 1
        var payload = Data(capacity: 82)
        payload.append(kind)
        payload.append(UInt8(fractions.count))
        payload.put(gesture)
        payload.put(touchSequence)
        payload.put(Float32(fractions[0].x)); payload.put(Float32(fractions[0].y))
        let second = fractions.count > 1 ? fractions[1] : .zero
        payload.put(Float32(second.x)); payload.put(Float32(second.y))
        payload.put(time)
        payload.put(offset)
        if kind == 4 {
            // A move also carries the two before it, so the Mac can recover a move whose own message was lost.
            for earlier in recentMoves {
                payload.put(Float32(earlier.fractions[0].x)); payload.put(Float32(earlier.fractions[0].y))
                let other = earlier.fractions.count > 1 ? earlier.fractions[1] : .zero
                payload.put(Float32(other.x)); payload.put(Float32(other.y))
                payload.put(Float32(time - earlier.time))
            }
            recentMoves.insert((fractions, time), at: 0)
            if recentMoves.count > 2 { recentMoves.removeLast() }
        }
        // Moves are worthless late, so they go as datagrams. Downs and ups must arrive, so they go on
        // the reliable stream, and also as a datagram, which is usually first; the Mac uses whichever arrives.
        send(kind == 4 ? 41 : 40, payload, timely: kind == 4)
        if kind != 4 { send(41, payload, timely: true) }
    }

    // MARK: Video

    private func configure(_ payload: Data) {
        guard payload.count >= 6 else { return }
        let codec = payload[payload.startIndex]
        let width = Int(payload.read(UInt16.self, at: 1)), height = Int(payload.read(UInt16.self, at: 3))
        let count = Int(payload[payload.startIndex + 5])
        var sets: [Data] = []
        var cursor = 6
        for _ in 0..<count {
            guard payload.count >= cursor + 2 else { return }
            let length = Int(payload.read(UInt16.self, at: cursor))
            guard payload.count >= cursor + 2 + length else { return }
            sets.append(payload.subdata(in: (payload.startIndex + cursor + 2)..<(payload.startIndex + cursor + 2 + length)))
            cursor += 2 + length
        }
        guard !sets.isEmpty, width > 0, height > 0 else { return }
        let pointers: [UnsafePointer<UInt8>] = sets.map { set in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: pointer, count: set.count)
            return UnsafePointer(pointer)
        }
        defer { pointers.forEach { $0.deallocate() } }
        let sizes = sets.map(\.count)
        var created: CMVideoFormatDescription?
        if codec == 1 {
            CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                                                                parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                nalUnitHeaderLength: 4, formatDescriptionOut: &created)
        } else {
            CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                                                                parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &created)
        }
        guard let created else { return }
        let size = CGSize(width: width, height: height)
        if size != videoSize {
            videoSize = size
            DispatchQueue.main.async { [weak self] in self?.onVideoSize?(size) }
        }
        format = created
        if let session, VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: created) { return }
        var newSession: VTDecompressionSession?
        let attributes = [kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue] as CFDictionary
        let result = VTDecompressionSessionCreate(allocator: nil, formatDescription: created, decoderSpecification: nil,
                                                  imageBufferAttributes: attributes, outputCallback: nil,
                                                  decompressionSessionOut: &newSession)
        guard result == noErr, let newSession else {
            session = nil
            return
        }
        VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = newSession
    }

    private func decode(_ payload: Data, received: Double) {
        guard payload.count > 41 else { return }
        let frameID = payload.read(UInt64.self, at: 0)
        let isKey = payload[payload.startIndex + 32] == 1
        // Each frame names the one sent before it. If that is not the last one seen here, a frame was
        // lost and everything up to the next keyframe is unusable.
        let previous = payload.read(UInt64.self, at: 33)
        if let lastFrameID, previous != lastFrameID, !isKey { waitingForKey = true }
        lastFrameID = frameID
        if waitingForKey {
            guard isKey else { requestKeyframe(); return }
            waitingForKey = false
        }
        guard let session, let format else { waitingForKey = true; requestKeyframe(); return }
        let length = payload.count - 41
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
                                           blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                           dataLength: length, flags: 0, blockBufferOut: &block)
        guard let block else { return }
        payload.withUnsafeBytes { bytes in
            _ = CMBlockBufferReplaceDataBytes(with: bytes.baseAddress! + 41, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        var sample: CMSampleBuffer?
        var sampleSize = length
        CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                  sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                  sampleSizeArray: &sampleSize, sampleBufferOut: &sample)
        guard let sample else { return }
        var decodedAt = 0.0
        // Synchronous decode: the handler runs before this call returns, so frames stay in order.
        let result = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { [self] status, _, image, _, _ in
            guard status == noErr, let image else { return }
            decodedAt = Self.now()
            display(image)
        }
        guard result == noErr, decodedAt > 0 else {
            // The session is unusable (for example after the background); restart from a keyframe.
            self.session = nil
            waitingForKey = true
            requestKeyframe()
            return
        }
        decodedInWindow += 1
        bytesInWindow += length
        // Tells the Mac this frame arrived and when, which is what its bitrate rule runs on.
        var report = Data()
        report.put(frameID)
        report.put(received)
        report.put(decodedAt)
        report.put(offset)
        report.put(roundTrip)
        report.put(decodedAt)
        send(11, report, timely: true)
    }

    private func display(_ image: CVImageBuffer) {
        lastImage = image
        guard let sample = Self.sample(of: image) else { return }
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
        for mirror in mirrors {
            if mirror.status == .failed { mirror.flush() }
            mirror.enqueue(sample)
        }
    }

    /// A frame to show at once, whatever the renderer's clock says.
    private static func sample(of image: CVImageBuffer) -> CMSampleBuffer? {
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &description)
        guard let description else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescription: description,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

extension Data {
    mutating func put<T>(_ value: T) { Swift.withUnsafeBytes(of: value) { append(contentsOf: $0) } }

    func read<T>(_ type: T.Type, at offset: Int) -> T {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
    }
}
