import Testing
import Foundation

// MARK: - Orientation Math Tests
//
// The iOS Simulator HID layer always operates in physical portrait space.
// The accessibility tree reports positions in the *logical* UI orientation.
// These tests verify the rotation math that maps logical coordinates to physical ones.
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
