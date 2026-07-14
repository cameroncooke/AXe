import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AXe

@Suite("Video Frame Utilities Tests")
struct VideoFrameUtilitiesTests {
    @Test("Compressed stream scaling uses pixel dimensions")
    func compressedStreamScalingUsesPixelDimensions() async throws {
        let source = try makePNG(width: 1206, height: 2622)

        let scaled = try await VideoFrameUtilities.processJPEGData(source, scale: 0.5, quality: 75)
        let image = try #require(VideoFrameUtilities.makeCGImage(from: scaled))

        #expect(image.width == 603)
        #expect(image.height == 1311)
    }

    private func makePNG(width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
