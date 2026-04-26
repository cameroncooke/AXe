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
/// ## Orientation detection
/// The orientation is inferred from the `Application`-typed root element in the
/// accessibility tree: if `frame.width > frame.height`, the device is in a
/// landscape orientation.  Portrait vs upside-down and landscape vs
/// landscape-flipped cannot be distinguished from element geometry alone.
/// The caller may supply an explicit orientation override (e.g. from a
/// `--landscape-flipped` flag) when the default is incorrect.
///
/// ## Portrait dimensions
/// The short side of the device in points is the portrait width; the long side
/// is the portrait height.  These are derived from the application frame: in
/// portrait they are `frame.width` and `frame.height`; in landscape they are
/// swapped.
@MainActor
struct OrientationAwareCoordinates {

    // MARK: - Orientation Detection

    /// Determines the current logical orientation by inspecting the accessibility
    /// tree of the given simulator.
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
            // Landscape — default to home-right (most common iOS landscape orientation).
            // Pass `--landscape-flipped` explicitly if the device is home-left.
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

    // MARK: - Coordinate Translation

    /// Translates a logical point (as reported by the accessibility tree) to the
    /// physical portrait point expected by FBSimulatorHIDEvent.
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

    /// Fetches orientation, derives portrait dimensions from the AX tree, translates
    /// the point, and logs the result.
    ///
    /// This is the single entry point used by `Tap`, `Touch`, and `Swipe`.
    ///
    /// - Parameters:
    ///   - point: Logical (x, y) as supplied by the caller.
    ///   - simulatorUDID: Target simulator UDID.
    ///   - orientationOverride: Optional explicit orientation; skips AX-based detection.
    ///   - logger: AXe logger instance.
    /// - Returns: Physical (x, y) ready for FBSimulatorHIDEvent.
    static func translate(
        point: (x: Double, y: Double),
        for simulatorUDID: String,
        orientationOverride: SimulatorOrientation? = nil,
        logger: AxeLogger
    ) async throws -> (x: Double, y: Double) {
        let orientation = try await detectOrientation(
            for: simulatorUDID,
            orientationOverride: orientationOverride,
            logger: logger
        )

        // Portrait requires no translation — skip the AX fetch entirely.
        guard orientation != .portrait else {
            return point
        }

        let roots = try await AccessibilityFetcher.fetchAccessibilityElements(
            for: simulatorUDID,
            logger: logger
        )

        guard let portraitSize = portraitDimensions(from: roots, orientation: orientation) else {
            logger.info().log(
                "Could not determine portrait dimensions; dispatching logical coordinates unchanged"
            )
            return point
        }

        let physical = translateToPhysical(point: point, orientation: orientation, portraitSize: portraitSize)

        if physical.x != point.x || physical.y != point.y {
            logger.info().log(
                "Translated logical (\(Int(point.x)), \(Int(point.y))) → physical (\(Int(physical.x)), \(Int(physical.y))) for \(orientation.rawValue) orientation"
            )
        }

        return physical
    }

    /// Translates multiple logical points in a single AX fetch round-trip.
    ///
    /// Prefer this over calling `translate(point:for:orientationOverride:logger:)` in a loop when
    /// translating several points for the same simulator state (e.g. swipe start and end).
    ///
    /// - Parameters:
    ///   - points: Logical (x, y) pairs in the current UI orientation.
    ///   - simulatorUDID: Target simulator UDID.
    ///   - orientationOverride: Optional explicit orientation; skips AX-based detection.
    ///   - logger: AXe logger instance.
    /// - Returns: Physical (x, y) pairs ready for FBSimulatorHIDEvent, in the same order as input.
    static func translateBatch(
        points: [(x: Double, y: Double)],
        for simulatorUDID: String,
        orientationOverride: SimulatorOrientation? = nil,
        logger: AxeLogger
    ) async throws -> [(x: Double, y: Double)] {
        // Detect orientation using the override or a single AX fetch.
        let roots = try await AccessibilityFetcher.fetchAccessibilityElements(
            for: simulatorUDID,
            logger: logger
        )

        let orientation: SimulatorOrientation
        if let override = orientationOverride {
            logger.info().log("Using explicit orientation override: \(override.rawValue)")
            orientation = override
        } else if let appFrame = applicationFrame(from: roots) {
            if appFrame.width > appFrame.height {
                logger.info().log(
                    "Detected landscape orientation from application frame \(Int(appFrame.width))x\(Int(appFrame.height))"
                )
                orientation = .landscape
            } else {
                logger.info().log(
                    "Detected portrait orientation from application frame \(Int(appFrame.width))x\(Int(appFrame.height))"
                )
                orientation = .portrait
            }
        } else {
            logger.info().log("Could not read application frame; assuming portrait orientation")
            orientation = .portrait
        }

        guard orientation != .portrait else {
            return points
        }

        guard let portraitSize = portraitDimensions(from: roots, orientation: orientation) else {
            logger.info().log(
                "Could not determine portrait dimensions; dispatching logical coordinates unchanged"
            )
            return points
        }

        return points.map { point in
            let physical = translateToPhysical(point: point, orientation: orientation, portraitSize: portraitSize)
            if physical.x != point.x || physical.y != point.y {
                logger.info().log(
                    "Translated logical (\(Int(point.x)), \(Int(point.y))) → physical (\(Int(physical.x)), \(Int(physical.y))) for \(orientation.rawValue) orientation"
                )
            }
            return physical
        }
    }

    // MARK: - Private Helpers

    private static func applicationFrame(
        from roots: [AccessibilityElement]
    ) -> AccessibilityElement.Frame? {
        roots.first { $0.type == "Application" }?.frame
            ?? roots.first?.frame
    }
}
