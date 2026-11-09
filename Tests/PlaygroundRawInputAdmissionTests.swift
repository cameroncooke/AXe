import Foundation
import Testing
@testable import AXe

@Suite("Ordinary raw input refuses concurrent commands", .serialized,
       .enabled(if: isE2EEnabled && !isDuoPlaygroundE2EEnabled))
struct PlaygroundRawInputAdmissionTests {
    enum HeldOwner: String, CaseIterable { case key, touch }
    enum CompetingAction: String, CaseIterable { case tap, touch, key }

    @Test("A held input refuses another action without a late replay",
          arguments: HeldOwner.allCases, CompetingAction.allCases)
    func concurrentInput(owner: HeldOwner, action: CompetingAction) async throws {
        let session = try await PlaygroundAgentFeatureSession.open(
            caseName: "raw-admission-" + owner.rawValue + "-" + action.rawValue)
        try await session.focusField()
        let seed = owner == .key ? String(repeating: "A", count: 256) : "AAAAAA"
        _ = try await session.rawCommand(["type", seed])
        let initial = try await session.document.waitFor("exact focused input seed") {
            $0.text == seed && $0.textFocused && $0.activeWindowTouches == 0
        }
        // Read the real control position before the held command. No AX reads run during input.
        let state = try await session.core.state()
        let frame = try session.core.frame(of: session.core.element("feature.tap", in: state))
        try #require(frame.width > 0 && frame.height > 0)
        let coordinates = ["-x", String(frame.x + frame.width / 2),
            "-y", String(frame.y + frame.height / 2)]
        let heldArguments: [String]
        switch owner {
        case .key: heldArguments = ["key", "42", "--duration", "4"]
        case .touch: heldArguments = ["touch", "--down", "--up", "--delay", "4"] + coordinates
        }
        let argv = heldArguments + ["--udid", session.agent.udid]
        try JSONEncoder().encode(argv).write(to: session.artifacts.appendingPathComponent("held-argv.json"))
        let held = try PlaygroundTestProcess(executable: TestHelpers.getAxePath(), arguments: argv,
            directory: session.artifacts, name: "held")
        do {
            try held.start()
            _ = try await session.document.waitFor("real held input began") { observed in
                switch owner {
                case .key:
                    return observed.text != seed && observed.textFocused
                        && observed.activeWindowTouches == 0
                case .touch:
                    return observed.activeWindowTouches == 1
                        && observed.windowTouchTrace.count > initial.windowTouchTrace.count
                }
            }
            try #require(held.isRunning, "The owner finished before the concurrent command.")
            let rejected = try await session.command(arguments(action, coordinates: coordinates), allowFailure: true)
            let knownBusy = "Error: Another AXe command is using the simulator. Try again when it finishes."
            let legacyBusy = "Error: " + HIDBroker.inputDeliveryFailureDescription
            let refusal = rejected.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let expectedRefusal: Bool
            if action == .key {
                expectedRefusal = refusal == knownBusy
            } else {
                expectedRefusal = refusal == knownBusy || refusal == legacyBusy
            }
            try #require(rejected.exitCode == 1 && expectedRefusal,
                "Expected a known refusal before input, got: \(rejected.output)")
            try #require(held.isRunning, "Refusal arrived after the owner finished; admission was not proved.")
            try await held.wait(timeout: 15)
            let diagnostics = try held.diagnostics()
            let stdout = try held.output()
            try #require(held.exitCode == 0, "The original held input failed: \(diagnostics)")
            try #require(stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            let released = try await session.document.waitFor("original held input released") {
                $0.activeWindowTouches == 0 && (owner == .key || $0.count("tap") == initial.count("tap") + 1)
            }
            switch owner {
            case .key:
                try #require(!released.text.isEmpty && released.text.count < seed.count
                    && released.text.allSatisfy { $0 == "A" })
                // Each ordinary one-character Backspace has one editingChanged callback.
                // An inserted character, even if later erased, adds two extra callbacks.
                try #require(released.count("textChanged") - initial.count("textChanged")
                    == seed.count - released.text.count,
                    "Text callbacks include input other than the original Backspace deletions.")
                try #require(released.count("tap") == initial.count("tap")
                    && released.inputState.windowTouchTrace == initial.inputState.windowTouchTrace)
            case .touch:
                try await session.requireButtonTap(after: initial)
                _ = try session.contacts(after: initial, in: released, count: 1, minimumHold: 3.5)
                try #require(released.text == seed)
            }
            try #require(released.textFocused && released.activeWindowTouches == 0)
            try #require(released.slider == initial.slider && released.switchOn == initial.switchOn)

            // Observe the end of the old command before sending any new input.
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let quiet = try session.document.read()
            try #require(quiet.inputState == released.inputState,
                "A refused command ran after the held input ended, or held input was not released.")
            switch action {
            case .tap:
                _ = try await session.command(arguments(action, coordinates: coordinates))
                try await session.requireButtonTap(after: quiet)
            case .touch:
                _ = try await session.rawCommand(arguments(action, coordinates: coordinates))
                try await session.requireButtonTap(after: quiet)
            case .key:
                _ = try await session.rawCommand(["key", "5"])
                let edited = try await session.document.waitFor("one fresh lowercase key after refusal") {
                    $0.text == quiet.text + "b" && $0.count("textChanged") == quiet.count("textChanged") + 1
                }
                try #require(edited.textFocused && edited.activeWindowTouches == 0)
                try #require(edited.count("tap") == quiet.count("tap")
                    && edited.inputState.windowTouchTrace == quiet.inputState.windowTouchTrace)
            }
            await held.finish()
        } catch {
            // Wait for this original complete command. Never repeat its DOWN, key or UP.
            await held.finish()
            throw error
        }
    }

    private func arguments(_ action: CompetingAction, coordinates: [String]) -> [String] {
        switch action {
        case .tap: return ["tap", "--tap-style", "physical"] + coordinates
        case .touch: return ["touch", "--down", "--up"] + coordinates
        case .key: return ["key", "5"]
        }
    }
}
