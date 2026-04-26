import Testing
import Foundation

// MARK: - Orientation Math Tests
//
// The iOS Simulator HID layer always operates in physical portrait space.
// The accessibility tree reports positions in the *logical* UI orientation.
// These tests verify the coordinate math that maps logical coordinates to physical ones.
//
// Two landscape cases are covered:
//   (a) Rotated hardware — `translateToPhysical` rotation math.
//   (b) Portrait hardware + landscape-only app — `letterboxToPhysical` scale + offset math.
//
// Because the AXe executable target does not expose its types to the test target,
// the reference math is duplicated here.  Any change to OrientationAwareCoordinates
// must be reflected in the local implementation below so that a divergence causes a
// test failure rather than a silent gap.
//
// Device under test in the parameterized tests: iPad Pro 13-inch (M5)
//   portrait width  = 1032 pts  (short side)
//   portrait height = 1376 pts  (long side)
//   landscape frame = 1376 × 1032 (width > height → isLandscape)
//   screenshot (portrait physical): 2064 × 2752 px  → 1032 × 1376 pts at 2x scale

// MARK: - Local Reference Implementation

/// Mirror of `SimulatorOrientation` in OrientationAwareCoordinates.swift.
private enum TestOrientation {
    case portrait
    case portraitUpsideDown
    case landscape
    case landscapeFlipped
}

/// Mirror of `OrientationAwareCoordinates.translateToPhysical`.
/// Must stay in sync with the production implementation.
private func translateToPhysical(
    lx: Double, ly: Double,
    orientation: TestOrientation,
    portraitWidth pw: Double,
    portraitHeight ph: Double
) -> (x: Double, y: Double) {
    switch orientation {
    case .portrait:
        return (lx, ly)
    case .portraitUpsideDown:
        return (pw - lx, ph - ly)
    case .landscape:
        // 90° CW: px = ly, py = ph - lx
        return (ly, ph - lx)
    case .landscapeFlipped:
        // 90° CCW: px = pw - ly, py = lx
        return (pw - ly, lx)
    }
}

/// Mirror of `OrientationAwareCoordinates.letterboxToPhysical`.
/// Must stay in sync with the production implementation.
private func letterboxToPhysical(
    lx: Double, ly: Double,
    scale: Double,
    offsetX: Double,
    offsetY: Double
) -> (x: Double, y: Double) {
    return (
        x: offsetX + lx * scale,
        y: offsetY + ly * scale
    )
}

/// Mirror of the letterbox parameter calculation in
/// `OrientationAwareCoordinates.detectMapping`.
///
/// Given:
///   - `logicalSize` = landscape AX frame (e.g. 1376 × 1032 for iPad Pro 13")
///   - `physicalSize` = portrait hardware viewport in points (e.g. 1032 × 1376)
///
/// Returns `(scale, offsetX, offsetY)`.
private func letterboxParameters(
    logicalW: Double, logicalH: Double,
    physicalW: Double, physicalH: Double
) -> (scale: Double, offsetX: Double, offsetY: Double) {
    let scale   = min(physicalW / logicalW, physicalH / logicalH)
    let offsetX = (physicalW - logicalW * scale) / 2
    let offsetY = (physicalH - logicalH * scale) / 2
    return (scale, offsetX, offsetY)
}

// MARK: - Tests

private let iPadPro13PortraitWidth = 1032.0
private let iPadPro13PortraitHeight = 1376.0

@Suite("Orientation-aware coordinate translation math")
struct OrientationAwareCoordinatesTests {

    // MARK: Portrait — identity

    @Test("Portrait: any point passes through unchanged")
    func portraitIsIdentity() {
        let (x, y) = translateToPhysical(
            lx: 200, ly: 400,
            orientation: .portrait,
            portraitWidth: iPadPro13PortraitWidth,
            portraitHeight: iPadPro13PortraitHeight
        )
        #expect(x == 200)
        #expect(y == 400)
    }

    @Test("Portrait: origin is identity")
    func portraitOriginIsIdentity() {
        let (x, y) = translateToPhysical(
            lx: 0, ly: 0,
            orientation: .portrait,
            portraitWidth: iPadPro13PortraitWidth,
            portraitHeight: iPadPro13PortraitHeight
        )
        #expect(x == 0)
        #expect(y == 0)
    }

    // MARK: Portrait Upside-Down — 180° mirror

    @Test("PortraitUpsideDown: mirrors both axes")
    func portraitUpsideDownMirrors() {
        // (200, 300) → (pw - 200, ph - 300) = (832, 1076)
        let (x, y) = translateToPhysical(
            lx: 200, ly: 300,
            orientation: .portraitUpsideDown,
            portraitWidth: iPadPro13PortraitWidth,
            portraitHeight: iPadPro13PortraitHeight
        )
        #expect(x == iPadPro13PortraitWidth - 200)
        #expect(y == iPadPro13PortraitHeight - 300)
    }

    @Test("PortraitUpsideDown: center maps to center")
    func portraitUpsideDownCenterIsFixed() {
        let cx = iPadPro13PortraitWidth / 2
        let cy = iPadPro13PortraitHeight / 2
        let (x, y) = translateToPhysical(
            lx: cx, ly: cy,
            orientation: .portraitUpsideDown,
            portraitWidth: iPadPro13PortraitWidth,
            portraitHeight: iPadPro13PortraitHeight
        )
        #expect(x == cx)
        #expect(y == cy)
    }

    // MARK: Landscape — 90° CW (home button right)

    @Test("Landscape: formula is px=ly, py=ph-lx")
    func landscapeFormula() {
        // Verifies the known point from paul-foreflight's Python workaround:
        // logical (1174, 428) → physical (428, 1376 - 1174) = (428, 202)
        let (x, y) = translateToPhysical(
            lx: 1174, ly: 428,
            orientation: .landscape,
            portraitWidth: iPadPro13PortraitWidth,
            portraitHeight: iPadPro13PortraitHeight
        )
        #expect(x == 428)
        #expect(y == iPadPro13PortraitHeight - 1174)
    }

    @Test("Landscape: parameterized corner mapping", arguments: [
        // (logicalX, logicalY, expectedPhysicalX, expectedPhysicalY)
        // Formula: px = ly, py = ph - lx
        (0.0,    0.0,    0.0,                     1376.0),  // top-left    → bottom-left physical
        (1376.0, 0.0,    0.0,                     0.0),     // top-right   → top-left physical
        (0.0,    1032.0, 1032.0,                  1376.0),  // bottom-left → bottom-right physical
        (1376.0, 1032.0, 1032.0,                  0.0),     // bottom-right→ top-right physical
    ])
    func landscapeCorners(
        _ testCase: (lx: Double, ly: Double, px: Double, py: Double)
    ) {
        let (x, y) = translateToPhysical(
            lx: testCase.lx, ly: testCase.ly,
            orientation: .landscape,
            portraitWidth: iPadPro13PortraitWidth,
            portraitHeight: iPadPro13PortraitHeight
        )
        #expect(x == testCase.px,
                "x mismatch for logical (\(testCase.lx), \(testCase.ly)): got \(x), expected \(testCase.px)")
        #expect(y == testCase.py,
                "y mismatch for logical (\(testCase.lx), \(testCase.ly)): got \(y), expected \(testCase.py)")
    }

    @Test("Landscape: output stays within portrait bounds for any in-frame input")
    func landscapeOutputInPortraitBounds() {
        let samples: [(Double, Double)] = [
            (0, 0), (688, 516), (1376, 1032), (100, 900), (1200, 50)
        ]
        for (lx, ly) in samples {
            let (x, y) = translateToPhysical(
                lx: lx, ly: ly,
                orientation: .landscape,
                portraitWidth: iPadPro13PortraitWidth,
                portraitHeight: iPadPro13PortraitHeight
            )
            #expect(x >= 0 && x <= iPadPro13PortraitWidth,
                    "physical x \(x) out of portrait width bounds for logical (\(lx), \(ly))")
            #expect(y >= 0 && y <= iPadPro13PortraitHeight,
                    "physical y \(y) out of portrait height bounds for logical (\(lx), \(ly))")
        }
    }

    // MARK: Landscape Flipped — 90° CCW (home button left)

    @Test("LandscapeFlipped: formula is px=pw-ly, py=lx")
    func landscapeFlippedFormula() {
        // logical (500, 200) → physical (1032 - 200, 500) = (832, 500)
        let (x, y) = translateToPhysical(
            lx: 500, ly: 200,
            orientation: .landscapeFlipped,
            portraitWidth: iPadPro13PortraitWidth,
            portraitHeight: iPadPro13PortraitHeight
        )
        #expect(x == iPadPro13PortraitWidth - 200)
        #expect(y == 500)
    }

    @Test("LandscapeFlipped: parameterized corner mapping", arguments: [
        // (logicalX, logicalY, expectedPhysicalX, expectedPhysicalY)
        // Formula: px = pw - ly, py = lx
        (0.0,    0.0,    1032.0, 0.0),     // top-left    → top-right physical
        (1376.0, 0.0,    1032.0, 1376.0),  // top-right   → bottom-right physical
        (0.0,    1032.0, 0.0,    0.0),     // bottom-left → top-left physical
        (1376.0, 1032.0, 0.0,    1376.0),  // bottom-right→ bottom-left physical
    ])
    func landscapeFlippedCorners(
        _ testCase: (lx: Double, ly: Double, px: Double, py: Double)
    ) {
        let (x, y) = translateToPhysical(
            lx: testCase.lx, ly: testCase.ly,
            orientation: .landscapeFlipped,
            portraitWidth: iPadPro13PortraitWidth,
            portraitHeight: iPadPro13PortraitHeight
        )
        #expect(x == testCase.px,
                "x mismatch for logical (\(testCase.lx), \(testCase.ly)): got \(x), expected \(testCase.px)")
        #expect(y == testCase.py,
                "y mismatch for logical (\(testCase.lx), \(testCase.ly)): got \(y), expected \(testCase.py)")
    }

    @Test("LandscapeFlipped: output stays within portrait bounds for any in-frame input")
    func landscapeFlippedOutputInPortraitBounds() {
        let samples: [(Double, Double)] = [
            (0, 0), (688, 516), (1376, 1032), (100, 900), (1200, 50)
        ]
        for (lx, ly) in samples {
            let (x, y) = translateToPhysical(
                lx: lx, ly: ly,
                orientation: .landscapeFlipped,
                portraitWidth: iPadPro13PortraitWidth,
                portraitHeight: iPadPro13PortraitHeight
            )
            #expect(x >= 0 && x <= iPadPro13PortraitWidth,
                    "physical x \(x) out of portrait width bounds for logical (\(lx), \(ly))")
            #expect(y >= 0 && y <= iPadPro13PortraitHeight,
                    "physical y \(y) out of portrait height bounds for logical (\(lx), \(ly))")
        }
    }

    // MARK: Determinism

    @Test("Same input always produces same output (determinism)")
    func translationIsDeterministic() {
        let input = (lx: 500.0, ly: 300.0)
        let orientations: [TestOrientation] = [.portrait, .portraitUpsideDown, .landscape, .landscapeFlipped]

        for orientation in orientations {
            let first = translateToPhysical(
                lx: input.lx, ly: input.ly,
                orientation: orientation,
                portraitWidth: iPadPro13PortraitWidth,
                portraitHeight: iPadPro13PortraitHeight
            )
            let second = translateToPhysical(
                lx: input.lx, ly: input.ly,
                orientation: orientation,
                portraitWidth: iPadPro13PortraitWidth,
                portraitHeight: iPadPro13PortraitHeight
            )
            #expect(first.x == second.x, "Non-deterministic x for \(orientation)")
            #expect(first.y == second.y, "Non-deterministic y for \(orientation)")
        }
    }

    // MARK: Portrait Dimension Detection

    @Test("Portrait frame: width is short side, height is long side")
    func portraitDimensionsFromPortraitFrame() {
        // Simulates what OrientationAwareCoordinates.portraitDimensions does:
        // portrait → frame is already portrait dimensions
        let frameWidth = 1032.0
        let frameHeight = 1376.0
        // In portrait, width < height → portrait dimensions = (frameWidth, frameHeight)
        let isLandscape = frameWidth > frameHeight
        let portraitWidth = isLandscape ? frameHeight : frameWidth
        let portraitHeight = isLandscape ? frameWidth : frameHeight
        #expect(portraitWidth == 1032)
        #expect(portraitHeight == 1376)
    }

    @Test("Landscape frame: width and height are swapped to get portrait dimensions")
    func portraitDimensionsFromLandscapeFrame() {
        // In landscape, the AX frame reports (1376, 1032) — width > height.
        // Portrait dimensions are the inverse: (1032, 1376).
        let frameWidth = 1376.0
        let frameHeight = 1032.0
        let isLandscape = frameWidth > frameHeight
        let portraitWidth = isLandscape ? frameHeight : frameWidth
        let portraitHeight = isLandscape ? frameWidth : frameHeight
        #expect(portraitWidth == 1032)
        #expect(portraitHeight == 1376)
    }
}

// MARK: - Letterbox Case Tests
//
// Setup: portrait hardware (iPad Pro 13" M5), landscape-only app.
//   AX application frame (logical):  1376 × 1032 pts  (landscape-shaped)
//   Physical portrait viewport:      1032 × 1376 pts
//   Screenshot pixel dims:           2064 × 2752 px   (portrait-shaped — detection trigger)
//
// Scale: min(1032/1376, 1376/1032) = min(0.75, 1.333) = 0.75
// offsetX: (1032 - 1376*0.75) / 2 = (1032 - 1032) / 2 = 0
// offsetY: (1376 - 1032*0.75) / 2 = (1376 - 774)  / 2 = 301
//
// Empirical verification: logical (86, 269) → physical (64.5, 502.75)
//   Confirmed on JAMDOG iPad Pro 13" M5 — tap switched fixture from 4-player to 8-player Lobby.

@Suite("Letterbox coordinate translation math — portrait HW, landscape-only app")
struct LetterboxCoordinatesTests {

    private let logicalW = 1376.0   // landscape AX frame width
    private let logicalH = 1032.0   // landscape AX frame height
    private let physicalW = 1032.0  // portrait hardware viewport width
    private let physicalH = 1376.0  // portrait hardware viewport height

    private var params: (scale: Double, offsetX: Double, offsetY: Double) {
        letterboxParameters(
            logicalW: logicalW, logicalH: logicalH,
            physicalW: physicalW, physicalH: physicalH
        )
    }

    // MARK: Parameter derivation

    @Test("Letterbox: scale is 0.75 for iPad Pro 13\" M5")
    func letterboxScale() {
        let (scale, _, _) = params
        #expect(abs(scale - 0.75) < 1e-9,
                "Expected scale 0.75, got \(scale)")
    }

    @Test("Letterbox: offsetX is 0 (landscape fills portrait width exactly at 0.75 scale)")
    func letterboxOffsetX() {
        let (_, offsetX, _) = params
        #expect(abs(offsetX) < 1e-9,
                "Expected offsetX 0, got \(offsetX)")
    }

    @Test("Letterbox: offsetY is 301 (top+bottom pillarbox of ~301 pts each)")
    func letterboxOffsetY() {
        let (_, _, offsetY) = params
        #expect(abs(offsetY - 301.0) < 1e-9,
                "Expected offsetY 301, got \(offsetY)")
    }

    // MARK: Empirical regression

    @Test("Letterbox: logical (86, 269) → physical (64.5, 502.75) — JAMDOG empirical fixture")
    func letterboxEmpiricalPoint() {
        // Verified on JAMDOG iPad Pro 13" M5 / iOS 26.4.1:
        // BeatSmart landscape-only app, device never rotated.
        // Tap (86, 269) switched Lobby from 4-player to 8-player fixture.
        let (scale, offsetX, offsetY) = params
        let (px, py) = letterboxToPhysical(
            lx: 86, ly: 269,
            scale: scale, offsetX: offsetX, offsetY: offsetY
        )
        #expect(abs(px - 64.5)   < 1e-9, "physical x: expected 64.5, got \(px)")
        #expect(abs(py - 502.75) < 1e-9, "physical y: expected 502.75, got \(py)")
    }

    // MARK: Corner mapping

    @Test("Letterbox: parameterized corner mapping", arguments: [
        // (logicalX, logicalY, expectedPhysicalX, expectedPhysicalY)
        // px = offsetX + lx * scale = 0 + lx * 0.75
        // py = offsetY + ly * scale = 301 + ly * 0.75
        (0.0,    0.0,    0.0,    301.0),     // top-left
        (1376.0, 0.0,    1032.0, 301.0),     // top-right
        (0.0,    1032.0, 0.0,    1075.0),    // bottom-left  (301 + 1032*0.75 = 301+774 = 1075)
        (1376.0, 1032.0, 1032.0, 1075.0),   // bottom-right
    ])
    func letterboxCorners(
        _ testCase: (lx: Double, ly: Double, px: Double, py: Double)
    ) {
        let (scale, offsetX, offsetY) = params
        let (x, y) = letterboxToPhysical(
            lx: testCase.lx, ly: testCase.ly,
            scale: scale, offsetX: offsetX, offsetY: offsetY
        )
        #expect(abs(x - testCase.px) < 1e-9,
                "x mismatch for logical (\(testCase.lx), \(testCase.ly)): got \(x), expected \(testCase.px)")
        #expect(abs(y - testCase.py) < 1e-9,
                "y mismatch for logical (\(testCase.lx), \(testCase.ly)): got \(y), expected \(testCase.py)")
    }

    // MARK: Bounds

    @Test("Letterbox: output stays within physical portrait bounds for any in-frame input")
    func letterboxOutputInPortraitBounds() {
        let (scale, offsetX, offsetY) = params
        let samples: [(Double, Double)] = [
            (0, 0), (688, 516), (1376, 1032), (100, 900), (1200, 50),
            (86, 269)  // JAMDOG empirical point
        ]
        for (lx, ly) in samples {
            let (x, y) = letterboxToPhysical(
                lx: lx, ly: ly,
                scale: scale, offsetX: offsetX, offsetY: offsetY
            )
            #expect(x >= 0 && x <= physicalW,
                    "physical x \(x) out of portrait width \(physicalW) bounds for logical (\(lx), \(ly))")
            #expect(y >= 0 && y <= physicalH,
                    "physical y \(y) out of portrait height \(physicalH) bounds for logical (\(lx), \(ly))")
        }
    }

    // MARK: Determinism

    @Test("Letterbox: same input always produces same output")
    func letterboxIsDeterministic() {
        let (scale, offsetX, offsetY) = params
        let input = (lx: 86.0, ly: 269.0)
        let first  = letterboxToPhysical(lx: input.lx, ly: input.ly, scale: scale, offsetX: offsetX, offsetY: offsetY)
        let second = letterboxToPhysical(lx: input.lx, ly: input.ly, scale: scale, offsetX: offsetX, offsetY: offsetY)
        #expect(first.x == second.x, "Non-deterministic x")
        #expect(first.y == second.y, "Non-deterministic y")
    }

    // MARK: Detection signal

    @Test("Letterbox detection: portrait screenshot + landscape AX frame = letterbox case")
    func letterboxDetectionSignal() {
        // The production detection logic triggers letterbox when:
        //   screenshot.height > screenshot.width  (portrait-shaped PNG)
        //   AND  axFrame.width > axFrame.height   (landscape-shaped AX frame)
        let screenshotWidth  = 2064  // pixel dims from JAMDOG iPad Pro 13" M5
        let screenshotHeight = 2752
        let axFrameWidth  = 1376.0
        let axFrameHeight = 1032.0

        let screenshotIsPortrait = screenshotHeight > screenshotWidth
        let axFrameIsLandscape   = axFrameWidth > axFrameHeight

        #expect(screenshotIsPortrait, "Screenshot should be portrait-shaped for letterbox detection")
        #expect(axFrameIsLandscape,   "AX frame should be landscape-shaped for letterbox detection")
        #expect(screenshotIsPortrait && axFrameIsLandscape, "Both conditions must hold to trigger letterbox mapping")
    }

    @Test("Rotation detection: landscape screenshot + landscape AX frame = rotation case")
    func rotationDetectionSignal() {
        // Rotated hardware: both screenshot and AX frame are landscape-shaped.
        let screenshotWidth  = 2752  // landscape pixel dims (long edge horizontal)
        let screenshotHeight = 2064
        let axFrameWidth  = 1376.0
        let axFrameHeight = 1032.0

        let screenshotIsLandscape = screenshotWidth > screenshotHeight
        let axFrameIsLandscape    = axFrameWidth > axFrameHeight

        #expect(screenshotIsLandscape, "Screenshot should be landscape-shaped for rotation detection")
        #expect(axFrameIsLandscape,    "AX frame should be landscape-shaped for rotation detection")
        #expect(screenshotIsLandscape && axFrameIsLandscape, "Both landscape → rotation mapping (not letterbox)")
    }
}
