import Foundation
import FBSimulatorControl
@preconcurrency import FBControlCore
import AVFoundation
import ImageIO
import os
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

actor CancellationFlag {
    private(set) var value = false

    func cancel() {
        value = true
    }

    func isCancelled() -> Bool {
        value
    }
}

final class SignalObserver {
    private var sources: [DispatchSourceSignal] = []
    private let signals: [Int32]
    private static let received = OSAllocatedUnfairLock<Int32?>(initialState: nil)

    /// The last SIGINT or SIGTERM any observer handled, so the process can exit with 128 + signal.
    static var lastReceivedSignal: Int32? { received.withLock { $0 } }

    init(signals: [Int32], handler: @escaping @Sendable () -> Void) {
        self.signals = signals
        for signalValue in signals {
            signal(signalValue, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalValue, queue: .main)
            source.setEventHandler {
                Self.received.withLock { $0 = signalValue }
                handler()
            }
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

enum VideoProcessingError: LocalizedError, UserFacingError {
    case failedToDecodeImage
    case failedToAllocatePixelBuffer

    var userFacingDescription: String {
        switch self {
        case .failedToDecodeImage:
            return "AXe could not decode a simulator video frame."
        case .failedToAllocatePixelBuffer:
            return "AXe could not allocate memory for a simulator video frame."
        }
    }

    var errorDescription: String? {
        userFacingDescription
    }
}

/// The default result of a saved screenshot or video: the file and its size in pixels, plus the
/// frame count for a video. Plain output is the path alone, as released; the full capture receipt
/// stays behind `--verbose`.
struct MediaOutput: Encodable, Sendable {
    let path: String
    let pixelWidth: Int
    let pixelHeight: Int
    var frames: Int64? = nil

    func emit() throws { try DeviceState.emit(self, text: [path]) }
}

struct VideoFrameUtilities {
    /// The image size; ImageIO creates the image lazily, so this does not decode the pixels.
    static func pixelSize(of data: Data) -> (width: Int, height: Int) {
        guard let image = makeCGImage(from: data) else { return (0, 0) }
        return (image.width, image.height)
    }

    static func captureScreenshotData(from simulator: FBSimulator) async throws -> Data {
        try await simulator.takeScreenshot(format: .png)
    }

    static func makeCGImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func processJPEGData(_ data: Data, scale: Double, quality: Int) async throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              ) != nil,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw VideoProcessingError.failedToDecodeImage
        }

        let imageType = CGImageSourceGetType(source)
        if let imageType, CFEqual(imageType, UTType.jpeg.identifier as CFString) {
            // Require a complete standalone frame, even when ImageIO tolerates truncation.
            let endOfImage: [UInt8] = [0xff, 0xd9]
            guard data.suffix(endOfImage.count).elementsEqual(endOfImage) else {
                throw VideoProcessingError.failedToDecodeImage
            }
        } else if let imageType, CFEqual(imageType, UTType.png.identifier as CFString) {
            let endChunk: [UInt8] = [0, 0, 0, 0, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82]
            guard data.suffix(endChunk.count).elementsEqual(endChunk) else {
                throw VideoProcessingError.failedToDecodeImage
            }
        }

        if scale < 1.0 {
            return try await scaleJPEGData(data, scale: scale, quality: quality)
        } else if quality != 80 {
            return try await reencodeJPEGData(data, quality: quality)
        }
        if let imageType, CFEqual(imageType, UTType.jpeg.identifier as CFString) {
            return data
        }
        return try await reencodeJPEGData(data, quality: quality)
    }

    static func computeDimensions(for image: CGImage, scale: Double) -> (width: Int, height: Int) {
        let scaledWidth = max(2, Int(Double(image.width) * scale))
        let scaledHeight = max(2, Int(Double(image.height) * scale))
        let evenWidth = scaledWidth - (scaledWidth % 2)
        let evenHeight = scaledHeight - (scaledHeight % 2)
        return (max(evenWidth, 2), max(evenHeight, 2))
    }

    private static func scaleJPEGData(_ data: Data, scale: Double, quality: Int) async throws -> Data {
        #if os(macOS)
        guard let image = makeCGImage(from: data) else {
            throw VideoProcessingError.failedToDecodeImage
        }
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        return try encodeJPEG(image, width: width, height: height, quality: quality)
        #else
        return data
        #endif
    }

    private static func reencodeJPEGData(_ data: Data, quality: Int) async throws -> Data {
        #if os(macOS)
        guard let image = makeCGImage(from: data) else {
            throw VideoProcessingError.failedToDecodeImage
        }
        return try encodeJPEG(image, width: image.width, height: image.height, quality: quality)
        #else
        return data
        #endif
    }

    #if os(macOS)
    private static func encodeJPEG(
        _ image: CGImage,
        width: Int,
        height: Int,
        quality: Int
    ) throws -> Data {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw VideoProcessingError.failedToAllocatePixelBuffer
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        context.cgContext.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let data = bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: Double(quality) / 100.0]
        ) else {
            throw VideoProcessingError.failedToDecodeImage
        }
        return data
    }
    #endif
}

final class H264StreamRecorder: @unchecked Sendable {
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
            throw CLIError(errorDescription: "Unable to configure video writer input", code: .captureFailed)
        }
        writer.add(input)

        if !writer.startWriting() {
            throw CLIError(errorDescription: "Failed to start asset writer: \(writer.error?.localizedDescription ?? "Unknown error")", code: .captureFailed)
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

        try appendReady(image: image, presentationTime: presentationTime)
    }

    /// Selected recording must yield so stop signals and task cancellation can be handled.
    /// The single recording owner serializes all writer calls.
    @MainActor
    func appendSelected(image: CGImage, presentationTime: CMTime, aspectFit: Bool = false) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            guard writer.status == .writing else {
                throw CLIError(errorDescription: "Video writer is not writing: \(writer.error?.localizedDescription ?? "unknown error")", code: .captureFailed)
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw CLIError(errorDescription: "Video writer readiness timed out", code: .timeout)
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try Task.checkCancellation()
        guard writer.status == .writing else {
            throw CLIError(errorDescription: "Video writer stopped before frame append", code: .captureFailed)
        }
        try appendReady(image: image, presentationTime: presentationTime, aspectFit: aspectFit)
    }

    @MainActor
    func finishSelected() async throws {
        try Task.checkCancellation()
        try await finish()
        try Task.checkCancellation()
        guard writer.status == .completed else {
            throw CLIError(errorDescription: "Video writer did not complete", code: .captureFailed)
        }
    }

    private func appendReady(image: CGImage, presentationTime: CMTime, aspectFit: Bool = false) throws {
        guard let pixelBuffer = Self.makePixelBuffer(width: width, height: height, adaptor: adaptor) else {
            throw VideoProcessingError.failedToAllocatePixelBuffer
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
            throw CLIError(errorDescription: "Failed to create drawing context", code: .captureFailed)
        }

        context.interpolationQuality = .high
        if aspectFit {
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            let factor = min(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
            let fittedWidth = CGFloat(image.width) * factor
            let fittedHeight = CGFloat(image.height) * factor
            let x = (CGFloat(width) - fittedWidth) / 2
            let y = (CGFloat(height) - fittedHeight) / 2
            context.draw(image, in: CGRect(x: x, y: y + fittedHeight, width: fittedWidth, height: -fittedHeight))
        } else {
            context.draw(image, in: CGRect(x: 0, y: CGFloat(height), width: CGFloat(width), height: -CGFloat(height)))
        }

        guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
            throw CLIError(errorDescription: "Failed to append frame: \(writer.error?.localizedDescription ?? "Unknown error")", code: .captureFailed)
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
