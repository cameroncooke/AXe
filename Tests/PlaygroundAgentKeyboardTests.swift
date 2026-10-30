import Foundation
import Testing

enum PlaygroundAgentKeyVariant: String, Sendable {
    case normal, stale, wrongPID, oldReferenceAfterFocusLoss, currentUnfocused, freshReference
    case duration, focusOverride, legacyBatch, selectedBatch, rawCompatibility, selectedCompatibility
    case lowercaseAfterModifier, duplicateModifiers, targetIsModifier, rawShift, rawLowercase
    case rawSequence, rawSingleKey
}

@Suite("Playground Agent Key E2E", .serialized, .enabled(if: isE2EEnabled))
struct PlaygroundAgentKeyTests {
    @Test("Backspace effects, current focus and refusal compatibility", arguments: [
        PlaygroundAgentKeyVariant.normal, .stale, .wrongPID, .oldReferenceAfterFocusLoss,
        .currentUnfocused, .freshReference, .duration, .focusOverride, .legacyBatch,
        .selectedBatch, .rawCompatibility, .selectedCompatibility,
    ])
    func key(_ variant: PlaygroundAgentKeyVariant) async throws { try await verifyAgentKeyboard(.key, variant: variant) }
}

@Suite("Playground Agent Shortcut E2E", .serialized, .enabled(if: isE2EEnabled))
struct PlaygroundAgentKeyComboTests {
    @Test("Shortcut effects, modifier release and guarded refusals", arguments: agentKeyboardVariants([
        PlaygroundAgentKeyVariant.normal, .stale, .lowercaseAfterModifier, .wrongPID,
        .oldReferenceAfterFocusLoss, .currentUnfocused, .freshReference, .duration,
        .focusOverride, .duplicateModifiers, .targetIsModifier, .legacyBatch,
        .selectedBatch, .rawShift, .rawLowercase, .selectedCompatibility,
    ], environmentKey: "AXE_E2E_AGENT_SHORTCUT_VARIANT"))
    func shortcut(_ variant: PlaygroundAgentKeyVariant) async throws { try await verifyAgentKeyboard(.combo, variant: variant) }
}

@Suite("Playground Agent Key Sequence E2E", .serialized, .enabled(if: isE2EEnabled))
struct PlaygroundAgentKeySequenceTests {
    @Test("Ordered key effects and current focused references", arguments: agentKeyboardVariants([
        PlaygroundAgentKeyVariant.normal, .stale, .wrongPID, .currentUnfocused,
        .rawSequence, .selectedCompatibility, .rawSingleKey,
    ], environmentKey: "AXE_E2E_AGENT_SEQUENCE_VARIANT"))
    func sequence(_ variant: PlaygroundAgentKeyVariant) async throws { try await verifyAgentKeyboard(.sequence, variant: variant) }
}

private enum PlaygroundAgentKeyboardAction: String {
    case key, combo, sequence
    var command: [String] {
        switch self {
        case .key: ["key", "42"]
        case .combo: ["key-combo", "--modifiers", "225", "--key", "4"]
        case .sequence: ["key-sequence", "--keycodes", "42,42"]
        }
    }
    var kind: String { self == .key ? "keyPress" : self == .combo ? "keyCombo" : "keySequence" }
    var events: Int { self == .key ? 2 : 4 }
}

private func verifyAgentKeyboard(_ action: PlaygroundAgentKeyboardAction,
                                 variant: PlaygroundAgentKeyVariant) async throws {
    let session = try await PlaygroundAgentFeatureSession.open(caseName: action.rawValue + "-" + variant.rawValue)
    try await session.focusField()
    let seed: String
    switch (action, variant) {
    case (.combo, .rawShift), (.combo, .rawLowercase): seed = "AbA"
    case (.combo, .freshReference): seed = "Ab"
    case (.combo, .selectedCompatibility): seed = "AbACd"
    case (.combo, _): seed = ""
    case (.sequence, .rawSequence), (.sequence, .rawSingleKey): seed = "A"
    case (.sequence, .selectedCompatibility): seed = "Abc"
    case (.sequence, _): seed = "ABC"
    case (.key, .selectedCompatibility): seed = "A"
    default: seed = "AB"
    }
    if !seed.isEmpty {
        _ = try await session.rawCommand(["type", seed])
        _ = try await session.document.waitFor("exact keyboard seed") { $0.text == seed }
    }
    var capture = try await session.capture()
    var arguments = action.command + (try session.contextArguments(capture, identifier: "feature.text"))
    var code: String?
    var message: String?
    var expected: String?
    var expectedCallbacks = action == .sequence ? 2 : 1
    var usesAgent = true
    switch variant {
    case .normal:
        expected = action == .key ? "A" : action == .combo ? "A" : "A"
    case .stale:
        _ = try await session.rawCommand(["key", "4"])
        _ = try await session.document.waitFor("real edit before stale-reference refusal") { $0.text == seed + "a" }
        _ = try await session.capture()
        code = "snapshotMissing"
    case .wrongPID:
        let index = try #require(arguments.firstIndex(of: "--expected-pid"))
        arguments[index + 1] = String(session.pid + 1)
        code = "contextChanged"
    case .oldReferenceAfterFocusLoss:
        try await session.dismissKeyboard()
        code = "snapshotMissing"
    case .currentUnfocused:
        try await session.dismissKeyboard()
        capture = try await session.capture()
        arguments = action.command + (try session.contextArguments(capture, identifier: "feature.text"))
        code = "unsupportedReference"
    case .freshReference:
        if action == .key {
            let first = try await session.command(arguments)
            try session.requireHIDSuccess(first, kind: action.kind, events: action.events)
            _ = try await session.document.waitFor("first agent Backspace") { $0.text == "A" }
            expected = ""
        } else {
            try await session.dismissKeyboard()
            try await session.focusField()
            expected = "AbA"
        }
        capture = try await session.capture()
        arguments = action.command + (try session.contextArguments(capture, identifier: "feature.text"))
    case .duration:
        arguments += ["--duration", "0.2"]
        message = action == .combo ? "Unknown option" : "Agent key requires --snapshot-id and --ref"
    case .focusOverride:
        arguments += ["--focus-id", "feature.text"]
        message = "requires --snapshot-id and --ref"
    case .legacyBatch, .selectedBatch:
        let step = arguments.joined(separator: " ")
        arguments = ["batch", "--step", step]
        if variant == .selectedBatch { arguments += session.selectedFlags }
        message = "Agent mode requires standalone commands"
    case .rawCompatibility:
        arguments = ["key", "42"]
        expected = "A"
        usesAgent = false
    case .selectedCompatibility:
        arguments = action.command + session.selectedFlags + ["--expected-pid", String(session.pid), "--focus-id", "feature.text"]
        if action == .combo {
            arguments = ["key-combo", "--modifiers", "225", "--key", "8"] + session.selectedFlags
                + ["--expected-pid", String(session.pid), "--focus-id", "feature.text"]
            expected = "AbACdE"
        } else { expected = action == .key ? "" : "A" }
        usesAgent = false
    case .duplicateModifiers, .targetIsModifier:
        arguments = ["key-combo", "--modifiers", variant == .duplicateModifiers ? "225,225" : "225",
            "--key", variant == .targetIsModifier ? "225" : "4"]
            + (try session.contextArguments(capture, identifier: "feature.text"))
        message = "1...8 unique modifiers"
    case .lowercaseAfterModifier:
        let first = try await session.command(arguments)
        try session.requireHIDSuccess(first, kind: action.kind, events: action.events)
        _ = try await session.document.waitFor("agent uppercase A") { $0.text == "A" }
        arguments = ["key", "5"]
        expected = "Ab"
        usesAgent = false
    case .rawShift:
        arguments = ["key-combo", "--modifiers", "225", "--key", "6"]
        expected = "AbAC"
        usesAgent = false
    case .rawLowercase:
        _ = try await session.rawCommand(["key-combo", "--modifiers", "225", "--key", "6"])
        _ = try await session.document.waitFor("raw uppercase C") { $0.text == "AbAC" }
        arguments = ["key", "7"]
        expected = "AbACd"
        usesAgent = false
    case .rawSequence:
        arguments = ["key-sequence", "--keycodes", "5,6"]
        expected = "Abc"
        usesAgent = false
    case .rawSingleKey:
        arguments = ["key", "7"]
        expected = "Ad"
        expectedCallbacks = 1
        usesAgent = false
    }
    let before = try session.document.read()
    let refused = code != nil || message != nil
    let result: CommandOutput
    if !usesAgent && variant != .selectedCompatibility { result = try await session.rawCommand(arguments) }
    else { result = try await session.command(arguments, allowFailure: refused) }
    if refused {
        try session.requireRefusal(result, before: before, code: code, message: message)
    } else {
        try #require(result.exitCode == 0)
        if usesAgent { try session.requireHIDSuccess(result, kind: action.kind, events: action.events) }
        else if variant == .selectedCompatibility {
            try session.requireSelectedSuccess(result, events: action.events, validatedKeys: action == .key ? 1 : 2)
        }
        let target = try #require(expected)
        let after = try await session.document.waitFor("exact public keyboard effect") { $0.text == target }
        try #require(after.count("textChanged") == before.count("textChanged") + expectedCallbacks)
        try #require(after.textFocused && after.activeWindowTouches == 0)
        try #require(after.inputState.windowTouchTrace == before.inputState.windowTouchTrace)
        try #require(after.slider == before.slider && after.switchOn == before.switchOn
            && after.count("tap") == before.count("tap"))
        if action == .sequence {
            if usesAgent {
                try session.requireReturnedValueIfPresent(result, identifier: "feature.text", expected: target, action: "typeText")
            }
            try await session.requireNativeFieldValue(target)
        }
    }
    try capture.requireUnexpired("after keyboard action/refusal")
}

/// Select an original parameterized case without changing its app setup or assertions.
private func agentKeyboardVariants(_ original: [PlaygroundAgentKeyVariant], environmentKey: String) -> [PlaygroundAgentKeyVariant] {
    guard let requested = ProcessInfo.processInfo.environment[environmentKey] else { return original }
    guard let variant = PlaygroundAgentKeyVariant(rawValue: requested), original.contains(variant) else {
        let allowed = original.map(\.rawValue).joined(separator: ", ")
        fatalError("Invalid \(environmentKey)=\(requested). Expected exactly one of: \(allowed).")
    }
    return [variant]
}
