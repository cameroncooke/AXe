import Foundation
import Testing

@Suite("Playground Agent Transport E2E", .serialized, .enabled(if: isE2EEnabled))
struct PlaygroundAgentTransportTests {
    @Test("Selected typing, coordinate drag and a fresh Button tap share safe input ownership")
    func typingThenCoordinateDrag() async throws {
        let session = try await PlaygroundAgentExamplesSession.open()
        let initial = try session.document.read()
        try requireState(initial, initial: initial, text: "", changes: 0, taps: 0)
        try #require(!initial.focused && initial.windowTouchTrace.isEmpty)
        try await session.tap("agent-examples.text")
        let seed = try await session.capture()
        let seededResult = try await session.run(["type", "ABc"] + (try session.arguments(seed, id: "agent-examples.text")))
        let seededAction = try #require(try session.decode(seededResult.output).data.action)
        try #require(seededAction.kind == "typeText" && seededAction.outcome == "enqueuedAndDrained"
            && seededAction.enqueuedEventCount > 0 && seededAction.cleanup == "notNeeded" && !seededAction.replayed)
        let seeded = try await session.document.waitFor("exact seed and released contact") {
            $0.text == "ABc" && $0.textChanges == 3 && $0.activeWindowTouches == 0
        }
        try requireState(seeded, initial: initial, text: "ABc", changes: 3, taps: 0)
        try #require(seeded.focused)
        _ = try await session.capture()
        let raw = try await session.run(["describe-ui"])
        let rawStart = try #require(raw.output.firstIndex { $0 == "[" || $0 == "{" })
        let roots = try JSONDecoder().decode([TransportNode].self, from: Data(raw.output[rawStart...].utf8))
        let field = try control("agent-examples.text", roots: roots, pid: session.pid, type: "TextField")
        _ = try control("agent-examples.tap", roots: roots, pid: session.pid, type: "Button")
        let fieldFrame = try #require(field.frame)
        let contextResult = try await session.run(["describe-ui", "--agent", "--expected-pid", String(session.pid)])
        let context = try decode(TransportContext.self, contextResult.output).data.context
        let selection = ["--input-mode", "selected", "--screen-id", String(context.screenID),
            "--screen-uuid", context.screenUUID.uuidString]
        let before = try session.document.read()
        try #require(before == seeded)
        let fieldPoint = (fieldFrame.x + fieldFrame.width / 2, fieldFrame.y + fieldFrame.height / 2)
        _ = try await selected(session, ["tap", "-x", String(fieldPoint.0), "-y", String(fieldPoint.1),
            "--tap-style", "physical"], selection: selection, context: context, events: 2)
        let focused = try await session.document.waitFor("selected field tap and release") {
            $0.windowTouchTrace.count > before.windowTouchTrace.count && $0.activeWindowTouches == 0
        }
        try requireState(focused, initial: initial, text: "ABc", changes: 3, taps: 0)
        try #require(focused.focused)
        let fieldRows = try contacts(before: before, after: focused)
        try #require(fieldRows.allSatisfy { $0.hitView == "agent-examples.text" })
        let typedReply = try await selected(session, ["type", "d", "--expected-pid", String(session.pid),
            "--focus-id", "agent-examples.text"], selection: selection, context: context, events: 2)
        let typed = try await session.document.waitFor("selected typed text and release") {
            $0.text == "ABcd" && $0.textChanges == 4 && $0.activeWindowTouches == 0
        }
        try requireState(typed, initial: initial, text: "ABcd", changes: 4, taps: 0)
        try #require(typed.focused && typed.windowTouchTrace == focused.windowTouchTrace)
        let keyboard = try #require(typedReply.keyboard)
        let target = keyboard.lastValidatedTarget
        try #require(keyboard.expectedPID == session.pid && keyboard.focusID == "agent-examples.text"
            && keyboard.validatedKeyDownCount == 1 && target.pid == session.pid)
        try #require(target.identifier == "agent-examples.text" && target.type == "TextField"
            && target.enabled == true && target.focused == true && target.hidden == false)
        let frame = try #require(target.frame)
        try requireFrame(frame, context: context)
        try #require(frame == fieldFrame && frame.width > 16 && frame.height > 8)
        let center = (frame.x + frame.width / 2, frame.y + frame.height / 2)
        let halfSpan = min(24, frame.width / 4)
        let start = (center.0 - halfSpan, center.1)
        let end = (center.0 + halfSpan, center.1)
        try #require(start.0 > frame.x + 2 && end.0 < frame.x + frame.width - 2
            && center.1 > frame.y + 2 && center.1 < frame.y + frame.height - 2)
        // No accessibility read can change the transport boundary between type and drag.
        _ = try await selected(session, ["drag", "--start-x", String(start.0), "--start-y", String(start.1),
            "--end-x", String(end.0), "--end-y", String(end.1)], selection: selection, context: context)
        let dragged = try await session.document.waitFor("moved field contact and release") {
            $0.windowTouchTrace.count > typed.windowTouchTrace.count && $0.activeWindowTouches == 0
        }
        try requireState(dragged, initial: initial, text: "ABcd", changes: 4, taps: 0)
        try #require(dragged.focused)
        let moved = try contacts(before: typed, after: dragged)
        try #require(moved.contains { $0.phase == "windowTouchMoved" })
        let first = try #require(moved.first), last = try #require(moved.last)
        try #require(first.hitView == "agent-examples.text")
        try #require(hypot(first.x - start.0, first.y - start.1) <= 2
            && hypot(last.x - end.0, last.y - end.1) <= 2)
        try #require(moved.allSatisfy { $0.x >= start.0 - 2 && $0.x <= end.0 + 2 && abs($0.y - center.1) <= 2 })
        let discovered = try await session.run(["describe-ui", "--expected-pid", String(session.pid)] + selection)
        let fresh = try decode(TransportReply.self, discovered.output)
        try #require(fresh.outcome == "ready" && fresh.enqueuedEventCount == 0 && fresh.cleanup == "notNeeded"
            && fresh.error == nil && fresh.quarantine == nil && fresh.context == context)
        let ax = try #require(fresh.ax)
        try #require(ax.expectedPID == session.pid)
        let button = try control("agent-examples.tap", roots: ax.roots, pid: session.pid, type: "Button")
        try #require(button.hidden == false)
        let buttonFrame = try #require(button.frame)
        try requireFrame(buttonFrame, context: context)
        let buttonPoint = (buttonFrame.x + buttonFrame.width / 2, buttonFrame.y + buttonFrame.height / 2)
        let beforeButton = try session.document.read()
        try #require(beforeButton == dragged)
        _ = try await selected(session, ["tap", "-x", String(buttonPoint.0), "-y", String(buttonPoint.1),
            "--tap-style", "physical"], selection: selection, context: context, events: 2)
        let after = try await session.document.waitFor("one Button callback and release") {
            $0.taps == 1 && $0.activeWindowTouches == 0
        }
        try requireState(after, initial: initial, text: "ABcd", changes: 4, taps: 1)
        let buttonRows = try contacts(before: beforeButton, after: after)
        try #require(buttonRows.allSatisfy { $0.hitView == "agent-examples.tap"
            && hypot($0.x - buttonPoint.0, $0.y - buttonPoint.1) <= 2 })
        let oldIDs = Set(before.windowTouchTrace.map(\.contactID))
        try #require(Set(after.windowTouchTrace.filter { !oldIDs.contains($0.contactID) }.map(\.contactID)).count == 3)
    }

    private func selected(_ session: PlaygroundAgentExamplesSession, _ arguments: [String], selection: [String],
                          context: DuoContext, events: Int? = nil) async throws -> TransportReply {
        let result = try await session.run(arguments + selection)
        let reply = try decode(TransportReply.self, result.output)
        try #require(result.exitCode == 0 && reply.outcome == "enqueuedAndDrained" && reply.cleanup == "notNeeded"
            && reply.error == nil && reply.quarantine == nil && reply.context == context)
        if let events { try #require(reply.enqueuedEventCount == events) }
        else { try #require(reply.enqueuedEventCount > 0) }
        return reply
    }

    private func requireState(_ value: PlaygroundAgentExamplesDocument, initial: PlaygroundAgentExamplesDocument,
                              text: String, changes: Int, taps: Int) throws {
        try #require(value.pid == initial.pid && value.generation == initial.generation)
        try #require(value.text == text && value.textChanges == changes && value.taps == taps)
        try #require(value.activeWindowTouches == 0 && value.windowTraceDropped == 0)
        try #require(value.status == "a" && !value.longVisible && value.longLength == 0
            && value.outerOffset == 0 && value.listOffset == 0 && value.photosStatus == initial.photosStatus)
    }

    private func contacts(before: PlaygroundAgentExamplesDocument,
                          after: PlaygroundAgentExamplesDocument) throws -> [PlaygroundAgentExampleContact] {
        try #require(Array(after.windowTouchTrace.prefix(before.windowTouchTrace.count)) == before.windowTouchTrace)
        let rows = Array(after.windowTouchTrace.dropFirst(before.windowTouchTrace.count))
        let first = try #require(rows.first), last = try #require(rows.last)
        let oldIDs = Set(before.windowTouchTrace.map(\.contactID))
        try #require(Set(rows.map(\.contactID)).count == 1 && !oldIDs.contains(first.contactID))
        try #require(first.phase == "windowTouchBegan" && last.phase == "windowTouchEnded")
        try #require(rows.filter { $0.phase == "windowTouchBegan" }.count == 1
            && rows.filter { $0.phase == "windowTouchEnded" || $0.phase == "windowTouchCancelled" }.count == 1)
        try #require(rows.dropFirst().dropLast().allSatisfy { $0.phase == "windowTouchMoved" })
        try #require(rows.dropLast().allSatisfy { $0.activeTouches == 1 } && last.activeTouches == 0)
        try #require(rows.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.timestamp.isFinite })
        try #require(zip(rows, rows.dropFirst()).allSatisfy { $0.0.timestamp <= $0.1.timestamp })
        return rows
    }

    private func control(_ identifier: String, roots: [TransportNode], pid: Int32, type: String) throws -> TransportNode {
        let matches = roots.flatMap(\.flattened).filter { $0.identifier == identifier }
        try #require(matches.count == 1)
        let value = try #require(matches.first)
        try #require(value.pid == pid && value.type == type && value.enabled == true)
        return value
    }

    private func requireFrame(_ frame: PlaygroundControlsRect, context: DuoContext) throws {
        try #require([frame.x, frame.y, frame.width, frame.height].allSatisfy { $0.isFinite })
        try #require(frame.width > 0 && frame.height > 0 && frame.x >= 0 && frame.y >= 0
            && frame.x + frame.width <= context.logicalWidth && frame.y + frame.height <= context.logicalHeight)
    }

    private func decode<Value: Decodable>(_ type: Value.Type, _ output: String) throws -> Value {
        for line in output.split(separator: "\n") where line.first == "{" {
            if let value = try? JSONDecoder().decode(type, from: Data(line.utf8)) { return value }
        }
        throw TestError.invalidJSON("No selected transport result: \(output)")
    }
}

private struct TransportContext: Decodable {
    struct Payload: Decodable { let context: DuoContext }
    let data: Payload
}

private struct TransportReply: Decodable {
    struct Keyboard: Decodable {
        let expectedPID: Int32
        let focusID: String
        let validatedKeyDownCount: Int
        let lastValidatedTarget: TransportNode
    }
    struct AX: Decodable { let expectedPID: Int32; let roots: [TransportNode] }
    let outcome: String
    let enqueuedEventCount: Int
    let cleanup: String
    let error: String?
    let quarantine: DuoCLIResponse.Quarantine?
    let context: DuoContext
    let keyboard: Keyboard?
    let ax: AX?
}

private struct TransportNode: Decodable {
    let type: String
    let pid: Int32?
    let enabled: Bool?
    let focused: Bool?
    let hidden: Bool?
    let identifier: String?
    let frame: PlaygroundControlsRect?
    let children: [TransportNode]?
    var flattened: [TransportNode] { [self] + (children ?? []).flatMap(\.flattened) }
    private enum CodingKeys: String, CodingKey {
        case type, pid, enabled, focused, hidden, frame, children
        case identifier = "AXUniqueId"
    }
}
