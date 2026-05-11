import Testing
import Foundation
@testable import AXe

@Suite("Drag Command Surface Tests")
struct DragCommandSurfaceTests {
    @Test("Drag help includes coordinate and timing options")
    func dragHelpIncludesCoordinateAndTimingOptions() async throws {
        let result = try await TestHelpers.runAxeCommand("drag --help")

        #expect(result.output.contains("--start-x"))
        #expect(result.output.contains("--start-y"))
        #expect(result.output.contains("--end-x"))
        #expect(result.output.contains("--end-y"))
        #expect(result.output.contains("--duration"))
        #expect(result.output.contains("--steps"))
    }

    @Test("Invalid drag coordinates fail validation")
    func invalidDragCoordinatesFailValidation() async throws {
        let result = try await TestHelpers.runAxeCommandAllowFailure(
            "drag --start-x 100 --start-y 100 --end-x 100 --end-y 100 --udid invalid"
        )

        #expect(result.exitCode != 0)
        #expect(result.output.contains("Start and end points must be different."))
    }

    @Test("Too many drag steps fails validation")
    func tooManyDragStepsFailsValidation() async throws {
        let result = try await TestHelpers.runAxeCommandAllowFailure(
            "drag --start-x 100 --start-y 100 --end-x 100 --end-y 200 --steps 1001 --udid invalid"
        )

        #expect(result.exitCode != 0)
        #expect(result.output.contains("Steps must be between 1 and 1000."))
    }

    @Test("Composite drag plan includes move points between touch down and touch up")
    @MainActor
    func compositeDragPlanIncludesMovePoints() throws {
        let movePoints = try HIDInteractor.compositeDragMovePoints(
            from: (x: 100, y: 200),
            to: (x: 300, y: 600),
            steps: 4
        )

        #expect(movePoints.count == 4)
        #expect(movePoints.first?.x == 150)
        #expect(movePoints.first?.y == 300)
        #expect(movePoints.last?.x == 300)
        #expect(movePoints.last?.y == 600)
        #expect(movePoints.contains { point in
            point.x > 100 && point.x < 300 && point.y > 200 && point.y < 600
        })
    }
}

@Suite("Drag Command Tests", .serialized, .enabled(if: isE2EEnabled))
struct DragTests {
    @Test("Low-level drag records requested start and end points")
    func lowLevelDragRecordsRequestedStartAndEndPoints() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "touch-control")

        _ = try await TestHelpers.waitForLabel(containing: "Touch Control Playground", timeout: 3) {
            $0 == "Touch Control Playground"
        }

        let start = (x: 250, y: 450)
        let end = (x: 250, y: 650)

        try await TestHelpers.runAxeCommand(
            "drag --start-x \(start.x) --start-y \(start.y) --end-x \(end.x) --end-y \(end.y) --duration 0.4 --steps 40",
            simulatorUDID: defaultSimulatorUDID
        )

        try await waitForRecordedDrag(start: start, end: end, timeout: 3)
    }

    private func waitForRecordedDrag(
        start: (x: Int, y: Int),
        end: (x: Int, y: Int),
        timeout: TimeInterval
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var didSeeStart = false
        var didSeeEnd = false
        var lastTouchHistory: String?

        while Date() < deadline {
            let uiState = try await TestHelpers.getUIState()
            didSeeStart = hasTouchEvent(in: uiState, type: "down", near: start)
            didSeeEnd = hasTouchEvent(in: uiState, type: "up", near: end)
            lastTouchHistory = UIStateParser.findElement(in: uiState, withIdentifier: "touch-history")?.value

            if didSeeStart && didSeeEnd {
                return
            }

            try await Task.sleep(nanoseconds: 200_000_000)
        }

        throw TestError.unexpectedState(
            "Timed out waiting for drag start (\(start.x), \(start.y)) and end (\(end.x), \(end.y)). Saw start: \(didSeeStart), saw end: \(didSeeEnd), last touch history: \(lastTouchHistory ?? "none")"
        )
    }

    private func hasTouchEvent(in uiState: UIElement, type: String, near expected: (x: Int, y: Int)) -> Bool {
        UIStateParser.findElement(in: uiState) { element in
            guard let value = element.value,
                  value.hasPrefix("\(type):"),
                  let point = CoordinateParser.parseNamedCoordinates(from: value) else {
                return false
            }

            return abs(point.x - expected.x) <= 1 && abs(point.y - expected.y) <= 1
        } != nil
    }
}
