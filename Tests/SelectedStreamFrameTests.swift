import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import AXe

@Suite("Selected stream frame bytes")
struct SelectedStreamFrameTests {
    @Test func bgraPreservesUprightRowsAndChannelOrderWithoutPadding() async throws {
        // CGImage provider bytes define top row red/green, bottom row blue/white.
        let png = try png(width: 2, height: 2, rgba: [
            255, 0, 0, 255, 0, 255, 0, 255,
            0, 0, 255, 255, 255, 255, 255, 255
        ])
        let result = try await SelectedStreamFrame.encode(png: png, format: .bgra, scale: 1, quality: 80)
        #expect(result.width == 2 && result.height == 2)
        #expect(result.bytes == Data([
            0, 0, 255, 255, 0, 255, 0, 255,
            255, 0, 0, 255, 255, 255, 255, 255
        ]))
    }

    @Test(arguments: ["mjpeg", "raw", "ffmpeg", "bgra"])
    func scalingUsesUprightPNGDimensions(format: String) async throws {
        let format = try #require(StreamVideo.OutputFormat(rawValue: format))
        let source = try png(width: 5, height: 3, rgba: Array(repeating: [UInt8(255), 0, 0, 255], count: 15).flatMap { $0 })
        let frame = try await SelectedStreamFrame.encode(png: source, format: format, scale: 0.5, quality: 80)
        #expect(frame.width == 2 && frame.height == 1)
        if format == .bgra {
            #expect(frame.bytes == Data([0, 0, 255, 255, 0, 0, 255, 255]))
        } else {
            let jpeg: Data
            switch format {
            case .mjpeg: jpeg = try multipartJPEG(frame.bytes)
            case .raw: jpeg = try lengthPrefixedJPEG(frame.bytes)
            default: jpeg = frame.bytes
            }
            try requireJPEG(jpeg, width: 2, height: 1)
        }
    }

    @Test func multipartUsesDeclaredBoundaryAndCompleteJPEGBody() async throws {
        let header = String(decoding: SelectedStreamFrame.header(.mjpeg), as: UTF8.self)
        let declaration = try #require(header.components(separatedBy: "boundary=").last)
        let boundary = try #require(declaration.components(separatedBy: "\r\n").first)
        #expect(!boundary.isEmpty && !boundary.hasPrefix("--"))
        #expect(header.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(header.hasSuffix("\r\n\r\n"))
        let result = try await SelectedStreamFrame.encode(png: solidPNG(), format: .mjpeg, scale: 1, quality: 80)
        #expect(result.bytes.starts(with: Data(("--" + boundary + "\r\n").utf8)))
        try requireJPEG(multipartJPEG(result.bytes), width: 4, height: 3)
        #expect(SelectedStreamFrame.trailer(.mjpeg) == Data(("--" + boundary + "--\r\n").utf8))
    }

    @Test func rawLengthIsBigEndianAndCountsOnlyJPEGBytes() async throws {
        let result = try await SelectedStreamFrame.encode(png: solidPNG(), format: .raw, scale: 1, quality: 80)
        try requireJPEG(lengthPrefixedJPEG(result.bytes), width: 4, height: 3)
        #expect(SelectedStreamFrame.header(.raw).isEmpty)
        #expect(SelectedStreamFrame.trailer(.raw).isEmpty)
    }

    @Test func ffmpegFormatIsOneBareJPEGWithoutProtocolBytes() async throws {
        let result = try await SelectedStreamFrame.encode(png: solidPNG(), format: .ffmpeg, scale: 1, quality: 80)
        try requireJPEG(result.bytes, width: 4, height: 3)
        #expect(result.bytes.starts(with: [0xff, 0xd8]))
        #expect(result.bytes.suffix(2) == Data([0xff, 0xd9]))
        #expect(SelectedStreamFrame.header(.ffmpeg).isEmpty)
        #expect(SelectedStreamFrame.trailer(.ffmpeg).isEmpty)
    }

    @Test func bgraHasNoContainerPrefixOrTrailer() async throws {
        let result = try await SelectedStreamFrame.encode(png: solidPNG(), format: .bgra, scale: 1, quality: 1)
        #expect(result.bytes.count == 4 * 3 * 4)
        #expect(SelectedStreamFrame.header(.bgra).isEmpty)
        #expect(SelectedStreamFrame.trailer(.bgra).isEmpty)
    }

    @Test(arguments: ["mjpeg", "raw", "ffmpeg", "bgra"])
    func invalidOrTruncatedPNGIsNeverAnOutputFrame(format: String) async throws {
        let format = try #require(StreamVideo.OutputFormat(rawValue: format))
        let complete = try solidPNG()
        for data in [Data(), Data("not an image".utf8), Data(complete.dropLast())] {
            await #expect(throws: (any Error).self) {
                _ = try await SelectedStreamFrame.encode(png: data, format: format, scale: 1, quality: 80)
            }
        }
    }

    private func solidPNG() throws -> Data {
        try png(width: 4, height: 3, rgba: Array(repeating: [UInt8(255), 0, 0, 255], count: 12).flatMap { $0 })
    }

    private func png(width: Int, height: Int, rgba: [UInt8]) throws -> Data {
        let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func multipartJPEG(_ packet: Data) throws -> Data {
        let separator = try #require(packet.range(of: Data("\r\n\r\n".utf8)))
        let headers = String(decoding: packet[..<separator.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        #expect(headers.contains("Content-Type: image/jpeg"))
        let lengthHeader = try #require(headers.first { $0.hasPrefix("Content-Length: ") })
        let count = try #require(Int(lengthHeader.dropFirst("Content-Length: ".count)))
        #expect(count > 0)
        #expect(packet.count == separator.upperBound + count + 2)
        #expect(packet.suffix(2) == Data("\r\n".utf8))
        return Data(packet[separator.upperBound..<packet.count - 2])
    }

    private func lengthPrefixedJPEG(_ packet: Data) throws -> Data {
        try #require(packet.count > 4)
        let count = packet.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        #expect(Int(count) == packet.count - 4)
        return Data(packet.dropFirst(4))
    }

    private func requireJPEG(_ bytes: Data, width: Int, height: Int) throws {
        let source = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
        let type = try #require(CGImageSourceGetType(source))
        #expect(CFEqual(type, "public.jpeg" as CFString))
        #expect(CGImageSourceGetCount(source) == 1)
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(CGImageSourceGetStatus(source) == .statusComplete)
        #expect(CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete)
        #expect(image.width == width && image.height == height)
    }
}
