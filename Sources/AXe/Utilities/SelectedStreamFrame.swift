import CoreGraphics
import Foundation
import ImageIO

/// Selected framing only. Legacy StreamVideo framing remains unchanged.
enum SelectedStreamFrame {
    static let boundary = "mjpegstream"
    struct Encoded {
        let bytes: Data
        let width: Int
        let height: Int
    }

    static func header(_ format: StreamVideo.OutputFormat) -> Data {
        format == .mjpeg
            ? Data("HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=\(boundary)\r\n\r\n".utf8)
            : Data()
    }

    static func trailer(_ format: StreamVideo.OutputFormat) -> Data {
        format == .mjpeg ? Data("--\(boundary)--\r\n".utf8) : Data()
    }

    static func encode(png: Data, format: StreamVideo.OutputFormat,
                       scale: Double, quality: Int) async throws -> Encoded {
        guard scale.isFinite, (0.1...1).contains(scale), (1...100).contains(quality) else {
            throw CLIError(errorDescription: "Invalid selected stream encoding options")
        }
        let end: [UInt8] = [0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130]
        guard png.suffix(end.count).elementsEqual(end),
              let source = CGImageSourceCreateWithData(png as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source).map({ CFEqual($0, "public.png" as CFString) }) == true,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let image = CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width > 0, image.height > 0,
              Double(image.width) * Double(image.height) <= 64_000_000 else {
            throw VideoProcessingError.failedToDecodeImage
        }
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        if format == .bgra {
            // Packed top-to-bottom BGRA, premultiplied alpha, no row padding.
            // The PNG is already upright. This changes row storage, not panel rotation.
            var pixels = Data(count: width * height * 4)
            try pixels.withUnsafeMutableBytes { bytes in
                guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
                    throw VideoProcessingError.failedToAllocatePixelBuffer
                }
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: CGFloat(height), width: CGFloat(width), height: -CGFloat(height)))
            }
            return Encoded(bytes: pixels, width: width, height: height)
        }
        let jpeg = try await VideoFrameUtilities.processJPEGData(png, scale: scale, quality: quality)
        var bytes: Data
        switch format {
        case .mjpeg:
            bytes = Data("--\(boundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".utf8)
            bytes.append(jpeg)
            bytes.append(Data("\r\n".utf8))
        case .raw:
            guard let length = UInt32(exactly: jpeg.count) else {
                throw CLIError(errorDescription: "Selected JPEG exceeds the raw frame length field")
            }
            var lengthBE = length.bigEndian
            bytes = Data(bytes: &lengthBE, count: 4)
            bytes.append(jpeg)
        case .ffmpeg:
            // Concatenated JPEGs. No ffmpeg process is started.
            bytes = jpeg
        case .h264:
            throw CLIError(errorDescription: "The native H.264 stream does not use screenshot framing.")
        case .bgra:
            throw CLIError(errorDescription: "Unexpected selected BGRA encoding branch")
        }
        return Encoded(bytes: bytes, width: width, height: height)
    }
}
