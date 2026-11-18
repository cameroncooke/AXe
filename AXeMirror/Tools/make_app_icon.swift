// Draws AXe Mirror's app icon: a phone-shaped screen on AXe's blue gradient, in front of a dark Mac window
// that shows the same screen, smaller. The two screens match because one mirrors the other. A glowing
// blue touch point sits on the phone's screen, and the same touch shows up on the small one in the window.
// Usage: swift Tools/make_app_icon.swift <appiconset-dir>
import AppKit
import CoreImage

let dir = URL(fileURLWithPath: CommandLine.arguments[1])

enum Variant { case light, dark, tinted }

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

struct Palette {
    var background: [CGColor]?  // nil leaves the background clear, for iOS to fill
    var glow: CGColor?          // a soft light behind the drawing
    var window: [CGColor], windowBar: CGColor, windowEdge: CGColor, windowGlow: CGColor, windowGrid: CGColor, windowShadow: CGColor
    var lights: [CGColor]       // the three dots in the window's corner
    var frame: [CGColor], frameShadow: CGColor, screen: [CGColor]
    var picture: [CGColor], hill: CGColor, sun: CGColor
    var dots: [[CGColor]], bar: CGColor
    var touch: [CGColor], touchRing: CGColor, touchHalo: CGColor, touchGlow: CGColor
    var shine: CGFloat  // strength of the white highlights

    static func of(_ variant: Variant) -> Palette {
        let light = Palette(
            background: [rgb(0x5ED2FF), rgb(0x2A7DFF), rgb(0x2630B8)], glow: rgb(0xFFFFFF, 0.34),
            window: [rgb(0x1C2C86), rgb(0x0B1246)], windowBar: rgb(0xFFFFFF, 0.07), windowEdge: rgb(0x8CC0FF, 0.75),
            windowGlow: rgb(0x4FA0FF, 0.55), windowGrid: rgb(0x6FA4FF, 0.13),
            windowShadow: rgb(0x060B3C, 0.5),
            lights: [rgb(0xFF6B6B), rgb(0xFFC94A), rgb(0x45D483)],
            frame: [rgb(0xFFFFFF), rgb(0xF0F4FF)], frameShadow: rgb(0x050A3C, 0.5), screen: [rgb(0xEDF3FF), rgb(0xDCE7FF)],
            picture: [rgb(0x7FE0FF), rgb(0x2F7BFF)], hill: rgb(0xFFFFFF, 0.3), sun: rgb(0xFFF3B0),
            dots: [[rgb(0xFFB199), rgb(0xFF5A5F), rgb(0xD12A4A)], [rgb(0xFFF0A0), rgb(0xFFC83A), rgb(0xF59A00)],
                   [rgb(0xA8F5C4), rgb(0x3DD17F), rgb(0x149A52)]],
            bar: rgb(0xB9C8EA),
            touch: [rgb(0xE4FAFF), rgb(0x3FC8FF), rgb(0x1E63F5)], touchRing: rgb(0x2B86FF), touchHalo: rgb(0xCFE5FF),
            touchGlow: rgb(0x2FA8FF, 0.85),
            shine: 1)
        switch variant {
        case .light:
            return light
        case .dark:
            // The same drawing on a blue near-black, toned down so it doesn't glare; the touch glows more.
            var dark = light
            dark.background = [rgb(0x131E5C), rgb(0x04061A)]
            dark.glow = rgb(0x2F6BFF, 0.28)
            dark.window = [rgb(0x1A2A80), rgb(0x0A1040)]
            dark.windowEdge = rgb(0x7FB4FF, 0.85)
            dark.windowGlow = rgb(0x3F8CFF, 0.8)
            dark.windowShadow = rgb(0x000000, 0.6)
            dark.frame = [rgb(0xE6EBF5), rgb(0xCDD5E6)]
            dark.frameShadow = rgb(0x000000, 0.65)
            dark.screen = [rgb(0xD5DEF2), rgb(0xBFCBE6)]
            dark.bar = rgb(0x9FAED2)
            dark.touchHalo = rgb(0xB9D3FA)
            dark.touchGlow = rgb(0x35A8FF, 1)
            dark.shine = 0.7
            return dark
        case .tinted:
            // Greys only: iOS keeps the brightness and supplies the colour. The touch is the brightest thing.
            return Palette(
                background: nil, glow: nil,
                window: [rgb(0x5C5C5C), rgb(0x444444)], windowBar: rgb(0xFFFFFF, 0.06), windowEdge: rgb(0xFFFFFF, 0.4),
                windowGlow: rgb(0xFFFFFF, 0.25), windowGrid: rgb(0xFFFFFF, 0.08),
                windowShadow: rgb(0x000000, 0.45),
                lights: [rgb(0x9A9A9A), rgb(0x9A9A9A), rgb(0x9A9A9A)],
                frame: [rgb(0xC4C4C4), rgb(0xAEAEAE)], frameShadow: rgb(0x000000, 0.45), screen: [rgb(0xA4A4A4), rgb(0x929292)],
                picture: [rgb(0x7C7C7C), rgb(0x5A5A5A)], hill: rgb(0xFFFFFF, 0.14), sun: rgb(0xD0D0D0),
                dots: [[rgb(0x7A7A7A), rgb(0x5E5E5E), rgb(0x464646)], [rgb(0x7A7A7A), rgb(0x5E5E5E), rgb(0x464646)],
                       [rgb(0x7A7A7A), rgb(0x5E5E5E), rgb(0x464646)]],
                bar: rgb(0x767676),
                touch: [rgb(0xFFFFFF), rgb(0xFFFFFF), rgb(0xE6E6E6)], touchRing: rgb(0xFFFFFF), touchHalo: rgb(0xC6C6C6),
                touchGlow: rgb(0xFFFFFF, 0.8),
                shine: 0.5)
        }
    }
}

extension CGContext {
    func fill(_ path: CGPath, _ color: CGColor) {
        addPath(path); setFillColor(color); fillPath()
    }

    func stroke(_ path: CGPath, width: CGFloat, _ color: CGColor) {
        addPath(path); setStrokeColor(color); setLineWidth(width); setLineCap(.round); strokePath()
    }

    /// Fills a path with a gradient across its bounding box, top to bottom unless `across`.
    func fill(_ path: CGPath, gradient colors: [CGColor], across: Bool = false) {
        let box = path.boundingBoxOfPath
        saveGState(); addPath(path); clip()
        let gradient = CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: nil)!
        let start = across ? CGPoint(x: box.minX, y: box.midY) : CGPoint(x: box.midX, y: box.minY)
        let end = across ? CGPoint(x: box.maxX, y: box.midY) : CGPoint(x: box.midX, y: box.maxY)
        drawLinearGradient(gradient, start: start, end: end, options: [])
        restoreGState()
    }

    /// Fills a path with a radial gradient lit from its upper left, so round things look round.
    func fill(_ path: CGPath, sphere colors: [CGColor]) {
        let box = path.boundingBoxOfPath
        saveGState(); addPath(path); clip()
        let gradient = CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: [0, 0.5, 1])!
        let light = CGPoint(x: box.minX + box.width * 0.36, y: box.minY + box.height * 0.3)
        drawRadialGradient(gradient, startCenter: light, startRadius: 0, endCenter: light,
                           endRadius: max(box.width, box.height) * 0.8, options: .drawsAfterEndLocation)
        restoreGState()
    }

    /// Draws `body` clipped to a path.
    func clipped(to path: CGPath, _ body: () -> Void) {
        saveGState(); addPath(path); clip(); body(); restoreGState()
    }

    /// Draws `body` with a soft shadow below it. Shadow offsets are in device space, where y points up.
    func withShadow(blur: CGFloat, drop: CGFloat, color: CGColor, _ body: () -> Void) {
        saveGState()
        setShadow(offset: CGSize(width: 0, height: -drop), blur: blur, color: color)
        beginTransparencyLayer(auxiliaryInfo: nil); body(); endTransparencyLayer()
        restoreGState()
    }

    /// Draws `body` blurred, for glows, in this context's current coordinates. The radius is in pixels.
    func blurred(radius: CGFloat, _ body: (CGContext) -> Void) {
        let layer = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        layer.concatenate(ctm)
        body(layer)
        let input = CIImage(cgImage: layer.makeImage()!)
        let output = input.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: input.extent)
        let image = CIContext().createCGImage(output, from: input.extent)!
        saveGState()
        concatenate(ctm.inverted())
        draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        restoreGState()
    }
}

func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, rotated degrees: CGFloat = 0) -> CGPath {
    var t = CGAffineTransform(translationX: cx, y: cy).rotated(by: degrees * .pi / 180)
    return CGPath(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2), transform: &t)
}

func capsule(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: width, height: height), cornerWidth: height / 2, cornerHeight: height / 2, transform: nil)
}

func rounded(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: width, height: height), cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func render(_ variant: Variant, to name: String) {
    let p = Palette.of(variant)
    // The light and dark icons must be fully opaque; only the tinted one keeps transparency.
    let alpha: CGImageAlphaInfo = variant == .tinted ? .premultipliedLast : .noneSkipLast
    let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: alpha.rawValue)!
    // Work top-down, with y growing downwards, like a design tool.
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)
    let white = { (a: CGFloat) in rgb(0xFFFFFF, a * p.shine) }

    if let background = p.background {
        ctx.fill(CGPath(rect: CGRect(x: 0, y: 0, width: 1024, height: 1024), transform: nil), gradient: background)
        // A soft glow: daylight from the top left on the light icon, a blue haze behind the drawing on the dark one.
        if let glow = p.glow {
            let centre = variant == .light ? CGPoint(x: 290, y: 90) : CGPoint(x: 512, y: 470)
            let gradient = CGGradient(colorsSpace: nil, colors: [glow, glow.copy(alpha: 0)!] as CFArray, locations: nil)!
            ctx.drawRadialGradient(gradient, startCenter: centre, startRadius: 0, endCenter: centre,
                                   endRadius: variant == .light ? 720 : 560, options: [])
        }
    }

    // One copy of the mirrored screen, laid out in a 400 by 640 box and drawn at `scale` with its top left at `origin`.
    // It has a frame, a picture with a sun and two hills, three rows of a dot and a line, and the touch point.
    func screen(at origin: CGPoint, scale: CGFloat, shadow: CGColor, shadowBlur: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.scaleBy(x: scale, y: scale)

        let frame = rounded(0, 0, 400, 640, 80)
        ctx.withShadow(blur: shadowBlur, drop: shadowBlur * 0.6, color: shadow) { ctx.fill(frame, p.frame[0]) }
        ctx.fill(frame, gradient: p.frame)
        ctx.fill(rounded(18, 18, 364, 604, 62), gradient: p.screen)

        // The picture.
        let picture = rounded(48, 50, 304, 200, 34)
        ctx.fill(picture, gradient: p.picture)
        ctx.clipped(to: picture) {
            ctx.fill(ellipse(282, 108, 30, 30), p.sun)
            ctx.fill(ellipse(140, 290, 170, 110), p.hill)
            ctx.fill(ellipse(300, 300, 150, 90), p.hill)
        }

        // The rows. The last line is short, to leave room for the touch.
        for (k, width) in [208, 156, 96].enumerated() {
            let y = 318 + CGFloat(k) * 82
            ctx.fill(ellipse(78, y, 27, 27), sphere: p.dots[k])
            ctx.fill(ellipse(69, y - 10, 9, 5, rotated: -30), white(0.55))
            ctx.fill(capsule(126, y - 15, CGFloat(width), 30), p.bar)
        }

        // The touch point: a bright dot in a ring, on a pale disc that spreads out from it, with a soft glow.
        let x: CGFloat = 280, y: CGFloat = 504
        ctx.blurred(radius: 30 * scale) { $0.fill(ellipse(x, y, 100, 100), p.touchGlow) }
        ctx.fill(ellipse(x, y, 88, 88), p.touchHalo)
        ctx.stroke(ellipse(x, y, 84, 84), width: 8, p.touchRing.copy(alpha: 0.35)!)
        ctx.stroke(ellipse(x, y, 58, 58), width: 13, p.touchRing)
        ctx.fill(ellipse(x, y, 36, 36), sphere: p.touch)
        ctx.fill(ellipse(x - 12, y - 13, 11, 7, rotated: -30), white(0.8))

        ctx.restoreGState()
    }

    // Everything is laid out at a base size, then drawn 5% larger about the middle.
    ctx.translateBy(x: 512, y: 512)
    ctx.scaleBy(x: 1.05, y: 1.05)
    ctx.translateBy(x: -510, y: -524)

    // The Mac window: a glowing edge, a title bar with three dots, and a faint blueprint grid below it.
    let window = rounded(140, 160, 600, 440, 48)
    ctx.withShadow(blur: 50, drop: 30, color: p.windowShadow) { ctx.fill(window, p.window[0]) }
    ctx.blurred(radius: 16) { $0.stroke(window, width: 14, p.windowGlow) }
    ctx.fill(window, gradient: p.window)
    ctx.clipped(to: window) {
        ctx.fill(CGPath(rect: CGRect(x: 140, y: 160, width: 600, height: 100), transform: nil), p.windowBar)
        for k in 1..<10 {
            ctx.fill(CGPath(rect: CGRect(x: 140 + CGFloat(k) * 60, y: 260, width: 3, height: 340), transform: nil), p.windowGrid)
        }
        for k in 0..<6 {
            ctx.fill(CGPath(rect: CGRect(x: 140, y: 260 + CGFloat(k) * 60, width: 600, height: 3), transform: nil), p.windowGrid)
        }
    }
    ctx.stroke(rounded(143, 163, 594, 434, 45), width: 6, p.windowEdge)
    for (k, light) in p.lights.enumerated() {
        ctx.fill(ellipse(198 + CGFloat(k) * 44, 210, 14, 14), light)
    }

    // The simulator inside the window, then the phone in front showing the same thing.
    screen(at: CGPoint(x: 218, y: 280), scale: 0.45, shadow: p.windowShadow, shadowBlur: 20)
    screen(at: CGPoint(x: 470, y: 250), scale: 1.025, shadow: p.frameShadow, shadowBlur: 54)

    let image = ctx.makeImage()!
    let destination = CGImageDestinationCreateWithURL(dir.appendingPathComponent(name) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

render(.light, to: "AppIcon.png")
render(.dark, to: "AppIcon-Dark.png")
render(.tinted, to: "AppIcon-Tinted.png")
print("done")
