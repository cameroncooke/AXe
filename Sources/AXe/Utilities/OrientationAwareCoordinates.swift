import Darwin
import Foundation
import AXeCore
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
        coreOrientation.isLandscape
    }

    var coreOrientation: OrientationCoordinateMath.Orientation {
        switch self {
        case .portrait:
            return .portrait
        case .portraitUpsideDown:
            return .portraitUpsideDown
        case .landscape:
            return .landscape
        case .landscapeFlipped:
            return .landscapeFlipped
        }
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
/// Detection: read SimulatorKit's private screen `uiOrientation` when available,
/// then fall back to screenshot pixel aspect ratio to distinguish portrait-hardware
/// letterboxing from a rotated simulator.
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
/// a landscape-shaped AX application frame. AXe first asks the simulator's private
/// screen properties for the current UI orientation so it can distinguish landscape
/// left from landscape right automatically. If that private probe is unavailable,
/// screenshot dimensions are used only to distinguish rotated hardware from a
/// portrait device running a letterboxed landscape-only app. If the screenshot
/// confirms rotated hardware but private orientation is unavailable, AXe fails
/// clearly instead of guessing landscape direction.
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
    /// 2. If an explicit override was supplied → rotation case.
    /// 3. Otherwise read SimulatorKit private UI orientation.
    /// 4. If private orientation is unavailable and the AX frame is portrait-shaped → passthrough.
    /// 5. If unavailable and landscape-shaped, probe screenshot dimensions.
    ///    - Screenshot portrait-shaped (taller than wide) → letterbox case.
    ///    - Screenshot landscape-shaped (wider than tall) → rotated device case.
    ///
    /// - Parameters:
    ///   - simulatorUDID: Target simulator UDID.
    ///   - orientationOverride: Forces a specific rotated-device `SimulatorOrientation`.
    ///     Intended for internal tests or future explicit callers; normal CLI commands
    ///     rely on automatic private orientation detection.
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

        return try await detectMapping(
            from: roots,
            simulatorUDID: simulatorUDID,
            orientationOverride: orientationOverride,
            logger: logger
        )
    }

    static func detectMapping(
        from roots: [AccessibilityElement],
        simulatorUDID: String,
        orientationOverride: SimulatorOrientation? = nil,
        logger: AxeLogger
    ) async throws -> CoordinateMapping {
        guard let appFrame = applicationFrame(from: roots) else {
            throw CLIError(errorDescription: "Unable to determine coordinate mapping because the accessibility application frame is unavailable.")
        }

        if let orientationOverride {
            logger.info().log("Using explicit orientation override: \(orientationOverride.rawValue)")
            guard let portraitSize = portraitDimensions(from: roots, orientation: orientationOverride) else {
                throw CLIError(errorDescription: "Unable to determine coordinate mapping because portrait dimensions are unavailable.")
            }
            return .rotation(orientationOverride, portraitSize: portraitSize)
        }

        // Prefer the simulator's private UI orientation state when available; this
        // distinguishes landscape-left from landscape-right and catches upside-down portrait.
        let simulatorOrientation = await SimulatorOrientationReader.currentOrientation(
            simulatorUDID: simulatorUDID,
            logger: logger
        )

        if let simulatorOrientation {
            logger.info().log("Detected simulator UI orientation: \(simulatorOrientation.rawValue)")
            guard let portraitSize = portraitDimensions(from: roots, orientation: simulatorOrientation) else {
                throw CLIError(errorDescription: "Unable to determine coordinate mapping because portrait dimensions are unavailable.")
            }

            switch simulatorOrientation {
            case .portrait:
                return .passthrough
            case .portraitUpsideDown, .landscape, .landscapeFlipped:
                return .rotation(simulatorOrientation, portraitSize: portraitSize)
            }
        }

        guard appFrame.width > appFrame.height else {
            logger.info().log(
                "AX frame \(Int(appFrame.width))×\(Int(appFrame.height)) is portrait; passthrough"
            )
            return .passthrough
        }

        // Fall back to screenshot aspect ratio to distinguish rotated hardware from a
        // portrait device running a landscape-only app.
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

        guard let screenshotDims else {
            throw CLIError(errorDescription: "Unable to determine coordinate mapping because screenshot probing failed for a landscape accessibility frame.")
        }

        // Screenshot is landscape-shaped — hardware is rotated.
        logger.info().log(
            "Screenshot \(screenshotDims.width)×\(screenshotDims.height)px is landscape-shaped; using rotation mapping"
        )

        throw CLIError(errorDescription: "Unable to determine rotated simulator orientation. AXe can read landscape coordinates only when SimulatorKit reports the current UI orientation; the screenshot confirms the simulator is rotated, but the private orientation probe was unavailable.")
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
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("axe-screenshot-probe-\(UUID().uuidString)")
            .appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "io", simulatorUDID, "screenshot", "--type", "png", tempURL.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            logger.info().log("Screenshot probe: could not launch xcrun simctl: \(error)")
            return nil
        }

        guard waitForProcessExit(process, timeout: 3.0, logger: logger), process.terminationStatus == 0 else {
            logger.info().log("Screenshot probe: simctl screenshot failed or timed out")
            return nil
        }

        let headerData: Data
        do {
            let data = try Data(contentsOf: tempURL)
            headerData = Data(data.prefix(24))
        } catch {
            logger.info().log("Screenshot probe: could not read temp PNG: \(error)")
            return nil
        }

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

    private static func waitForProcessExit(
        _ process: Process,
        timeout: TimeInterval,
        logger: AxeLogger
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        guard process.isRunning else { return true }

        logger.info().log("Screenshot probe: timed out waiting for simctl screenshot")
        process.terminate()

        let terminateDeadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < terminateDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        if process.isRunning {
            logger.info().log("Screenshot probe: force-killing unresponsive simctl screenshot process")
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        return false
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
        OrientationCoordinateMath.translateToPhysical(
            x: point.x,
            y: point.y,
            orientation: orientation.coreOrientation,
            portraitWidth: portraitSize.width,
            portraitHeight: portraitSize.height
        )
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
        OrientationCoordinateMath.letterboxToPhysical(
            x: point.x,
            y: point.y,
            scale: scale,
            offsetX: offsetX,
            offsetY: offsetY
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
    ///   - orientationOverride: Optional explicit rotated-device orientation. Pass
    ///     `.landscapeFlipped` when the device is rotated counter-clockwise. Leave nil for
    ///     automatic letterbox detection in portrait-hardware landscape-only apps.
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

    static func translate(
        point: (x: Double, y: Double),
        roots: [AccessibilityElement],
        for simulatorUDID: String,
        orientationOverride: SimulatorOrientation? = nil,
        logger: AxeLogger
    ) async throws -> (x: Double, y: Double) {
        let mapping = try await detectMapping(
            from: roots,
            simulatorUDID: simulatorUDID,
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

    static func translateBatch(
        points: [(x: Double, y: Double)],
        roots: [AccessibilityElement],
        for simulatorUDID: String,
        orientationOverride: SimulatorOrientation? = nil,
        logger: AxeLogger
    ) async throws -> [(x: Double, y: Double)] {
        let mapping = try await detectMapping(
            from: roots,
            simulatorUDID: simulatorUDID,
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
