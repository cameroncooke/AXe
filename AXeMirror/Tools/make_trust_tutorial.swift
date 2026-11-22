// Cuts a recording of the trust journey into the looping tutorial AXe Mirror shows in Picture in
// Picture while the person is in Safari and Settings.
//
//     swift make_trust_tutorial.swift <recording.mp4> ../Resources/trust-tutorial.mp4 [canvas width] [bit rate]
//
// The video is a phone on a dark ground with a camera that moves: each new place opens on the whole
// screen, so the person sees where they are, eases in on the control as it is tapped, with a ring
// where the finger goes, and eases out again. Under it, the step in large type, numbered as the
// app's own setup screen numbers them, and a bar that shows how far round the loop it is.
//
// The recording is of an iPhone simulator (402 by 874 points, dark, 9:41), made with `xcrun simctl
// io recordVideo` while each step was tapped in turn with a few seconds between them: Safari's
// question, the Home Screen, Settings, the profile, Certificate Trust Settings, and back to the
// app. The times and points below are read from that recording (the moment the screen starts to
// change after each touch), so a new recording needs new numbers.
import AppKit
import AVFoundation
import CoreText

let arguments = CommandLine.arguments
guard arguments.count >= 3 else { fatalError("usage: make_trust_tutorial.swift <recording.mp4> <out.mp4> [canvas width] [bit rate]") }
let W = CGFloat(arguments.count > 3 ? Int(arguments[3]) ?? 900 : 900)
let bitRate = arguments.count > 4 ? Int(arguments[4]) ?? 480_000 : 480_000
let pictureH = (W * 910 / 900).rounded(), bandH = (W * 290 / 900).rounded(), H = pictureH + bandH
let unit = W / 900                                  // sizes below are for a canvas 900 wide
let fps = 30.0
let screen = CGSize(width: 402, height: 874)       // the recorded simulator, in points
let fit = (pictureH - 48 * unit) / screen.height   // pixels to a point with the whole screen in view

/// Where the camera looks: the point of the screen at the middle of the picture, and how far in.
/// At zoom 1 the whole screen is in view; at 2 the screen is a little wider than the picture.
struct Cam: Equatable {
    var x: CGFloat, y: CGFloat, zoom: CGFloat
    static let wide = Cam(x: 201, y: 437, zoom: 1)
    static func at(_ y: CGFloat, zoom: CGFloat = 2.0) -> Cam { Cam(x: 201, y: y, zoom: zoom) }

    /// Kept from looking past the top or the bottom of the phone by more than a sliver.
    var clamped: Cam {
        let seen = pictureH / (fit * zoom)
        guard seen < screen.height else { return Cam(x: x, y: screen.height / 2, zoom: zoom) }
        return Cam(x: x, y: min(max(y, seen / 2 - 16), screen.height - seen / 2 + 16), zoom: zoom)
    }
}

enum Touch {
    case tap(at: Double, CGPoint)
    case swipe(from: Double, to: Double, CGPoint, CGPoint)
}

/// A stretch of the recording played as it happened. Times are the recording's own.
struct Shot {
    var from: Double, to: Double
    var step: Int                       // 1 to 3, as the app's setup screen numbers them; 0 for the end
    var caption: String
    var camera: [(at: Double, Cam)]     // eased between; held before the first and after the last
    var touch: Touch?
    var duration: Double { to - from }
}

let stepNames = ["", "Download it", "Install it", "Switch it on"]
let safari = Cam.at(450), top = Cam.at(240), alert = Cam.at(470), general = Cam.at(400), bottom = Cam.at(700), trust = Cam.at(400)

let shots: [Shot] = [
    // 1 · Download it
    Shot(from: 5.6, to: 8.9, step: 1, caption: "In Safari, tap Allow",
         camera: [(6.1, .wide), (6.8, safari)], touch: .tap(at: 7.15, CGPoint(x: 340, y: 463))),
    Shot(from: 10.9, to: 13.4, step: 1, caption: "Then tap Close",
         camera: [(10.9, safari), (12.7, safari), (13.3, .wide)], touch: .tap(at: 12.25, CGPoint(x: 201, y: 497))),
    // 2 · Install it
    Shot(from: 14.8, to: 17.6, step: 2, caption: "Go to the Home Screen",
         camera: [(14.8, .wide)], touch: .swipe(from: 15.55, to: 16.25, CGPoint(x: 201, y: 860), CGPoint(x: 201, y: 610))),
    Shot(from: 19.3, to: 21.75, step: 2, caption: "Open Settings",
         camera: [(19.6, .wide), (20.35, Cam.at(423)), (21.15, Cam.at(423)), (21.7, .wide)], touch: .tap(at: 20.95, CGPoint(x: 340, y: 423))),
    Shot(from: 24.6, to: 28.0, step: 2, caption: "Tap Profile Downloaded",
         camera: [(25.0, .wide), (25.75, Cam.at(406)), (26.9, Cam.at(406)), (27.6, top)], touch: .tap(at: 26.35, CGPoint(x: 201, y: 406))),
    Shot(from: 30.2, to: 32.3, step: 2, caption: "Tap Install",
         camera: [(30.2, top)], touch: .tap(at: 31.25, CGPoint(x: 346, y: 100))),
    Shot(from: 35.1, to: 37.15, step: 2, caption: "Enter your passcode, then tap Install",
         camera: [(35.1, top), (36.55, top), (37.1, alert)], touch: .tap(at: 36.25, CGPoint(x: 346, y: 100))),
    Shot(from: 40.4, to: 42.65, step: 2, caption: "Tap Install once more",
         camera: [(40.4, alert), (41.95, alert), (42.55, top)], touch: .tap(at: 41.45, CGPoint(x: 275, y: 497))),
    Shot(from: 46.5, to: 48.7, step: 2, caption: "Tap the tick to finish",
         camera: [(46.5, top), (47.95, top), (48.55, .wide)], touch: .tap(at: 47.55, CGPoint(x: 364, y: 100))),
    // 3 · Switch it on
    Shot(from: 50.9, to: 53.2, step: 3, caption: "Go back to General",
         camera: [(50.9, .wide), (51.15, .wide), (51.8, top), (52.5, top), (53.1, general)], touch: .tap(at: 52.15, CGPoint(x: 38, y: 84))),
    Shot(from: 56.2, to: 58.6, step: 3, caption: "Tap About",
         camera: [(56.2, general), (57.75, general), (58.4, .wide)], touch: .tap(at: 57.25, CGPoint(x: 201, y: 434))),
    Shot(from: 62.3, to: 64.45, step: 3, caption: "Scroll to the bottom",
         camera: [(62.3, .wide), (63.8, .wide), (64.4, bottom)], touch: .swipe(from: 62.95, to: 63.5, CGPoint(x: 201, y: 640), CGPoint(x: 201, y: 400))),
    Shot(from: 67.2, to: 69.4, step: 3, caption: "Tap Certificate Trust Settings",
         camera: [(67.2, bottom), (68.3, bottom), (68.95, .wide)], touch: .tap(at: 68.15, CGPoint(x: 201, y: 776))),
    Shot(from: 71.5, to: 74.6, step: 3, caption: "Switch on AXe Mirror installs",
         camera: [(71.8, .wide), (72.55, trust)], touch: .tap(at: 73.25, CGPoint(x: 336, y: 322))),
    Shot(from: 77.5, to: 80.4, step: 3, caption: "Tap Continue",
         camera: [(77.5, trust), (78.95, trust), (79.6, .wide)], touch: .tap(at: 78.45, CGPoint(x: 275, y: 517))),
    Shot(from: 82.3, to: 84.6, step: 3, caption: "Go back to the Home Screen",
         camera: [(82.3, .wide)], touch: .swipe(from: 82.65, to: 83.35, CGPoint(x: 201, y: 860), CGPoint(x: 201, y: 610))),
    Shot(from: 86.3, to: 88.3, step: 3, caption: "Find AXe Mirror",
         camera: [(86.3, .wide)], touch: .swipe(from: 86.9, to: 87.35, CGPoint(x: 330, y: 520), CGPoint(x: 90, y: 520))),
    Shot(from: 90.5, to: 92.36, step: 3, caption: "Open AXe Mirror",
         camera: [(90.7, .wide), (91.45, Cam.at(240))], touch: .tap(at: 92.05, CGPoint(x: 340, y: 222))),
    // The end: the Home Screen again, dimmed, under a tick.
    Shot(from: 0, to: 2.7, step: 0, caption: "That’s it. All set up", camera: [(0, .wide)], touch: nil),
]
let endFrame = 90.4
let fade = 0.26
let total = shots.reduce(0) { $0 + $1.duration }

func ease(_ t: Double) -> Double { let c = min(1, max(0, t)); return c * c * (3 - 2 * c) }

func camera(of shot: Shot, at time: Double) -> Cam {
    guard let first = shot.camera.first, time > first.at else { return (shot.camera.first?.1 ?? .wide).clamped }
    for (index, key) in shot.camera.enumerated().dropFirst() where time <= key.at {
        let before = shot.camera[index - 1]
        let a = before.1.clamped, b = key.1.clamped
        let t = CGFloat(ease((time - before.at) / (key.at - before.at)))
        // The zoom is eased as a ratio, so the picture grows evenly on the way in and out.
        return Cam(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t, zoom: a.zoom * pow(b.zoom / a.zoom, t))
    }
    return shot.camera[shot.camera.count - 1].1.clamped
}

/// Reads the recording's frames in order. It has a frame only when the screen changed, so the
/// picture at a time is the last frame at or before it.
final class Source {
    let asset: AVURLAsset
    let track: AVAssetTrack
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var current: (time: Double, buffer: CVPixelBuffer)?
    private var next: (time: Double, buffer: CVPixelBuffer)?
    private var cached: (time: Double, image: CGImage)?

    init(_ path: String) {
        asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let wait = DispatchSemaphore(value: 0)
        var found: AVAssetTrack?
        let asset = self.asset
        Task { found = try? await asset.loadTracks(withMediaType: .video).first; wait.signal() }
        wait.wait()
        track = found!
    }

    func seek(to time: Double) {
        reader?.cancelReading()
        let reader = try! AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, time - 4), preferredTimescale: 600), duration: .positiveInfinity)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()
        self.reader = reader
        self.output = output
        current = nil
        next = read()
        cached = nil
    }

    private func read() -> (time: Double, buffer: CVPixelBuffer)? {
        while let sample = output?.copyNextSampleBuffer() {
            if let buffer = CMSampleBufferGetImageBuffer(sample) { return (CMSampleBufferGetPresentationTimeStamp(sample).seconds, buffer) }
        }
        return nil
    }

    func image(at time: Double) -> CGImage? {
        while let coming = next, coming.time <= time || current == nil {
            current = coming
            next = read()
        }
        guard let current else { return nil }
        if let cached, cached.time == current.time { return cached.image }
        CVPixelBufferLockBaseAddress(current.buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(current.buffer, .readOnly) }
        let made = CGContext(data: CVPixelBufferGetBaseAddress(current.buffer), width: CVPixelBufferGetWidth(current.buffer), height: CVPixelBufferGetHeight(current.buffer),
                             bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(current.buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)?.makeImage()
        if let made { cached = (current.time, made) }
        return made
    }
}

let source = Source(arguments[1])

// Everything below draws with the origin at the top left; `R` turns that into the context's own.
func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: H - y - h, width: w, height: h) }
func colour(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Text in a box, from its top, in the largest of `sizes` that fits in `lines` lines. Returns the height used.
@discardableResult
func text(_ string: String, sizes: [CGFloat], weight: NSFont.Weight, colour: CGColor, in ctx: CGContext, x: CGFloat, top: CGFloat, width: CGFloat,
          lines: Int = 2, centredIn height: CGFloat? = nil, centred: Bool = false, tracking: CGFloat = 0) -> CGFloat {
    for (index, size) in sizes.enumerated() {
        let style = NSMutableParagraphStyle()
        style.alignment = centred ? .center : .left
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = size * 0.06
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor(cgColor: colour)!, .paragraphStyle: style, .kern: tracking])
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let fitted = ceil(CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil, CGSize(width: width, height: 10_000), nil).height)
        let line = ceil(font.ascender - font.descender + font.leading + style.lineSpacing)
        guard fitted <= line * CGFloat(lines) + 2 || index == sizes.count - 1 else { continue }
        let y = height.map { top + ($0 - fitted) / 2 } ?? top
        CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: R(x, y, width, fitted + 2), transform: nil), nil), ctx)
        return fitted
    }
    return 0
}

func tick(in ctx: CGContext, centre: CGPoint, radius: CGFloat) {
    ctx.setFillColor(colour(0x34C759))
    ctx.fillEllipse(in: R(centre.x - radius, centre.y - radius, radius * 2, radius * 2))
    ctx.setStrokeColor(colour(0xFFFFFF))
    ctx.setLineWidth(radius * 0.2)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.beginPath()
    for (index, point) in [CGPoint(x: -0.42, y: 0.02), CGPoint(x: -0.12, y: 0.32), CGPoint(x: 0.44, y: -0.3)].enumerated() {
        let place = CGPoint(x: centre.x + point.x * radius, y: H - (centre.y + point.y * radius))
        if index == 0 { ctx.move(to: place) } else { ctx.addLine(to: place) }
    }
    ctx.strokePath()
}

func ring(in ctx: CGContext, centre: CGPoint, radius: CGFloat, alpha: Double) {
    guard alpha > 0 else { return }
    let box = R(centre.x - radius, centre.y - radius, radius * 2, radius * 2)
    ctx.setFillColor(colour(0xFFFFFF, 0.34 * alpha))
    ctx.fillEllipse(in: box)
    // A dark edge outside the white one, so the ring shows on a light icon as well as a dark page.
    ctx.setStrokeColor(colour(0x000000, 0.45 * alpha))
    ctx.setLineWidth(11 * unit)
    ctx.strokeEllipse(in: box)
    ctx.setStrokeColor(colour(0xFFFFFF, 0.97 * alpha))
    ctx.setLineWidth(5 * unit)
    ctx.strokeEllipse(in: box)
}

/// One finished frame: the phone as the camera sees it, the finger's ring, and the band with the step.
func draw(_ shot: Shot, local: Double, overall: Double, in ctx: CGContext) {
    // The ground the phone stands on.
    let ground = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [colour(0x161B26), colour(0x07090D)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(ground, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: bandH), options: [])

    let isEnd = shot.step == 0
    let time = shot.from + local
    let cam = camera(of: shot, at: time)
    let scale = fit * cam.zoom
    let origin = CGPoint(x: W / 2 - cam.x * scale, y: pictureH / 2 - cam.y * scale)
    func place(_ point: CGPoint) -> CGPoint { CGPoint(x: origin.x + point.x * scale, y: origin.y + point.y * scale) }

    ctx.saveGState()
    ctx.clip(to: R(0, 0, W, pictureH))
    // The phone: a body a little larger than its screen, and the screen with its round corners.
    let edge = 7 * scale, corner = 56 * scale
    let glass = R(origin.x, origin.y, screen.width * scale, screen.height * scale)
    let body = glass.insetBy(dx: -edge, dy: -edge)
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * unit), blur: 40 * unit, color: colour(0x000000, 0.6))
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: corner + edge, cornerHeight: corner + edge, transform: nil))
    ctx.setFillColor(colour(0x2B2D33))
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: corner + edge, cornerHeight: corner + edge, transform: nil))
    ctx.setStrokeColor(colour(0xFFFFFF, 0.28))
    ctx.setLineWidth(2 * unit)
    ctx.strokePath()
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: glass, cornerWidth: corner, cornerHeight: corner, transform: nil))
    ctx.clip()
    ctx.setFillColor(colour(0x000000))
    ctx.fill(glass)
    if let picture = source.image(at: isEnd ? endFrame : time) {
        ctx.interpolationQuality = .high
        ctx.draw(picture, in: glass)
    }
    if isEnd {
        ctx.setFillColor(colour(0x000000, 0.66 * ease(local / 0.35)))
        ctx.fill(glass)
    }
    ctx.restoreGState()
    if isEnd {
        ctx.setAlpha(CGFloat(ease(local / 0.35)))
        tick(in: ctx, centre: CGPoint(x: W / 2, y: pictureH / 2), radius: 96 * unit * CGFloat(0.8 + 0.2 * ease(local / 0.4)))
        ctx.setAlpha(1)
    }
    switch shot.touch {
    case .tap(let at, let point):
        // The ring arrives, presses in at the tap, and lets go.
        let since = time - at
        var alpha = 0.0, size = 1.0
        if since < 0 {
            alpha = ease((since + 1.0) / 0.3)
        } else if since < 0.12 {
            alpha = 1; size = 1 - 0.28 * (since / 0.12)
        } else if since < 0.6 {
            let out = (since - 0.12) / 0.48
            alpha = 1 - ease(out); size = 0.72 + 0.9 * ease(out)
        }
        ring(in: ctx, centre: place(point), radius: max(30 * scale, 38 * unit) * CGFloat(size), alpha: alpha)
    case .swipe(let from, let to, let start, let end):
        // The ring lands, travels, and lifts.
        let along = CGFloat(ease((time - from) / (to - from)))
        let alpha = time < from ? ease((time - from + 0.35) / 0.3) : 1 - ease((time - to) / 0.3)
        ring(in: ctx, centre: place(CGPoint(x: start.x + (end.x - start.x) * along, y: start.y + (end.y - start.y) * along)), radius: max(30 * scale, 38 * unit), alpha: alpha)
    case nil:
        break
    }
    ctx.restoreGState()

    // The band: which of the three steps, and what to do now.
    ctx.setFillColor(colour(0x14181F))
    ctx.fill(R(0, pictureH, W, bandH))
    ctx.setFillColor(colour(0xFFFFFF, 0.10))
    ctx.fill(R(0, pictureH, W, 2 * unit))
    let margin = 40 * unit, chip = 108 * unit, middle = pictureH + (bandH - 8 * unit) / 2
    if isEnd {
        tick(in: ctx, centre: CGPoint(x: margin + chip / 2, y: middle), radius: chip / 2)
    } else {
        ctx.setFillColor(colour(0x0A84FF))
        ctx.fillEllipse(in: R(margin, middle - chip / 2, chip, chip))
        text(String(shot.step), sizes: [66 * unit], weight: .bold, colour: colour(0xFFFFFF), in: ctx, x: margin, top: middle - chip / 2, width: chip,
             lines: 1, centredIn: chip, centred: true)
    }
    let left = margin + chip + 30 * unit, width = W - left - margin
    let label = isEnd ? "DONE" : "STEP \(shot.step) OF 3 · \(stepNames[shot.step].uppercased())"
    let labelTop = pictureH + 34 * unit
    text(label, sizes: [27 * unit], weight: .semibold, colour: colour(0x8FA0BA), in: ctx, x: left, top: labelTop, width: width, lines: 1, tracking: 1.5 * unit)
    let captionTop = labelTop + 44 * unit
    text(shot.caption, sizes: [62 * unit, 56 * unit, 50 * unit, 45 * unit], weight: .semibold, colour: colour(0xFFFFFF), in: ctx, x: left, top: captionTop, width: width,
         centredIn: pictureH + bandH - 26 * unit - captionTop)

    // How far round the loop this is.
    let bar = 8 * unit
    ctx.setFillColor(colour(0xFFFFFF, 0.12))
    ctx.fill(R(0, H - bar, W, bar))
    ctx.setFillColor(colour(0x0A84FF))
    ctx.fill(R(0, H - bar, W * CGFloat(overall / total), bar))
}

// The writer.
let out = URL(fileURLWithPath: arguments[2])
try? FileManager.default.removeItem(at: out)
let writer = try! AVAssetWriter(outputURL: out, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: Int(W), AVVideoHeightKey: Int(H),
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitRate, AVVideoMaxKeyFrameIntervalKey: 90],
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: Int(W), kCVPixelBufferHeightKey as String: Int(H),
])
writer.add(input)
writer.shouldOptimizeForNetworkUse = true
guard writer.startWriting() else { fatalError("\(String(describing: writer.error))") }
writer.startSession(atSourceTime: .zero)

var frame = 0
var before: CGImage?            // the last frame of the shot before, to fade from where time is skipped
var elapsed = 0.0
for shot in shots {
    source.seek(to: shot.step == 0 ? endFrame : shot.from)
    let count = Int((shot.duration * fps).rounded())
    var last: CGImage?
    for index in 0..<count {
        let local = Double(index) / fps
        while !input.isReadyForMoreMediaData { usleep(2000) }
        var made: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &made)
        guard let buffer = made else { fatalError("no buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        draw(shot, local: local, overall: elapsed + local, in: ctx)
        if index == count - 1 { last = ctx.makeImage() }
        if let before, local < fade {
            ctx.setAlpha(CGFloat(1 - ease(local / fade)))
            ctx.draw(before, in: CGRect(x: 0, y: 0, width: W, height: H))
            ctx.setAlpha(1)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        frame += 1
    }
    before = last
    elapsed += shot.duration
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
print("wrote \(frame) frames, \(String(format: "%.1f", Double(frame) / fps)) s, \(size / 1024) KB, \(Int(W))x\(Int(H))")
