import Foundation
import FBSimulatorControl
@preconcurrency import FBControlCore
import AVFoundation
import ImageIO
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

enum VideoProcessingError: Error {
    case emptyScreenshot
    case failedToDecodeImage
    case failedToAllocatePixelBuffer
}

struct VideoFrameUtilities {
    static func captureScreenshotData(from simulator: FBSimulator) async throws -> Data {
        let screenshotFuture = simulator.takeScreenshot(.PNG)
        let nsData = try await FutureBridge.value(screenshotFuture)
        guard let data = nsData as Data? else {
            throw VideoProcessingError.emptyScreenshot
        }
        return data
    }

    static func makeCGImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func processJPEGData(_ data: Data, scale: Double, quality: Int) async throws -> Data {
        if scale < 1.0 {
            return try await scaleJPEGData(data, scale: scale, quality: quality)
        } else if quality != 80 {
            return try await reencodeJPEGData(data, quality: quality)
        }
        return data
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
        guard let image = NSImage(data: data) else {
            throw VideoProcessingError.failedToDecodeImage
        }

        let newSize = NSSize(
            width: image.size.width * scale,
            height: image.size.height * scale
        )

        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize))
        newImage.unlockFocus()

        guard let tiffData = newImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [NSBitmapImageRep.PropertyKey.compressionFactor: Double(quality) / 100.0]) else {
            throw VideoProcessingError.failedToDecodeImage
        }

        return jpegData
        #else
        return data
        #endif
    }

    private static func reencodeJPEGData(_ data: Data, quality: Int) async throws -> Data {
        #if os(macOS)
        guard let image = NSImage(data: data),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [NSBitmapImageRep.PropertyKey.compressionFactor: Double(quality) / 100.0]) else {
            throw VideoProcessingError.failedToDecodeImage
        }

        return jpegData
        #else
        return data
        #endif
    }
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
