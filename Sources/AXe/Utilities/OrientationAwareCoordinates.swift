import Foundation
import FBControlCore
import FBSimulatorControl

// MARK: - Simulator Orientation

/// Logical UI orientation of a simulator as reported by its accessibility tree.
///
/// Matches UIInterfaceOrientation semantics:
///   - `portrait`            — home button at the bottom (default)
///   - `portraitUpsideDown`  — home button at the top (180°)
///   - `landscape`           — home button to the right (90° CW from portrait)
///   - `landscapeFlipped`    — home button to the left (90° CCW from portrait)
enum SimulatorOrientation: String, CaseIterable {
    case portrait
    case portraitUpsideDown
    case landscape
    case landscapeFlipped

    /// True when the logical screen width is wider than tall.
    var isLandscape: Bool {
        self == .landscape || self == .landscapeFlipped
    }
}

// MARK: - Coordinate Mapping

/// Describes how logical coordinates from the accessibility tree map to the physical
/// portrait coordinate space that FBSimulatorHIDEvent expects.
///
/// The AX application frame alone cannot distinguish two landscape cases:
///   - **Rotation:**  hardware is in landscape (device rotated). Rotation math applies.
///   - **Letterbox:** hardware is portrait, but the app declares landscape-only
///     orientations. iOS scales + centers the landscape UI inside the portrait
///     viewport. Scale + offset math applies.
///
/// Detection: compare screenshot pixel aspect ratio to AX frame aspect ratio.
/// If screenshot is taller-than-wide while AX frame is wider-than-tall →
/// letterbox case. Otherwise → rotated device case.
enum CoordinateMapping {
    /// Portrait device, portrait app — pass coordinates through unchanged.
    case passthrough

    /// Hardware is rotated. Apply rotation math.
    ///
    /// `portraitSize` = `(width: shortSide, height: longSide)` in logical points.
    case rotation(SimulatorOrientation, portraitSize: (width: Double, height: Double))

    /// Hardware is portrait, app is landscape-only. Apply letterbox scale + offset.
    ///
    /// Physical point = `(offsetX + lx * scale, offsetY + ly * scale)`.
    case letterbox(scale: Double, offsetX: Double, offsetY: Double)
}

// MARK: - Orientation-Aware Coordinate Translation

/// Translates logical UI coordinates (as reported by the accessibility tree and
/// consumed by `axe tap`, `axe touch`, and `axe swipe`) into the physical portrait
/// coordinate space that FBSimulatorHIDEvent expects.
///
/// ## Root cause
/// The iOS Simulator's HID layer always operates in physical portrait space.
/// The accessibility tree, however, reports element positions in the *logical*
/// orientation the app currently presents.  When the device is rotated, logical
/// coordinates must be mapped back to physical portrait before dispatching HID
/// events, otherwise taps land in the wrong location.
///
/// ## Two landscape cases
/// Both a rotated device and a portrait device running a landscape-only app produce
/// a landscape-shaped AX application frame. Detection uses screenshot pixel
/// dimensions via `xcrun simctl io <udid> screenshot -`: if the screenshot is
/// taller than wide while the AX frame is wider than tall, the device hardware is
/// portrait (letterbox case). If both are landscape-shaped, the hardware is rotated.
///
/// ## Orientation detection (rotated case)
/// Portrait vs upside-down and landscape vs landscape-flipped cannot be
/// distinguished from element geometry alone.  The caller may supply an explicit
/// orientation override (e.g. from a `--landscape-flipped` flag) for the rotated
/// case when the default landscape-home-right assumption is incorrect.
///
/// ## Portrait dimensions
/// The short side of the device in points is the portrait width; the long side
/// is the portrait height.  These are derived from the application frame: in
/// portrait they are `frame.width` and `frame.height`; in landscape they are
/// swapped.
@MainActor
struct OrientationAwareCoordinates {

    // MARK: - Coordinate Mapping Detection

    /// Determines which coordinate mapping to apply for the given simulator.
    ///
    /// Detection flow:
    /// 1. Fetch AX application frame.
    /// 2. If portrait-shaped → passthrough.
    /// 3. If landscape-shaped → probe screenshot pixel dimensions.
    ///    - Screenshot portrait-shaped (taller than wide) → letterbox case.
    ///    - Screenshot landscape-shaped (wider than tall) → rotated device case.
    /// 4. Apply orientation override (landscape-flipped flag) only in the rotated case.
    ///
    /// - Parameters:
    ///   - simulatorUDID: Target simulator UDID.
    ///   - orientationOverride: Forces a specific `SimulatorOrientation` for the rotated
    ///     device case. Has no effect in the letterbox case. Pass `.landscapeFlipped` when
    ///     the device is rotated counter-clockwise and the default (landscape home-right)
    ///     is wrong.
    ///   - logger: AXe logger instance.
    /// - Returns: The `CoordinateMapping` that applies to the current simulator state.
    static func detectMapping(
        for simulatorUDID: String,
        orientationOverride: SimulatorOrientation? = nil,
        logger: AxeLogger
    ) async throws -> CoordinateMapping {
        let roots = try await AccessibilityFetcher.fetchAccessibilityElements(
            for: simulatorUDID,
            logger: logger
        )

        guard let appFrame = applicationFrame(from: roots) else {
            logger.info().log("Could not read application frame; assuming portrait passthrough")
            return .passthrough
        }

        guard appFrame.width > appFrame.height else {
            // Portrait-shaped AX frame — no translation needed.
            logger.info().log(
                "AX frame \(Int(appFrame.width))×\(Int(appFrame.height)) is portrait; passthrough"
            )
            return .passthrough
        }

        // Landscape-shaped AX frame. Distinguish rotated hardware from letterboxed app.
        logger.info().log(
            "AX frame \(Int(appFrame.width))×\(Int(appFrame.height)) is landscape; probing screenshot dimensions"
        )

        let screenshotDims = await screenshotPixelDimensions(for: simulatorUDID, logger: logger)

        if let dims = screenshotDims, dims.height > dims.width {
            // Screenshot is portrait-shaped despite a landscape AX frame →
            // hardware is portrait, app is landscape-only: letterbox case.
            logger.info().log(
                "Screenshot \(dims.width)×\(dims.height)px is portrait-shaped; using letterbox mapping"
            )

            // Physical viewport in points: short side = portrait width, long side = portrait height.
            // Derived from the landscape AX frame by swapping axes (same as portraitDimensions).
            let physW = appFrame.height  // portrait width  = landscape logical height
            let physH = appFrame.width   // portrait height = landscape logical width
            let logW  = appFrame.width   // logical landscape width
            let logH  = appFrame.height  // logical landscape height

            // Uniform scale to fit logical content into physical viewport.
            let scale = min(physW / logW, physH / logH)
            let offsetX = (physW - logW * scale) / 2
            let offsetY = (physH - logH * scale) / 2

            logger.info().log(
                String(format: "Letterbox: scale=%.4f offsetX=%.1f offsetY=%.1f", scale, offsetX, offsetY)
            )
            return .letterbox(scale: scale, offsetX: offsetX, offsetY: offsetY)
        }

        // Screenshot is landscape-shaped (or unavailable) — hardware is rotated.
        if screenshotDims == nil {
            logger.info().log("Screenshot probe unavailable; assuming rotated hardware")
        } else {
            logger.info().log(
                "Screenshot \(screenshotDims!.width)×\(screenshotDims!.height)px is landscape-shaped; using rotation mapping"
            )
        }

        let orientation: SimulatorOrientation
        if let override = orientationOverride {
            logger.info().log("Using explicit orientation override: \(override.rawValue)")
            orientation = override
        } else {
            // Default: landscape home-right (most common iOS landscape orientation).
            // Pass `--landscape-flipped` when the device is rotated counter-clockwise.
            orientation = .landscape
            logger.info().log("Defaulting to landscape (home right) orientation")
        }

        guard let portraitSize = portraitDimensions(from: roots, orientation: orientation) else {
            logger.info().log(
                "Could not determine portrait dimensions; falling back to passthrough"
            )
            return .passthrough
        }

        return .rotation(orientation, portraitSize: portraitSize)
    }

    // MARK: - Screenshot Dimension Probe

    /// Reads the pixel dimensions of the current simulator screenshot via
    /// `xcrun simctl io <udid> screenshot -`.
    ///
    /// Only the first 24 bytes of the PNG output are consumed (PNG IHDR chunk),
    /// so this is fast and does not write any files.
    ///
    /// Returns `nil` if the process fails or the output is not a valid PNG.
    static func screenshotPixelDimensions(
        for simulatorUDID: String,
        logger: AxeLogger
    ) async -> (width: Int, height: Int)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "io", simulatorUDID, "screenshot", "--type", "png", "-"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()  // suppress simctl stderr

        do {
            try process.run()
        } catch {
            logger.info().log("Screenshot probe: could not launch xcrun simctl: \(error)")
            return nil
        }

        // Read just the first 24 bytes — enough for PNG signature (8) + IHDR (16).
        // PNG spec: bytes 16-19 = width (big-endian uint32), 20-23 = height.
        var headerData = Data()
        let fileHandle = pipe.fileHandleForReading
        while headerData.count < 24 {
            let chunk = fileHandle.availableData
            if chunk.isEmpty { break }
            headerData.append(chunk)
        }
        process.terminate()

        guard headerData.count >= 24 else {
            logger.info().log("Screenshot probe: PNG header too short (\(headerData.count) bytes)")
            return nil
        }

        // Verify PNG signature: 8 bytes \x89PNG\r\n\x1a\n
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard headerData.prefix(8).elementsEqual(pngSignature) else {
            logger.info().log("Screenshot probe: output is not a valid PNG")
            return nil
        }

        // IHDR width and height at bytes 16-19 and 20-23 (big-endian uint32).
        let widthBytes  = headerData[16..<20]
        let heightBytes = headerData[20..<24]

        let width  = widthBytes.reduce(0)  { Int($0) << 8 | Int($1) }
        let height = heightBytes.reduce(0) { Int($0) << 8 | Int($1) }

        logger.info().log("Screenshot probe: \(width)×\(height)px")
        return (width: width, height: height)
    }

    // MARK: - Coordinate Translation

    /// Translates a logical point (as reported by the accessibility tree) to the
    /// physical portrait point expected by FBSimulatorHIDEvent using rotation math.
    ///
    /// - Parameters:
    ///   - point: Logical (x, y) in the current UI orientation.
    ///   - orientation: The current logical orientation of the simulator.
    ///   - portraitSize: The device's portrait dimensions `(width: shortSide, height: longSide)`.
    /// - Returns: Physical (x, y) in portrait space.
    static func translateToPhysical(
        point: (x: Double, y: Double),
        orientation: SimulatorOrientation,
        portraitSize: (width: Double, height: Double)
    ) -> (x: Double, y: Double) {
        let pw = portraitSize.width   // short side (portrait width)
        let ph = portraitSize.height  // long side  (portrait height)

        switch orientation {
        case .portrait:
            return point

        case .portraitUpsideDown:
            // 180° rotation: mirror both axes
            return (x: pw - point.x, y: ph - point.y)

        case .landscape:
            // 90° CW from portrait (home button to the right)
            // Logical origin = physical top-left; logical x-axis = physical y-axis (downward)
            // px = ly, py = ph - lx
            return (x: point.y, y: ph - point.x)

        case .landscapeFlipped:
            // 90° CCW from portrait (home button to the left)
            // px = pw - ly, py = lx
            return (x: pw - point.y, y: point.x)
        }
    }

    /// Translates a logical point to a physical point using letterbox scale + offset math.
    ///
    /// iOS places a landscape-only app inside the portrait viewport by scaling it
    /// uniformly and centering it. The physical point is:
    ///
    ///   `px = offsetX + lx * scale`
    ///   `py = offsetY + ly * scale`
    ///
    /// - Parameters:
    ///   - point:   Logical (x, y) as reported by the AX tree.
    ///   - scale:   Uniform scale factor (`min(physW / logW, physH / logH)`).
    ///   - offsetX: Horizontal letterbox offset in points (`(physW - logW * scale) / 2`).
    ///   - offsetY: Vertical letterbox offset in points (`(physH - logH * scale) / 2`).
    /// - Returns: Physical (x, y) in the portrait hardware viewport.
    static func letterboxToPhysical(
        point: (x: Double, y: Double),
        scale: Double,
        offsetX: Double,
        offsetY: Double
    ) -> (x: Double, y: Double) {
        return (
            x: offsetX + point.x * scale,
            y: offsetY + point.y * scale
        )
    }

    /// Derives the device's portrait dimensions from the accessibility tree.
    ///
    /// In portrait, the application frame is already in portrait coordinates.
    /// In landscape, the width and height are swapped compared to portrait.
    ///
    /// - Parameters:
    ///   - roots: Root accessibility elements from `AccessibilityFetcher`.
    ///   - orientation: The current logical orientation.
    /// - Returns: Portrait `(width, height)`, or `nil` if the application frame is unavailable.
    static func portraitDimensions(
        from roots: [AccessibilityElement],
        orientation: SimulatorOrientation
    ) -> (width: Double, height: Double)? {
        guard let frame = applicationFrame(from: roots) else { return nil }

        if orientation.isLandscape {
            // In landscape: logical width = portrait height, logical height = portrait width
            return (width: frame.height, height: frame.width)
        }
        return (width: frame.width, height: frame.height)
    }

    // MARK: - Full Pipeline

    /// Detects the appropriate coordinate mapping and translates a single logical
    /// point to the physical portrait point expected by FBSimulatorHIDEvent.
    ///
    /// This is the single entry point used by `Tap`, `Touch`, and `Swipe`.
    ///
    /// Handles three cases automatically:
    /// - Portrait device, portrait app → passthrough.
    /// - Portrait device, landscape-only app → letterbox scale + offset.
    /// - Rotated hardware → rotation math.
    ///
    /// - Parameters:
    ///   - point: Logical (x, y) as supplied by the caller.
    ///   - simulatorUDID: Target simulator UDID.
    ///   - orientationOverride: Optional explicit orientation for the rotated device case.
    ///     Pass `.landscapeFlipped` when the device is rotated counter-clockwise. Has no
    ///     effect when the letterbox case is detected.
    ///   - logger: AXe logger instance.
    /// - Returns: Physical (x, y) ready for FBSimulatorHIDEvent.
    static func translate(
        point: (x: Double, y: Double),
        for simulatorUDID: String,
        orientationOverride: SimulatorOrientation? = nil,
        logger: AxeLogger
    ) async throws -> (x: Double, y: Double) {
        let mapping = try await detectMapping(
            for: simulatorUDID,
            orientationOverride: orientationOverride,
            logger: logger
        )

        return applyMapping(mapping, to: point, logger: logger)
    }

    /// Translates multiple logical points using a single detection round-trip.
    ///
    /// Prefer this over calling `translate(point:for:orientationOverride:logger:)` in a loop when
    /// translating several points for the same simulator state (e.g. swipe start and end).
    ///
    /// - Parameters:
    ///   - points: Logical (x, y) pairs in the current UI orientation.
    ///   - simulatorUDID: Target simulator UDID.
    ///   - orientationOverride: Optional explicit orientation for the rotated device case.
    ///   - logger: AXe logger instance.
    /// - Returns: Physical (x, y) pairs ready for FBSimulatorHIDEvent, in the same order as input.
    static func translateBatch(
        points: [(x: Double, y: Double)],
        for simulatorUDID: String,
        orientationOverride: SimulatorOrientation? = nil,
        logger: AxeLogger
    ) async throws -> [(x: Double, y: Double)] {
        let mapping = try await detectMapping(
            for: simulatorUDID,
            orientationOverride: orientationOverride,
            logger: logger
        )

        return points.map { applyMapping(mapping, to: $0, logger: logger) }
    }

    // MARK: - Private Helpers

    /// Applies a `CoordinateMapping` to a single logical point, logging the translation.
    private static func applyMapping(
        _ mapping: CoordinateMapping,
        to point: (x: Double, y: Double),
        logger: AxeLogger
    ) -> (x: Double, y: Double) {
        let physical: (x: Double, y: Double)

        switch mapping {
        case .passthrough:
            return point

        case .rotation(let orientation, let portraitSize):
            physical = translateToPhysical(point: point, orientation: orientation, portraitSize: portraitSize)
            logger.info().log(
                "Translated logical (\(Int(point.x)), \(Int(point.y))) → physical (\(Int(physical.x)), \(Int(physical.y))) [rotation: \(orientation.rawValue)]"
            )

        case .letterbox(let scale, let offsetX, let offsetY):
            physical = letterboxToPhysical(point: point, scale: scale, offsetX: offsetX, offsetY: offsetY)
            logger.info().log(
                String(format: "Translated logical (%d, %d) → physical (%.1f, %.1f) [letterbox: scale=%.4f offsetX=%.1f offsetY=%.1f]",
                       Int(point.x), Int(point.y), physical.x, physical.y, scale, offsetX, offsetY)
            )
        }

        return physical
    }

    private static func applicationFrame(
        from roots: [AccessibilityElement]
    ) -> AccessibilityElement.Frame? {
        roots.first { $0.type == "Application" }?.frame
            ?? roots.first?.frame
    }

    // MARK: - Orientation Detection (legacy — preserved for callers that need it directly)

    /// Determines the current logical orientation by inspecting the accessibility tree.
    ///
    /// Prefer `detectMapping(for:orientationOverride:logger:)` for full tap/touch/swipe
    /// coordinate translation. This method only reads the AX frame and cannot distinguish
    /// a rotated device from a letterboxed landscape-only app.
    ///
    /// - Parameters:
    ///   - simulatorUDID: Target simulator UDID.
    ///   - orientationOverride: When non-nil, skip detection and use this value.
    ///   - logger: AXe logger instance.
    /// - Returns: The detected (or overridden) orientation.
    static func detectOrientation(
        for simulatorUDID: String,
        orientationOverride: SimulatorOrientation? = nil,
        logger: AxeLogger
    ) async throws -> SimulatorOrientation {
        if let override = orientationOverride {
            logger.info().log("Using explicit orientation override: \(override.rawValue)")
            return override
        }

        let roots = try await AccessibilityFetcher.fetchAccessibilityElements(
            for: simulatorUDID,
            logger: logger
        )

        guard let appFrame = applicationFrame(from: roots) else {
            logger.info().log("Could not read application frame; assuming portrait orientation")
            return .portrait
        }

        if appFrame.width > appFrame.height {
            logger.info().log(
                "Detected landscape orientation from application frame \(Int(appFrame.width))x\(Int(appFrame.height))"
            )
            return .landscape
        }

        logger.info().log(
            "Detected portrait orientation from application frame \(Int(appFrame.width))x\(Int(appFrame.height))"
        )
        return .portrait
    }
}
