import FBControlCore
import Foundation
import Testing
@testable import AXe

@Suite("Simulator coordinate mapping")
@MainActor
struct SimulatorCoordinateMappingTests {
    @Test("Apple TV preserves native points without a screenshot", arguments: [(1920, 1080), (3840, 2160)])
    func appleTVPassthrough(width: Int, height: Int) async throws {
        let roots = try JSONDecoder().decode([AccessibilityElement].self, from: Data("""
            [{"type":"Application","frame":{"x":0,"y":0,"width":\(width),"height":\(height)}}]
            """.utf8))
        let logger = AxeLogger()
        let mapping = try await OrientationAwareCoordinates.detectMapping(
            from: roots,
            screenState: SimulatorScreenState(productFamily: .familyAppleTV, orientation: nil),
            logger: logger,
            screenshotReader: { Issue.record("Apple TV must not probe a screenshot"); return nil }
        )
        guard case .passthrough = mapping else {
            Issue.record("Apple TV must use native coordinates")
            return
        }
        let points: [(x: Double, y: Double)] = [
            (0, 0), (Double(width), 0), (0, Double(height)), (Double(width), Double(height)),
            (Double(width) / 2, Double(height) / 2), (1500, 200),
            (1400, 200), (1300, 200), (1200, 200)
        ]
        for point in points {
            let physical = OrientationAwareCoordinates.applyMapping(mapping, to: point, logger: logger)
            #expect(physical.x == point.x)
            #expect(physical.y == point.y)
        }
    }

    @Test("A wide screenshot cannot identify Apple TV", arguments: [
        FBControlCoreProductFamily.familyiPhone, .familyiPad, .familyUnknown
    ])
    func unavailableOrientation(family: FBControlCoreProductFamily) async throws {
        let roots = try JSONDecoder().decode([AccessibilityElement].self, from: Data("""
            [{"type":"Application","frame":{"x":0,"y":0,"width":1920,"height":1080}}]
            """.utf8))
        var screenshotReads = 0
        do {
            _ = try await OrientationAwareCoordinates.detectMapping(
                from: roots,
                screenState: SimulatorScreenState(productFamily: family, orientation: nil),
                logger: AxeLogger(),
                screenshotReader: { screenshotReads += 1; return (1920, 1080) }
            )
            Issue.record("Unknown landscape orientation must fail closed")
        } catch {
            let error = try #require(error as? CLIError)
            #expect(error.code == .readFailed)
            #expect(error.errorDescription.contains("private orientation probe was unavailable"))
        }
        #expect(screenshotReads == 1)
    }

    @Test("Known orientations and explicit overrides avoid screenshots", arguments: SimulatorOrientation.allCases)
    func knownOrientation(orientation: SimulatorOrientation) async throws {
        let width = orientation.isLandscape ? 800 : 400
        let height = orientation.isLandscape ? 400 : 800
        let roots = try JSONDecoder().decode([AccessibilityElement].self, from: Data("""
            [{"type":"Application","frame":{"x":0,"y":0,"width":\(width),"height":\(height)}}]
            """.utf8))
        for override in [false, true] {
            let mapping = try await OrientationAwareCoordinates.detectMapping(
                from: roots,
                screenState: SimulatorScreenState(
                    productFamily: override ? .familyAppleTV : .familyiPhone,
                    orientation: override ? nil : orientation),
                orientationOverride: override ? orientation : nil,
                logger: AxeLogger(),
                screenshotReader: { Issue.record("Known orientation must not probe a screenshot"); return nil }
            )
            if !override, orientation == .portrait {
                guard case .passthrough = mapping else {
                    Issue.record("Portrait must pass through")
                    return
                }
            } else {
                guard case .rotation(let detected, let size) = mapping else {
                    Issue.record("Expected rotation mapping")
                    return
                }
                #expect(detected == orientation)
                #expect(size.width == 400)
                #expect(size.height == 800)
            }
        }
    }

    @Test("Portrait frames pass through without orientation or a screenshot")
    func portraitFallback() async throws {
        let roots = try JSONDecoder().decode([AccessibilityElement].self, from: Data("""
            [{"type":"Application","frame":{"x":0,"y":0,"width":400,"height":800}}]
            """.utf8))
        let mapping = try await OrientationAwareCoordinates.detectMapping(
            from: roots,
            screenState: SimulatorScreenState(productFamily: .familyUnknown, orientation: nil),
            logger: AxeLogger(),
            screenshotReader: { Issue.record("Portrait must not probe a screenshot"); return nil }
        )
        guard case .passthrough = mapping else {
            Issue.record("Portrait must pass through")
            return
        }
    }

    @Test("A portrait screenshot preserves letterboxing", arguments: [nil, SimulatorOrientation.portrait])
    func letterbox(orientation: SimulatorOrientation?) async throws {
        let roots = try JSONDecoder().decode([AccessibilityElement].self, from: Data("""
            [{"type":"Application","frame":{"x":0,"y":0,"width":800,"height":400}}]
            """.utf8))
        let mapping = try await OrientationAwareCoordinates.detectMapping(
            from: roots,
            screenState: SimulatorScreenState(productFamily: .familyiPad, orientation: orientation),
            logger: AxeLogger(), screenshotReader: { (800, 1600) }
        )
        guard case .letterbox(let scale, let offsetX, let offsetY) = mapping else {
            Issue.record("Expected letterbox mapping")
            return
        }
        #expect(scale == 0.5)
        #expect(offsetX == 0)
        #expect(offsetY == 300)
    }

    @Test("Missing frames and failed screenshots remain read errors", arguments: [false, true])
    func missingInput(missingFrame: Bool) async throws {
        let roots = try JSONDecoder().decode([AccessibilityElement].self, from: Data("""
            [{"type":"Application","frame":{"x":0,"y":0,"width":800,"height":400}}]
            """.utf8))
        var screenshotReads = 0
        do {
            _ = try await OrientationAwareCoordinates.detectMapping(
                from: missingFrame ? [] : roots,
                screenState: SimulatorScreenState(
                    productFamily: missingFrame ? .familyAppleTV : .familyUnknown, orientation: nil),
                logger: AxeLogger(),
                screenshotReader: { screenshotReads += 1; return nil }
            )
            Issue.record("Missing mapping input must fail")
        } catch {
            let error = try #require(error as? CLIError)
            #expect(error.code == .readFailed)
            #expect(error.errorDescription.contains(missingFrame ? "application frame is unavailable" : "screenshot probing failed"))
        }
        #expect(screenshotReads == (missingFrame ? 0 : 1))
    }
}
