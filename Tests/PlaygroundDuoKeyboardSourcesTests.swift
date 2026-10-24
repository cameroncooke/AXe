import Foundation
import Testing

@Suite("Playground Duo Keyboard Sources E2E", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundDuoKeyboardSourcesTests {
    @Test("Literal, file and stdin input change the real field exactly",
          arguments: [DuoControlsPosition.outer0, .inner90], KeyboardSourceCase.all)
    func exactText(position: DuoControlsPosition, sourceCase: KeyboardSourceCase) async throws {
        let interface = sourceCase.interface
        let source = sourceCase.source
        try await withDuoPlaygroundScreen(pose: position.pose, rotation: position.rotation) {
            let check = try await KeyboardAcceptanceSession()
            try await check.focus()
            let text = "aQ7"
            let file = check.controls.artifacts.appendingPathComponent("exact-source.txt")
            try Data(text.utf8).write(to: file, options: .withoutOverwriting)
            let arguments: [String]
            switch source {
            case .literal: arguments = ["type", text]
            case .file: arguments = ["type", "--file", file.path]
            case .stdin: arguments = ["type", "--stdin"]
            }
            let response = try await check.send(arguments, interface: interface,
                standardInput: source == .stdin ? file : nil)
            let value = try await check.controls.documents.waitFor("three exact real text changes") {
                $0.text == text && $0.count("textChanged") == 3 && $0.activeWindowTouches == 0
            }
            try value.requireClear()
            if interface == .selected {
                let receipt = try #require(response)
                try #require(receipt.enqueuedEventCount == 8 && receipt.cleanup == "notNeeded")
                try #require(receipt.keyboard?.validatedKeyDownCount == 4)
            }
            try check.controls.preserveState("exact-" + interface.rawValue + "-" + source.rawValue)
            try await check.controls.freshTap()
        }
    }

    @Test("Selected Backspace, shortcut, sequence and Return have real effects",
          arguments: [DuoControlsPosition.outer0, .inner90])
    func selectedEdits(position: DuoControlsPosition) async throws {
        try await withDuoPlaygroundScreen(pose: position.pose, rotation: position.rotation) {
            let check = try await KeyboardAcceptanceSession()
            try await check.focus()
            _ = try await check.send(["type", "ab"], interface: .selected)
            try await check.requireText("ab", changes: 2)
            _ = try await check.send(["key", "42"], interface: .selected)
            try await check.requireText("a", changes: 3)
            _ = try await check.send(["key-combo", "--modifiers", "225", "--key", "4"], interface: .selected)
            try await check.requireText("aA", changes: 4)
            _ = try await check.send(["key-sequence", "--keycodes", "4,5", "--delay", "0.1"], interface: .selected)
            try await check.requireText("aAab", changes: 6)
            _ = try await check.send(["key-sequence", "--keycodes", "42,42", "--delay", "0.1"], interface: .selected)
            try await check.requireText("aA", changes: 8)
            let result = try #require(try await check.send(["key", "40"], interface: .selected))
            try #require(result.enqueuedEventCount == 2 && result.keyboard?.validatedKeyDownCount == 1)
            let ended = try await check.controls.documents.waitFor("Return ends real editing") {
                !$0.textFocused && $0.count("returnKey") == 1 && $0.text == "aA" && $0.activeWindowTouches == 0
            }
            try ended.requireClear()
            try #require(ended.count("textChanged") == 8)
            try check.controls.preserveState("selected-edits-complete")
            try await check.controls.freshTap()
        }
    }

    @Test("Focus loss stops remaining keys and unfocused input sends zero events",
          arguments: [DuoControlsPosition.outer0, .inner90])
    func selectedFocusLoss(position: DuoControlsPosition) async throws {
        try await withDuoPlaygroundScreen(pose: position.pose, rotation: position.rotation) {
            let check = try await KeyboardAcceptanceSession()
            try await check.focus()
            let stopped = try #require(try await check.send(
                ["key-sequence", "--keycodes", "40,4", "--delay", "0.3"], interface: .selected, allowFailure: true))
            try #require(stopped.outcome == "failedNoReplay" && stopped.enqueuedEventCount == 2)
            try #require(stopped.cleanup == "notNeeded" && stopped.quarantine == nil && stopped.error != nil)
            try #require(stopped.keyboard?.validatedKeyDownCount == 1)
            let blurred = try await check.controls.documents.waitFor("Return blurs before the second key") {
                !$0.textFocused && $0.count("returnKey") == 1 && $0.text.isEmpty && $0.count("textChanged") == 0
            }
            try blurred.requireClear()
            let refused = try #require(try await check.send(["key", "4"], interface: .selected, allowFailure: true))
            try #require(refused.outcome == "failedBeforeInput" && refused.enqueuedEventCount == 0)
            try #require(refused.cleanup == "notNeeded" && refused.quarantine == nil && refused.error != nil)
            try #require(refused.keyboard?.validatedKeyDownCount == 0)
            let after = try check.controls.documents.read()
            try #require(after.text.isEmpty && after.count("textChanged") == 0 && !after.textFocused)
            try after.requireClear()
            try check.controls.preserveState("focus-loss-no-later-effect")
            try await check.controls.freshTap()
            try await check.focus()
            _ = try await check.send(["type", "fresh"], interface: .raw)
            try await check.requireText("fresh", changes: 5)
        }
    }
}

@Suite("Playground Duo Selected Held Key E2E", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundDuoSelectedKeyInterruptionTests {
    @Test("Opening stops selected held Space and fresh real Button input works")
    func heldSpaceDuringOpening() async throws { try await heldSpace(mode: "fold", pose: .closed, rotation: 0, angle: 180) }

    @Test("Rotating stops selected held Space and fresh real Button input works")
    func heldSpaceDuringRotation() async throws { try await heldSpace(mode: "rotate", pose: .open, rotation: 90, angle: 0) }

    private func heldSpace(mode: String, pose: DuoPlaygroundPose, rotation: Int, angle: Int) async throws {
        try await preparePlaygroundChangingScreen(pose: pose, rotation: rotation) {
            let check = try await KeyboardAcceptanceSession()
            try await check.focus()
            let environment = ProcessInfo.processInfo.environment
            let script = try #require(environment["AXE_VERIFY_DUO_HELD_KEY_PATH"])
            let stateOperator = try #require(environment["AXE_DUO_STATE_CHANGE_PATH"])
            try #require(FileManager.default.isReadableFile(atPath: script))
            try #require(FileManager.default.isExecutableFile(atPath: stateOperator))
            let arguments = ["/usr/bin/python3", script, "--mode", mode, "--fold-angle", String(angle),
                "--cli", try TestHelpers.getAxePath(), "--device", check.controls.app.udid,
                "--pid", String(check.controls.pid), "--operator", stateOperator,
                "--out", check.controls.artifacts.appendingPathComponent("held-key-proof").path]
            try JSONEncoder().encode(arguments).write(to: check.controls.artifacts.appendingPathComponent("held-key-driver-argv.json"))
            let result = try await CommandRunner.run(arguments.map(KeyboardAcceptanceSession.quote).joined(separator: " "),
                allowFailure: true, timeout: 60)
            try Data(result.output.utf8).write(to: check.controls.artifacts.appendingPathComponent("held-key-driver-output.txt"))
            try #require(result.exitCode == 0, "Selected held Space proof failed: \(result.output)")
            let after = try check.controls.documents.read()
            try #require(after.count("tap") == 1 && !after.text.isEmpty)
            try after.requireClear()
            try check.controls.preserveState("selected-held-space-after-fresh-tap")
        }
    }
}

@Suite("Playground Duo Selected Batch Keyboard E2E", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundDuoSelectedBatchKeyboardTests {
    @Test("Selected batch reads each text source at its step and then taps a real Button",
          arguments: [DuoControlsPosition.outer0, .inner90], KeyboardTextSource.allCases)
    func sources(position: DuoControlsPosition, source: KeyboardTextSource) async throws {
        try await withDuoPlaygroundScreen(pose: position.pose, rotation: position.rotation) {
            let check = try await KeyboardAcceptanceSession()
            try await check.focus()
            let file = check.controls.artifacts.appendingPathComponent("batch-source.txt")
            try Data("aQ7".utf8).write(to: file, options: .withoutOverwriting)
            let input: String
            switch source {
            case .literal: input = "type 'aQ7'"
            case .file: input = "type --file " + playgroundShellQuote(file.path)
            case .stdin: input = "type --stdin"
            }
            let rows = try await check.sendBatch([input + check.keyboardStepOptions,
                "tap --id feature.tap --element-type Button --expected-pid " + String(check.controls.pid)],
                standardInput: source == .stdin ? file : nil)
            let statuses = rows.map(\.status)
            try #require(rows.count == 2 && statuses == ["completed", "completed"])
            let first = try #require(rows[0].response)
            try #require(first.enqueuedEventCount == 8 && first.keyboard?.validatedKeyDownCount == 4)
            let second = try #require(rows[1].response)
            try #require(second.enqueuedEventCount == 2 && second.cleanup == "notNeeded")
            let after = try await check.controls.documents.waitFor("exact batch text followed by one Button callback") {
                $0.text == "aQ7" && $0.count("textChanged") == 3 && $0.count("tap") == 1 && $0.activeWindowTouches == 0
            }
            try after.requireClear()
            try check.controls.preserveState("batch-text-source-complete")
        }
    }

    @Test("EOF rejects the second stdin step and omits later Button input",
          arguments: [DuoControlsPosition.outer0, .inner90])
    func stdinEOF(position: DuoControlsPosition) async throws {
        try await withDuoPlaygroundScreen(pose: position.pose, rotation: position.rotation) {
            let check = try await KeyboardAcceptanceSession()
            try await check.focus()
            let file = check.controls.artifacts.appendingPathComponent("one-stdin.txt")
            try Data("aQ7".utf8).write(to: file, options: .withoutOverwriting)
            let rows = try await check.sendBatch(["type --stdin" + check.keyboardStepOptions,
                "type --stdin" + check.keyboardStepOptions,
                "tap --id feature.tap --expected-pid " + String(check.controls.pid)], standardInput: file, allowFailure: true)
            try #require(rows.count == 2 && rows[0].status == "completed" && rows[1].status == "rejectedBeforeSend")
            try #require(rows[1].requestID == nil && rows[1].response == nil && rows[1].error != nil)
            try await check.requireText("aQ7", changes: 3)
            try #require(try check.controls.documents.read().count("tap") == 0)
            try check.controls.preserveState("batch-EOF-no-sentinel")
            try await check.controls.freshTap()
        }
    }

    @Test("A completed Return makes the later type step reject before input",
          arguments: [DuoControlsPosition.outer0, .inner90])
    func focusLoss(position: DuoControlsPosition) async throws {
        try await withDuoPlaygroundScreen(pose: position.pose, rotation: position.rotation) {
            let check = try await KeyboardAcceptanceSession()
            try await check.focus()
            let rows = try await check.sendBatch(["key 40" + check.keyboardStepOptions,
                "type 'a'" + check.keyboardStepOptions,
                "tap --id feature.tap --expected-pid " + String(check.controls.pid)], allowFailure: true)
            try #require(rows.count == 2 && rows[0].status == "completed" && rows[1].status == "failedResponse")
            let first = try #require(rows[0].response)
            try #require(first.enqueuedEventCount == 2 && first.cleanup == "notNeeded")
            let refused = try #require(rows[1].response)
            try #require(refused.outcome == "failedBeforeInput" && refused.enqueuedEventCount == 0)
            try #require(refused.cleanup == "notNeeded" && refused.quarantine == nil && refused.error != nil)
            let state = try await check.controls.documents.waitFor("batch focus loss with no later edits or tap") {
                !$0.textFocused && $0.text.isEmpty && $0.count("returnKey") == 1
                    && $0.count("textChanged") == 0 && $0.count("tap") == 0 && $0.activeWindowTouches == 0
            }
            try state.requireClear()
            try check.controls.preserveState("batch-focus-loss-no-sentinel")
            try await check.controls.freshTap()
        }
    }
}

enum KeyboardInterface: String, CaseIterable, Sendable { case raw, selected }
enum KeyboardTextSource: String, CaseIterable, Sendable { case literal, file, stdin }
struct KeyboardSourceCase: Sendable {
    let interface: KeyboardInterface
    let source: KeyboardTextSource
    static let all = KeyboardInterface.allCases.flatMap { interface in
        KeyboardTextSource.allCases.map { KeyboardSourceCase(interface: interface, source: $0) }
    }
}

private struct KeyboardAcceptanceSession {
    let controls: PlaygroundControlsSession
    init() async throws { controls = try await PlaygroundControlsSession() }

    func focus() async throws {
        try await controls.show("feature.showText")
        _ = try await controls.frame("feature.text")
        _ = try await controls.app.run(["tap", "--id", "feature.text", "--element-type", "TextField"])
        let focused = try await controls.documents.waitFor("real text field focus") { $0.textFocused && $0.activeWindowTouches == 0 }
        try focused.requireClear()
    }

    func requireText(_ text: String, changes: Int) async throws {
        let state = try await controls.documents.waitFor("exact text and editing callbacks") {
            $0.text == text && $0.count("textChanged") == changes && $0.activeWindowTouches == 0
        }
        try state.requireClear()
    }

    func send(_ command: [String], interface: KeyboardInterface, standardInput: URL? = nil,
              allowFailure: Bool = false) async throws -> KeyboardAcceptanceReceipt? {
        var arguments = command
        if interface == .selected {
            arguments += controls.selection() + ["--expected-pid", String(controls.pid), "--focus-id", "feature.text"]
        }
        let invocation = [try TestHelpers.getAxePath()] + arguments + ["--udid", controls.app.udid]
        let name = UUID().uuidString
        try JSONEncoder().encode(invocation).write(to: controls.artifacts.appendingPathComponent(name + "-argv.json"))
        var shell = invocation.map(Self.quote).joined(separator: " ")
        if let standardInput { shell += " < " + Self.quote(standardInput.path) }
        let output = try await CommandRunner.run(shell, allowFailure: true, timeout: 35)
        try Data(output.output.utf8).write(to: controls.artifacts.appendingPathComponent(name + "-output.txt"))
        try controls.preserveState(name + "-app-state")
        if !allowFailure { try #require(output.exitCode == 0, "Keyboard command failed: \(output.output)") }
        else { try #require(output.exitCode == 1, "Expected command refusal: \(output.output)") }
        guard interface == .selected else { return nil }
        let line = output.output.split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
        let receipt = try JSONDecoder().decode(KeyboardAcceptanceReceipt.self, from: Data(line.utf8))
        if !allowFailure {
            try #require(receipt.outcome == "enqueuedAndDrained" && receipt.error == nil && receipt.quarantine == nil)
            try #require(receipt.cleanup == "notNeeded")
            let context = try #require(receipt.context)
            try context.requireMatch(controls.catalogue)
        }
        let keyboard = try #require(receipt.keyboard)
        try #require(keyboard.expectedPID == controls.pid && keyboard.focusID == "feature.text")
        return receipt
    }

    var keyboardStepOptions: String { " --expected-pid " + String(controls.pid) + " --focus-id feature.text" }

    func sendBatch(_ steps: [String], standardInput: URL? = nil,
                   allowFailure: Bool = false) async throws -> [KeyboardBatchAcceptanceReceipt] {
        var arguments = [try TestHelpers.getAxePath(), "batch"] + controls.selection() + ["--udid", controls.app.udid]
        for step in steps { arguments += ["--step", step] }
        let name = UUID().uuidString
        try JSONEncoder().encode(arguments).write(to: controls.artifacts.appendingPathComponent(name + "-argv.json"))
        var shell = arguments.map(Self.quote).joined(separator: " ")
        if let standardInput { shell += " < " + Self.quote(standardInput.path) }
        let output = try await CommandRunner.run(shell, allowFailure: true, timeout: 40)
        try Data(output.output.utf8).write(to: controls.artifacts.appendingPathComponent(name + "-output.txt"))
        try #require(output.exitCode == (allowFailure ? 1 : 0), "Batch keyboard command failed: \(output.output)")
        let rows = try output.output.split(separator: "\n").filter { $0.first == "{" }.map {
            try JSONDecoder().decode(KeyboardBatchAcceptanceReceipt.self, from: Data($0.utf8))
        }
        try #require(!rows.isEmpty)
        for (offset, row) in rows.enumerated() {
            try #require(row.index == offset + 1 && row.totalSteps == steps.count)
            if row.status == "completed" {
                let receipt = try #require(row.response)
                try #require(row.requestID != nil && row.error == nil && receipt.outcome == "enqueuedAndDrained")
                try #require(receipt.error == nil && receipt.quarantine == nil && receipt.cleanup == "notNeeded")
                let context = try #require(receipt.context)
                try context.requireMatch(controls.catalogue)
            }
        }
        return rows
    }

    static func quote(_ argument: String) -> String { "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

private struct KeyboardAcceptanceReceipt: Decodable {
    let outcome: String
    let enqueuedEventCount: Int
    let cleanup: String
    let error: String?
    let context: DuoContext?
    let quarantine: DuoCLIResponse.Quarantine?
    let keyboard: Keyboard?
    struct Keyboard: Decodable {
        let expectedPID: Int32
        let focusID: String
        let validatedKeyDownCount: Int
    }
}

private struct KeyboardBatchAcceptanceReceipt: Decodable {
    let index: Int
    let totalSteps: Int
    let status: String
    let requestID: UUID?
    let response: KeyboardAcceptanceReceipt?
    let error: String?
}
