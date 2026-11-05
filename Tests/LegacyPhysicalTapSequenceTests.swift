import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Legacy physical tap sequence")
@MainActor
struct LegacyPhysicalTapSequenceTests {
    private enum Failure: Error, Equatable { case original, cleanup }

    @Test func releasePrecedesTheSingleSubmissionDrain() async throws {
        var submissions = 0
        var phases: [String] = []
        var intendedHold = 0.0
        try await HIDInteractor.sendPhysicalTap(at: (12.5, 34.25)) { event in
            submissions += 1
            let parts: [FBSimulatorHIDEvent]
            if case let .composite(events) = event { parts = events } else { parts = [event] }
            for part in parts {
                switch part {
                case .touch(.down, let x, let y):
                    #expect(x == 12.5 && y == 34.25)
                    phases.append("down")
                case .delay(let duration):
                    intendedHold += duration
                    phases.append("hold")
                case .touch(.up, let x, let y):
                    #expect(x == 12.5 && y == 34.25)
                    phases.append("up")
                default: Issue.record("Unexpected physical-tap primitive")
                }
            }
            // Native send drains once after every submitted event/composite.
            phases.append("drain")
        }
        #expect(submissions == 1)
        #expect(phases == ["down", "hold", "up", "drain"])
        #expect(intendedHold == 0.25)
    }

    @Test func partialFailureSendsOnlyOneReleaseWithoutReplayingDown() async throws {
        var attempts: [FBSimulatorHIDEvent] = []
        do {
            try await HIDInteractor.sendPhysicalTap(at: (12.5, 34.25)) { event in
                attempts.append(event)
                if attempts.count == 1 { throw Failure.original }
            }
            Issue.record("The original send failure was lost")
        } catch let error as Failure { #expect(error == .original) }
        #expect(attempts.count == 2)
        #expect(attempts.last == .touch(direction: .up, x: 12.5, y: 34.25))
        #expect(attempts.first == .tapAt(x: 12.5, y: 34.25, duration: 0.25))
    }

    @Test func failedCleanupStillReturnsOriginalFailureWithoutAnotherAttempt() async throws {
        var attempts: [FBSimulatorHIDEvent] = []
        do {
            try await HIDInteractor.sendPhysicalTap(at: (7, 9)) { event in
                attempts.append(event)
                throw attempts.count == 1 ? Failure.original : Failure.cleanup
            }
            Issue.record("A failed tap unexpectedly returned success")
        } catch let error as Failure { #expect(error == .original) }
        #expect(attempts.count == 2)
        #expect(attempts.last == .touch(direction: .up, x: 7, y: 9))
    }
}
