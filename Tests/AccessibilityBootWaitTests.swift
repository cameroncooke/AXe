import FBSimulatorControl
import Foundation
import Testing
@testable import AXe

@Suite("Accessibility preparation waits for the displays")
@MainActor
struct AccessibilityBootWaitTests {
    private struct DisplaysNotReady: Error {}

    @Test("Preparation waits until the displays can be read")
    func waitsForDisplays() async throws {
        var reads = 0
        var waits: [Duration] = []
        try await AccessibilityFetcher.waitingForReadableDisplays(
            simulatorUDID: "FIXTURE", logger: AxeLogger(), wait: { waits.append($0) }
        ) {
            reads += 1
            if reads < 4 { throw DisplaysNotReady() }
        }
        #expect(reads == 4)
        #expect(waits == Array(repeating: .milliseconds(250), count: 3))
    }

    @Test("A settled simulator reads the displays once and never waits")
    func settledSimulator() async throws {
        var reads = 0
        try await AccessibilityFetcher.waitingForReadableDisplays(
            simulatorUDID: "FIXTURE", logger: AxeLogger(), wait: { _ in Issue.record("No wait when ready") }
        ) { reads += 1 }
        #expect(reads == 1)
    }

    @Test("Displays still unreadable at the deadline stop the read with the cause")
    func reportsStartingSimulator() async {
        var reads = 0
        do {
            try await AccessibilityFetcher.waitingForReadableDisplays(
                simulatorUDID: "FIXTURE", logger: AxeLogger(), maximumWait: .zero,
                wait: { _ in Issue.record("No wait after the deadline") }
            ) {
                reads += 1
                throw DisplaysNotReady()
            }
            Issue.record("Expected the starting-simulator error")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("is still starting"))
            #expect(message.contains("axe list-simulators --displays --udid FIXTURE"))
            #expect(!message.contains("translation object"))
        }
        #expect(reads == 1)
    }

    @Test("A whole-tree read retries a missing translation until the tree arrives")
    func retriesMissingTranslation() async throws {
        var reads = 0
        let data = try await AccessibilityFetcher.retryingMissingTranslation(logger: AxeLogger(), wait: { _ in }) {
            reads += 1
            if reads < 3 { throw FBAccessibilityError.noTranslationObject }
            return Data("tree".utf8)
        }
        #expect(String(decoding: data, as: UTF8.self) == "tree")
        #expect(reads == 3)
    }

    @Test("A missing translation at the deadline and other errors are reported without another read")
    func missingTranslationBounds() async {
        for (error, maximumWait) in [(FBAccessibilityError.noTranslationObject, Duration.zero),
                                     (.dispatcherUnavailable, .seconds(10))] {
            var reads = 0
            do {
                _ = try await AccessibilityFetcher.retryingMissingTranslation(
                    logger: AxeLogger(), maximumWait: maximumWait,
                    wait: { _ in Issue.record("No wait expected") }
                ) {
                    reads += 1
                    throw error
                }
                Issue.record("Expected \(error)")
            } catch {}
            #expect(reads == 1)
        }
    }

    @Test("Only a boot whose displays all report an unknown backlight waits", arguments: [
        (["unknown"], false), (["unknown", "unknown"], false),
        (["activeOn"], true), (["activeDimmed"], true), (["inactiveOn"], true), (["off"], true),
        (["unknown", "activeOn"], true), ([nil], true), ([], true)] as [([String?], Bool)])
    func startedDisplay(states: [String?], started: Bool) {
        #expect(((try? AccessibilityFetcher.requireStartedDisplay(backlightStates: states)) != nil) == started)
    }

    @Test("Cancellation is not retried")
    func cancellation() async {
        var reads = 0
        do {
            try await AccessibilityFetcher.waitingForReadableDisplays(
                simulatorUDID: "FIXTURE", logger: AxeLogger(), wait: { _ in Issue.record("No wait on cancellation") }
            ) {
                reads += 1
                throw CancellationError()
            }
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(reads == 1)
    }
}
