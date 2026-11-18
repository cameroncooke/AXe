import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import AXe

@Suite("Mirror QR code")
struct MirrorQRCodeTests {
    private let link = "https://axe-cli.com/pair#7K3QM9XW2B"

    /// Paints the squares as a picture, eight pixels to a square with a white border, and reads it
    /// back with the system's QR reader.
    private func read(_ modules: [[Bool]]) -> String? {
        let scale = 8, border = 4, size = (modules.count + 2 * border) * scale
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(gray: 0, alpha: 1)
        for (row, squares) in modules.enumerated() {
            for (column, dark) in squares.enumerated() where dark {
                context.fill(CGRect(x: (column + border) * scale, y: size - (row + border + 1) * scale, width: scale, height: scale))
            }
        }
        guard let image = context.makeImage(),
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else { return nil }
        return detector.features(in: CIImage(cgImage: image)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
    }

    @Test("The squares are a square QR code that reads back as the pairing link")
    func readsBack() throws {
        let modules = try #require(MirrorQRCode.modules(for: link))
        #expect(modules.count >= 21)
        #expect(modules.allSatisfy { $0.count == modules.count })
        #expect(read(modules) == link)
    }

    @Test("The terminal drawing has a quiet border and two rows of squares to a line")
    func drawsLines() throws {
        let modules = try #require(MirrorQRCode.modules(for: link))
        let lines = try #require(MirrorQRCode.lines(for: link, plain: true))
        #expect(lines.count == (modules.count + 4 + 1) / 2)
        #expect(lines.allSatisfy { $0.count == modules.count + 4 })
        #expect(lines.first?.allSatisfy { $0 == " " } == true)
        #expect(lines.allSatisfy { $0.allSatisfy { " ▀▄█".contains($0) } })
        let coloured = try #require(MirrorQRCode.lines(for: link))
        #expect(coloured.allSatisfy { $0.hasPrefix("\u{1B}[30;107m") && $0.hasSuffix("\u{1B}[0m") })
    }

    @Test("The drawing redrawn from its characters still reads back")
    func drawingReadsBack() throws {
        let lines = try #require(MirrorQRCode.lines(for: link, plain: true))
        var rows: [[Bool]] = []
        for line in lines {
            rows.append(line.map { $0 == "▀" || $0 == "█" })
            rows.append(line.map { $0 == "▄" || $0 == "█" })
        }
        let width = rows[0].count
        let square = Array(rows.prefix(width))
        #expect(read(square) == link)
    }
}
