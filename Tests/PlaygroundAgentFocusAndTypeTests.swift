import Foundation
import Testing

enum PlaygroundFocusField: String, CaseIterable, Sendable {
    case uiKit, swiftUI

    var screen: String { self == .uiKit ? "agent-examples" : "text-input" }
    var identifier: String { self == .uiKit ? "agent-examples.text" : "text-input-field" }
    var emptyValues: [String?] { self == .uiKit ? [nil, "", "Input"] : [nil, "", "empty", "Type here..."] }
}

@Suite("Playground Agent Focus And Type E2E", .serialized,
       .enabled(if: isE2EEnabled && !isDuoPlaygroundE2EEnabled))
struct PlaygroundAgentFocusAndTypeTests {
    @Test("Find, focus and type in each ordinary iPhone field", arguments: PlaygroundFocusField.allCases)
    private func focusAndType(_ field: PlaygroundFocusField) async throws {
        try await PlaygroundFocusTypeCheck.run(field: field)
    }
}

struct PlaygroundFocusTypeCheck {
    let app: AgentPlaygroundSession
    let pid: Int32
    let field: PlaygroundFocusField
    let artifacts: URL
    let document: PlaygroundDocumentReader<PlaygroundAgentExamplesDocument>?
    private let text = "AXe ref 123"

    static func run(field: PlaygroundFocusField, position: DuoControlsPosition = .outer0) async throws {
        let app = try AgentPlaygroundSession()
        let pid = try await openAgentPlaygroundScreen(app, screen: field.screen,
            readyID: field.identifier, position: position)
        let directory = try #require(ProcessInfo.processInfo.environment["AXE_E2E_ARTIFACT_DIR"])
        let artifacts = URL(fileURLWithPath: directory)
            .appendingPathComponent("focus-type-" + field.rawValue + "-" + position.rawValue + "-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let document: PlaygroundDocumentReader<PlaygroundAgentExamplesDocument>?
        if field == .uiKit {
            document = try await PlaygroundDocumentReader(udid: app.udid, pid: pid, fileName: "agent-examples.json")
        } else {
            document = nil
            // The normal SwiftUI page focuses on entry. Empty-field Return dismisses it.
            let returned = try await app.run(["key", "40"], allowFailure: true)
            try Data(returned.output.utf8).write(to: artifacts.appendingPathComponent("normal-return-setup.txt"))
            try #require(returned.exitCode == 0)
        }
        let check = Self(app: app, pid: pid, field: field, artifacts: artifacts, document: document)
        try await check.verify(position: position)
    }

    private func command(_ name: String, _ arguments: [String], allowFailure: Bool = false) async throws -> CommandOutput {
        let canonical = canonicalAgentArguments(arguments)
        try JSONEncoder().encode(canonical + ["--udid", app.udid])
            .write(to: artifacts.appendingPathComponent(name + "-argv.json"))
        let result = try await app.run(canonical, allowFailure: true)
        try Data(result.output.utf8).write(to: artifacts.appendingPathComponent(name + "-output.txt"))
        try JSONEncoder().encode(result.exitCode).write(to: artifacts.appendingPathComponent(name + "-exit.json"))
        if !allowFailure { try #require(result.exitCode == 0, "Command failed; output and exit code were saved before refusal.") }
        return result
    }

    private func capture(_ name: String) async throws -> PlaygroundFocusEnvelope.Capture {
        let output = try await command(name, ["describe-ui", "--agent", "--view", "full"])
        let result = try PlaygroundFocusEnvelope.decode(output.output)
        try #require(!result.didError && result.schema == "axe.output.agent-result" && result.schemaVersion == "1")
        try #require(result.data.cache?.requiresRefresh == false)
        let capture = try #require(result.data.capture)
        try #require(capture.body.applicationPID == pid && capture.body.rs == "1")
        try #require(UUID(uuidString: capture.body.udid) == UUID(uuidString: app.udid))
        return capture
    }

    private func reference(_ capture: PlaygroundFocusEnvelope.Capture) throws -> String {
        let rows = try (capture.body.targets + capture.body.scroll + capture.body.text).map(AgentPlaygroundRow.init)
        let refs = Set(rows.filter { $0.identifier == field.identifier && $0.action == "tap" }.map(\.ref))
        try #require(refs.count == 1, "One current tap reference is required for this field.")
        return try #require(refs.first)
    }

    private func native(_ name: String, context: DuoContext) async throws -> PlaygroundFocusNativeRead {
        let output = try await command(name, ["describe-ui", "--input-mode", "selected",
            "--screen-id", String(context.screenID), "--screen-uuid", context.screenUUID.uuidString,
            "--expected-pid", String(pid), "--verbose"])
        let read = try JSONDecoder().decode(PlaygroundFocusNativeRead.self, from: Data(output.output.utf8))
        try #require(read.outcome == "ready" && read.enqueuedEventCount == 0 && read.cleanup == "notNeeded")
        try #require(read.error == nil && read.quarantine == nil && read.context == context
            && read.ax.expectedPID == pid && read.ax.kind == "describe")
        return read
    }

    private func selectedField(_ read: PlaygroundFocusNativeRead, context: DuoContext) throws -> PlaygroundFocusNativeRead.Node {
        let fields = read.nodes.filter { $0.type == "TextField" && $0.identifier == field.identifier }
        try #require(fields.count == 1)
        let selected = try #require(fields.first)
        try #require(selected.pid == pid && selected.enabled == true && selected.hidden == false && selected.focused != nil)
        let frame = try #require(selected.frame)
        let finiteFrame = [frame.x, frame.y, frame.width, frame.height].allSatisfy(\.isFinite)
        try #require(finiteFrame)
        try #require(frame.x >= 0 && frame.y >= 0 && frame.width > 0 && frame.height > 0
            && frame.x + frame.width <= context.logicalWidth && frame.y + frame.height <= context.logicalHeight)
        return selected
    }

    private func verify(position: DuoControlsPosition) async throws {
        let first = try await capture("initial-capture")
        let context = first.context
        let expectedScreen: UInt32 = isDuoPlaygroundE2EEnabled && position == .inner90 ? 3 : 1
        try #require(context.screenID == expectedScreen && context.rotationDegrees == position.rotation)
        let beforeRead = try await native("before-invalid-text", context: context)
        let before = try selectedField(beforeRead, context: context)
        try #require(before.focused == false && field.emptyValues.contains(before.value))
        let beforeDocument = try document?.read()
        if let beforeDocument {
            try #require(beforeDocument.text.isEmpty && !beforeDocument.focused
                && beforeDocument.activeWindowTouches == 0 && beforeDocument.windowTraceDropped == 0)
        }
        let rejected = try await command("invalid-text", ["type", "£", "--agent", "--focus",
            "--snapshot-id", first.body.snapshotID.uuidString, "--ref", try reference(first)], allowFailure: true)
        let refusal = try PlaygroundFocusEnvelope.decode(rejected.output)
        try #require(rejected.exitCode != 0 && refusal.didError && refusal.error?.code == "commandFailed")
        try #require(refusal.error?.message.contains("No keycode found for character: '£'") == true)
        try #require(refusal.data.action == nil && refusal.data.batch == nil)
        let unchanged = try await native("after-invalid-text", context: context)
        try #require(unchanged.fieldStates == beforeRead.fieldStates, "Invalid text changed actual fields before dispatch.")
        if let beforeDocument { try #require(try document?.read() == beforeDocument) }

        let fresh = try await capture("fresh-reference")
        try #require(fresh.context == context)
        let output = try await command("focus-and-type", ["type", text, "--agent", "--focus",
            "--snapshot-id", fresh.body.snapshotID.uuidString, "--ref", try reference(fresh)])
        let accepted = try PlaygroundFocusEnvelope.decode(output.output)
        try #require(output.exitCode == 0 && !accepted.didError && accepted.error == nil)
        let batch = try #require(accepted.data.batch)
        try #require(batch.totalSteps == 2 && batch.completedSteps == 2 && batch.steps.count == 2
            && batch.stoppedAt == nil && !batch.replayed && !batch.rolledBack)
        for (index, step) in batch.steps.enumerated() {
            try #require(step.index == index + 1 && step.status == "completed" && step.error == nil)
            try #require(step.action == (index == 0 ? "tap" : "type"))
            let receipt = try #require(step.receipt)
            try #require(receipt.kind == (index == 0 ? "tap" : "typeText")
                && receipt.outcome == "enqueuedAndDrained" && receipt.cleanup != "uncertain" && !receipt.replayed)
            try #require(index == 0 ? receipt.enqueuedEventCount == 2 : receipt.enqueuedEventCount > 0)
        }
        try #require(accepted.data.cache?.requiresRefresh == false)
        let finalCapture = try #require(accepted.data.capture)
        try #require(finalCapture.context == context && finalCapture.body.applicationPID == pid)
        let afterRead = try await native("actual-final-field", context: context)
        let after = try selectedField(afterRead, context: context)
        try #require(after.focused == true && after.value == text)
        try #require(afterRead.otherValues(excluding: field.identifier) == beforeRead.otherValues(excluding: field.identifier))
        if let beforeDocument, let document {
            let actual = try await document.waitFor("exact current text and editing callbacks") {
                $0.text == text && $0.textChanges == beforeDocument.textChanges + text.count && $0.focused
            }
            try #require(actual.taps == beforeDocument.taps && actual.activeWindowTouches == 0
                && actual.windowTraceDropped == 0)
        } else {
            let counts = afterRead.nodes.filter { $0.identifier == "character-count" }
            try #require(counts.count == 1 && counts.first?.value == String(text.count))
        }
        // Public AX output omits opaque identity. This does not claim exact native UID continuity.
    }
}

private struct PlaygroundFocusEnvelope: Decodable {
    struct Failure: Decodable { let code: String; let message: String }
    struct Payload: Decodable {
        let capture: Capture?
        let action: AgentPlaygroundResult.Action?
        let cache: AgentPlaygroundResult.Cache?
        let batch: Batch?
    }
    struct Capture: Decodable {
        let body: AgentPlaygroundCapture
        let context: DuoContext
        private enum CodingKeys: CodingKey { case context }
        init(from decoder: Decoder) throws {
            body = try AgentPlaygroundCapture(from: decoder)
            context = try decoder.container(keyedBy: CodingKeys.self).decode(DuoContext.self, forKey: .context)
        }
    }
    struct Batch: Decodable {
        struct Step: Decodable {
            let index: Int
            let action: String
            let status: String
            let receipt: AgentPlaygroundResult.Action?
            let error: Failure?
        }
        let totalSteps: Int
        let completedSteps: Int
        let steps: [Step]
        let stoppedAt: Int?
        let replayed: Bool
        let rolledBack: Bool
    }
    let schema: String
    let schemaVersion: String
    let didError: Bool
    let error: Failure?
    let data: Payload
    static func decode(_ text: String) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(text.utf8))
    }
}

private struct PlaygroundFocusNativeRead: Decodable {
    struct Frame: Decodable, Equatable { let x: Double; let y: Double; let width: Double; let height: Double }
    struct FieldState: Equatable {
        let identifier: String?
        let label: String?
        let value: String?
        let pid: Int32?
        let enabled: Bool?
        let hidden: Bool?
        let focused: Bool?
        let frame: Frame?
    }
    struct FieldValue: Hashable { let identifier: String?; let label: String?; let value: String? }
    struct Node: Decodable {
        let type: String
        let pid: Int32?
        let enabled: Bool?
        let hidden: Bool?
        let focused: Bool?
        let frame: Frame?
        let identifier: String?
        let label: String?
        let value: String?
        let children: [Node]
        var flattened: [Node] { [self] + children.flatMap(\.flattened) }
        private enum CodingKeys: String, CodingKey {
            case type, pid, enabled, hidden, focused, frame, children
            case identifier = "AXUniqueId", label = "AXLabel", value = "AXValue"
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            type = try values.decode(String.self, forKey: .type)
            pid = try values.decodeIfPresent(Int32.self, forKey: .pid)
            enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled)
            hidden = try values.decodeIfPresent(Bool.self, forKey: .hidden)
            focused = try values.decodeIfPresent(Bool.self, forKey: .focused)
            frame = try values.decodeIfPresent(Frame.self, forKey: .frame)
            identifier = try values.decodeIfPresent(String.self, forKey: .identifier)
            label = try values.decodeIfPresent(String.self, forKey: .label)
            value = try? values.decode(String.self, forKey: .value)
            children = try values.decodeIfPresent([Node].self, forKey: .children) ?? []
        }
    }
    struct AX: Decodable { let kind: String; let expectedPID: Int32; let roots: [Node] }
    let outcome: String
    let enqueuedEventCount: Int
    let cleanup: String
    let error: String?
    let quarantine: DuoCLIResponse.Quarantine?
    let context: DuoContext
    let ax: AX
    var nodes: [Node] { ax.roots.flatMap(\.flattened) }
    var fieldStates: [FieldState] {
        nodes.filter { $0.type == "TextField" }.map {
            FieldState(identifier: $0.identifier, label: $0.label, value: $0.value, pid: $0.pid,
                enabled: $0.enabled, hidden: $0.hidden, focused: $0.focused, frame: $0.frame)
        }
    }
    func otherValues(excluding identifier: String) -> [FieldValue: Int] {
        var values: [FieldValue: Int] = [:]
        for node in nodes where node.type == "TextField" && node.identifier != identifier {
            values[FieldValue(identifier: node.identifier, label: node.label, value: node.value), default: 0] += 1
        }
        return values
    }
}
