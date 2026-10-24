import Darwin
import Foundation
import Testing

enum PlaygroundSelectedClientInput: String, CaseIterable, Sendable {
    case heldSpace, keySequence, heldTouch, movingPinch
    var keyboard: Bool { self == .heldSpace || self == .keySequence }
    var contactCount: Int { keyboard ? 0 : self == .heldTouch ? 1 : 2 }
}

enum PlaygroundSelectedClientSignal: String, CaseIterable, Sendable {
    case interrupt, terminate
    var number: Int32 { self == .interrupt ? SIGINT : SIGTERM }
}

@Suite("Playground Selected Client Exit E2E", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundSelectedClientExitTests {
    @Test("Held Space stops when its CLI receives SIGINT")
    func heldSpaceInterrupt() async throws {
        try await SelectedClientExitProof(input: .heldSpace, signal: .interrupt).run()
    }

    @Test("Held Space stops when its CLI receives SIGTERM")
    func heldSpaceTerminate() async throws {
        try await SelectedClientExitProof(input: .heldSpace, signal: .terminate).run()
    }

    @Test("The key sequence stops when its CLI receives SIGINT")
    func keySequenceInterrupt() async throws {
        try await SelectedClientExitProof(input: .keySequence, signal: .interrupt).run()
    }

    @Test("The key sequence stops when its CLI receives SIGTERM")
    func keySequenceTerminate() async throws {
        try await SelectedClientExitProof(input: .keySequence, signal: .terminate).run()
    }

    @Test("The held touch releases when its CLI receives SIGINT")
    func heldTouchInterrupt() async throws {
        try await SelectedClientExitProof(input: .heldTouch, signal: .interrupt).run()
    }

    @Test("The held touch releases when its CLI receives SIGTERM")
    func heldTouchTerminate() async throws {
        try await SelectedClientExitProof(input: .heldTouch, signal: .terminate).run()
    }

    @Test("Both moving pinch touches release when their CLI receives SIGINT")
    func movingPinchInterrupt() async throws {
        try await SelectedClientExitProof(input: .movingPinch, signal: .interrupt).run()
    }

    @Test("Both moving pinch touches release when their CLI receives SIGTERM")
    func movingPinchTerminate() async throws {
        try await SelectedClientExitProof(input: .movingPinch, signal: .terminate).run()
    }
}

private struct SelectedClientExitProof {
    let input: PlaygroundSelectedClientInput
    let signal: PlaygroundSelectedClientSignal

    func run() async throws {
        let session = try await PlaygroundAgentFeatureSession.open(caseName: "selected-client-" + input.rawValue + "-" + signal.rawValue)
        if input.keyboard { try await session.focusField() }
        else { try await session.show("feature.showPad") }
        let state = try await session.core.state()
        let frame = try session.core.frame(of: session.core.element(input.keyboard ? "feature.text" : "feature.pad", in: state))
        let before = try session.document.read()
        let arguments = inputArguments(session, frame: frame) + ["--udid", session.agent.udid]
        try JSONEncoder().encode(arguments).write(to: session.artifacts.appendingPathComponent("client-input-argv.json"))
        let process = try PlaygroundTestProcess(executable: TestHelpers.getAxePath(), arguments: arguments,
            directory: session.artifacts, name: "client-input")
        do {
            try process.start()
            let held = try await session.document.waitFor("real input before stopping its CLI", timeout: 12) { value in
                try #require(process.isRunning, "The input ended before its real app effect.")
                if input.keyboard { return value.text != before.text }
                let groups = newContacts(value, since: before)
                guard value.activeWindowTouches == input.contactCount && groups.count == input.contactCount else { return false }
                return input == .heldTouch || groups.allSatisfy { rows in rows.contains { $0.phase == "windowTouchMoved" } }
            }
            if input == .keySequence { try #require(held.text == before.text + "a") }
            try Data(contentsOf: session.document.url).write(to: session.artifacts.appendingPathComponent("before-client-signal.json"))
            let signalledAt = ProcessInfo.processInfo.systemUptime
            try process.signal(signal.number)
            try await process.wait(timeout: 3)
            try #require(process.exitCode != 0, "The signalled CLI did not exit as interrupted.")
            if input.contactCount > 0 {
                let releaseBudget = 3 - (ProcessInfo.processInfo.systemUptime - signalledAt)
                try #require(releaseBudget > 0)
                let released = try await session.document.waitFor("all original contacts released after client exit", timeout: releaseBudget) {
                    $0.activeWindowTouches == 0
                }
                try requireReleased(before: before, held: held, released: released)
                try Data(contentsOf: session.document.url).write(to: session.artifacts.appendingPathComponent("contacts-released.json"))
            }
            // The native cleanup budget is two seconds. Check readiness after that budget,
            // without sending another input command or retrying a failed read.
            let remaining = 3 - (ProcessInfo.processInfo.systemUptime - signalledAt)
            if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
            let ready = try await session.command(["describe-ui", "--expected-pid", String(session.pid)] + session.selectedFlags)
            let receipt = try session.rawReceipt(ready.output)
            try #require(ready.exitCode == 0 && receipt.outcome == "ready" && receipt.enqueuedEventCount == 0
                && receipt.cleanup == "notNeeded" && receipt.error == nil && receipt.quarantine == nil
                && receipt.context == session.initialContext)
            let settled = try session.document.read()
            try settled.requireClear()
            if input == .keySequence { try #require(settled.text == before.text + "a") }
            // Wait beyond the old five-second key gap and observe the app only. This would
            // catch a broker that returned ready but continued old input later.
            let stableUntil = max(signalledAt + 7, ProcessInfo.processInfo.systemUptime + 1)
            while ProcessInfo.processInfo.systemUptime < stableUntil {
                let current = try session.document.read()
                try #require(current.inputState == settled.inputState, "Old input continued after client cleanup.")
                try await Task.sleep(for: .milliseconds(50))
            }
            if !input.keyboard {
                try await session.show("feature.showText")
                let focused = try await session.command(["tap", "--id", "feature.text", "--element-type", "TextField",
                    "--expected-pid", String(session.pid)] + session.selectedFlags)
                try session.requireSelectedSuccess(focused, events: 2)
                _ = try await session.document.waitFor("fresh selected field focus") { $0.textFocused && $0.activeWindowTouches == 0 }
            }
            let beforeType = try session.document.read()
            // Stable text, a closed input owner and fresh typing bound key release here;
            // this is not an independent inventory of OS pressed keys.
            let typed = try await session.command(["type", "q7", "--expected-pid", String(session.pid),
                "--focus-id", "feature.text"] + session.selectedFlags)
            try session.requireSelectedSuccess(typed, events: 4, validatedKeys: 2)
            _ = try await session.document.waitFor("fresh exact typing after client exit") {
                $0.text == beforeType.text + "q7" && $0.activeWindowTouches == 0
            }
            try await session.requireNativeFieldValue(beforeType.text + "q7")
            try await freshSelectedTap(session)
            await process.finish()
        } catch { await process.finish(); throw error }
    }

    private func inputArguments(_ session: PlaygroundAgentFeatureSession, frame: UIElement.Frame) -> [String] {
        let cx = String(frame.x + frame.width / 2)
        let cy = String(frame.y + frame.height / 2)
        let keyboardFlags = ["--expected-pid", String(session.pid), "--focus-id", "feature.text"]
        switch input {
        case .heldSpace: return ["key", "44", "--duration", "8"] + session.selectedFlags + keyboardFlags
        case .keySequence: return ["key-sequence", "--keycodes", "4,5", "--delay", "5"] + session.selectedFlags + keyboardFlags
        case .heldTouch: return ["touch", "--down", "--up", "--delay", "8", "-x", cx, "-y", cy] + session.selectedFlags
        case .movingPinch:
            return ["gesture", "pinch", "-x", cx, "-y", cy, "--radius", "20", "--scale", "1.8",
                "--duration", "8", "--delta", "0.5"] + session.selectedFlags
        }
    }

    private func newContacts(_ value: PlaygroundControlsDocument,
                             since before: PlaygroundControlsDocument) -> [[PlaygroundControlsContact]] {
        let old = Set(before.windowTouchTrace.map(\.contactID))
        return Dictionary(grouping: value.windowTouchTrace.filter { !old.contains($0.contactID) }, by: \.contactID)
            .values.sorted { ($0.first?.contactID ?? 0) < ($1.first?.contactID ?? 0) }
    }

    private func requireReleased(before: PlaygroundControlsDocument, held: PlaygroundControlsDocument,
                                 released: PlaygroundControlsDocument) throws {
        try released.requireClear()
        let original = newContacts(held, since: before)
        let terminal = newContacts(released, since: before)
        try #require(original.count == input.contactCount && terminal.count == input.contactCount)
        for (saved, rows) in zip(original, terminal) {
            let first = try #require(rows.first)
            let last = try #require(rows.last)
            try #require(first.contactID == saved.first?.contactID && first.phase == "windowTouchBegan")
            try #require(["windowTouchEnded", "windowTouchCancelled"].contains(last.phase))
            try #require(rows.filter { $0.phase == "windowTouchBegan" }.count == 1)
            try #require(rows.filter { ["windowTouchEnded", "windowTouchCancelled"].contains($0.phase) }.count == 1)
            try #require(rows.dropFirst().dropLast().allSatisfy { $0.phase == "windowTouchMoved" })
            try #require(rows.count >= saved.count)
            let ordered = zip(rows, rows.dropFirst()).allSatisfy { $0.0.timestamp <= $0.1.timestamp }
            try #require(ordered)
            for (old, current) in zip(saved, rows) { try #require(PlaygroundComparableContact(old) == PlaygroundComparableContact(current)) }
        }
    }

    private func freshSelectedTap(_ session: PlaygroundAgentFeatureSession) async throws {
        try await session.show("feature.showPad")
        let state = try await session.core.state()
        let target = try session.core.element("feature.tap", in: state)
        try #require(target.type == "Button" && target.enabled == true)
        let before = try session.document.read()
        let result = try await session.command(["tap", "--id", "feature.tap", "--element-type", "Button",
            "--expected-pid", String(session.pid)] + session.selectedFlags)
        try session.requireSelectedSuccess(result, events: 2)
        try await session.requireButtonTap(after: before)
    }
}
