#if AXE_MIRROR
import CoreMedia
import CoreVideo
@preconcurrency import FBControlCore
import FBSimulatorControl
import Foundation
import IOSurface
import VideoToolbox

/// One simulator mirrored to one viewer at a time.
///
/// The simulator's screen is read from its framebuffer surface, scaled to the viewer's pane, encoded
/// as HEVC and sent over the link, one frame per screen change and never faster than the frame-rate
/// limit. Nothing is encoded while no viewer is attached. The viewer's touches are replayed into the
/// simulator by `MirrorInput`. All state here is touched on `queue` only.
final class MirrorSession: NSObject, FBFramebufferConsumer, @unchecked Sendable {
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
    private let framebuffer: FBFramebuffer
    private let simulator: FBSimulator
    private let secret: Data
    private let link: MirrorLink
    private let health = MirrorLinkHealth()
    private var input: MirrorInput?
    /// One event for the command to print: a name and its fields.
    var onEvent: (([String: String]) -> Void)?

    private var surface: IOSurface?
    private var lastSeed: UInt32 = 0
    private var damageTime: TimeInterval?
    private var lastEncodeStart: TimeInterval = 0
    private var encodeScheduled = false
    private var forceKey = true
    private var encoder: VTCompressionSession?
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
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
    private var relayWatch: Task<Void, Never>?
    private var blockedGesture: UInt32?     // demo only: the gesture now being dropped
    private var demoAppTimer: DispatchSourceTimer?

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

    init(simulator: FBSimulator, framebuffer: FBFramebuffer, secret: Data, settings: Settings) {
        self.simulator = simulator
        self.framebuffer = framebuffer
        self.secret = secret
        self.settings = settings
        link = MirrorLink(queue: queue)
        super.init()
    }

    func start() {
        queue.sync {
            surface = framebuffer.attach(self, on: queue)
            startInput()
            health.onReport = { [weak self] line, short in
                mirrorNote(line)
                self?.queue.async {
                    guard let self, !short.isEmpty else { return }
                    self.sendControl(24, Data(short.utf8))     // the viewer shows it under its other figures
                }
            }
            health.start()
            link.onNote = { [weak self] text in
                mirrorNote(text)
                if text.hasPrefix("iroh endpoint "), let self {
                    self.onEvent?(["event": "endpoint", "hostID": String(text.dropFirst("iroh endpoint ".count))])
                } else if text.hasPrefix("iroh online, home relay "), let self {
                    self.onEvent?(["event": "ready", "udid": self.simulator.udid, "relay": String(text.dropFirst("iroh online, home relay ".count))])
                }
            }
            link.onConnected = { [weak self] in
                self?.endSession()
                self?.onEvent?(["event": "viewerConnected"])
                self?.showDemoApp()
            }
            link.onMessage = { [weak self] type, payload in self?.handle(type: type, payload: payload) }
            link.onClosed = { [weak self] in
                self?.endSession()
                self?.onEvent?(["event": "viewerDisconnected"])
            }
            link.onPathSelected = { [weak self] relay in self?.pathChanged(toRelay: relay) }
            if settings.demo { link.turnsAwayWhileBusy = { MirrorDemo.isBusy(connectedFor: $0) } }
            if let viewers = settings.viewers {
                link.allows = { viewers.allows($0) }
                link.onRefused = { [weak self] viewer in self?.onEvent?(["event": "refused", "viewer": viewer, "reason": "not paired"]) }
            }
            link.start(secret: secret, relayOnly: settings.relayOnly, relayURLs: settings.relayURLs)
            let adapt = DispatchSource.makeTimerSource(queue: queue)
            adapt.schedule(deadline: .now() + 0.25, repeating: 0.25)
            adapt.setEventHandler { [weak self] in self?.adaptBitrate() }
            adapt.resume()
            adaptTimer = adapt
            if settings.watchRelays { watchRelays() }
        }
    }

    /// Keeps a long-running host on a relay that works. Every half minute, while no viewer is
    /// connected, the host asks its relay whether it is there. When `MirrorRelays.checkDue` says so,
    /// the relays are chosen again; if the choice differs, the endpoint is given the new ones.
    private func watchRelays() {
        let seed = settings.relaySeed, record = settings.relayRecord
        relayWatch = Task { [weak self] in
            var lastCheck = ProcessInfo.processInfo.systemUptime
            var missed = 0
            while true {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled, let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let current = self.queue.sync { self.settings.relayURLs }
                guard !self.link.hasViewer else { missed = 0; continue }
                if let home = current.first { missed = await MirrorRelays.measure([home]).isEmpty ? missed + 1 : 0 }
                guard MirrorRelays.checkDue(onOwn: !current.isEmpty, missed: missed, sinceCheck: now - lastCheck) else { continue }
                lastCheck = now
                let choice = await MirrorRelays.choose(explicit: nil, seed: seed, record: record)
                guard choice.relays != current, !Task.isCancelled, !self.link.hasViewer else { continue }
                self.queue.sync { self.settings.relayURLs = choice.relays }
                await self.link.useRelays(choice.relays)
                self.onEvent?(choice.event)
            }
        }
    }

    /// Stops streaming and closes the link so the viewer notices at once. Returns the last lines worth printing.
    func stop() -> [String] {
        relayWatch?.cancel()
        queue.sync {
            adaptTimer?.cancel()
            adaptTimer = nil
            endSession()
            framebuffer.detach(self)
            if let encoder { VTCompressionSessionInvalidate(encoder) }
            encoder = nil
        }
        health.stop()
        link.closeAndWait()
        return health.summary()
    }

    private func startInput() {
        guard let surface else { return }
        let scale = Double(simulator.screenInfo?.scale ?? 3)
        let width = Double(IOSurfaceGetWidth(surface)) / scale, height = Double(IOSurfaceGetHeight(surface)) / scale
        Task { [self] in
            do {
                let hid = try await FBSimulatorHID.ready(for: simulator)
                let owner = MirrorInput(hid: hid, width: width, height: height, hertz: 60, delay: settings.inputDelayMs / 1000)
                owner.delayRule = settings.delayRule
                owner.lead = settings.replayLeadMs / 1000
                queue.async { self.input = owner }
                mirrorNote("input ready: \(Int(width))x\(Int(height)) points")
            } catch {
                mirrorNote("input unavailable: \(error)")
            }
        }
    }

    // MARK: Framebuffer callbacks (on `queue`)

    func didChange(_ surface: IOSurface?) {
        self.surface = surface
        forceKey = true
        if sessionStarted { rebuild() }
        frameReady()
    }

    func didReceiveDamageRect() {
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

    /// The output size: the simulator's pixels scaled to fit the viewer's pane, never above native.
    private func fittedSize() -> (Int, Int)? {
        guard let surface else { return nil }
        let sourceWidth = Double(IOSurfaceGetWidth(surface)), sourceHeight = Double(IOSurfaceGetHeight(surface))
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
        guard let size = fittedSize() else { return }
        (targetWidth, targetHeight) = size

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
        mirrorNote("encoder hevc \(targetWidth)x\(targetHeight), low-latency")
        onEvent?(["event": "streaming", "width": String(targetWidth), "height": String(targetHeight)])
    }

    private func encode(recheck: Int) {
        guard streaming, let surface else { return }
        if pool == nil { rebuild() }
        guard let transfer, let pool, let encoder else { return }

        // A callback can arrive before the surface content changes; look again shortly.
        let seed = IOSurfaceGetSeed(surface)
        if seed == lastSeed, !forceKey {
            if recheck < 3 {
                queue.asyncAfter(deadline: .now() + 0.003) { [self] in encode(recheck: recheck + 1) }
            } else {
                damageTime = nil
            }
            return
        }
        // Skip, rather than queue, when the link has not taken earlier frames.
        guard link.videoBacklog <= 2 else { return }
        // Skip while the viewer is far behind, so a slow link costs frames and not a growing delay.
        // Encoding resumes from the current screen when the viewer's reports catch up.
        if let oldest = unacked.first, let sent = frames[oldest]?.encodeDone, sent > 0 {
            let age = mirrorNow() - sent
            if age > 3 {
                unacked.removeAll()     // reports stopped coming; do not wait for them forever
            } else if settings.maxLagMs > 0, age > settings.maxLagMs / 1000 {
                waitingOnViewer = true
                damageTime = nil
                return
            }
        }
        lastSeed = seed
        let start = mirrorNow()
        let captured = damageTime ?? start
        damageTime = nil
        lastEncodeStart = start

        var unmanagedSource: Unmanaged<CVPixelBuffer>?
        CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface, nil, &unmanagedSource)
        guard let source = unmanagedSource?.takeRetainedValue() else { return }
        var destination: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination)
        guard let destination, VTPixelTransferSessionTransferImage(transfer, from: source, to: destination) == noErr else { return }

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
            guard status == noErr, let sample, let self else { return }
            self.queue.async {
                // A frame encoded for a stream that has since been replaced would arrive ahead of the new keyframe.
                guard generation == self.videoGeneration else { return }
                self.send(sample: sample, frameID: frameID, encodeDone: done)
            }
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
            unacked.removeAll()
            forceKey = true
            encode(recheck: 3)
        case 13:    // viewer info: its network and the size of its pane
            guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return }
            if let network = json["network"] as? String, network != viewerNetwork {
                viewerNetwork = network
                mirrorNote("viewer network \(network)")
            }
            guard let width = json["paneWidth"] as? Double, let height = json["paneHeight"] as? Double, width > 0, height > 0 else { return }
            let changed = abs(width - paneWidth) > 1 || abs(height - paneHeight) > 1
            paneWidth = width
            paneHeight = height
            if !sessionStarted {
                startSession()
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
                    // A touch that starts at the top or bottom edge is dropped whole, down to up.
                    if message.isDown { blockedGesture = MirrorDemo.blocksTouch(downAt: message.y1) || (message.contacts > 1 && MirrorDemo.blocksTouch(downAt: message.y2)) ? message.gesture : nil }
                    if message.gesture == blockedGesture { return }
                }
                input?.receive(message)
                for earlier in MirrorTouch.history(in: payload, received: time) { input?.receive(earlier) }
            }
        case 43 where payload.count >= 2 && !settings.demo:   // a hardware button pressed in the viewer: button, number of presses
            input?.press(button: payload[payload.startIndex], count: payload[payload.startIndex + 1])
        default:
            break
        }
    }

    // MARK: Demo

    /// Starts the demo's sample app afresh when a viewer arrives, so that every visitor begins on
    /// its first screen and not where the last one stopped. Every half minute while one is
    /// connected it is brought to the front again, in case the visitor found a way out of it.
    private func showDemoApp() {
        guard settings.demo, let app = settings.demoApp else { return }
        let udid = simulator.udid
        let launch = { (afresh: Bool) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["simctl", "launch"] + (afresh ? ["--terminate-running-process"] : []) + [udid, app]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
        }
        launch(true)
        demoAppTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self, self.link.hasViewer else { self?.demoAppTimer?.cancel(); self?.demoAppTimer = nil; return }
            launch(false)
        }
        timer.resume()
        demoAppTimer = timer
    }

    // MARK: Session

    private func startSession() {
        sessionStarted = true
        rebuild()
        let info: [String: Any] = ["mode": "iroh", "codec": "hevc", "playout": "default", "barcodeY": 0.0]
        if let data = try? JSONSerialization.data(withJSONObject: info) { sendControl(23, data) }
        link.restartVideo()     // the first video stream
        videoGeneration += 1
        streaming = true
        forceKey = true
        damageTime = nil
        mirrorNote("streaming")
        encode(recheck: 3)
    }

    private func endSession() {
        streaming = false
        sessionStarted = false
        unacked.removeAll()
        waitingOnViewer = false
        paneWidth = 0
        paneHeight = 0
        currentMbps = 0
        onRelay = true
        otherPath = PathRate()
        ceilingMbps = 0; ceilingUntil = 0; ceilingFound = 0
        ackLog = []; ageHistory = []
    }
}
#endif
