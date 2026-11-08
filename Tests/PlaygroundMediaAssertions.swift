import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Testing
@preconcurrency import AVFoundation

struct PlaygroundMarkerGeometry {
    let width: Int
    let height: Int
    let x: [Double]
    let y: [Double]
    let bounds: [CGRect]
    let samplingStep: Int
}

/// Normal visible cell frames from raw AX, matched to fresh native display size and rotation.
struct PlaygroundMediaLayout {
    let name: String
    let width: Double
    let height: Double
    let cells: [CGRect]

    func contentRect(canvasWidth: Int, canvasHeight: Int) -> CGRect {
        let scale = min(Double(canvasWidth) / width, Double(canvasHeight) / height)
        return CGRect(x: (Double(canvasWidth) - width * scale) / 2,
            y: (Double(canvasHeight) - height * scale) / 2,
            width: width * scale, height: height * scale)
    }

    func fittedCells(canvasWidth: Int, canvasHeight: Int) -> [CGRect] {
        let content = contentRect(canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        let scale = content.width / width
        return cells.map { CGRect(x: content.minX + $0.minX * scale, y: content.minY + $0.minY * scale,
            width: $0.width * scale, height: $0.height * scale) }
    }
}

enum PlaygroundMediaAssertions {
    static func image(_ data: Data, type: String) throws -> PlaygroundMarkerGeometry {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil), "Media is not a decodable image.")
        try #require(CGImageSourceGetType(source).map { CFEqual($0, type as CFString) } == true)
        try #require(CGImageSourceGetStatus(source) == .statusComplete && CGImageSourceGetCount(source) == 1)
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixels = Data(count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
            context.draw(image, in: CGRect(x: 0, y: image.height, width: image.width, height: -image.height))
        }
        return try markers(pixels, width: image.width, height: image.height, bytesPerRow: image.width * 4)
    }

    static func markers(_ pixels: Data, width: Int, height: Int, bytesPerRow: Int) throws -> PlaygroundMarkerGeometry {
        let detected = detectMarkers(pixels, width: width, height: height, bytesPerRow: bytesPerRow)
        return try #require(detected.geometry, "\(detected.failure)")
    }

    /// Finds the four upright capture markers without recording a test issue, so a caller can
    /// judge a frame that legitimately shows none (such as one captured mid-rotation).
    static func detectMarkers(_ pixels: Data, width: Int, height: Int,
                              bytesPerRow: Int) -> (geometry: PlaygroundMarkerGeometry?, failure: String) {
        guard width > 0 && height > 0 && bytesPerRow >= width * 4 && pixels.count >= bytesPerRow * height else {
            return (nil, "The frame buffer is smaller than its size: \(width)x\(height), \(bytesPerRow) bytes per row")
        }
        var count = [Int](repeating: 0, count: 4)
        var x = [Double](repeating: 0, count: 4)
        var y = x
        var minX = [Int](repeating: width, count: 4), minY = [Int](repeating: height, count: 4)
        var maxX = [Int](repeating: -1, count: 4), maxY = [Int](repeating: -1, count: 4)
        let step = max(1, min(width, height) / 100)
        pixels.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for row in stride(from: 0, to: height, by: step) {
                for column in stride(from: 0, to: width, by: step) {
                    let offset = row * bytesPerRow + column * 4
                    let b = bytes[offset], g = bytes[offset + 1], r = bytes[offset + 2]
                    let index: Int?
                    if r > 180, g < 65, b < 65 { index = 0 }
                    else if g > 180, r < 65, b < 65 { index = 1 }
                    else if b > 180, r < 65, g < 65 { index = 2 }
                    else if r > 180, g > 180, b < 65 { index = 3 }
                    else { index = nil }
                    guard let index else { continue }
                    count[index] += 1; x[index] += Double(column); y[index] += Double(row)
                    minX[index] = min(minX[index], column); minY[index] = min(minY[index], row)
                    maxX[index] = max(maxX[index], column); maxY[index] = max(maxY[index], row)
                }
            }
        }
        guard count.allSatisfy({ $0 >= 25 }) else { return (nil, "The frame is missing a visible colour marker: \(count)") }
        for index in 0..<4 { x[index] /= Double(count[index]); y[index] /= Double(count[index]) }
        guard x[0] < x[1] && x[2] < x[3] && y[0] < y[2] && y[1] < y[3] else {
            return (nil, "Capture markers are not upright: x=\(x), y=\(y)")
        }
        guard abs(x[0] - x[2]) < Double(width) * 0.08 && abs(y[0] - y[1]) < Double(height) * 0.08 else {
            return (nil, "Capture markers are not aligned in a grid: x=\(x), y=\(y)")
        }
        let bounds = (0..<4).map { CGRect(x: minX[$0], y: minY[$0],
            width: maxX[$0] - minX[$0] + step, height: maxY[$0] - minY[$0] + step) }
        return (PlaygroundMarkerGeometry(width: width, height: height, x: x, y: y,
            bounds: bounds, samplingStep: step), "")
    }

    static func streamFrames(_ data: Data, format: String, width: Int, height: Int,
                             complete: Bool) throws -> [Data] {
        var frames: [Data] = []
        var offset = 0
        if format == "bgra" {
            let length = width * height * 4
            try #require(length > 0)
            while data.count - offset >= length {
                frames.append(data.subdata(in: offset..<(offset + length)))
                offset += length
            }
        } else if format == "raw" {
            while data.count - offset >= 4 {
                let length = data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
                try #require(length > 4 && length < 64_000_000)
                guard data.count - offset - 4 >= length else { break }
                frames.append(data.subdata(in: (offset + 4)..<(offset + 4 + length)))
                offset += 4 + length
            }
        } else if format == "ffmpeg" {
            while data.count - offset >= 2 {
                try #require(data[offset] == 0xff && data[offset + 1] == 0xd8, "Concatenated frame lacks JPEG SOI.")
                guard let end = data.range(of: Data([0xff, 0xd9]), in: (offset + 2)..<data.count) else { break }
                frames.append(data.subdata(in: offset..<end.upperBound))
                offset = end.upperBound
            }
        } else {
            let header = Data("HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=mjpegstream\r\n\r\n".utf8)
            guard data.count >= header.count else { return [] }
            try #require(data.prefix(header.count) == header)
            offset = header.count
            let trailer = Data("--mjpegstream--\r\n".utf8)
            while offset < data.count {
                if data.suffix(from: offset) == trailer { offset = data.count; break }
                guard let end = data.range(of: Data("\r\n\r\n".utf8), in: offset..<data.count),
                      let text = String(data: data.subdata(in: offset..<end.lowerBound), encoding: .utf8) else { break }
                try #require(text.hasPrefix("--mjpegstream\r\nContent-Type: image/jpeg\r\nContent-Length: "))
                let length = try #require(Int(text.components(separatedBy: "Content-Length: ").last ?? ""))
                guard data.count - end.upperBound >= length + 2 else { break }
                frames.append(data.subdata(in: end.upperBound..<(end.upperBound + length)))
                try #require(data.subdata(in: (end.upperBound + length)..<(end.upperBound + length + 2)) == Data("\r\n".utf8))
                offset = end.upperBound + length + 2
            }
            if complete { try #require(data.suffix(trailer.count) == trailer) }
        }
        if complete { try #require(offset == data.count, "Incomplete or extra stream bytes: \(data.count - offset)") }
        return frames
    }

    static func movie(_ url: URL, width: Int, height: Int, expectedFrames: Int,
                      layouts: [PlaygroundMediaLayout] = []) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try #require(tracks.first)
        try #require(tracks.count == 1)
        let compressedTimes = try compressedPresentationTimes(asset: asset, track: track, expectedFrames: expectedFrames)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        try #require(reader.canAdd(output))
        reader.add(output)
        try #require(reader.startReading())
        var frames = 0
        var previous: CMTime?
        var observedLayouts = Set<Int>()
        var observedBlackBars = false
        // Per frame: the settled layouts it matches, and why it matched none.
        var frameLayouts: [Set<Int>] = []
        var unmatched: [Int: String] = [:]
        while let sample = output.copyNextSampleBuffer() {
            try #require(CMSampleBufferIsValid(sample) && CMSampleBufferDataIsReady(sample))
            let sampleCount = CMSampleBufferGetNumSamples(sample)
            if sampleCount == 0 { continue } // Public AVAssetReader marker buffer, not a video frame.
            try #require(sampleCount == 1 && frames < compressedTimes.count)
            let time = try presentationTime(sample, at: 0)
            try #require(time.isValid && time.isNumeric)
            try #require(CMTimeCompare(time, compressedTimes[frames]) == 0,
                "Decoded frame time differs from its compressed sample time.")
            if let previous { try #require(CMTimeCompare(time, previous) > 0, "Movie timestamps did not increase.") }
            else { try #require(CMTimeCompare(time, .zero) == 0) }
            previous = time
            let buffer = try #require(CMSampleBufferGetImageBuffer(sample))
            try #require(CVPixelBufferGetWidth(buffer) == width && CVPixelBufferGetHeight(buffer) == height)
            try #require(CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess)
            do {
                let address = try #require(CVPixelBufferGetBaseAddress(buffer))
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                let pixels = Data(bytes: address, count: stride * height)
                if layouts.isEmpty {
                    _ = try markers(pixels, width: width, height: height, bytesPerRow: stride)
                } else {
                    // A frame captured during a rotation or fold animation is genuine screen content
                    // that matches no settled layout. It is checked against its neighbours below.
                    var matched = Set<Int>()
                    let detected = detectMarkers(pixels, width: width, height: height, bytesPerRow: stride)
                    if let geometry = detected.geometry {
                        matched = matchingLayouts(pixels, geometry: geometry, bytesPerRow: stride, layouts: layouts)
                        if matched.isEmpty {
                            let expected = layouts.map { "\($0.name): \($0.fittedCells(canvasWidth: width, canvasHeight: height))" }
                            unmatched[frames] = "actual=\(geometry.bounds), expected=\(expected)"
                        }
                    } else {
                        unmatched[frames] = detected.failure
                    }
                    frameLayouts.append(matched)
                    observedLayouts.formUnion(matched)
                    if matched.contains(where: { index in
                        let content = layouts[index].contentRect(canvasWidth: width, canvasHeight: height)
                        return content.minX > 8 || content.minY > 8
                    }) { observedBlackBars = true }
                }
            } catch {
                CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
                throw error
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            frames += 1
        }
        try #require(reader.status == .completed, "Movie decode failed: \(reader.error?.localizedDescription ?? "unknown")")
        try #require(frames == expectedFrames && frames >= 2, "Movie decoded \(frames), expected \(expectedFrames).")
        if !layouts.isEmpty {
            // An unmatched frame is allowed only inside a layout change: the nearest matched frames
            // on both sides must show different layouts. The first and last frames must match.
            for (index, matched) in frameLayouts.enumerated() where matched.isEmpty {
                let before = frameLayouts[..<index].last { !$0.isEmpty }
                let after = frameLayouts[(index + 1)...].first { !$0.isEmpty }
                let insideChange = before.flatMap { before in after.map { before.isDisjoint(with: $0) } } ?? false
                try #require(insideChange,
                    "Decoded frame \(index) differs from every settled layout outside a layout change: \(unmatched[index] ?? "")")
            }
            try #require(observedLayouts == Set(layouts.indices), "A requested visible layout was absent from the decoded movie.")
            try #require(observedBlackBars, "The recording never showed the required decoded black bars.")
        }
    }

    private static func compressedPresentationTimes(asset: AVAsset, track: AVAssetTrack,
                                                    expectedFrames: Int) throws -> [CMTime] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        try #require(reader.canAdd(output))
        reader.add(output)
        try #require(reader.startReading())
        defer { reader.cancelReading() }
        var times: [CMTime] = []
        while let sample = output.copyNextSampleBuffer() {
            try #require(CMSampleBufferIsValid(sample) && CMSampleBufferDataIsReady(sample))
            let count = CMSampleBufferGetNumSamples(sample)
            try #require(count >= 0 && count <= expectedFrames - times.count)
            for index in 0..<count { times.append(try presentationTime(sample, at: index)) }
        }
        try #require(reader.status == .completed, "Compressed sample read failed: \(reader.error?.localizedDescription ?? "unknown")")
        try #require(times.count == expectedFrames && times.count >= 2)
        times.sort { CMTimeCompare($0, $1) < 0 } // Compressed decode order can differ from presentation order.
        for index in 1..<times.count {
            try #require(CMTimeCompare(times[index], times[index - 1]) > 0)
        }
        return times
    }

    private static func presentationTime(_ sample: CMSampleBuffer, at index: Int) throws -> CMTime {
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
        let result = CMSampleBufferGetSampleTimingInfo(sample, at: index, timingInfoOut: &timing)
        try #require(result == noErr && timing.presentationTimeStamp.isValid && timing.presentationTimeStamp.isNumeric)
        return timing.presentationTimeStamp
    }

    private static func matchingLayouts(_ pixels: Data, geometry: PlaygroundMarkerGeometry,
                                        bytesPerRow: Int, layouts: [PlaygroundMediaLayout]) -> Set<Int> {
        // Sample-grid rounding plus a small H264 colour-edge margin, expressed in output pixels.
        let tolerance = Double(geometry.samplingStep + 3)
        let matching = Set(layouts.indices.filter { index in
            let expected = layouts[index].fittedCells(canvasWidth: geometry.width, canvasHeight: geometry.height)
            let geometryMatches = zip(geometry.bounds, expected).allSatisfy { actual, target in
                abs(actual.minX - target.minX) <= tolerance && abs(actual.minY - target.minY) <= tolerance
                    && abs(actual.maxX - target.maxX) <= tolerance && abs(actual.maxY - target.maxY) <= tolerance
            }
            guard geometryMatches else { return false }
            let content = layouts[index].contentRect(canvasWidth: geometry.width, canvasHeight: geometry.height)
            return barsAreBlack(pixels, width: geometry.width, height: geometry.height,
                bytesPerRow: bytesPerRow, content: content)
        })
        return matching
    }

    private static func barsAreBlack(_ pixels: Data, width: Int, height: Int,
                                     bytesPerRow: Int, content: CGRect) -> Bool {
        // Ignore four pixels next to the content edge to exclude H264 edge ringing.
        pixels.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for row in 0..<height {
                for column in 0..<width {
                    let x = Double(column) + 0.5, y = Double(row) + 0.5
                    guard x < content.minX - 4 || x > content.maxX + 4
                        || y < content.minY - 4 || y > content.maxY + 4 else { continue }
                    let offset = row * bytesPerRow + column * 4
                    if bytes[offset] > 24 || bytes[offset + 1] > 24 || bytes[offset + 2] > 24 { return false }
                }
            }
            return true
        }
    }
}
