import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AXe

@Suite("JPEG Frame Contract Tests")
struct JPEGFrameContractTests {
    @Test("Complete JPEG defaults preserve the original bytes")
    func jpegDefaultsPreserveBytes() async throws {
        let input = try makeImageData(type: .jpeg)
        let output = try await VideoFrameUtilities.processJPEGData(input, scale: 1, quality: 80)
        #expect(output == input)
        try expectJPEG(output, width: 96, height: 64)
    }

    @Test("PNG defaults produce a complete JPEG at the original dimensions")
    func pngDefaultsEncodeJPEG() async throws {
        let input = try makeImageData(type: .png)
        let output = try await VideoFrameUtilities.processJPEGData(input, scale: 1, quality: 80)
        #expect(output != input)
        try expectJPEG(output, width: 96, height: 64)
        let originalImage = try #require(VideoFrameUtilities.makeCGImage(from: input))
        #expect(originalImage.width == 96)
        #expect(originalImage.height == 64)
        let originalSource = try #require(CGImageSourceCreateWithData(input as CFData, nil))
        #expect(CGImageSourceGetType(originalSource) as String? == UTType.png.identifier)
    }

    @Test("Invalid image bytes fail in default and nondefault paths")
    func invalidDataFails() async {
        for input in [Data(), Data("not an image".utf8), Data([0xff, 0xd8, 0xff])] {
            for options in [(1.0, 80), (1.0, 25), (0.5, 80)] {
                await expectDecodeFailure(input, scale: options.0, quality: options.1)
            }
        }
    }

    @Test("Truncated JPEG and PNG bytes fail before encoding")
    func truncatedImagesFail() async throws {
        let jpeg = try makeImageData(type: .jpeg)
        let png = try makeImageData(type: .png)
        #expect(Array(jpeg.suffix(2)) == [0xff, 0xd9])
        let truncated = [Data(jpeg.prefix(jpeg.count / 2)), Data(jpeg.dropLast(2)),
                         Data(png.prefix(png.count / 2)), Data(png.dropLast(12))]
        let labels = ["JPEG half", "JPEG without EOI", "PNG half", "PNG without IEND"]
        for (label, input) in zip(labels, truncated) {
            for options in [(1.0, 80), (1.0, 25), (0.5, 80)] {
                await expectDecodeFailure(input, scale: options.0, quality: options.1, context: label)
            }
        }
    }

    @Test("Nondefault quality still reencodes JPEG and PNG")
    func nondefaultQualityReencodes() async throws {
        for type in [UTType.jpeg, .png] {
            let input = try makeImageData(type: type)
            let output = try await VideoFrameUtilities.processJPEGData(input, scale: 1, quality: 25)
            #expect(output != input)
            try expectJPEG(output, width: 96, height: 64)
        }
    }

    @Test("Nondefault scaling still uses pixel dimensions for both formats")
    func nondefaultScalingUsesPixels() async throws {
        for type in [UTType.jpeg, .png] {
            let input = try makeImageData(type: type)
            for quality in [80, 25] {
                let output = try await VideoFrameUtilities.processJPEGData(input, scale: 0.5, quality: quality)
                try expectJPEG(output, width: 48, height: 32)
            }
        }
    }

    private func expectDecodeFailure(_ input: Data, scale: Double, quality: Int, context: String = "invalid bytes") async {
        do {
            _ = try await VideoFrameUtilities.processJPEGData(input, scale: scale, quality: quality)
            Issue.record("Invalid or incomplete image was accepted: \(context), scale=\(scale), quality=\(quality), bytes=\(input.count)")
        } catch VideoProcessingError.failedToDecodeImage {
            // The actual production function rejected the input.
        } catch {
            Issue.record("Unexpected error for \(context), scale=\(scale), quality=\(quality): \(error)")
        }
    }

    private func expectJPEG(_ data: Data, width: Int, height: Int) throws {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        let image = try #require(CGImageSourceCreateImageAtIndex(
            source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        ))
        #expect(CGImageSourceGetStatus(source) == .statusComplete)
        #expect(CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete)
        #expect(image.width == width)
        #expect(image.height == height)
    }

    private func makeImageData(type: UTType) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: 96, height: 64, bitsPerComponent: 8, bytesPerRow: 96 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        for x in 0..<96 {
            context.setFillColor(CGColor(red: CGFloat(x) / 96, green: 0.4, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 1, height: 64))
        }
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data, type.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
