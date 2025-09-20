import ArgumentParser
import Foundation
import FBSimulatorControl
@preconcurrency import FBControlCore
import AVFoundation
import ImageIO
import Dispatch
import Darwin

struct StreamVideo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stream-video",
        abstract: "Record the simulator display to an MP4 file using H.264 encoding"
    )

    @Option(name: .customLong("udid"), help: "The UDID of the simulator.")
    var simulatorUDID: String

    @Option(help: "Frames per second (1-30, default: 10)")
    var fps: Int = 10

    @Option(help: "Quality factor (1-100) controlling bitrate (default: 80)")
    var quality: Int = 80

    @Option(help: "Scale factor (0.1-1.0, default: 1.0)")
    var scale: Double = 1.0

    @Option(help: "Output MP4 file path. Defaults to axe-video-<timestamp>.mp4 in the current directory.")
    var output: String?

    func validate() throws {
        guard fps >= 1 && fps <= 30 else {
            throw ValidationError("FPS must be between 1 and 30")
        }

        guard quality >= 1 && quality <= 100 else {
            throw ValidationError("Quality must be between 1 and 100")
        }

        guard scale >= 0.1 && scale <= 1.0 else {
            throw ValidationError("Scale must be between 0.1 and 1.0")
        }
    }

    func run() async throws {
        let logger = AxeLogger()
        try await setup(logger: logger)
        try await performGlobalSetup(logger: logger)

        let trimmedUDID = simulatorUDID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUDID.isEmpty else {
            throw CLIError(errorDescription: "Simulator UDID cannot be empty. Use --udid to specify a simulator.")
        }

        let simulatorSet = try await getSimulatorSet(deviceSetPath: nil, logger: logger, reporter: EmptyEventReporter.shared)
        guard let targetSimulator = simulatorSet.allSimulators.first(where: { $0.udid == trimmedUDID }) else {
            throw CLIError(errorDescription: "Simulator with UDID \(trimmedUDID) not found.")
        }

        guard targetSimulator.state == .booted else {
            let stateDescription = FBiOSTargetStateStringFromState(targetSimulator.state)
            throw CLIError(errorDescription: "Simulator \(trimmedUDID) is not booted. Current state: \(stateDescription)")
        }

        let outputURL = try prepareOutputURL()
        FileHandle.standardError.write(Data("Recording simulator \(targetSimulator.udid) to \(outputURL.path)\n".utf8))
        FileHandle.standardError.write(Data("Press Ctrl+C to stop recording\n".utf8))

        let cancellationFlag = CancellationFlag()
        let signalObserver = SignalObserver(signals: [SIGINT, SIGTERM]) {
            Task {
                await cancellationFlag.cancel()
            }
        }
        defer { signalObserver.invalidate() }

        do {
            try await recordVideo(
                simulator: targetSimulator,
                outputURL: outputURL,
                fps: fps,
                quality: quality,
                scale: scale,
                cancellationFlag: cancellationFlag
            )
            FileHandle.standardError.write(Data("Recording saved to \(outputURL.path)\n".utf8))
            print(outputURL.path)
        } catch {
            throw CLIError(errorDescription: "Failed to record video: \(error.localizedDescription)")
        }
    }

    // MARK: - Recording

    private func recordVideo(
        simulator: FBSimulator,
        outputURL: URL,
        fps: Int,
        quality: Int,
        scale: Double,
        cancellationFlag: CancellationFlag
    ) async throws {
        let initialFrameData = try await captureScreenshotData(from: simulator)
        guard let initialImage = Self.makeCGImage(from: initialFrameData) else {
            throw CLIError(errorDescription: "Failed to decode simulator screenshot")
        }

        let dimensions = Self.computeDimensions(for: initialImage, scale: scale)
        let recorder = try StreamRecorder(
            outputURL: outputURL,
            width: dimensions.width,
            height: dimensions.height,
            fps: fps,
            quality: quality
        )
        defer { recorder.invalidate() }

        let frameInterval = 1.0 / Double(fps)
        var frameCount: Int64 = 1
        var lastLogFrame: Int64 = 0
        let startTime = Date()
        var lastPresentationTime = CMTime.zero

        try recorder.append(image: initialImage, presentationTime: .zero)
        let writerStartTime = Date()

        while true {
            if Task.isCancelled {
                break
            }
            if await cancellationFlag.value {
                break
            }

            let frameStart = Date()

            do {
                let frameData = try await captureScreenshotData(from: simulator)
                guard let cgImage = Self.makeCGImage(from: frameData) else {
                    FileHandle.standardError.write(Data("Unable to decode screenshot frame\n".utf8))
                    continue
                }

                let now = Date()
                var presentationTime = CMTime(seconds: now.timeIntervalSince(writerStartTime), preferredTimescale: 600)
                if presentationTime <= lastPresentationTime {
                    presentationTime = CMTimeAdd(lastPresentationTime, CMTime(value: 1, timescale: 600))
                }

                try recorder.append(image: cgImage, presentationTime: presentationTime)
                lastPresentationTime = presentationTime
                frameCount += 1

                if frameCount - lastLogFrame >= Int64(fps) {
                    lastLogFrame = frameCount
                    let elapsed = Date().timeIntervalSince(startTime)
                    let actualFPS = Double(frameCount) / max(elapsed, 0.0001)
                    FileHandle.standardError.write(Data(String(format: "Captured %lld frames (%.1f FPS actual)\n", frameCount, actualFPS).utf8))
                }
            } catch {
                FileHandle.standardError.write(Data("Error capturing frame: \(error.localizedDescription)\n".utf8))
            }

            let elapsed = Date().timeIntervalSince(frameStart)
            let sleepTime = frameInterval - elapsed
            if sleepTime > 0 {
                try await Task.sleep(nanoseconds: UInt64(sleepTime * 1_000_000_000))
            }
        }

        try await recorder.finish()
    }

    private func captureScreenshotData(from simulator: FBSimulator) async throws -> Data {
        let screenshotFuture = simulator.takeScreenshot(.PNG)
        let nsData = try await FutureBridge.value(screenshotFuture)
        guard let data = nsData as Data? else {
            throw CLIError(errorDescription: "Screenshot returned empty data")
        }
        return data
    }

    private func prepareOutputURL() throws -> URL {
        let fileManager = FileManager.default
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let providedPath = output?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPath: String
        if let providedPath, !providedPath.isEmpty {
            resolvedPath = (providedPath as NSString).expandingTildeInPath
        } else {
            resolvedPath = "axe-video-\(formatter.string(from: Date())).mp4"
        }

        let baseURL: URL
        if resolvedPath.hasPrefix("/") {
            baseURL = URL(fileURLWithPath: resolvedPath)
        } else {
            baseURL = URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent(resolvedPath)
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: baseURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            // Treat the provided path as a directory and generate a file name within it
            let filename = "axe-video-\(formatter.string(from: Date())).mp4"
            let directoryURL = baseURL
            if !fileManager.fileExists(atPath: directoryURL.path) {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
            }
            return directoryURL.appendingPathComponent(filename)
        }

        let directoryURL = baseURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        }

        if fileManager.fileExists(atPath: baseURL.path) {
            var existingIsDirectory: ObjCBool = false
            fileManager.fileExists(atPath: baseURL.path, isDirectory: &existingIsDirectory)
            if existingIsDirectory.boolValue {
                throw CLIError(errorDescription: "Output path \(baseURL.path) is a directory. Provide a file name or point to a different location.")
            }
            try fileManager.removeItem(at: baseURL)
        }

        return baseURL
    }

    private static func makeCGImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func computeDimensions(for image: CGImage, scale: Double) -> (width: Int, height: Int) {
        let scaledWidth = max(2, Int(Double(image.width) * scale))
        let scaledHeight = max(2, Int(Double(image.height) * scale))
        let evenWidth = scaledWidth - (scaledWidth % 2)
        let evenHeight = scaledHeight - (scaledHeight % 2)
        return (max(evenWidth, 2), max(evenHeight, 2))
    }
}

// MARK: - Helpers

private actor CancellationFlag {
    private(set) var value = false
    func cancel() {
        value = true
    }
}

private final class SignalObserver {
    private var sources: [DispatchSourceSignal] = []
    private let signals: [Int32]

    init(signals: [Int32], handler: @escaping @Sendable () -> Void) {
        self.signals = signals
        for signalValue in signals {
            signal(signalValue, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalValue, queue: .main)
            source.setEventHandler(handler: handler)
            source.resume()
            sources.append(source)
        }
    }

    func invalidate() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        for signalValue in signals {
            signal(signalValue, SIG_DFL)
        }
    }

    deinit {
        invalidate()
    }
}

private final class StreamRecorder: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let width: Int
    private let height: Int

    init(outputURL: URL, width: Int, height: Int, fps: Int, quality: Int) throws {
        self.width = width
        self.height = height

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: Self.estimateBitrate(width: width, height: height, fps: fps, quality: quality),
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: fps * 2,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
        ]

        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compressionProperties
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = true

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )

        guard writer.canAdd(input) else {
            throw CLIError(errorDescription: "Unable to configure video writer input")
        }
        writer.add(input)

        if !writer.startWriting() {
            throw CLIError(errorDescription: "Failed to start asset writer: \(writer.error?.localizedDescription ?? "Unknown error")")
        }
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.input = input
        self.adaptor = adaptor
    }

    func append(image: CGImage, presentationTime: CMTime) throws {
        if !input.isReadyForMoreMediaData {
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.005)
            }
        }

        guard let pixelBuffer = Self.makePixelBuffer(width: width, height: height, adaptor: adaptor) else {
            throw CLIError(errorDescription: "Failed to allocate pixel buffer")
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw CLIError(errorDescription: "Failed to create drawing context")
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: CGFloat(height), width: CGFloat(width), height: -CGFloat(height)))

        guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
            throw CLIError(errorDescription: "Failed to append frame: \(writer.error?.localizedDescription ?? "Unknown error")")
        }
    }

    func finish() async throws {
        input.markAsFinished()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.finishWriting {
                if let error = self.writer.error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func invalidate() {
        if writer.status == .writing {
            input.markAsFinished()
            writer.cancelWriting()
        }
    }

    private static func makePixelBuffer(width: Int, height: Int, adaptor: AVAssetWriterInputPixelBufferAdaptor) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        if let pool = adaptor.pixelBufferPool {
            let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard status == kCVReturnSuccess else {
                return nil
            }
        } else {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
            guard status == kCVReturnSuccess else {
                return nil
            }
        }
        return pixelBuffer
    }

    private static func estimateBitrate(width: Int, height: Int, fps: Int, quality: Int) -> Int {
        let qualityFactor = max(0.1, min(Double(quality) / 100.0, 1.0))
        let bitsPerPixel = 0.1 + (0.4 * qualityFactor)
        let bitrate = Double(width * height) * bitsPerPixel * Double(fps)
        return min(max(Int(bitrate), 1_000_000), 50_000_000)
    }
}
