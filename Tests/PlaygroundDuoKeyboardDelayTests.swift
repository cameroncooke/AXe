import Foundation
import Testing

@Suite("Playground Duo Keyboard Delay", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundDuoKeyboardDelayTests {
    @Test("A valid ten-second sequence checks focus for all keys and releases before fresh input")
    func explicitDelayDoesNotConsumeInputAllowance() async throws {
        let controls = try await prepareDuoControls(.inner90)
        try await controls.show("feature.showText")
        _ = try await controls.app.run(["tap", "--id", "feature.text", "--element-type", "TextField"])
        let before = try await controls.documents.waitFor("real focused field before delayed input") {
            $0.textFocused && $0.text.isEmpty && $0.activeWindowTouches == 0
        }
        try before.requireClear()
        let options = controls.selection() + ["--expected-pid", String(controls.pid), "--focus-id", "feature.text"]
        let arguments = ["key-sequence", "--keycodes", "4,5,6", "--delay", "5"] + options
        try JSONEncoder().encode([try TestHelpers.getAxePath()] + arguments + ["--udid", controls.app.udid])
            .write(to: controls.artifacts.appendingPathComponent("delayed-sequence-argv.json"))
        let start = ProcessInfo.processInfo.systemUptime
        let output = try await controls.app.run(arguments, allowFailure: true)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        try Data(output.output.utf8).write(to: controls.artifacts.appendingPathComponent("delayed-sequence-output.txt"))
        try #require(output.exitCode == 0, "Valid delayed keyboard input failed: \(output.output)")
        try #require(elapsed >= 10, "Both requested five-second waits must occur.")
        let line = output.output.split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
        let receipt = try JSONDecoder().decode(DelayedKeyboardReceipt.self, from: Data(line.utf8))
        try receipt.requireCompleted(controls: controls, keys: 3, events: 6)
        let after = try await controls.documents.waitFor("exact abc from the delayed sequence") {
            $0.text == "abc" && $0.textFocused && $0.count("textChanged") == before.count("textChanged") + 3
                && $0.activeWindowTouches == 0
        }
        try after.requireClear()
        try #require(after.count("tap") == before.count("tap") && after.count("returnKey") == before.count("returnKey"))
        try controls.preserveState("delayed-sequence-complete")

        // This is a new explicit action. It proves that later input works without replay.
        let next = try await controls.app.run(["key", "4"] + options)
        try Data(next.output.utf8).write(to: controls.artifacts.appendingPathComponent("following-key-output.txt"))
        let nextLine = next.output.split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
        let nextReceipt = try JSONDecoder().decode(DelayedKeyboardReceipt.self, from: Data(nextLine.utf8))
        try nextReceipt.requireCompleted(controls: controls, keys: 1, events: 2)
        let final = try await controls.documents.waitFor("one following lowercase key") {
            $0.text == "abca" && $0.count("textChanged") == before.count("textChanged") + 4 && $0.activeWindowTouches == 0
        }
        try final.requireClear()
        try controls.preserveState("delayed-sequence-and-following-key")
        try await controls.freshTap()
    }
}

private struct DelayedKeyboardReceipt: Decodable {
    let outcome: String
    let enqueuedEventCount: Int
    let cleanup: String
    let quarantine: DuoCLIResponse.Quarantine?
    let error: String?
    let context: DuoContext?
    let keyboard: Keyboard?

    struct Keyboard: Decodable {
        let expectedPID: Int32
        let focusID: String
        let validatedKeyDownCount: Int
        let initialTarget: Field?
        let lastValidatedTarget: Field?
    }
    struct Field: Decodable {
        let type: String?
        let pid: Int32?
        let AXUniqueId: String?
        let focused: Bool?
        let enabled: Bool?
        let hidden: Bool?
        let frame: Frame?
    }
    struct Frame: Decodable, Equatable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    func requireCompleted(controls: PlaygroundControlsSession, keys: Int, events: Int) throws {
        try #require(outcome == "enqueuedAndDrained" && enqueuedEventCount == events && cleanup == "notNeeded")
        try #require(quarantine == nil && error == nil)
        let context = try #require(context)
        try context.requireMatch(controls.catalogue)
        let keyboard = try #require(keyboard)
        try #require(keyboard.expectedPID == controls.pid && keyboard.focusID == "feature.text")
        try #require(keyboard.validatedKeyDownCount == keys)
        let initial = try #require(keyboard.initialTarget)
        let last = try #require(keyboard.lastValidatedTarget)
        for field in [initial, last] {
            try #require(field.type == "TextField" && field.pid == controls.pid && field.AXUniqueId == "feature.text")
            try #require(field.focused == true && field.enabled == true && field.hidden == false)
            let frame = try #require(field.frame)
            let finite = [frame.x, frame.y, frame.width, frame.height].allSatisfy(\.isFinite)
            try #require(finite && frame.width > 0 && frame.height > 0)
        }
        try #require(initial.frame == last.frame)
    }
}
