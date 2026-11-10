import Testing
import Foundation
import FBSimulatorControl
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

    @Test("Composite drag plan holds, moves evenly and releases at the end")
    @MainActor
    func compositeDragPlanIncludesMovePoints() throws {
        let event = try HIDInteractor.makeCompositeDragEvent(from: (x: 100, y: 200), to: (x: 300, y: 600),
            duration: 0.4, steps: 4, initialHold: 0.05, finalHold: 0.05)
        let expected: [FBSimulatorHIDEvent] = [
            .touch(direction: .down, x: 100, y: 200), .delay(0.05),
            .delay(0.1), .touch(direction: .down, x: 150, y: 300),
            .delay(0.1), .touch(direction: .down, x: 200, y: 400),
            .delay(0.1), .touch(direction: .down, x: 250, y: 500),
            .delay(0.1), .touch(direction: .down, x: 300, y: 600),
            .delay(0.05), .touch(direction: .up, x: 300, y: 600),
        ]
        #expect(event.subEvents == expected)
    }
}
