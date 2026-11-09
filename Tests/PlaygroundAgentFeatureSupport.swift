import Foundation
import Testing

extension PlaygroundControlsDocument {
    var inputState: PlaygroundControlsInputState {
        PlaygroundControlsInputState(counts: counts, slider: slider, switchOn: switchOn, text: text,
            textFocused: textFocused, listOffsetY: listOffsetY, pageOffsetY: pageOffsetY,
            canvasOffsetX: canvasOffsetX, canvasOffsetY: canvasOffsetY, pinchScale: pinchScale,
            rotationRadians: rotationRadians, panX: panX, panY: panY, advancedSliders: advancedSliders,
            waitTargetVisible: waitTargetVisible, waitDuplicateVisible: waitDuplicateVisible,
            activeWindowTouches: activeWindowTouches, windowTraceDropped: windowTraceDropped,
            recognizerTraceDropped: recognizerTraceDropped,
            windowTouchTrace: windowTouchTrace.map(PlaygroundComparableContact.init))
    }
}

struct PlaygroundControlsInputState: Equatable {
    let counts: [String: Int]
    let slider: Double
    let switchOn: Bool
    let text: String
    let textFocused: Bool
    let listOffsetY: Double
    let pageOffsetY: Double
    let canvasOffsetX: Double
    let canvasOffsetY: Double
    let pinchScale: Double
    let rotationRadians: Double
    let panX: Double
    let panY: Double
    let advancedSliders: [String: Double]
    let waitTargetVisible: Bool
    let waitDuplicateVisible: Bool
    let activeWindowTouches: Int
    let windowTraceDropped: Int
    let recognizerTraceDropped: Int
    let windowTouchTrace: [PlaygroundComparableContact]
}

struct PlaygroundComparableContact: Equatable {
    let contactID: Int
    let phase: String
    let x: Double
    let y: Double
    let timestamp: Double
    let activeTouches: Int
    let hitView: String

    init(_ value: PlaygroundControlsContact) {
        contactID = value.contactID
        phase = value.phase
        x = value.x
        y = value.y
        timestamp = value.timestamp
        activeTouches = value.activeTouches
        hitView = value.hitView
    }
}

private struct AgentFeatureContextEnvelope: Decodable {
    struct Capture: Decodable { let context: DuoContext? }
    struct Payload: Decodable { let context: DuoContext?; let capture: Capture? }
    let data: Payload
}

struct PlaygroundAgentFeatureSession {
    let core: CorePlaygroundSession
    let agent: AgentPlaygroundSession
    let pid: Int32
    let document: PlaygroundDocumentReader<PlaygroundControlsDocument>
    let selectedFlags: [String]
    let initialContext: DuoContext
    let artifacts: URL

    static func open(caseName: String = "agent-case", position: DuoControlsPosition = .outer0) async throws -> PlaygroundAgentFeatureSession {
        let root = try #require(ProcessInfo.processInfo.environment["AXE_E2E_ARTIFACT_DIR"],
            "Set AXE_E2E_ARTIFACT_DIR through the Playground matrix.")
        let artifacts = URL(fileURLWithPath: root).appendingPathComponent(caseName + "-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        print("Agent case artifacts: \(artifacts.path)")
        let core = try CorePlaygroundSession()
        let agent = try AgentPlaygroundSession()
        let pid = try await openAgentPlaygroundScreen(agent, screen: "duo-controls", readyID: "feature.tap", position: position)
        let document = try await PlaygroundDocumentReader<PlaygroundControlsDocument>(
            udid: agent.udid, pid: pid, fileName: "state.json")
        _ = try await document.waitFor("released normal controls") { $0.activeWindowTouches == 0 }
        let contextReply = try await core.command(canonicalAgentArguments(["describe-ui", "--agent", "--expected-pid", String(pid)]))
        let context = try Self.context(from: contextReply.output)
        let selectedFlags = ["--input-mode", "selected", "--screen-id", String(context.screenID),
            "--screen-uuid", context.screenUUID.uuidString]
        return PlaygroundAgentFeatureSession(core: core, agent: agent, pid: pid, document: document, selectedFlags: selectedFlags, initialContext: context, artifacts: artifacts)
    }

    func capture() async throws -> AgentPlaygroundTimedCapture {
        let started = ProcessInfo.processInfo.systemUptime
        let reply = try await command(["describe-ui", "--agent", "--expected-pid", String(pid)])
        let envelope = try decodeAgent(reply.output)
        try #require(!envelope.didError)
        let capture = try #require(envelope.data.capture)
        let timed = try AgentPlaygroundTimedCapture(capture: capture, requestStartedUptime: started)
        try timed.requireUnexpired("after recorded capture")
        return timed
    }

    func reference(_ identifier: String, in capture: AgentPlaygroundCapture) throws -> String {
        let rows = try (capture.targets + capture.scroll + capture.text).map(AgentPlaygroundRow.init)
        let refs = Set(rows.filter { $0.identifier == identifier }.map(\.ref))
        guard refs.count == 1, let ref = refs.first else {
            throw TestError.elementNotFound("Expected one current agent ref for \(identifier).")
        }
        return ref
    }

    func contextArguments(_ capture: AgentPlaygroundTimedCapture, identifier: String) throws -> [String] {
        try capture.requireUnexpired("before agent action")
        return ["--agent", "--expected-pid", String(pid), "--snapshot-id", capture.capture.snapshotID.uuidString,
                "--ref", try reference(identifier, in: capture.capture)]
    }

    func decodeAgent(_ output: String) throws -> AgentPlaygroundResult {
        for line in output.split(separator: "\n") where line.first == "{" {
            if let value = try? JSONDecoder().decode(AgentPlaygroundResult.self, from: Data(line.utf8)) { return value }
        }
        throw TestError.invalidJSON("No agent result envelope: \(output)")
    }

    func command(_ arguments: [String], allowFailure: Bool = false) async throws -> CommandOutput {
        let arguments = canonicalAgentArguments(arguments)
        let identifier = UUID().uuidString
        let start = ProcessInfo.processInfo.systemUptime
        let before = try Data(contentsOf: document.url)
        try before.write(to: artifacts.appendingPathComponent(identifier + "-before.json"), options: .withoutOverwriting)
        do {
            let result = try await core.command(arguments, allowFailure: allowFailure)
            let receipt = AgentFeatureCommandRecord(arguments: arguments, started: start,
                finished: ProcessInfo.processInfo.systemUptime, exitCode: result.exitCode, output: result.output, error: nil)
            try save(receipt, name: identifier + "-command")
            let after = try Data(contentsOf: document.url)
            try after.write(to: artifacts.appendingPathComponent(identifier + "-after.json"), options: .withoutOverwriting)
            return result
        } catch {
            let original = error
            let receipt = AgentFeatureCommandRecord(arguments: arguments, started: start,
                finished: ProcessInfo.processInfo.systemUptime, exitCode: nil, output: nil, error: String(describing: original))
            try? save(receipt, name: identifier + "-failure")
            throw original
        }
    }

    private func save<Value: Encodable>(_ value: Value, name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: artifacts.appendingPathComponent(name + ".json"), options: .withoutOverwriting)
    }

    func requireHIDSuccess(_ result: CommandOutput, kind: String, events: Int? = nil) throws {
        try #require(result.exitCode == 0)
        let value = try decodeAgent(result.output)
        try #require(!value.didError)
        let action = try #require(value.data.action)
        try #require(action.kind == kind && action.outcome == "enqueuedAndDrained")
        try #require(action.cleanup == "notNeeded" && !action.replayed)
        if let events { try #require(action.enqueuedEventCount == events) }
        else { try #require(action.enqueuedEventCount > 0) }
    }

    func requireRefusal(_ result: CommandOutput, before: PlaygroundControlsDocument,
                        code: String? = nil, message: String? = nil) throws {
        try #require(result.exitCode != 0, "Unexpected success: \(result.output)")
        if let code {
            let value = try decodeAgent(result.output)
            try #require(value.didError && value.error?.code == code)
            try #require(value.data.action == nil)
        }
        if let message { try #require(result.output.contains(message), "Wrong refusal reason: \(result.output)") }
        let after = try document.read()
        try #require(after.inputState == before.inputState, "A refused command changed real app input state.")
    }

    func requireButtonTap(after before: PlaygroundControlsDocument) async throws {
        let after = try await document.waitFor("one real Button callback and release") {
            $0.count("tap") == before.count("tap") + 1 && $0.activeWindowTouches == 0
        }
        try #require(after.traceScope == "duo-controls-page")
        try #require(after.windowTraceDropped == before.windowTraceDropped)
        _ = try contacts(after: before, in: after, count: 1)
        try #require(after.slider == before.slider && after.switchOn == before.switchOn
            && after.text == before.text && after.listOffsetY == before.listOffsetY)
    }

    private static func context(from output: String) throws -> DuoContext {
        for line in output.split(separator: "\n") where line.first == "{" {
            if let value = try? JSONDecoder().decode(AgentFeatureContextEnvelope.self, from: Data(line.utf8)),
               let context = value.data.context { return context }
        }
        throw TestError.invalidJSON("No measured context in agent capture: \(output)")
    }

    func focusField() async throws {
        try await show("feature.showText")
        let before = try document.read()
        let result = try await command(["tap", "--agent", "--expected-pid", String(pid),
            "--id", "feature.text", "--element-type", "TextField"])
        try requireHIDSuccess(result, kind: "tap", events: 2)
        _ = try await document.waitFor("real TextField focus") { $0.textFocused && $0.activeWindowTouches == 0 }
        // Once the keyboard has shown, UIKit scrolls the page to keep the field above it: on iPhone
        // the page moved 0 to 17 pt over ~0.3 s, starting within 80 ms of keyboardDidShow. A state
        // read during that scroll differs from a later one with no input sent.
        _ = try await document.waitFor("software keyboard shown") { $0.keyboardVisible }
        var settledOffset: Double?
        var equalReads = 0
        _ = try await document.waitFor("page settled above the keyboard") { value in
            if value.pageOffsetY == settledOffset { equalReads += 1 } else { settledOffset = value.pageOffsetY; equalReads = 0 }
            return equalReads >= 2
        }
        let focused = try document.read()
        try #require(focused.count("textFocused") == before.count("textFocused") + 1)
        _ = try contacts(after: before, in: focused, count: 1)
    }

    func dismissKeyboard() async throws {
        let before = try document.read()
        let result = try await command(["tap", "--agent", "--expected-pid", String(pid),
            "--id", "feature.dismissKeyboard", "--element-type", "Button"])
        try requireHIDSuccess(result, kind: "tap", events: 2)
        let after = try await document.waitFor("normal keyboard dismissal") { !$0.textFocused && $0.activeWindowTouches == 0 }
        _ = try contacts(after: before, in: after, count: 1)
    }
}

private struct AgentFeatureCommandRecord: Encodable {
    let arguments: [String]
    let started: Double
    let finished: Double
    let exitCode: Int32?
    let output: String?
    let error: String?
}

extension PlaygroundAgentFeatureSession {
    func contacts(after before: PlaygroundControlsDocument, in after: PlaygroundControlsDocument,
                  count: Int, minimumHold: Double = 0) throws -> [[PlaygroundControlsContact]] {
        try after.requireClear()
        let oldIDs = Set(before.windowTouchTrace.map(\.contactID))
        let added = after.windowTouchTrace.filter { !oldIDs.contains($0.contactID) }
        let groups = Dictionary(grouping: added, by: \.contactID).values.map { $0 }
        try #require(groups.count == count)
        for rows in groups {
            let first = try #require(rows.first)
            let last = try #require(rows.last)
            try #require(first.phase == "windowTouchBegan" && last.phase == "windowTouchEnded")
            try #require(rows.filter { $0.phase == "windowTouchBegan" }.count == 1)
            try #require(rows.filter { $0.phase == "windowTouchEnded" || $0.phase == "windowTouchCancelled" }.count == 1)
            try #require(last.timestamp - first.timestamp >= minimumHold)
            try #require(rows.dropFirst().dropLast().allSatisfy { $0.phase == "windowTouchMoved" })
            let ordered = zip(rows, rows.dropFirst()).allSatisfy { $0.0.timestamp <= $0.1.timestamp }
            try #require(ordered)
        }
        return groups
    }

    func rawReceipt(_ output: String) throws -> PlaygroundControlsReceipt {
        for line in output.split(separator: "\n") where line.first == "{" {
            if let result = try? JSONDecoder().decode(PlaygroundControlsReceipt.self, from: Data(line.utf8)) { return result }
        }
        throw TestError.invalidJSON("No selected input receipt: \(output)")
    }

    func show(_ identifier: String) async throws {
        let output = try await command(["tap", "--agent", "--expected-pid", String(pid), "--id", identifier,
            "--element-type", "Button"])
        try requireHIDSuccess(output, kind: "tap", events: 2)
        _ = try await document.waitFor("toolbar contact release") { $0.activeWindowTouches == 0 }
    }
}

func openAgentPlaygroundScreen(_ app: AgentPlaygroundSession, screen: String, readyID: String,
                               position: DuoControlsPosition = .outer0) async throws -> Int32 {
    guard isDuoPlaygroundE2EEnabled else { return try await app.open(screen, readyID: readyID) }
    let device = try DuoPlaygroundSession()
    let original = try await device.catalogue()
    let measured = try await device.position(position.pose, rotation: position.rotation, boot: original.bootIdentity)
    try #require(try measured.activePanel.rotationDegrees() == position.rotation)
    let target = DuoPlaygroundLaunchTarget(bootIdentity: measured.bootIdentity, panel: measured.activePanel)
    return try await DuoPlaygroundLaunchTarget.$current.withValue(target) {
        try await app.open(screen, readyID: readyID)
    }
}


extension PlaygroundAgentFeatureSession {
    /// Preserve the raw stdout contract while keeping stderr as separate evidence.
    func rawCommand(_ arguments: [String]) async throws -> CommandOutput {
        let name = "raw-" + UUID().uuidString
        let argv = arguments + ["--udid", agent.udid]
        try JSONEncoder().encode(argv).write(to: artifacts.appendingPathComponent(name + "-argv.json"))
        let before = try Data(contentsOf: document.url)
        try before.write(to: artifacts.appendingPathComponent(name + "-before.json"))
        let process = try PlaygroundTestProcess(executable: TestHelpers.getAxePath(), arguments: argv,
            directory: artifacts, name: name)
        do {
            try process.start()
            try await process.wait(timeout: 30)
            let stdout = try process.output()
            let diagnostics = try process.diagnostics()
            if process.exitCode != 0 {
                do {
                    let initial = try JSONDecoder().decode(PlaygroundControlsDocument.self, from: before)
                    let after = try Data(contentsOf: document.url)
                    let observed = try JSONDecoder().decode(PlaygroundControlsDocument.self, from: after)
                    guard initial.pid == pid, observed.pid == pid, observed.generation == initial.generation else {
                        throw TestError.unexpectedState("Raw failure document changed process or page generation.")
                    }
                    try after.write(to: artifacts.appendingPathComponent(name + "-after-failure.json"), options: .withoutOverwriting)
                } catch {
                    try? Data(String(describing: error).utf8).write(
                        to: artifacts.appendingPathComponent(name + "-after-failure-error.txt"), options: .withoutOverwriting)
                }
            }
            try #require(process.exitCode == 0, "Raw command failed: \(diagnostics)")
            try #require(stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "The raw command changed its empty stdout contract: \(stdout)")
            try Data(contentsOf: document.url).write(to: artifacts.appendingPathComponent(name + "-after.json"))
            let result = CommandOutput(output: diagnostics, exitCode: process.exitCode)
            await process.finish()
            return result
        } catch { await process.finish(); throw error }
    }

    /// A completed action can require a fresh read when its replacement capture is absent.
    func requireReturnedValueIfPresent(_ result: CommandOutput, identifier: String,
                                      expected: String, action: String) throws {
        let envelope = try decodeAgent(result.output)
        try #require(!envelope.didError)
        guard let capture = envelope.data.capture else {
            try #require(envelope.data.cache.requiresRefresh)
            return
        }
        try requireAgentCaptureValue(capture, identifier: identifier, expected: expected,
            action: action, pid: pid, udid: agent.udid)
        let line = try #require(result.output.split(separator: "\n").first { $0.first == "{" })
        let details = try JSONDecoder().decode(AgentFeatureContextEnvelope.self, from: Data(line.utf8))
        try #require(details.data.capture?.context == initialContext)
    }

    func requireNativeFieldValue(_ expected: String) async throws {
        let result = try await command(["describe-ui", "--expected-pid", String(pid)] + selectedFlags)
        let receipt = try rawReceipt(result.output)
        try #require(result.exitCode == 0 && receipt.outcome == "ready" && receipt.enqueuedEventCount == 0
            && receipt.cleanup == "notNeeded" && receipt.error == nil && receipt.quarantine == nil)
        try #require(receipt.context == initialContext)
        let line = try #require(result.output.split(separator: "\n").first { $0.first == "{" })
        let native = try JSONDecoder().decode(AgentFeatureNativeValueEnvelope.self, from: Data(line.utf8))
        try #require(native.ax.kind == "describe" && native.ax.expectedPID == pid)
        let fields = native.ax.roots.flatMap { $0.flattened }.filter { $0.identifier == "feature.text" }
        try #require(fields.count == 1)
        let field = try #require(fields.first)
        try #require(field.type == "TextField" && field.enabled == true && field.focused == true
            && field.hidden == false && field.pid == pid)
        try #require(Array((field.value ?? "").utf8) == Array(expected.utf8))
    }
}

func requireAgentCaptureValue(_ capture: AgentPlaygroundCapture, identifier: String,
                             expected: String, action: String, pid: Int32, udid: String) throws {
    try #require(capture.rs == "1" && capture.applicationPID == pid)
    try #require(UUID(uuidString: capture.udid) == UUID(uuidString: udid))
    let rows = Set(capture.targets + capture.scroll + capture.text).map {
        $0.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    }.filter { $0.count == 6 && $0[5] == identifier && $0[1] == action }
    try #require(rows.count == 1)
    let row = try #require(rows.first)
    try #require(Array(row[4].utf8) == Array(expected.utf8))
}

private struct AgentFeatureNativeValueEnvelope: Decodable {
    struct AX: Decodable { let kind: String; let expectedPID: Int32; let roots: [Node] }
    struct Node: Decodable {
        let type: String
        let pid: Int32?
        let enabled: Bool?
        let focused: Bool?
        let hidden: Bool?
        let identifier: String?
        let value: String?
        let children: [Node]
        var flattened: [Node] { [self] + children.flatMap { $0.flattened } }

        private enum CodingKeys: String, CodingKey {
            case type, pid, enabled, focused, hidden, children, AXUniqueId, AXIdentifier, AXValue
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            type = try values.decode(String.self, forKey: .type)
            pid = try values.decodeIfPresent(Int32.self, forKey: .pid)
            enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled)
            focused = try values.decodeIfPresent(Bool.self, forKey: .focused)
            hidden = try values.decodeIfPresent(Bool.self, forKey: .hidden)
            identifier = try values.decodeIfPresent(String.self, forKey: .AXUniqueId)
                ?? values.decodeIfPresent(String.self, forKey: .AXIdentifier)
            value = try? values.decode(String.self, forKey: .AXValue)
            children = try values.decodeIfPresent([Node].self, forKey: .children) ?? []
        }
    }
    let ax: AX
}

extension PlaygroundAgentFeatureSession {
    func requireSelectedSuccess(_ result: CommandOutput, events: Int, validatedKeys: Int? = nil) throws {
        try #require(result.exitCode == 0)
        let receipt = try rawReceipt(result.output)
        try #require(receipt.outcome == "enqueuedAndDrained" && receipt.enqueuedEventCount == events
            && receipt.cleanup == "notNeeded" && receipt.error == nil && receipt.quarantine == nil)
        try #require(receipt.context == initialContext)
        if let validatedKeys {
            let line = try #require(result.output.split(separator: "\n").first { $0.first == "{" })
            let envelope = try JSONDecoder().decode(AgentFeatureSelectedKeyboardEnvelope.self, from: Data(line.utf8))
            try #require(envelope.keyboard.expectedPID == pid && envelope.keyboard.focusID == "feature.text"
                && envelope.keyboard.validatedKeyDownCount == validatedKeys)
        }
    }
}

private struct AgentFeatureSelectedKeyboardEnvelope: Decodable {
    struct Keyboard: Decodable {
        let expectedPID: Int32
        let focusID: String
        let validatedKeyDownCount: Int
    }
    let keyboard: Keyboard
}
