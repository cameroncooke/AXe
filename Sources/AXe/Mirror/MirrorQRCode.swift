import CoreGraphics
import CoreImage
import Foundation

/// Draws a QR code in a terminal, for the viewer app to scan when pairing.
enum MirrorQRCode {
    /// The code's squares, top row first: true is dark. Nil when the text cannot be encoded.
    static func modules(for text: String) -> [[Bool]]? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage else { return nil }
        let width = Int(image.extent.width), height = Int(image.extent.height)
        guard width > 0, height > 0 else { return nil }
        // Core Image makes one pixel per square with its own quiet border; that border is cut off
        // here and a fixed one is added when drawing.
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let rendered = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(image, from: image.extent) else { return nil }
        context.interpolationQuality = .none
        context.draw(rendered, in: CGRect(x: 0, y: 0, width: width, height: height))
        var rows = (0..<height).map { y in (0..<width).map { x in pixels[y * width + x] < 128 } }
        while let first = rows.first, !first.contains(true) { rows.removeFirst() }
        while let last = rows.last, !last.contains(true) { rows.removeLast() }
        guard let left = rows.compactMap({ $0.firstIndex(of: true) }).min(),
              let right = rows.compactMap({ $0.lastIndex(of: true) }).max() else { return nil }
        return rows.map { Array($0[left...right]) }
    }

    /// The code as lines of text, two rows of squares to a line. Colours are set outright (black on
    /// white) so that it scans in a dark terminal too; `plain` leaves them out for a light terminal
    /// or a file.
    static func lines(for text: String, plain: Bool = false) -> [String]? {
        guard let code = modules(for: text) else { return nil }
        let border = 2, width = (code.first?.count ?? 0) + 2 * border
        let blank = [Bool](repeating: false, count: width)
        var rows = [[Bool]](repeating: blank, count: border)
        rows += code.map { [Bool](repeating: false, count: border) + $0 + [Bool](repeating: false, count: border) }
        rows += [[Bool]](repeating: blank, count: border)
        if rows.count % 2 == 1 { rows.append(blank) }
        return stride(from: 0, to: rows.count, by: 2).map { index in
            let line = zip(rows[index], rows[index + 1]).map { top, bottom in top ? (bottom ? "█" : "▀") : (bottom ? "▄" : " ") }.joined()
            return plain ? line : "\u{1B}[30;107m" + line + "\u{1B}[0m"
        }
    }
}
