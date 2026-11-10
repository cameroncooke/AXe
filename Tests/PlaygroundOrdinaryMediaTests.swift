import CoreMedia
import CoreVideo
import Darwin
import Foundation
import Testing
@preconcurrency import AVFoundation

/// Plain screenshot, JPEG stream and recording commands on an ordinary iPhone or iPad. Each decodes
/// the Playground's four colour markers upright from the captured pixels.
@Suite("Playground Ordinary Media E2E", .serialized, .enabled(if: isOrdinaryPlaygroundE2EEnabled))
struct PlaygroundOrdinaryMediaTests {
    @Test("screenshot writes an upright PNG of the display")
    func screenshot() async throws {
        let app = try OrdinaryPlaygroundSession()
        try await app.openMediaPattern()
        let file = try app.artifact("screen.png")
        let output = try await app.run(["screenshot", "--output", file.path])
        try #require(output.contains(file.path), "screenshot did not report its file: \(output)")
        let image = try PlaygroundMediaAssertions.image(Data(contentsOf: file), type: "public.png")
        try #require(image.width > 300 && image.height > 300)
    }

    @Test("JPEG stream formats deliver upright scaled frames and stop cleanly on SIGINT", arguments: ["mjpeg", "raw", "ffmpeg"])
    func compressedStream(format: String) async throws {
        let app = try OrdinaryPlaygroundSession()
        let display = try await app.openMediaPattern()
        let stream = try app.start(["stream-video", "--format", format, "--fps", "4", "--quality", "70", "--scale", "0.5"], name: "stream")
        let frames: [Data]
        do {
            try await app.waitForStreamFrames(stream, format: format, minimum: 2)
            try stream.signal(SIGINT)
            try await stream.wait(timeout: 15)
            try #require(stream.exitCode == 0, "stream-video did not stop cleanly: \((try? stream.errorOutput()) ?? "")")
            frames = try PlaygroundMediaAssertions.streamFrames(try stream.stdoutData(), format: format,
                width: 0, height: 0, complete: true)
        } catch { await stream.finish(); throw error }
        await stream.finish()
        try #require(frames.count >= 2)
        for frame in frames {
            let decoded = try PlaygroundMediaAssertions.image(frame, type: "public.jpeg")
            try #require(abs(decoded.width - display.width / 2) <= 1 && abs(decoded.height - display.height / 2) <= 1,
                "A 0.5-scale frame is \(decoded.width)x\(decoded.height) for a \(display.width)x\(display.height) display.")
        }
    }

    @Test("record-video writes a decodable upright MP4 to a file or into a directory", arguments: ["file", "directory"])
    func record(target: String) async throws {
        let app = try OrdinaryPlaygroundSession()
        let display = try await app.openMediaPattern()
        let file = try app.artifact("recording.mp4")
        let directory = file.deletingLastPathComponent()
        let sentinel = directory.appendingPathComponent("sentinel.txt")
        try "keep".write(to: sentinel, atomically: true, encoding: .utf8)
        let output = target == "file" ? file.path : directory.path
        let recording = try app.start(["--output", "json", "record-video", "--fps", "4", "--scale", "0.5", "--output", output], name: "record")
        let receipt: OrdinaryMovieReceipt
        do {
            // The writer creates the movie when its first frame is in; then record for 1.5 seconds.
            let deadline = Date().addingTimeInterval(30)
            while try !app.movieStarted(in: directory) {
                try #require(recording.isRunning && Date() < deadline, "The recording did not start: \((try? recording.errorOutput()) ?? "")")
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            try await Task.sleep(nanoseconds: 1_500_000_000)
            try recording.signal(SIGINT)
            try await recording.wait(timeout: 20)
            try #require(recording.exitCode == 0, "record-video did not stop cleanly: \((try? recording.errorOutput()) ?? "")")
            receipt = try recording.receipt(OrdinaryMovieReceipt.self)
        } catch { await recording.finish(); throw error }
        await recording.finish()
        let result = receipt.data.result
        let path = URL(fileURLWithPath: result.path).resolvingSymlinksInPath().path
        if target == "file" {
            try #require(path == file.resolvingSymlinksInPath().path)
        } else {
            try #require(path.hasPrefix(directory.resolvingSymlinksInPath().path + "/") && path.hasSuffix(".mp4"))
        }
        try #require(FileManager.default.fileExists(atPath: sentinel.path), "Recording into a directory removed its contents.")
        try #require(abs(result.pixelWidth - display.width / 2) <= 1 && abs(result.pixelHeight - display.height / 2) <= 1)
        try await OrdinaryPlaygroundSession.requireUprightMovie(URL(fileURLWithPath: path), width: result.pixelWidth,
            height: result.pixelHeight, frames: result.frames)
    }
}

private struct OrdinaryMovieReceipt: Decodable {
    let data: Payload
    struct Payload: Decodable { let result: Result }
    struct Result: Decodable {
        let path: String
        let pixelWidth: Int
        let pixelHeight: Int
        let frames: Int
    }
}

extension OrdinaryPlaygroundSession {
    /// Opens the colour-marker screen and returns the display's pixel size from a PNG of it.
    @discardableResult
    func openMediaPattern() async throws -> (width: Int, height: Int) {
        _ = try await open("media-pattern", readyID: "media-pattern-phase")
        _ = try await core.waitFor("the first marker phase") { core.value("media-pattern-phase", in: $0) == "0" }
        let file = try artifact("display.png")
        try await run(["screenshot", "--output", file.path])
        let image = try PlaygroundMediaAssertions.image(Data(contentsOf: file), type: "public.png")
        return (image.width, image.height)
    }

    /// Starts a long-running command whose output goes to files beside the test artifacts.
    func start(_ arguments: [String], name: String) throws -> PlaygroundTestProcess {
        let directory = try artifact(name).deletingLastPathComponent()
        let process = try PlaygroundTestProcess(executable: axe, arguments: arguments + ["--udid", udid],
                                                directory: directory, name: name)
        try process.start()
        return process
    }

    func movieStarted(in directory: URL) throws -> Bool {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]).contains { url in
            url.pathExtension == "mp4" && ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
        }
    }

    /// Decodes every frame of a plain recording: the reported count, increasing times, upright markers.
    static func requireUprightMovie(_ url: URL, width: Int, height: Int, frames expected: Int) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try #require(tracks.first)
        try #require(tracks.count == 1)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        try #require(reader.canAdd(output))
        reader.add(output)
        try #require(reader.startReading())
        var decoded = 0
        var previous: CMTime?
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            try #require(time.isNumeric)
            if let previous { try #require(CMTimeCompare(time, previous) > 0, "Movie timestamps did not increase.") }
            previous = time
            let buffer = try #require(CMSampleBufferGetImageBuffer(sample))
            try #require(CVPixelBufferGetWidth(buffer) == width && CVPixelBufferGetHeight(buffer) == height)
            try #require(CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let address = try #require(CVPixelBufferGetBaseAddress(buffer))
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            _ = try PlaygroundMediaAssertions.markers(Data(bytes: address, count: stride * height),
                width: width, height: height, bytesPerRow: stride)
            decoded += 1
        }
        try #require(reader.status == .completed, "Movie decode failed: \(reader.error?.localizedDescription ?? "unknown")")
        try #require(decoded == expected && decoded >= 2, "Decoded \(decoded) frames; record-video reported \(expected).")
    }

    func waitForStreamFrames(_ process: PlaygroundTestProcess, format: String, minimum: Int) async throws {
        let deadline = Date().addingTimeInterval(30)
        repeat {
            try #require(process.isRunning, "The stream ended early: \((try? process.errorOutput()) ?? "")")
            let frames = try PlaygroundMediaAssertions.streamFrames(try process.stdoutData(), format: format,
                width: 0, height: 0, complete: false)
            if frames.count >= minimum { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        } while Date() < deadline
        throw TestError.unexpectedState("No \(minimum) \(format) frames: \((try? process.errorOutput()) ?? "")")
    }
}
