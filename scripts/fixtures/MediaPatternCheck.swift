// Checks frames of the Playground Capture Markers screen (`screen=media-pattern`).
//
// Usage: MediaPatternCheck <file>
//   .png/.jpg  one screenshot
//   .raw       `stream-video --format raw` output (JPEG frames, split at SOI/EOI markers)
//   .mp4/.mov  `record-video` output (AVAssetReader)
//   .h264      `stream-video --format h264` Annex B output (VideoToolbox)
//
// Prints one JSON object: frame count and sizes, content padding, the clockwise rotations that made
// frames upright, phases in order with frame counts, and how many frames failed the phase,
// white-square or edge checks. Native H.264 keeps the panel's orientation, so frames may need turning. Each frame is checked for the four
// quadrant colours in the order the phase sets, the four white squares at their known centres with tile
// colour around them and none at mirrored positions, and the tile colour at eight outer edge samples.
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import VideoToolbox

struct Frame { let width: Int; let height: Int; let stride: Int; let bytes: [UInt8] }

/// A frame turned clockwise by `rotation` degrees, without copying pixels.
struct View {
    let frame: Frame
    let rotation: Int
    var width: Int { rotation % 180 == 0 ? frame.width : frame.height }
    var height: Int { rotation % 180 == 0 ? frame.height : frame.width }

    func source(_ x: Int, _ y: Int) -> (Int, Int) {
        switch rotation {
        case 90: return (y, frame.height - 1 - x)
        case 180: return (frame.width - 1 - x, frame.height - 1 - y)
        case 270: return (frame.width - 1 - y, x)
        default: return (x, y)
        }
    }
}

enum Colour: String { case red, green, blue, yellow, white, black, other }
let tileOrder: [Colour] = [.red, .green, .blue, .yellow]

func pixel(_ v: View, _ x: Int, _ y: Int) -> (Int, Int, Int) {
    let (px, py) = v.source(max(0, min(v.width - 1, x)), max(0, min(v.height - 1, y)))
    let f = v.frame
    let offset = py * f.stride + px * 4
    return (Int(f.bytes[offset + 2]), Int(f.bytes[offset + 1]), Int(f.bytes[offset]))
}

func colour(_ c: (Int, Int, Int)) -> Colour {
    let (r, g, b) = c
    if r > 200 && g > 200 && b > 200 { return .white }
    if r < 60 && g < 60 && b < 60 { return .black }
    // Video chroma subsampling desaturates tile colours next to the white squares.
    if r > 170 && g > 170 && b < 130 { return .yellow }
    if r > 170 && g < 130 && b < 130 { return .red }
    if g > 170 && r < 130 && b < 130 { return .green }
    if b > 170 && r < 130 && g < 130 { return .blue }
    return .other
}

struct Result { var phase: Int?; var squares = false; var edges = false; var padding = [0, 0, 0, 0] }

func analyse(_ f: View) -> Result {
    var result = Result()
    func isTile(_ x: Int, _ y: Int) -> Bool { tileOrder.contains(colour(pixel(f, x, y))) }
    let rows = [0.40, 0.60].map { Int($0 * Double(f.height)) }
    let columns = [0.12, 0.88].map { Int($0 * Double(f.width)) }
    // Native video can pad the right and bottom edges; find the content bounds.
    let left = rows.map { y in (0..<f.width).first { isTile($0, y) } ?? f.width }.max()!
    let right = rows.map { y in f.width - 1 - ((0..<f.width).reversed().first { isTile($0, y) } ?? 0) }.max()!
    let top = columns.map { x in (0..<f.height).first { isTile(x, $0) } ?? f.height }.max()!
    let bottom = columns.map { x in f.height - 1 - ((0..<f.height).reversed().first { isTile(x, $0) } ?? 0) }.max()!
    result.padding = [left, top, right, bottom]
    let width = f.width - left - right, height = f.height - top - bottom
    guard width > 0, height > 0 else { return result }
    func at(_ fx: Double, _ fy: Double) -> Colour {
        colour(pixel(f, left + Int(fx * Double(width)), top + Int(fy * Double(height))))
    }
    let quadrants = [at(0.12, 0.40), at(0.88, 0.40), at(0.12, 0.60), at(0.88, 0.60)]
    guard let phase = tileOrder.firstIndex(of: quadrants[0]),
          (0..<4).allSatisfy({ quadrants[$0] == tileOrder[($0 + phase) % 4] }) else { return result }
    result.phase = phase

    let centres = [(0.065, 0.18), (0.935, 0.22), (0.075, 0.79), (0.925, 0.84)]
    let side = 0.045 * Double(min(width, height))
    let dx = side * 1.2 / Double(width), dy = side * 1.2 / Double(height)
    result.squares = centres.enumerated().allSatisfy { index, centre in
        // Each tile label sits at the tile centre, so check vertically on the side away from it.
        let away = centre.1 < 0.5 ? -dy : dy
        return at(centre.0, centre.1) == .white
            && [(dx, 0.0), (-dx, 0.0), (0.0, away)].allSatisfy { at(centre.0 + $0.0, centre.1 + $0.1) == quadrants[index] }
            && at(1 - centre.0, centre.1) != .white && at(centre.0, 1 - centre.1) != .white
    }
    let samples: [(Int, Int, Int)] = [
        (0, left + width / 4, top), (0, left, top + height / 4),
        (1, left + 3 * width / 4, top), (1, left + width - 1, top + height / 4),
        (2, left, top + 3 * height / 4), (2, left + width / 4, top + height - 1),
        (3, left + width - 1, top + 3 * height / 4), (3, left + 3 * width / 4, top + height - 1),
    ]
    result.edges = samples.allSatisfy { colour(pixel(f, $0.1, $0.2)) == quadrants[$0.0] }
    return result
}

func frame(_ image: CGImage) -> Frame {
    let width = image.width, height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return Frame(width: width, height: height, stride: width * 4, bytes: bytes)
}

func frame(_ buffer: CVPixelBuffer) -> Frame {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    return Frame(width: width, height: height, stride: stride, bytes: Array(UnsafeBufferPointer(start: base, count: stride * height)))
}

func images(_ url: URL) -> [Frame] {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
    return (0..<CGImageSourceGetCount(source)).compactMap { CGImageSourceCreateImageAtIndex(source, $0, nil).map(frame) }
}

func jpegs(_ url: URL) throws -> [Frame] {
    let data = [UInt8](try Data(contentsOf: url))
    var frames: [Frame] = []
    var index = 0
    while index + 1 < data.count {
        guard data[index] == 0xFF, data[index + 1] == 0xD8 else { index += 1; continue }
        var end = index + 2
        while end + 1 < data.count, !(data[end] == 0xFF && data[end + 1] == 0xD9) { end += 1 }
        let jpeg = Data(data[index...min(end + 1, data.count - 1)])
        if let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            frames.append(frame(image))
        }
        index = end + 2
    }
    return frames
}

func movie(_ url: URL) async throws -> [Frame] {
    let asset = AVURLAsset(url: url)
    let track = try await asset.loadTracks(withMediaType: .video)[0]
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track,
        outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output)
    reader.startReading()
    var frames: [Frame] = []
    while let sample = output.copyNextSampleBuffer() {
        if let buffer = CMSampleBufferGetImageBuffer(sample) { frames.append(frame(buffer)) }
    }
    return frames
}

func annexB(_ url: URL) throws -> (frames: [Frame], decodeFailures: Int) {
    let data = [UInt8](try Data(contentsOf: url))
    var starts: [Int] = []
    var index = 0
    while index + 3 <= data.count {
        if data[index] == 0, data[index + 1] == 0, data[index + 2] == 1 { starts.append(index + 3); index += 3 } else { index += 1 }
    }
    var units: [[UInt8]] = []
    for (number, start) in starts.enumerated() {
        var end = number + 1 < starts.count ? starts[number + 1] - 3 : data.count
        while end > start, data[end - 1] == 0 { end -= 1 }
        if end > start { units.append(Array(data[start..<end])) }
    }
    var sps: [UInt8]?, pps: [UInt8]?
    var format: CMVideoFormatDescription?
    var session: VTDecompressionSession?
    var frames: [Frame] = []
    var pending: [[UInt8]] = []
    var failures = 0
    func configure() {
        guard let sps, let pps else { return }
        var description: CMVideoFormatDescription?
        sps.withUnsafeBufferPointer { s in pps.withUnsafeBufferPointer { p in
            _ = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2,
                parameterSetPointers: [s.baseAddress!, p.baseAddress!], parameterSetSizes: [sps.count, pps.count],
                nalUnitHeaderLength: 4, formatDescriptionOut: &description)
        } }
        guard let description else { return }
        if let format, session != nil, CMFormatDescriptionEqual(format, otherFormatDescription: description) { return }
        format = description
        if let session { VTDecompressionSessionInvalidate(session) }
        let attributes = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] as CFDictionary
        VTDecompressionSessionCreate(allocator: nil, formatDescription: description, decoderSpecification: nil,
            imageBufferAttributes: attributes, outputCallback: nil, decompressionSessionOut: &session)
    }
    func flush() {
        defer { pending = [] }
        guard !pending.isEmpty, let session, let format else { return }
        var avcc: [UInt8] = []
        for unit in pending {
            withUnsafeBytes(of: UInt32(unit.count).bigEndian) { avcc.append(contentsOf: $0) }
            avcc.append(contentsOf: unit)
        }
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: avcc.count, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block)
        guard let block else { failures += 1; return }
        CMBlockBufferReplaceDataBytes(with: avcc, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count)
        var sample: CMSampleBuffer?
        var size = avcc.count
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample)
        guard let sample else { failures += 1; return }
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
            result, _, image, _, _ in
            if result == noErr, let image { frames.append(frame(image)) } else { failures += 1 }
        }
        if status != noErr { failures += 1 }
    }
    for unit in units {
        switch unit[0] & 0x1F {
        case 7: flush(); sps = unit
        case 8: flush(); pps = unit; configure()
        case 1, 5:
            // A slice whose first_mb_in_slice is zero starts a new picture.
            if unit.count > 1, unit[1] & 0x80 != 0 { flush() }
            pending.append(unit)
        default: break
        }
    }
    flush()
    return (frames, failures)
}

@main
struct MediaPatternCheck {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: MediaPatternCheck <file>\n".utf8))
            exit(64)
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        var decodeFailures = 0
        let frames: [Frame]
        switch url.pathExtension.lowercased() {
        case "mp4", "mov": frames = try await movie(url)
        case "h264": (frames, decodeFailures) = try annexB(url)
        case "raw": frames = try jpegs(url)
        default: frames = images(url)
        }
        var phases: [[Int]] = []
        var rotations = Set<Int>()
        var preferred = 0
        var noPhase = 0, squareFailures = 0, edgeFailures = 0
        var sizes = Set<String>(), paddings = Set<String>()
        for f in frames {
            sizes.insert("\(f.width)x\(f.height)")
            var result = analyse(View(frame: f, rotation: preferred))
            if result.phase == nil {
                for rotation in [0, 90, 180, 270] where rotation != preferred {
                    let turned = analyse(View(frame: f, rotation: rotation))
                    if turned.phase != nil { result = turned; preferred = rotation; break }
                }
            }
            if result.phase != nil { rotations.insert(preferred) }
            paddings.insert(result.padding.map(String.init).joined(separator: ","))
            guard let phase = result.phase else { noPhase += 1; continue }
            if !result.squares { squareFailures += 1 }
            if !result.edges { edgeFailures += 1 }
            if let last = phases.last, last[0] == phase { phases[phases.count - 1][1] += 1 } else { phases.append([phase, 1]) }
        }
        let summary: [String: Any] = [
            "frames": frames.count, "sizes": sizes.sorted(), "rotations": rotations.sorted(), "padding": paddings.sorted(), "phases": phases,
            "noPhase": noPhase, "squareFailures": squareFailures, "edgeFailures": edgeFailures,
            "decodeFailures": decodeFailures,
        ]
        let json = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
        FileHandle.standardOutput.write(json + Data("\n".utf8))
    }
}
