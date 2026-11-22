#if AXE_MIRROR
import CoreMedia
import CoreVideo
@preconcurrency import FBControlCore
import FBSimulatorControl
import Foundation
import IOSurface
import VideoToolbox

/// One viewer's session with this Mac: the simulator it is shown, and the builds it is offered.
///
/// Every paired viewer has a session of its own (`MirrorHostSessions`), so any number are connected
/// at once and none takes another's place. A session outlives its viewer's connection: a viewer
/// that comes back finds the simulator it was watching still attached. A demo host has one session,
/// which its visitors share one at a time.
///
/// The simulator is the one the host was started with, or, on a host started without one, the one
/// the viewer chooses from the list it is sent (see `MirrorSimulatorList`). The viewer may change
/// it while connected. Two viewers may be shown the same simulator: each has its own picture of
/// it, and the touches of both reach it.
///
/// A simulator's framebuffer stays in its panel's own portrait shape when the simulator turns to
/// landscape: the interface is drawn on its side inside it. So the host reads which way the screen
/// is turned (see `watchRotation()`), turns each frame upright before encoding it, and turns the
/// viewer's touches back into the panel's coordinates (`MirrorInput.rotation`). The viewer sees an
/// upright picture of the right shape and needs to know nothing of it.
///
/// An iPhone Duo has two screens and lights one at a time. The host streams the lit one's own
/// framebuffer, moving to the other's when the Duo folds, aims touches at it, and tells the viewer
/// which screen it is and how far the hinge is open (`MirrorScreenState`). The viewer can fold it
/// (`MirrorFoldRequest`). See `MirrorLitScreen` for what was measured.
///
/// The simulator's screen is read from its framebuffer surface, scaled to the viewer's pane, encoded
/// as HEVC and sent over the link, one frame per screen change and never faster than the frame-rate
/// limit. Nothing is encoded while no viewer is attached. The viewer's touches are replayed into the
/// simulator by `MirrorInput`. All state here is touched on `queue` only.
final class MirrorSession: NSObject, @unchecked Sendable {
    struct Settings {
        var fps = 60.0
        var mbps = 6.0                  // the most the stream may use; the bitrate rule works below it
        var minMbps = 1.0
        var maxScale = 1.0              // upper limit on output size relative to the simulator's pixels
        var maxLagMs = 400.0            // stop encoding while the viewer is this far behind
        var relayStartMbps = 3.0        // where the bitrate starts on a relayed path
        var relayCeilingShare = 0.8     // rises stop at this share of a relay's known ceiling (0.9 on a direct path)
        var inputDelayMs = 25.0         // the shortest replay delay for touch moves
        var delayRule = "gestures"
        var replayLeadMs = 17.0
        var relayURLs: [String] = []    // our relays in order of preference; empty means iroh's public relays
        var relayRecord: String?        // stands in for the published relay list
        var relaySeed = ""              // decides which of several equally near relays this host uses
        var watchRelays = false         // choose again while running if the relay is lost or the list changes
        var viewers: MirrorViewers?     // only these viewers may connect; nil lets any viewer in (tests)
        var demo = false                // a demo host: see `MirrorDemo`
        var demoApp: String?            // the sample app a demo host keeps in front
        var relayOnly = false
        var avoidLocalNetwork = false   // macOS keeps this process off the local network: see `MirrorEndpoint.avoidsLocalNetwork`
        var assumeLocalNetworkBlocked = false   // tests: every later check also answers "blocked"
        var choosesSimulator = false    // started without a simulator: the viewer chooses, boots or creates one
        var builds: MirrorBuildCatalogue?   // app builds offered to the viewer to install on its own device
        var installIdentity = MirrorInstallIdentityStore.standard   // the certificate viewers serve builds to iOS with
    }

    private struct Frame {
        let encodeStart: TimeInterval
        let captureTime: TimeInterval
        var encodeDone: TimeInterval = 0
        var bytes = 0
        var reported = false
    }

    /// What the bitrate rule has learned about one path, relay or direct.
    private struct PathRate { var mbps = 0.0, ceiling = 0.0, hold: TimeInterval = 60, until: TimeInterval = 0, found: TimeInterval = 0 }

    private var settings: Settings
    private let queue = DispatchQueue(label: "axe.mirror")
    private var framebuffer: FBFramebuffer?
    private var tap: MirrorSurfaceTap?          // the attachment to `framebuffer`
    private var tapNumber = 0
    /// Every built-in screen's framebuffer: one, or two on an iPhone Duo.
    private var screens: [FBFramebuffer] = []
    private var lit: MirrorLitScreen?           // the screen streamed now, as last read
    private var hingeDegrees: Double?           // the Duo's hinge, as last read
    private var sentScreen: MirrorScreenState?
    private var retargetNumber = 0              // counts touch connections asked for; an older one that opens late is dropped
    private var foldNumber = 0                  // the newest fold asked for; an older one's result is dropped
    private var duo: FBSimulatorDuoControl?     // the Duo's hinge and the way it is held; see `MirrorFold`
    private var foldsUnderWay = 0               // folds asked for whose hinge is still being watched
    private var foldTask: Task<Void, Never>?    // the newest of them; a newer fold cancels it
    private var shutInnerSince: TimeInterval?   // since when a shut Duo has had its inner screen lit
    private var shutMended = false              // that has been put right once since the Duo was last open
    private var offeredBuilds: [MirrorBuild]?   // the builds last sent to this viewer; nil until it asks
    private var buildsTimer: DispatchSourceTimer?
    private var readingPiece = false            // a piece of a build is being read from the disk for this viewer
    private var pieceNumber = 0                 // counts connections; a piece read for an older one is dropped
    private let burst = MirrorBurst()           // the screen is read more often for a moment after a fold or a turn
    private var responsiveness = MirrorResponsiveness() // whether the simulator is answering; see `noteHealth`
    /// How busy this Mac is, as the host last found it; see `hostLoadChanged`.
    private var hostLoad = MirrorHostLoad(busy: false, load: 0, cpu: 0)
    private var hasHinge: Bool { screens.count > 1 }
    private var simulator: FBSimulator?
    /// This viewer's connection. The host hands it each connection the viewer makes.
    let link: MirrorLink
    private var input: MirrorInput?
    private var inputOpening = false            // the touch connection is being opened
    private var inputNumber = 0                 // counts attempts to open it; an older one's result is dropped
    private var inputFailures = 0               // attempts in a row that failed
    /// One event for the command to print: a name and its fields.
    var onEvent: (([String: String]) -> Void)?
    /// This viewer is about to shut down, delete or restart a simulator (its UDID, then the
    /// `MirrorSimulatorAction`), and, with `done`, has finished. The host tells its other viewers.
    var onManaging: ((_ udid: String, _ action: String, _ done: Bool) -> Void)?

    private var surface: IOSurface?
    private var lastSeed: UInt32 = 0
    private var damageTime: TimeInterval?
    private var lastEncodeStart: TimeInterval = 0
    private var encodeScheduled = false
    private var forceKey = true
    /// The screen as it is now has not reached the viewer: a frame was skipped or lost. It is sent
    /// again without waiting for the screen to change, which on a still screen it never does.
    private var owed = false
    private var owedCheck = false           // a look at `owed` is scheduled
    private var encoder: VTCompressionSession?
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    /// Which way the simulator's screen is turned, in degrees as its display reports it: 90 for
    /// landscape left, 270 for landscape right. Frames are turned upright by this much.
    private var rotation = 0
    private var rotationWatch: Task<Void, Never>?
    private var rotator: VTPixelRotationSession?
    private var unrotatedPool: CVPixelBufferPool?       // the scaled frame before it is turned
    private var targetWidth = 0, targetHeight = 0
    private var paneWidth = 0.0, paneHeight = 0.0
    private var resizeWork: DispatchWorkItem?
    private var sessionStarted = false
    private var streaming = false
    private var nextFrameID: UInt64 = 0
    private var frames: [UInt64: Frame] = [:]
    private var order: [UInt64] = []
    private var lastSentFrame = UInt64.max
    private var unacked: [UInt64] = []      // frames sent and not yet reported back by the viewer
    private var waitingOnViewer = false
    private var videoGeneration = 0         // counts video stream restarts; frames encoded for an older one are dropped
    private var viewerNetwork = ""
    private var adaptTimer: DispatchSourceTimer?
    private var lastKeyframeRequest: TimeInterval = 0   // when a keyframe the viewer asked for was last made
    private var keyframeQueued = false
    /// The least time between two keyframes made because the viewer asked.
    static let keyframeSpacing: TimeInterval = 0.25
    private var blockedGesture: UInt32?     // demo only: the gesture now being dropped
    private var demoLock: MirrorDemoLock?   // demo only: keeps the visitor inside the sample app
    /// The host cannot go on: the message says why.
    var onFatal: ((String) -> Void)?

    // The bitrate rule's state; see `adaptBitrate()`.
    private var currentMbps = 0.0
    private var lastBehind: TimeInterval = 0, lastRaise: TimeInterval = 0, lastCut: TimeInterval = 0
    private var ackLog: [(time: TimeInterval, bytes: Int, age: TimeInterval)] = []
    private var ageHistory: [TimeInterval] = []
    private var growingChecks = 0, behindChecks = 0
    private var ceilingMbps = 0.0
    private var ceilingHold: TimeInterval = 60
    private var ceilingUntil: TimeInterval = 0
    private var ceilingFound: TimeInterval = 0
    private var lastCleanMbps = 0.0
    private var lastOverloadMbps = 0.0
    private var lastOverloadTime: TimeInterval = 0
    private var onRelay = true              // a connection starts on the relay and moves to a direct path if one opens
    private var otherPath = PathRate()

    // A host that lets the viewer choose; see `greet(_:)` and `choose(_:)`.
    private var greeted = false             // this connection's first viewer info has been dealt with
    private var awaitingChoice = false      // the viewer is at the list: nothing is streamed until it has chosen
    private var choiceNumber = 0            // counts choices and connections; the result of an older choice is dropped

    /// `simulator` and `framebuffer` are nil on a host that lets the viewer choose. The framebuffer
    /// is this session's own: two sessions showing one simulator each read its screen themselves.
    init(simulator: FBSimulator?, framebuffer: FBFramebuffer?, settings: Settings) {
        self.simulator = simulator
        self.framebuffer = framebuffer
        self.settings = settings
        link = MirrorLink(queue: queue)
        super.init()
    }

    /// Whether this session's viewer is connected now.
    var hasViewer: Bool { link.hasViewer }

    func start() {
        queue.sync {
            if let framebuffer {
                attach(framebuffer)
                loadScreens()
                startInput()
            }
            link.onNote = { mirrorNote($0) }
            if settings.demo, let app = settings.demoApp, let simulator {
                let lock = MirrorDemoLock(simulator: simulator, app: app) { mirrorNote($0) }
                lock.onAppMissing = { [weak self] in
                    self?.onFatal?("The demo's sample app \(app) could not be started on the simulator. Install it and start the demo again.")
                }
                demoLock = lock
            }
            link.onConnected = { [weak self] in
                self?.endSession()
                // A viewer is here to touch it: do not make it wait out a retry that is counting down.
                if let self, self.input == nil, !self.inputOpening, self.simulator != nil {
                    self.inputFailures = 0
                    self.startInput()
                }
                self?.onEvent?(["event": "viewerConnected"])
                self?.demoLock?.visitorArrived()
            }
            link.onMessage = { [weak self] type, payload in self?.handle(type: type, payload: payload) }
            link.onClosed = { [weak self] in
                self?.endSession()
                self?.demoLock?.visitorLeft()
                self?.onEvent?(["event": "viewerDisconnected"])
            }
            link.onPathSelected = { [weak self] relay in self?.pathChanged(toRelay: relay) }
            if settings.demo { link.turnsAwayWhileBusy = { MirrorDemo.isBusy(connectedFor: $0) } }
            let adapt = DispatchSource.makeTimerSource(queue: queue)
            adapt.schedule(deadline: .now() + 0.25, repeating: 0.25)
            adapt.setEventHandler { [weak self] in self?.adaptBitrate() }
            adapt.resume()
            adaptTimer = adapt
        }
    }

    /// The Mac's own network link, as the host's probe found it: the viewer shows it under its
    /// other figures.
    func linkHealth(_ short: String) {
        queue.async { self.sendControl(24, Data(short.utf8)) }
    }

    /// How busy the Mac is, as the host samples it. The viewer is told when it becomes busy or
    /// stops being busy: a simulator that is slow on a busy Mac may be starved rather than stuck,
    /// and the viewer says so.
    func hostLoadChanged(_ load: MirrorHostLoad, tell: Bool) {
        queue.async {
            self.hostLoad = load
            if tell, self.sessionStarted { self.send(MirrorMessage.hostLoad, json: load) }
        }
    }

    /// Stops streaming and closes the viewer's connection, so that it notices at once. `reason` and
    /// `code` are what the viewer is told: the host stopped, or the viewer is no longer paired.
    func stop(reason: String = "host stopped", code: Int64 = MirrorClose.stopped) {
        rotationWatch?.cancel()
        queue.sync {
            adaptTimer?.cancel()
            adaptTimer = nil
            endSession()
            detachFramebuffer()
            if let encoder { VTCompressionSessionInvalidate(encoder) }
            encoder = nil
        }
        demoLock?.visitorLeft()
        link.close(reason: reason, code: code)
    }

    /// Opens the simulator's touch connection, unless it is open or being opened. Called when a
    /// simulator is attached, and again whenever there is still none: when the screen's surface
    /// first arrives, when a viewer connects, and a while after an attempt has failed (2 seconds,
    /// then twice as long each time, up to 30). Without that, one failure, or a surface that was
    /// not there yet, left the session showing video and dropping every touch until the host was
    /// started again.
    private func startInput() {
        guard let surface, let simulator, input == nil, !inputOpening else { return }
        inputOpening = true
        inputNumber += 1
        let number = inputNumber
        let scale = Double(simulator.screenInfo?.scale ?? 3)
        var width = Double(IOSurfaceGetWidth(surface)) / scale, height = Double(IOSurfaceGetHeight(surface)) / scale
        let aimed = hasHinge
        Task { [self] in
            do {
                // An iPhone Duo's touches go on a connection aimed at the lit screen, in its upright points.
                let hid: FBSimulatorHID
                if aimed, let screen = await MirrorLitScreen.read(for: simulator) {
                    hid = try await FBSimulatorHID.ready(for: simulator, displayContext: try screen.context())
                    width = screen.logicalWidth
                    height = screen.logicalHeight
                    queue.async { self.lit = self.lit ?? screen }
                } else {
                    hid = try await FBSimulatorHID.ready(for: simulator)
                }
                let owner = MirrorInput(hid: hid, width: width, height: height, hertz: 60, delay: settings.inputDelayMs / 1000, oriented: aimed)
                owner.delayRule = settings.delayRule
                owner.lead = settings.replayLeadMs / 1000
                owner.onResult = { [weak self] ok in self?.queue.async { self?.noteHealth { $0.touch(ok: ok) } } }
                queue.async {
                    // The viewer may have moved to another simulator while this one's input was opening.
                    guard number == self.inputNumber, self.simulator === simulator else { owner.close(); return }
                    self.inputOpening = false
                    self.inputFailures = 0
                    owner.rotation = self.rotation
                    self.input = owner
                    self.noteHealth { $0.input(ready: true) }
                }
                mirrorNote("input ready: \(Int(width))x\(Int(height)) points\(aimed ? ", aimed at the lit screen" : "")")
            } catch {
                queue.async {
                    guard number == self.inputNumber, self.simulator === simulator else { return }
                    self.inputOpening = false
                    self.inputFailures += 1
                    let wait = MirrorSession.inputRetryDelay(afterFailures: self.inputFailures)
                    mirrorNote("input unavailable: \(error); trying again in \(Int(wait)) s")
                    self.queue.asyncAfter(deadline: .now() + wait) { [weak self] in
                        guard let self, number == self.inputNumber, self.simulator === simulator else { return }
                        self.startInput()
                    }
                }
            }
        }
        // A stuck simulator's touch connection neither opens nor fails.
        queue.asyncAfter(deadline: .now() + MirrorResponsiveness.inputDeadline) { [weak self] in
            guard let self, self.simulator === simulator, self.input == nil else { return }
            self.noteHealth { $0.input(ready: false) }
        }
    }

    /// How long after a failed attempt to open the touch connection the next one is made.
    static func inputRetryDelay(afterFailures failures: Int) -> TimeInterval {
        min(30, 2 * pow(2, Double(max(1, failures) - 1)))
    }

    // MARK: Framebuffer callbacks (on `queue`)

    /// Starts taking `framebuffer`'s frames, in place of any other's.
    private func attach(_ framebuffer: FBFramebuffer) {
        detachFramebuffer()
        tapNumber += 1
        let tap = MirrorSurfaceTap(number: tapNumber,
            changed: { [weak self] number, surface in self?.didChange(surface, tap: number) },
            damaged: { [weak self] number in self?.didReceiveDamage(tap: number) })
        self.framebuffer = framebuffer
        self.tap = tap
        surface = framebuffer.attach(tap, on: queue)
    }

    private func detachFramebuffer() {
        if let tap { framebuffer?.detach(tap) }
        tap = nil
    }

    /// Finds every built-in screen's framebuffer. Only an iPhone Duo has more than one.
    private func loadScreens() {
        guard let simulator else { screens = []; return }
        let logger = FBControlCoreLoggerFactory.systemLoggerWriting(toStderr: false, withDebugLogging: false)
        screens = (try? FBFramebuffer.builtInDisplaySurfaces(for: simulator, logger: logger)) ?? []
        if screens.count > 1 { mirrorNote("two screens: the picture follows the lit one") }
    }

    private func didChange(_ surface: IOSurface?, tap number: Int) {
        guard number == tapNumber else { return }
        self.surface = surface
        forceKey = true
        // The surface was not there when the simulator was attached: its touches can be opened now.
        if surface != nil, input == nil { startInput() }
        if sessionStarted { rebuild() }
        frameReady()
    }

    private func didReceiveDamage(tap number: Int) {
        guard number == tapNumber else { return }
        frameReady()
    }

    private func frameReady() {
        // Without a viewer nothing is encoded, so a frame's age only counts from when one is attached.
        guard streaming else { return }
        if damageTime == nil { damageTime = mirrorNow() }
        scheduleEncode(recheck: 0)
    }

    /// Encodes at once if the frame-rate limit allows, otherwise at the next allowed moment.
    private func scheduleEncode(recheck: Int) {
        guard streaming, !encodeScheduled else { return }
        // Allow a little under one frame interval, so a frame that arrives slightly early is not pushed back.
        let delay = lastEncodeStart + 0.8 / settings.fps - mirrorNow()
        if delay <= 0 {
            encode(recheck: recheck)
        } else {
            encodeScheduled = true
            queue.asyncAfter(deadline: .now() + delay) { [self] in
                encodeScheduled = false
                encode(recheck: recheck)
            }
        }
    }

    // MARK: Scaling and encoding

    /// True when frames are turned a quarter, so that the picture's width is the panel's height.
    private var quarterTurned: Bool { rotation == 90 || rotation == 270 }

    /// The output size: the simulator's pixels, turned upright, scaled to fit the viewer's pane,
    /// never above native.
    private func fittedSize() -> (Int, Int)? {
        guard let surface else { return nil }
        let panelWidth = Double(IOSurfaceGetWidth(surface)), panelHeight = Double(IOSurfaceGetHeight(surface))
        let sourceWidth = quarterTurned ? panelHeight : panelWidth, sourceHeight = quarterTurned ? panelWidth : panelHeight
        var scale = settings.maxScale
        if paneWidth > 0, paneHeight > 0 {
            scale = min(scale, paneWidth / sourceWidth, paneHeight / sourceHeight)
        }
        // Even dimensions, width snapped to 16 px so small pane changes do not rebuild the encoder.
        var width = max(160, Int((sourceWidth * scale / 16).rounded()) * 16)
        var height = Int((Double(width) * sourceHeight / sourceWidth / 2).rounded()) * 2
        if scale >= 0.999 || width > Int(sourceWidth) { width = Int(sourceWidth) & ~1; height = Int(sourceHeight) & ~1 }
        return (width, height)
    }

    private func rebuild() {
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        encoder = nil
        transfer = nil
        pool = nil
        rotator = nil
        unrotatedPool = nil
        guard let size = fittedSize() else { return }
        (targetWidth, targetHeight) = size
        if rotation != 0 {
            // The frame is scaled in the panel's shape, then turned into the picture's.
            let unrotated: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey: quarterTurned ? targetHeight : targetWidth,
                kCVPixelBufferHeightKey: quarterTurned ? targetWidth : targetHeight,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            var createdPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, unrotated as CFDictionary, &createdPool)
            unrotatedPool = createdPool
            var session: VTPixelRotationSession?
            VTPixelRotationSessionCreate(nil, &session)
            if let session {
                // A screen turned to landscape left has its interface drawn a quarter turn anticlockwise.
                let turn = rotation == 90 ? kVTRotation_CW90 : rotation == 270 ? kVTRotation_CCW90 : kVTRotation_180
                VTSessionSetProperty(session, key: kVTPixelRotationPropertyKey_Rotation, value: turn)
            }
            rotator = session
        }

        var transferSession: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transferSession)
        transfer = transferSession
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: targetWidth,
            kCVPixelBufferHeightKey: targetHeight,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var createdPool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &createdPool)
        pool = createdPool
        forceKey = true

        var created: VTCompressionSession?
        let lowLatency = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue] as CFDictionary
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(targetWidth), height: Int32(targetHeight),
                                                codecType: kCMVideoCodecType_HEVC, encoderSpecification: lowLatency, imageBufferAttributes: nil,
                                                compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                                compressionSessionOut: &created)
        guard status == noErr, let created else {
            mirrorNote("cannot create the video encoder: \(status)")
            onEvent?(["event": "error", "message": "The video encoder could not be created (\(status))."])
            return
        }
        func set(_ key: CFString, _ value: CFTypeRef) {
            let result = VTSessionSetProperty(created, key: key, value: value)
            if result != noErr { mirrorNote("encoder property \(key) refused: \(result)") }
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        // A rebuilt encoder keeps the rate the bitrate rule had reached.
        set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: Int((currentMbps > 0 ? min(currentMbps, settings.mbps) : settings.mbps) * 1_000_000)))
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: settings.fps))
        // Keyframes are sent when the viewer asks or the stream restarts, so the encoder's own interval is very long.
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: 100_000))
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
        VTCompressionSessionPrepareToEncodeFrames(created)
        encoder = created
        mirrorNote("encoder hevc \(targetWidth)x\(targetHeight), low-latency\(rotation == 0 ? "" : ", turned \(rotation)°")")
        onEvent?(["event": "streaming", "width": String(targetWidth), "height": String(targetHeight)])
    }

    private func encode(recheck: Int) {
        guard streaming, let surface else { return }
        if pool == nil { rebuild() }
        guard let transfer, let pool, let encoder else { return }

        // A callback can arrive before the surface content changes; look again shortly.
        let seed = IOSurfaceGetSeed(surface)
        if seed == lastSeed, !forceKey, !owed {
            if recheck < 3 {
                queue.asyncAfter(deadline: .now() + 0.003) { [self] in encode(recheck: recheck + 1) }
            } else {
                damageTime = nil
            }
            return
        }
        // Skip, rather than queue, when the link has not taken earlier frames. The screen is then
        // ahead of what was sent, and may not change again: look once more shortly.
        guard link.videoBacklog <= 2 else { oweFrame(after: 0.05); return }
        // Skip while the viewer is far behind, so a slow link costs frames and not a growing delay.
        // Encoding resumes from the current screen when the viewer's reports catch up.
        if let oldest = unacked.first, let sent = frames[oldest]?.encodeDone, sent > 0 {
            let age = mirrorNow() - sent
            if age > 3 {
                unacked.removeAll()     // reports stopped coming; do not wait for them forever
            } else if settings.maxLagMs > 0, age > settings.maxLagMs / 1000 {
                // Its report restarts the encoding. Reports are datagrams and can be lost, so
                // this is looked at again without one.
                waitingOnViewer = true
                damageTime = nil
                oweFrame(after: 0.5)
                return
            }
        }
        owed = false
        lastSeed = seed
        let start = mirrorNow()
        let captured = damageTime ?? start
        damageTime = nil
        lastEncodeStart = start

        var unmanagedSource: Unmanaged<CVPixelBuffer>?
        CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface, nil, &unmanagedSource)
        // A frame that cannot be made is owed: `lastSeed` already says this screen was dealt with.
        guard let source = unmanagedSource?.takeRetainedValue() else { oweFrame(after: 0.1); return }
        var destination: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination)
        guard let destination else { oweFrame(after: 0.1); return }
        if let rotator, let unrotatedPool {
            var scaled: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, unrotatedPool, &scaled)
            guard let scaled, VTPixelTransferSessionTransferImage(transfer, from: source, to: scaled) == noErr,
                  VTPixelRotationSessionRotateImage(rotator, scaled, destination) == noErr else { oweFrame(after: 0.1); return }
        } else {
            guard VTPixelTransferSessionTransferImage(transfer, from: source, to: destination) == noErr else { oweFrame(after: 0.1); return }
        }

        let wantKey = forceKey
        forceKey = false
        let frameID = nextFrameID
        nextFrameID += 1
        frames[frameID] = Frame(encodeStart: start, captureTime: captured)
        order.append(frameID)
        // Only recent frames are ever looked up again.
        if order.count > 2000 {
            for old in order.prefix(1000) { frames[old] = nil }
            order.removeFirst(1000)
        }

        let properties = wantKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        let generation = videoGeneration
        VTCompressionSessionEncodeFrame(encoder, imageBuffer: destination,
                                        presentationTimeStamp: CMTime(seconds: start, preferredTimescale: 1_000_000),
                                        duration: .invalid, frameProperties: properties, infoFlagsOut: nil) { [weak self] status, _, sample in
            let done = mirrorNow()
            guard let self else { return }
            guard status == noErr, let sample else {
                // The encoder dropped the frame, as its rate control may: the viewer has not got it.
                self.queue.async { if generation == self.videoGeneration { self.oweFrame(after: 0.05) } }
                return
            }
            self.queue.async {
                // A frame encoded for a stream that has since been replaced would arrive ahead of the new keyframe.
                guard generation == self.videoGeneration else { return }
                self.send(sample: sample, frameID: frameID, encodeDone: done)
            }
        }
    }

    /// Notes that the screen as it is now did not reach the viewer, and looks again after `delay`:
    /// by then the link may have room, the viewer may have caught up, or the encoder may take it.
    /// One look is scheduled at a time, and each look that fails schedules the next.
    private func oweFrame(after delay: TimeInterval) {
        owed = true
        guard !owedCheck else { return }
        owedCheck = true
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            owedCheck = false
            guard streaming, owed else { return }
            encode(recheck: 3)
        }
    }

    private func parameterSets(of format: CMFormatDescription) -> [Data] {
        var sets: [Data] = []
        var count = 0
        func fetch(_ index: Int) -> Data? {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                            parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            guard status == noErr, let pointer else { return nil }
            return Data(bytes: pointer, count: size)
        }
        guard let first = fetch(0) else { return [] }
        sets.append(first)
        for index in 1..<max(1, count) { if let next = fetch(index) { sets.append(next) } }
        return sets
    }

    private func send(sample: CMSampleBuffer, frameID: UInt64, encodeDone: TimeInterval) {
        guard streaming, let block = CMSampleBufferGetDataBuffer(sample),
              let format = CMSampleBufferGetFormatDescription(sample), var frame = frames[frameID] else { return }
        var isKey = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let notSync = attachments.first?[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKey = !notSync
        }
        let length = CMBlockBufferGetDataLength(block)
        var bytes = Data(count: length)
        bytes.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }

        var out = Data()
        if isKey {
            // The decoder configuration rides with every keyframe, so a viewer can start at any of them.
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            var config = Data()
            config.put(UInt8(2))        // HEVC
            config.put(UInt16(dimensions.width))
            config.put(UInt16(dimensions.height))
            let sets = parameterSets(of: format)
            config.put(UInt8(sets.count))
            for set in sets { config.put(UInt16(set.count)); config.append(set) }
            out.append(mirrorMessage(type: 1, payload: config))
        }
        var payload = Data(capacity: length + 41)
        payload.put(frameID)
        payload.put(frame.captureTime)
        payload.put(frame.encodeStart)
        payload.put(encodeDone)
        payload.put(UInt8(isKey ? 1 : 0))
        // The frame sent before this one. The encoder may drop frames, so frame numbers alone have gaps.
        payload.put(lastSentFrame)
        lastSentFrame = frameID
        payload.append(bytes)
        out.append(mirrorMessage(type: 2, payload: payload))

        frame.encodeDone = encodeDone
        frame.bytes = length
        frames[frameID] = frame
        unacked.append(frameID)
        link.sendVideo(out)
    }

    // MARK: Bitrate

    /// Four times a second: decides whether the stream is too big for the link.
    ///
    /// The measure is the age of the oldest frame the viewer has not yet reported, against the usual
    /// age (the lowest of the last ten seconds), and how fast it is growing.
    ///
    /// Overload is one of two things. Either the age is 100 ms above usual and rising steadily for
    /// three checks: a queue is building. A rise of a full second per second means nothing is getting
    /// through at all, which is a stall and not a throughput limit, so slopes of 0.8 and over do not
    /// count. Or the age has been 60 ms above usual for three seconds without a break: a queue that
    /// will not drain.
    ///
    /// On overload the target drops 15%, or to nine tenths of what the viewer really received when
    /// the queue is building fast, but never more than 30% at once. Two overloads at about the same
    /// rate within a minute mark a ceiling: rises then stop below it for a minute, and for twice as
    /// long each time a later probe finds it again, up to five minutes. After three quiet seconds the
    /// target rises by 8%.
    ///
    /// A relay and a direct path are different links, so each keeps its own target and ceiling. On a
    /// relay the stream starts low and rises stop at eight tenths of a known ceiling, where a direct
    /// path starts at the full rate and stops at nine tenths.
    private func adaptBitrate() {
        guard streaming, encoder != nil else { return }
        let time = mirrorNow()
        if currentMbps == 0 {
            currentMbps = settings.mbps
            if onRelay, settings.relayStartMbps < settings.mbps { setBitrate(settings.relayStartMbps, why: "starting on a relay") }
        }
        ackLog.removeAll { time - $0.time > 10 }
        let usual = ackLog.map(\.age).min() ?? 0.05
        var age = 0.0
        if let oldest = unacked.first, let sent = frames[oldest]?.encodeDone, sent > 0 { age = time - sent }
        let previous = ageHistory.last ?? age
        let earlier = ageHistory.count >= 2 ? ageHistory[ageHistory.count - 2] : previous
        ageHistory.append(age)
        if ageHistory.count > 8 { ageHistory.removeFirst() }
        let slope = (age - earlier) / 0.5, lastSlope = (age - previous) / 0.25
        let building = age > usual + 0.1 && slope > 0.03 && slope < 0.8 && lastSlope > 0 && lastSlope < 0.8
        growingChecks = building ? growingChecks + 1 : 0
        behindChecks = age > usual + 0.06 ? behindChecks + 1 : 0
        if age > usual + 0.06 { lastBehind = time }
        var target = currentMbps
        var why = ""
        // A ceiling is remembered for ten minutes after it stops capping rises. Near it, a queue that
        // will not drain is believed after one second, not three.
        let known = ceilingMbps > 0 && time - ceilingFound < 600
        let nearCeiling = known && currentMbps > ceilingMbps * 0.92
        if growingChecks >= 3 || behindChecks >= (nearCeiling ? 4 : 12), time - lastCut > 1.5 {
            why = growingChecks >= 3 ? "queue building" : "behind"
            let rate = currentMbps
            let held = time < ceilingUntil
            let similar = lastOverloadMbps > 0 && time - lastOverloadTime < 60 && abs(rate - lastOverloadMbps) < 0.12 * lastOverloadMbps
            let delivered = Double(ackLog.filter { time - $0.time <= 1 }.reduce(0) { $0 + $1.bytes }) * 8 / 1_000_000
            target = rate * 0.85
            if known, rate >= ceilingMbps * 0.95, time - ceilingFound < 5 {
                // Still the same episode: the cut below is enough.
            } else if known, rate >= ceilingMbps * 0.95 {
                // A probe found the ceiling again: trust it for twice as long. If the rate before the
                // last rise ran clean above the remembered ceiling, the ceiling was set too low.
                ceilingMbps = min(rate, max(ceilingMbps, lastCleanMbps))
                ceilingHold = min(300, ceilingHold * 2)
                ceilingUntil = time + ceilingHold
                ceilingFound = time
                why += ", ceiling found again"
            } else if similar, !held || rate < ceilingMbps * 0.88 {
                ceilingMbps = min(rate, lastOverloadMbps)
                ceilingHold = 60
                ceilingUntil = time + ceilingHold
                ceilingFound = time
                why += ", ceiling set"
            } else if !known, growingChecks >= 3, slope > 0.15, delivered > 0.3 {
                // Far too much is being sent and nothing is known about the link yet: what the viewer
                // received in the last second is the link's capacity, near enough to start from.
                ceilingMbps = delivered
                ceilingHold = 30
                ceilingUntil = time + ceilingHold
                ceilingFound = time
                target = max(rate * 0.5, delivered * 0.88)
                why += ", ceiling taken from what arrived"
            } else if growingChecks >= 3, slope > 0.15 {
                target = max(rate * 0.7, min(target, delivered * 0.9))
            }
            lastOverloadMbps = rate
            lastOverloadTime = time
            if onRelay, ceilingMbps > 0, time - ceilingFound < 600 { target = min(target, ceilingMbps * settings.relayCeilingShare) }
            target = max(settings.minMbps, target)
            lastCut = time
            growingChecks = 0
            behindChecks = 0
        } else if time - lastBehind > 3, time - lastRaise > 3, time - lastCut > 3, currentMbps < settings.mbps {
            var limit = settings.mbps
            if time < ceilingUntil { limit = min(limit, ceilingMbps * (onRelay ? settings.relayCeilingShare : 0.9)) }
            target = max(currentMbps, min(limit, currentMbps * 1.08))
            if target > currentMbps { lastCleanMbps = currentMbps }
            lastRaise = time
        }
        guard target != currentMbps else { return }
        setBitrate(target, why: String(format: "oldest %.0f ms, usual %.0f ms, slope %.2f%@", age * 1000, usual * 1000, slope, why.isEmpty ? "" : "; " + why))
    }

    private func setBitrate(_ target: Double, why: String) {
        currentMbps = target
        if let encoder { VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: Int(target * 1_000_000))) }
        mirrorNote(String(format: "bitrate %.2f Mbps (%@)", target, why))
    }

    /// The connection moved between the relay and a direct path. What was learned about the path left
    /// is put aside, and the rule carries on from what it knew about the path arrived at, or from
    /// that path's starting rate.
    private func pathChanged(toRelay: Bool) {
        onEvent?(["event": "path", "kind": toRelay ? "relay" : "direct"])
        guard toRelay != onRelay else { return }
        let time = mirrorNow()
        let arriving = otherPath
        otherPath = PathRate(mbps: currentMbps, ceiling: ceilingMbps, hold: ceilingHold, until: ceilingUntil, found: ceilingFound)
        onRelay = toRelay
        ceilingMbps = arriving.ceiling; ceilingHold = arriving.hold; ceilingUntil = arriving.until; ceilingFound = arriving.found
        growingChecks = 0; behindChecks = 0; ageHistory = []
        lastOverloadMbps = 0; lastCleanMbps = 0
        lastCut = time      // a moment's grace: what is queued was sent into the old path
        guard streaming, currentMbps > 0 else { return }
        let start = toRelay ? min(settings.mbps, settings.relayStartMbps) : settings.mbps
        let target = min(settings.mbps, arriving.mbps > 0 ? arriving.mbps : start)
        if target != currentMbps { setBitrate(target, why: toRelay ? "path now a relay" : "path now direct") }
    }

    // MARK: The viewer's messages (on `queue`)

    private func sendControl(_ type: UInt8, _ payload: Data) {
        link.sendControl(mirrorMessage(type: type, payload: payload))
    }

    private func handle(type: UInt8, payload: Data) {
        switch type {
        case 10 where payload.count >= 8:   // ping: echo the viewer's time with ours
            var reply = Data()
            reply.put(payload.read(Double.self, at: 0))
            reply.put(mirrorNow())
            sendControl(3, reply)
        case 11 where payload.count >= 8:   // frame report
            let frameID = payload.read(UInt64.self, at: 0)
            guard var frame = frames[frameID], !frame.reported else { return }
            frame.reported = true
            frames[frameID] = frame
            if frame.encodeDone > 0 { ackLog.append((mirrorNow(), frame.bytes, mirrorNow() - frame.encodeDone)) }
            if let index = unacked.firstIndex(where: { $0 > frameID }) { unacked.removeFirst(index) } else { unacked.removeAll() }
            if waitingOnViewer {
                waitingOnViewer = false
                encode(recheck: 3)
            }
        case 12:    // keyframe request
            // A keyframe costs many times what another frame does, so a viewer gets them no faster
            // than `keyframeSpacing`, and through the frame-rate limit like any other frame. One
            // asked for sooner is made when its time comes.
            unacked.removeAll()
            let wait = lastKeyframeRequest + Self.keyframeSpacing - mirrorNow()
            if wait <= 0 {
                lastKeyframeRequest = mirrorNow()
                forceKey = true
                scheduleEncode(recheck: 3)
            } else if !keyframeQueued {
                keyframeQueued = true
                queue.asyncAfter(deadline: .now() + wait) { [self] in
                    keyframeQueued = false
                    guard streaming else { return }
                    lastKeyframeRequest = mirrorNow()
                    forceKey = true
                    scheduleEncode(recheck: 3)
                }
            }
        case 13:    // viewer info: its network and the size of its pane
            guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return }
            if let network = json["network"] as? String, network != viewerNetwork {
                viewerNetwork = network
                mirrorNote("viewer network \(network)")
            }
            var changed = false
            if let width = json["paneWidth"] as? Double, let height = json["paneHeight"] as? Double, width > 0, height > 0 {
                changed = abs(width - paneWidth) > 1 || abs(height - paneHeight) > 1
                paneWidth = width
                paneHeight = height
            }
            if settings.choosesSimulator, !greeted {
                greeted = true
                greet(json)
            }
            guard paneWidth > 0, paneHeight > 0 else { return }
            if !sessionStarted {
                startSessionIfReady()
            } else if changed {
                // Wait for the pane to settle before paying for a new encoder and a keyframe.
                resizeWork?.cancel()
                let work = DispatchWorkItem { [self] in
                    guard let size = fittedSize(), size != (targetWidth, targetHeight) else { return }
                    rebuild()
                    encode(recheck: 3)
                }
                resizeWork = work
                queue.asyncAfter(deadline: .now() + 0.3, execute: work)
            }
        case 30 where !settings.demo:   // profile chosen in the viewer: frame rate, bitrate and scale, applied at once
            guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return }
            if let fps = json["fps"] as? Double, fps >= 10, fps <= 120 { settings.fps = fps }
            if let mbps = json["mbps"] as? Double, mbps >= settings.minMbps, mbps <= 50 { settings.mbps = mbps }
            if let scale = json["scale"] as? Double, scale > 0, scale <= 1 { settings.maxScale = scale }
            mirrorNote("profile: \(Int(settings.fps)) fps, \(settings.mbps) Mbps, scale limit \(settings.maxScale)")
            guard sessionStarted else { return }
            rebuild()
            encode(recheck: 3)
        case 40, 41:    // touch
            let time = mirrorNow()
            if let message = MirrorTouch(payload, received: time) {
                if settings.demo {
                    // A touch that starts at the top or bottom edge, or while another app than the
                    // sample app is in front, is dropped whole, down to up.
                    if message.isDown {
                        let edge = MirrorDemo.blocksTouch(downAt: message.y1) || (message.contacts > 1 && MirrorDemo.blocksTouch(downAt: message.y2))
                        blockedGesture = edge || demoLock?.allowsInput == false ? message.gesture : nil
                    }
                    if message.gesture == blockedGesture { return }
                }
                input?.receive(message)
                for earlier in MirrorTouch.history(in: payload, received: time) { input?.receive(earlier) }
            }
        case MirrorMessage.list where settings.choosesSimulator:
            sendSimulatorList()
        case MirrorMessage.choose where settings.choosesSimulator:
            guard let choice = try? JSONDecoder().decode(MirrorSimulatorChoice.self, from: payload) else { return }
            choose(choice)
        case MirrorMessage.leave where settings.choosesSimulator:
            choiceNumber += 1       // a choice still under way is dropped
            release()
            awaitingChoice = true
            sendSimulatorList()
        case MirrorMessage.manage where settings.choosesSimulator:
            guard let request = try? JSONDecoder().decode(MirrorSimulatorAction.self, from: payload) else { return }
            manage(request)
        case MirrorMessage.rotate where !settings.demo:
            guard let request = try? JSONDecoder().decode(MirrorRotationRequest.self, from: payload) else { return }
            rotate(to: request.to)
        case MirrorMessage.fold where !settings.demo:
            guard let request = try? JSONDecoder().decode(MirrorFoldRequest.self, from: payload) else { return }
            fold(request)
        case 43 where payload.count >= 2 && !settings.demo:   // a hardware button pressed in the viewer: button, number of presses
            input?.press(button: payload[payload.startIndex], count: payload[payload.startIndex + 1])
        case MirrorMessage.listBuilds where !settings.demo:
            watchBuilds()
        case MirrorMessage.installIdentityRequest where !settings.demo:
            sendInstallIdentity()
        case MirrorMessage.fetchBuild where !settings.demo:
            guard let request = try? JSONDecoder().decode(MirrorBuildFetch.self, from: payload) else { return }
            sendBuildPiece(request)
        case MirrorMessage.installing where !settings.demo:
            guard let request = try? JSONDecoder().decode(MirrorBuildInstall.self, from: payload),
                  let build = offeredBuilds?.first(where: { $0.id == request.id }) else { return }
            mirrorNote("the viewer is installing \(build.name) \(build.versionText)")
            onEvent?(["event": "installRequested", "bundleID": build.bundleID, "name": build.name, "version": build.version, "build": build.build])
        default:
            break
        }
    }

    // MARK: Builds to install (on `queue`)

    /// Sends the viewer the builds on offer, and from then on reads the folder every three seconds
    /// while that viewer is connected and sends them again when they have changed, so a build
    /// published while someone is watching shows up in the app without their asking. A viewer that
    /// never asks is sent nothing: an older app has no use for the list.
    private func watchBuilds() {
        guard let catalogue = settings.builds else {
            offeredBuilds = []
            send(MirrorMessage.builds, json: MirrorBuildList(builds: []))
            return
        }
        offeredBuilds = nil
        readBuilds(from: catalogue)
        buildsTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in self?.readBuilds(from: catalogue) }
        timer.resume()
        buildsTimer = timer
    }

    /// Sends the viewer the certificate its own build server uses, making it the first time.
    private func sendInstallIdentity() {
        let store = settings.installIdentity
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let identity = try store.load()
                self?.queue.async { self?.send(MirrorMessage.installIdentity, json: identity) }
            } catch {
                let message = CLIErrorMapping.failure(for: error).message
                mirrorNote("no certificate for installs: \(message)")
                self?.onEvent?(["event": "warning", "code": "installCertificateFailed", "message": message])
                self?.queue.async { self?.send(MirrorMessage.installIdentityFailed, json: MirrorBuildFetchFailure(id: "", message: message)) }
            }
        }
    }

    /// Sends a piece of a build's file: only a build this host offered this viewer, and only one
    /// whose file the host holds. The viewer asks for the pieces in turn; one that asks for more
    /// while the last is still being read or sent is refused, so nothing piles up.
    private func sendBuildPiece(_ request: MirrorBuildFetch) {
        guard MirrorBuildFetch.accepted(reading: readingPiece, queued: link.controlBacklog) else {
            send(MirrorMessage.fetchFailed, json: MirrorBuildFetchFailure(id: request.id, message: "This Mac is still sending the last piece."))
            return
        }
        guard let catalogue = settings.builds, let build = offeredBuilds?.first(where: { $0.id == request.id }),
              request.offset >= 0, request.length > 0 else {
            send(MirrorMessage.fetchFailed, json: MirrorBuildFetchFailure(id: request.id, message: "This Mac no longer has that build."))
            return
        }
        let file = MirrorBuildStore(root: catalogue.folder).folder(bundleID: build.bundleID, buildID: build.id).appendingPathComponent("app.ipa")
        let length = min(request.length, MirrorBuildFetch.largest)
        readingPiece = true
        let number = pieceNumber
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var bytes: Data?
            if let handle = try? FileHandle(forReadingFrom: file) {
                try? handle.seek(toOffset: UInt64(request.offset))
                bytes = try? handle.read(upToCount: length)
                try? handle.close()
            }
            self?.queue.async {
                // The viewer this was read for may have gone, and another connection come, meanwhile.
                guard let self, number == self.pieceNumber else { return }
                self.readingPiece = false
                if let bytes {
                    if request.offset == 0 { mirrorNote("sending \(build.name) \(build.versionText) to the viewer over the connection") }
                    self.sendControl(MirrorMessage.buildPiece, MirrorBuildPiece(id: request.id, offset: request.offset, bytes: bytes).encoded)
                } else {
                    self.send(MirrorMessage.fetchFailed, json: MirrorBuildFetchFailure(id: request.id, message: "This Mac could not read that build."))
                }
            }
        }
    }

    private func readBuilds(from catalogue: MirrorBuildCatalogue) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let builds = catalogue.read()
            self?.queue.async {
                guard let self, self.buildsTimer != nil, builds != self.offeredBuilds else { return }
                let first = self.offeredBuilds == nil
                self.offeredBuilds = builds
                self.send(MirrorMessage.builds, json: MirrorBuildList(builds: builds))
                mirrorNote("offering \(builds.count) build\(builds.count == 1 ? "" : "s") to install")
                if !first, let newest = builds.first {
                    self.onEvent?(["event": "buildsChanged", "count": String(builds.count), "newest": "\(newest.name) \(newest.versionText)"])
                }
            }
        }
    }

    // MARK: Session

    /// Starts the stream once there is a simulator to show and the viewer has said how big its
    /// pane is. A viewer still at the list is sent nothing.
    private func startSessionIfReady() {
        guard !sessionStarted, !awaitingChoice, simulator != nil, paneWidth > 0, paneHeight > 0 else { return }
        startSession()
    }

    private func startSession() {
        sessionStarted = true
        rebuild()
        // The viewer shows the simulator's name and UDID, and offers the list if it may choose.
        var info: [String: Any] = ["mode": "iroh", "codec": "hevc", "playout": "default", "barcodeY": 0.0,
                                   "chooser": settings.choosesSimulator]
        // A demo's visitors are strangers and have no use for this Mac's simulator IDs.
        if let simulator, !settings.demo {
            info["udid"] = simulator.udid
            info["name"] = simulator.name
            info["model"] = simulator.device.deviceType?.name ?? ""
            info["rotates"] = true      // this host takes rotation requests
            info["hinge"] = hasHinge    // an iPhone Duo: this host takes fold requests and sends screen states
        }
        if let data = try? JSONSerialization.data(withJSONObject: info) { sendControl(23, data) }
        sentScreen = nil
        sendScreenIfChanged()
        if !responsiveness.responding {
            send(MirrorMessage.health, json: MirrorSimulatorHealth(responding: false, reason: responsiveness.reason))
        }
        send(MirrorMessage.hostLoad, json: hostLoad)
        watchScreen()
        link.restartVideo()     // the first video stream
        videoGeneration += 1
        streaming = true
        forceKey = true
        damageTime = nil
        mirrorNote("streaming")
        encode(recheck: 3)
    }

    private func endSession() {
        stopStreaming()
        // A choice the last viewer made and did not see finished is dropped. A simulator it was
        // watching stays attached, for a viewer that has only lost its connection and returns.
        greeted = false
        awaitingChoice = false
        buildsTimer?.cancel()
        buildsTimer = nil
        offeredBuilds = nil
        readingPiece = false
        pieceNumber += 1
        choiceNumber += 1
        paneWidth = 0
        paneHeight = 0
        currentMbps = 0
        onRelay = true
        otherPath = PathRate()
        ceilingMbps = 0; ceilingUntil = 0; ceilingFound = 0
        ackLog = []; ageHistory = []
        // The next viewer numbers its gestures from one again.
        blockedGesture = nil
        input?.viewerChanged()
    }

    private func stopStreaming() {
        rotationWatch?.cancel()
        rotationWatch = nil
        streaming = false
        sessionStarted = false
        unacked.removeAll()
        waitingOnViewer = false
        owed = false
        resizeWork?.cancel()
        resizeWork = nil
    }

    // MARK: Choosing a simulator (on `queue`)

    private func send<Message: Encodable>(_ type: UInt8, json message: Message) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        sendControl(type, data)
    }

    /// The first thing a viewer says after it connects to a host that lets it choose.
    ///
    /// A viewer that names the simulator it was watching, when that is still the one attached, has
    /// only lost its connection: it carries on. Any other viewer starts at the list, and a
    /// simulator left attached by the last one is let go. An app from before the list existed
    /// cannot show it; it is shown the attached simulator if there is one, and the host says why
    /// it gets no picture if there is none.
    private func greet(_ info: [String: Any]) {
        guard info["chooser"] as? Bool == true else {
            if simulator == nil {
                onEvent?(["event": "warning", "code": "viewerTooOld",
                          "message": "The viewer's AXe Mirror app is too old to choose a simulator. Update the app, or start the host with --udid."])
            }
            return
        }
        if let resume = info["resume"] as? String, let simulator, UUID(uuidString: resume) == UUID(uuidString: simulator.udid) { return }
        release()
        awaitingChoice = true
        sendSimulatorList()
    }

    /// A failure as the viewer is told it: the Mac's own message, for an older viewer and the log,
    /// and the same thing said for the person holding the viewer, with what they can do about it.
    private nonisolated func failed(_ doing: String, _ error: Error, udid: String?, name: String?) -> MirrorSimulatorProgress {
        let failure = CLIErrorMapping.failure(for: error)
        let problem = MirrorProblem.describe(doing: doing, errorCode: failure.code, technical: failure.message, name: name?.isEmpty == false ? name : nil)
        return MirrorSimulatorProgress(step: "failed", udid: udid, name: name, message: failure.message, problem: problem, doing: doing)
    }

    private func sendSimulatorList() {
        Task { [self] in
            do {
                let list = try await MirrorSimulatorControl.list()
                queue.async { self.send(MirrorMessage.simulators, json: list) }
            } catch {
                let failed = self.failed("list", error, udid: nil, name: nil)
                mirrorNote("simulator list failed: \(failed.message ?? "")")
                queue.async { self.send(MirrorMessage.progress, json: failed) }
            }
        }
    }

    /// Opens the simulator the viewer chose, creating and booting it first if it has to, and
    /// starts the stream. The viewer is told each step; a failure leaves it at the list.
    private func choose(_ choice: MirrorSimulatorChoice) {
        choiceNumber += 1
        let number = choiceNumber
        release()
        awaitingChoice = true
        func tell(_ progress: MirrorSimulatorProgress) {
            queue.async {
                guard number == self.choiceNumber else { return }
                self.send(MirrorMessage.progress, json: progress)
            }
        }
        func tell(_ step: String, udid: String? = nil, name: String? = nil) {
            tell(MirrorSimulatorProgress(step: step, udid: udid, name: name))
        }
        // The simulator's name once it is known, for the words the viewer shows if this fails.
        let named = MirrorLastValue()
        Task { [self] in
            do {
                let udid: String
                var name = choice.name
                var booted = false
                if let existing = choice.udid {
                    // Only what the list offers may be opened: an iPhone or iPad simulator of this Mac.
                    guard let listed = try await MirrorSimulatorControl.list().simulators.first(where: { UUID(uuidString: $0.udid) == UUID(uuidString: existing) }) else {
                        throw CLIError(errorDescription: "That simulator is no longer on this Mac.", code: .commandFailed)
                    }
                    udid = listed.udid
                    name = listed.name
                    booted = listed.booted
                    _ = named.changed(to: [listed.name])
                } else {
                    tell("creating", name: choice.name)
                    let made = try await MirrorSimulatorControl.create(name: choice.name, deviceType: choice.deviceType, runtime: choice.runtime)
                    udid = made.udid
                    name = made.name
                    _ = named.changed(to: [made.name])
                    mirrorNote("created simulator \(made.name) \(made.udid)")
                    onEvent?(["event": "simulatorCreated", "udid": made.udid, "name": made.name, "model": made.model, "os": made.os])
                }
                if !booted {
                    tell("booting", udid: udid, name: name)
                    try await MirrorSimulatorControl.boot(udid: udid)
                }
                tell("opening", udid: udid, name: name)
                let (simulator, framebuffer) = try await MirrorHost.open(udid: udid)
                queue.async {
                    // The viewer chose again, went back to the list or left while this one started.
                    guard number == self.choiceNumber else { return }
                    self.simulator = simulator
                    self.attach(framebuffer)
                    self.loadScreens()
                    self.forceKey = true
                    self.startInput()
                    self.awaitingChoice = false
                    self.onEvent?(["event": "simulatorSelected", "udid": simulator.udid, "name": simulator.name])
                    self.startSessionIfReady()
                }
            } catch {
                let failed = self.failed(choice.udid == nil ? "create" : "open", error, udid: choice.udid, name: named.current?.first ?? choice.name)
                mirrorNote("simulator choice failed: \(failed.message ?? "")")
                tell(failed)
            }
        }
    }

    /// Shuts a simulator down or deletes it for the viewer, then sends the list as it now is. Only
    /// a simulator the list offers can be named. If it is the one on screen it is let go first:
    /// that is how a viewer leaves a simulator without leaving it running.
    private func manage(_ request: MirrorSimulatorAction) {
        if let simulator, UUID(uuidString: simulator.udid) == UUID(uuidString: request.udid) {
            choiceNumber += 1
            release()
            awaitingChoice = true
        }
        // What the viewer had chosen when it asked. A restart opens the simulator again only if
        // that still stands: by the time a forced shut-down is over the viewer may have opened
        // another, or left.
        let number = choiceNumber
        let managed = MirrorLastValue()     // the simulator's name, for the words the viewer shows if this fails
        Task { [self] in
            do {
                guard let listed = try await MirrorSimulatorControl.list().simulators.first(where: { UUID(uuidString: $0.udid) == UUID(uuidString: request.udid) }) else {
                    throw CLIError(errorDescription: "That simulator is no longer on this Mac.", code: .commandFailed)
                }
                _ = managed.changed(to: [listed.name])
                let known = [MirrorSimulatorAction.shutDown, MirrorSimulatorAction.delete, MirrorSimulatorAction.restart].contains(request.action)
                if known { onManaging?(listed.udid, request.action, false) }
                defer { if known { onManaging?(listed.udid, request.action, true) } }
                switch request.action {
                case MirrorSimulatorAction.shutDown:
                    try await MirrorSimulatorControl.shutDown(listed)
                    mirrorNote("shut down simulator \(listed.name) \(listed.udid)")
                    onEvent?(["event": "simulatorShutDown", "udid": listed.udid, "name": listed.name])
                case MirrorSimulatorAction.delete:
                    try await MirrorSimulatorControl.delete(listed)
                    mirrorNote("deleted simulator \(listed.name) \(listed.udid)")
                    onEvent?(["event": "simulatorDeleted", "udid": listed.udid, "name": listed.name])
                case MirrorSimulatorAction.restart:
                    // Shut down, by force if it has stopped answering, then booted and opened as a choice is.
                    // The viewer is told at once: a forced shut-down can take half a minute.
                    queue.async { self.send(MirrorMessage.progress, json: MirrorSimulatorProgress(step: "restarting", udid: listed.udid, name: listed.name)) }
                    try await MirrorSimulatorControl.forceShutDown(udid: listed.udid)
                    mirrorNote("shut down simulator \(listed.name) \(listed.udid) to restart it")
                    onEvent?(["event": "simulatorRestarting", "udid": listed.udid, "name": listed.name])
                    let stillWanted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                        queue.async {
                            let wanted = number == self.choiceNumber
                            if wanted { self.choose(MirrorSimulatorChoice(udid: listed.udid)) }
                            continuation.resume(returning: wanted)
                        }
                    }
                    if stillWanted { return }
                    // The viewer has moved on. The simulator is started again all the same, since
                    // a restart was asked for, and whatever the viewer is looking at is left alone.
                    mirrorNote("the viewer chose again while \(listed.name) was restarting: booting it without opening it")
                    try await MirrorSimulatorControl.boot(udid: listed.udid)
                default:
                    throw CLIError(errorDescription: "This host does not know how to \(request.action) a simulator.", code: .commandFailed)
                }
                // The list as it now is, for a viewer that is still at it. One that has opened a
                // simulator meanwhile is sent nothing: the list would take it away from what it
                // is watching.
                queue.async { if self.simulator == nil || self.awaitingChoice { self.sendSimulatorList() } }
            } catch {
                let failed = self.failed(request.action, error, udid: request.udid, name: managed.current?.first)
                mirrorNote("simulator \(request.action) failed: \(failed.message ?? "")")
                queue.async { self.send(MirrorMessage.progress, json: failed) }
            }
        }
    }

    /// Another viewer of this Mac is shutting down, deleting or restarting a simulator. If it is
    /// the one this viewer is watching, this viewer is told so and sent back to the list: left
    /// alone, its picture froze and it was told only, seconds later, that the simulator was not
    /// responding. With `done`, a viewer at the list is sent the list as it now is.
    func simulatorManagedElsewhere(udid: String, action: String, done: Bool) {
        queue.async {
            guard self.settings.choosesSimulator else { return }
            if done {
                if self.link.hasViewer, self.simulator == nil || self.awaitingChoice { self.sendSimulatorList() }
                return
            }
            guard let simulator = self.simulator, UUID(uuidString: simulator.udid) == UUID(uuidString: udid) else { return }
            let name = simulator.name
            self.choiceNumber += 1      // a choice of this simulator still under way is dropped with it
            self.release()
            self.awaitingChoice = true
            guard self.link.hasViewer else { return }
            let problem = MirrorProblem.takenAway(name: name, action: action)
            mirrorNote("\(name) was taken from this viewer by another: \(action)")
            self.send(MirrorMessage.progress, json: MirrorSimulatorProgress(step: "failed", udid: udid, name: name, message: problem.title, problem: problem, doing: "open"))
            self.sendSimulatorList()
        }
    }

    // MARK: Rotation and the Duo's screens (on `queue`)

    /// While streaming, asks the simulator which screen is lit and which way it is turned, twice a
    /// second, or four times on an iPhone Duo, with its hinge. For a moment after a fold or a turn
    /// (`burst`) it asks every 40 ms, so the viewer sees the hinge move and the screen change as
    /// they happen. That catches every change: the viewer's, Simulator.app's, an agent's, and an app
    /// that turns itself. A display read is an XPC request to the simulator's own CoreDevice
    /// service, 2.5 to 4.5 ms (measured on an iPad simulator, iOS 27.3, 20 November 2026); a hinge
    /// read is about 3 ms (Duo, iOS 27.2).
    private func watchScreen() {
        rotationWatch?.cancel()
        guard let simulator else { return }
        let duo = hasHinge
        let reads = MirrorBoundedReads(), burst = burst
        rotationWatch = Task { [weak self] in
            var round = 0
            while !Task.isCancelled {
                let (answered, screen, hinge) = await reads.run(within: 4) { await MirrorLitScreen.readAnswer(for: simulator, hinged: duo) } ?? (false, nil, nil)
                self?.queue.async { if self?.simulator === simulator { self?.noteHealth { $0.read(ok: answered) } } }
                // About every ten seconds, a process started in the simulator says whether it is answering at all.
                if round % (duo ? 40 : 20) == 10, !burst.active {
                    let alive = await MirrorSimulatorControl.answers(udid: simulator.udid)
                    self?.queue.async { if self?.simulator === simulator { self?.noteHealth { $0.probe(ok: alive) } } }
                }
                if !burst.active { round += 1 }
                self?.queue.async { self?.screenRead(screen, hinge: hinge, of: simulator) }
                // A read that failed, as on a simulator whose services have stopped answering, is
                // not tried again at once.
                try? await Task.sleep(nanoseconds: !answered ? 2_000_000_000 : burst.active ? 40_000_000 : duo ? 250_000_000 : 500_000_000)
            }
        }
    }

    private func screenRead(_ screen: MirrorLitScreen?, hinge: Double?, of read: FBSimulator) {
        guard read === simulator else { return }
        if let hinge { hingeDegrees = hinge }
        // The hinge is passed on even when the display report could not be read.
        guard let screen else { sendScreenIfChanged(); return }
        mendShut(screen, of: read)
        let previous = lit
        lit = screen
        var rebuildNeeded = false
        if hasHinge, previous?.displayID != screen.displayID || framebuffer.flatMap({ $0.currentSurface }).map({ !screen.owns($0) }) == true {
            // The Duo folded: the picture moves to the lit screen's framebuffer.
            if let next = screens.first(where: { $0.currentSurface.map(screen.owns) ?? false }), next !== framebuffer {
                attach(next)
                forceKey = true
                rebuildNeeded = true
                mirrorNote("picture now from the \(screen.role) screen")
                onEvent?(["event": "screenChanged", "udid": read.udid, "screen": screen.role])
            }
        }
        if screen.rotation != rotation {
            rotation = screen.rotation
            input?.rotation = screen.rotation
            let names = [0: "portrait", 90: "landscapeLeft", 180: "portraitUpsideDown", 270: "landscapeRight"]
            mirrorNote("screen turned \(screen.rotation)°")
            onEvent?(["event": "rotated", "udid": read.udid, "orientation": names[screen.rotation] ?? "\(screen.rotation)"])
            rebuildNeeded = true
        }
        if hasHinge, previous.map({ $0.displayID != screen.displayID || $0.rotation != screen.rotation }) ?? false {
            retargetInput(screen)
        }
        sendScreenIfChanged()
        guard sessionStarted, rebuildNeeded else { return }
        rebuild()
        encode(recheck: 3)
    }

    /// Opens a touch connection aimed at the screen now lit, and moves the input to it.
    private func retargetInput(_ screen: MirrorLitScreen) {
        guard let simulator else { return }
        retargetNumber += 1
        let number = retargetNumber
        Task { [self] in
            do {
                let hid = try await FBSimulatorHID.ready(for: simulator, displayContext: try screen.context())
                queue.async {
                    guard number == self.retargetNumber, self.simulator === simulator, let input = self.input else { hid.disconnect(); return }
                    input.retarget(hid, width: screen.logicalWidth, height: screen.logicalHeight)
                }
            } catch {
                mirrorNote("could not aim touches at the \(screen.role) screen: \(error)")
            }
        }
    }

    /// Tells the viewer which screen it sees and how far the hinge is open, when either has changed.
    /// The angle is sent to the degree.
    private func sendScreenIfChanged() {
        guard sessionStarted, let lit else { return }
        let state = MirrorScreenState(role: lit.role, width: lit.logicalWidth, height: lit.logicalHeight,
                                      degrees: hasHinge ? hingeDegrees.map { $0.rounded() } : nil)
        guard state != sentScreen else { return }
        sentScreen = state
        send(MirrorMessage.screen, json: state)
    }

    /// Turns the simulator as the viewer asked, as Simulator.app's Rotate Left and Rotate Right
    /// do. Whether the screen follows is up to the app in front; the next read shows what it did.
    /// An iPhone skips upside down, which iPhone apps do not support. An iPhone Duo is turned
    /// through AXe's input broker, as `axe rotate` does.
    private func rotate(to wanted: String) {
        guard let simulator else { return }
        if hasHinge {
            guard let lit, let held = MirrorFold.held(turning: wanted, role: lit.role, rotation: lit.rotation) else { return }
            do {
                try duoControl(for: simulator).setOrientation(held)
                mirrorNote("holding the simulator \(held.rawValue)")
                burst.start(for: 1.5)
            } catch {
                mirrorNote("could not turn the simulator: \(CLIErrorMapping.failure(for: error).message)")
            }
            return
        }
        let iPad = (simulator.device.deviceType?.name ?? "").hasPrefix("iPad")
        var target: Int
        switch wanted {
        case MirrorRotationRequest.left, MirrorRotationRequest.right:
            let step = wanted == MirrorRotationRequest.left ? 90 : 270
            target = (rotation + step) % 360
            if target == 180, !iPad { target = (target + step) % 360 }
        case MirrorRotationRequest.landscape:
            guard !quarterTurned else { return }
            target = 90
        case MirrorRotationRequest.portrait:
            guard rotation != 0 else { return }
            target = 0
        default:
            return
        }
        let orientations: [Int: FBSimulatorHIDDeviceOrientation] = [0: .portrait, 90: .landscapeLeft, 180: .portraitUpsideDown, 270: .landscapeRight]
        guard let orientation = orientations[target] else { return }
        mirrorNote("turning the simulator to \(orientation.name)")
        input?.turn(to: orientation)
    }

    /// A Duo that is shut has its outer screen lit, and its inner one cannot be seen. iOS can leave
    /// it the other way round (see `MirrorFold`), whoever shut it: this viewer before the host knew
    /// better, Device Hub, an agent. When the simulator a viewer is watching has stood like that
    /// for a second, with no fold of the viewer's under way, the host opens its hinge to 8 degrees
    /// and shuts it again, which lights the outer screen: once for each time it is shut.
    private func mendShut(_ screen: MirrorLitScreen, of simulator: FBSimulator) {
        guard hasHinge, let hinge = hingeDegrees else { return }
        guard hinge <= MirrorLitScreen.shut else { shutInnerSince = nil; shutMended = false; return }
        guard screen.role == "inner", !shutMended, sessionStarted, foldsUnderWay == 0 else { shutInnerSince = nil; return }
        let now = ProcessInfo.processInfo.systemUptime
        guard let since = shutInnerSince else { shutInnerSince = now; return }
        guard now - since >= 1 else { return }
        shutMended = true
        shutInnerSince = nil
        mirrorNote("shut with its inner screen lit: opening the hinge to \(Int(MirrorFold.nudge))° and shutting it, to light the outer one")
        let control = duoControl(for: simulator)
        burst.start(for: 2.5)
        foldsUnderWay += 1
        foldTask = Task { [self] in
            try? await MirrorFold.perform(MirrorFold.Plan(hinge: 0), control: control, simulator: simulator)
            queue.async { self.foldsUnderWay -= 1 }
        }
    }

    /// The connection the Duo's hinge and the way it is held are set on, opened at the first use.
    private func duoControl(for simulator: FBSimulator) -> FBSimulatorDuoControl {
        if let duo { return duo }
        let made = FBSimulatorDuoControl(simulator: simulator)
        duo = made
        return made
    }

    /// Folds an iPhone Duo simulator as the viewer asked: see `MirrorFold`. A bare angle, which is
    /// what a finger dragging the viewer's 3D Duo sends, is one message and nothing more. Any other
    /// fold is then watched: the hinge has three seconds to get there, ten times what it takes, and
    /// if it has not the viewer is told. A newer fold makes an older one's result of no interest.
    private func fold(_ request: MirrorFoldRequest) {
        guard hasHinge, let simulator else { return }
        let plan = MirrorFold.plan(request, outerLit: lit?.role == "outer")
        let control = duoControl(for: simulator)
        foldNumber += 1
        let number = foldNumber
        // An older fold still at work is stopped where it is: this one is what the viewer wants now.
        foldTask?.cancel()
        foldTask = nil
        burst.start(for: 2)
        if request.posture == MirrorFoldRequest.angle {
            do { try control.setHinge(plan.hinge) } catch {
                mirrorNote("could not move the hinge: \(CLIErrorMapping.failure(for: error).message)")
            }
            return
        }
        mirrorNote("folding: \(request.posture) at \(Int(plan.hinge))°\(plan.held.map { ", held \($0.rawValue)" } ?? "")")
        foldsUnderWay += 1
        foldTask = Task { [self] in
            var late = false
            defer { queue.async { self.foldsUnderWay -= 1 } }
            do {
                try await MirrorFold.perform(plan, control: control, simulator: simulator)
                guard await MirrorFold.arrived(plan.hinge, simulator: simulator, within: 3) else {
                    late = true
                    throw CLIError(errorDescription: "The simulator's hinge did not get to \(Int(plan.hinge)) degrees.", code: .commandFailed)
                }
                queue.async {
                    guard self.foldNumber == number, self.simulator === simulator else { return }
                    self.onEvent?(["event": "folded", "udid": simulator.udid, "posture": request.posture])
                    self.noteHealth { $0.fold(timedOut: false) }
                }
            } catch {
                queue.async {
                    guard self.foldNumber == number, self.simulator === simulator else { return }
                    let message = CLIErrorMapping.failure(for: error).message
                    mirrorNote("fold failed: \(message)")
                    self.onEvent?(["event": "warning", "code": "foldFailed", "message": message])
                    // The viewer says so on screen; an older viewer never asks for a fold.
                    var failed = self.failed("fold", error, udid: simulator.udid, name: simulator.name)
                    failed.step = "foldFailed"
                    self.send(MirrorMessage.progress, json: failed)
                    self.noteHealth { $0.fold(timedOut: late) }
                }
            }
        }
    }

    // MARK: Whether the simulator is answering (on `queue`)

    /// Records a read, a touch or a fold, and when the simulator has stopped answering, or started
    /// again, tells the viewer and prints an event. The host does not restart a simulator by itself:
    /// a restart loses what is running in it, and an agent may be using it. The viewer offers it.
    private func noteHealth(_ change: (inout MirrorResponsiveness) -> Bool) {
        guard simulator != nil, change(&responsiveness) else { return }
        let udid = simulator?.udid ?? ""
        if responsiveness.responding {
            mirrorNote("the simulator is answering again")
            onEvent?(["event": "responsive", "udid": udid])
        } else {
            mirrorNote("the simulator is not answering: \(responsiveness.reason ?? "")")
            onEvent?(["event": "unresponsive", "udid": udid, "reason": responsiveness.reason ?? ""])
        }
        guard sessionStarted else { return }
        send(MirrorMessage.health, json: MirrorSimulatorHealth(responding: responsiveness.responding, reason: responsiveness.reason))
    }

    /// Stops mirroring the attached simulator. It stays booted.
    private func release() {
        stopStreaming()
        guard let simulator else { return }
        detachFramebuffer()
        framebuffer = nil
        screens = []
        lit = nil
        hingeDegrees = nil
        sentScreen = nil
        foldNumber += 1
        foldTask?.cancel()
        foldTask = nil
        duo?.close()
        duo = nil
        shutInnerSince = nil
        shutMended = false
        responsiveness = MirrorResponsiveness()
        retargetNumber += 1
        inputNumber += 1
        inputOpening = false
        inputFailures = 0
        self.simulator = nil
        surface = nil
        lastSeed = 0
        damageTime = nil
        input?.close()
        input = nil
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        encoder = nil
        transfer = nil
        pool = nil
        rotator = nil
        unrotatedPool = nil
        rotation = 0
        onEvent?(["event": "simulatorReleased", "udid": simulator.udid])
    }
}
#endif
