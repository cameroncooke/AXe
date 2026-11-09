import Foundation
import Testing

@Suite("Playground Agent Native State E2E", .serialized, .enabled(if: isE2EEnabled))
struct PlaygroundAgentNativeStateTests {
    @Test("Anonymous controls have tap references; discovery leaves state unchanged and hides hidden text")
    func unavailableRows() async throws {
        let session = try await PlaygroundAgentExamplesSession.open()
        let before = try session.document.read()
        let capture = try await anonymousCapture(session)
        let targets = capture.rows
        let duplicate = targets.filter { $0.label == "Same" && $0.identifier.isEmpty
            && capture.buttonRefs.contains($0.ref) }
        try #require(duplicate.count == 2 && Set(duplicate.map(\.ref)).count == 2
            && duplicate.allSatisfy { $0.action == "tap" })
        let unnamed = targets.filter { $0.label.isEmpty && $0.identifier.isEmpty && $0.action == "tap"
            && capture.buttonRefs.contains($0.ref) }
        try #require(unnamed.count == 1)
        // Anonymous tap is granted only when the native snapshot has complete, unique object metadata.
        // Public ID reads remain empty; private object keys must not become IDs.
        for row in duplicate + unnamed {
            let detail = try await anonymousDetail(session, capture: capture, row: row, field: "id")
            try #require(detail.text.isEmpty && detail.totalLength == 0)
        }
        let field = try #require(targets.first { $0.identifier == "agent-examples.text" })
        try #require(field.action == "tap")
        try #require(!capture.rows.contains { $0.label.contains("Hidden note") })
        let after = try session.document.read()
        try #require(after == before)
    }

    @Test("Fresh references tap both anonymous Same buttons and the unnamed button")
    func anonymousPhysicalReferences() async throws {
        let session = try await PlaygroundAgentExamplesSession.open(
            position: isDuoPlaygroundE2EEnabled ? .inner90 : .outer0)
        let before = try session.document.read()
        let initial = try await anonymousCapture(session)
        let firstPair = try await anonymousButtons(session, in: initial, label: "Same", count: 2)
        try #require(firstPair[0].frame != firstPair[1].frame)
        // Both callbacks update one shared counter. This checks control identity, not different business actions.
        let firstFrame = firstPair[0].frame
        let secondFrame = firstPair[1].frame
        var previous = try await tapAnonymous(session, button: firstPair[0], capture: initial, before: before, excluding: [secondFrame])

        let second = try await anonymousCapture(session)
        try #require(second.timed.capture.snapshotID != initial.timed.capture.snapshotID)
        let secondPair = try await anonymousButtons(session, in: second, label: "Same", count: 2)
        try #require(Set(secondPair.map(\.frame)) == Set([firstFrame, secondFrame]))
        let other = try #require(secondPair.first { $0.frame == secondFrame })
        previous = try await tapAnonymous(session, button: other, capture: second, before: previous, excluding: [firstFrame])

        let third = try await anonymousCapture(session)
        try #require(third.timed.capture.snapshotID != second.timed.capture.snapshotID)
        let thirdPair = try await anonymousButtons(session, in: third, label: "Same", count: 2)
        let unnamed = try await anonymousButtons(session, in: third, label: "", count: 1)
        let blank = try #require(unnamed.first)
        previous = try await tapAnonymous(session, button: blank, capture: third, before: previous, excluding: thirdPair.map(\.frame))
        try #require(previous.taps == before.taps + 3)
    }

    private struct AnonymousCapture {
        let timed: AgentPlaygroundTimedCapture
        let rows: [AgentPlaygroundRow]
        let buttonRefs: Set<String>
    }

    private struct AnonymousPageEnvelope: Decodable {
        struct Payload: Decodable {
            struct Capture: Decodable { let nextRowOffset: Int? }
            let capture: Capture
        }
        let data: Payload
    }

    private struct AnonymousDetailEnvelope: Decodable {
        struct Payload: Decodable {
            struct Detail: Decodable {
                let ref: String
                let field: String
                let text: String
                let offset: Int
                let nextOffset: Int?
                let totalLength: Int
                let frame: AnonymousFrame?
            }
            let detail: Detail
        }
        let didError: Bool
        let data: Payload
    }

    private struct AnonymousFrame: Decodable, Hashable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    private struct AnonymousButton {
        let row: AgentPlaygroundRow
        let frame: AnonymousFrame
    }

    private func anonymousCapture(_ session: PlaygroundAgentExamplesSession) async throws -> AnonymousCapture {
        let started = ProcessInfo.processInfo.systemUptime
        var output = try await session.run(["describe-ui", "--agent", "--expected-pid", String(session.pid)])
        let result = try session.decode(output.output)
        try #require(output.exitCode == 0 && !result.didError && result.data.action == nil)
        let capture = try #require(result.data.capture)
        try #require(capture.type == "runtime-snapshot" && capture.applicationPID == session.pid
            && UUID(uuidString: capture.udid) == UUID(uuidString: session.app.udid))
        let timed = try AgentPlaygroundTimedCapture(capture: capture, requestStartedUptime: started)
        var rows = try (capture.targets + capture.scroll + capture.text).map(AgentPlaygroundRow.init)
        var buttonRefs = try canonicalButtonRefs(capture.targets + capture.scroll + capture.text)
        var seen: Set<Int> = [0]
        while let next = try JSONDecoder().decode(AnonymousPageEnvelope.self,
            from: Data(output.output.utf8)).data.capture.nextRowOffset {
            try #require(next > (seen.max() ?? 0) && seen.count < 256)
            seen.insert(next)
            try timed.requireUnexpired("before anonymous reference page")
            output = try await session.run(["describe-ui", "--agent", "--expected-pid", String(session.pid),
                "--snapshot-id", capture.snapshotID.uuidString, "--row-offset", String(next)])
            let pageResult = try session.decode(output.output)
            try #require(output.exitCode == 0 && !pageResult.didError && pageResult.data.action == nil)
            let page = try #require(pageResult.data.capture)
            try #require(page.snapshotID == capture.snapshotID && page.applicationPID == session.pid)
            rows += try (page.targets + page.scroll + page.text).map(AgentPlaygroundRow.init)
            buttonRefs.formUnion(try canonicalButtonRefs(page.targets + page.scroll + page.text))
        }
        return AnonymousCapture(timed: timed, rows: rows, buttonRefs: buttonRefs)
    }

    private func canonicalButtonRefs(_ rows: [String]) throws -> Set<String> {
        var refs: Set<String> = []
        for row in rows {
            let fields = row.split(separator: "|", omittingEmptySubsequences: false)
            try #require(fields.count == 6)
            if fields[2] == "button" { refs.insert(String(fields[0])) }
        }
        return refs
    }

    private func anonymousDetail(_ session: PlaygroundAgentExamplesSession, capture: AnonymousCapture,
                                 row: AgentPlaygroundRow, field: String) async throws -> AnonymousDetailEnvelope.Payload.Detail {
        try capture.timed.requireUnexpired("before anonymous public field read")
        let output = try await session.run(["describe-ui", "--agent", "--expected-pid", String(session.pid),
            "--snapshot-id", capture.timed.capture.snapshotID.uuidString, "--read-ref", row.ref,
            "--text-field", field, "--text-limit", "4096"])
        let envelope = try JSONDecoder().decode(AnonymousDetailEnvelope.self, from: Data(output.output.utf8))
        let detail = envelope.data.detail
        try #require(output.exitCode == 0 && !envelope.didError && detail.ref == row.ref
            && detail.field == field && detail.offset == 0 && detail.nextOffset == nil)
        return detail
    }

    private func anonymousButtons(_ session: PlaygroundAgentExamplesSession, in capture: AnonymousCapture,
                                  label: String, count: Int) async throws -> [AnonymousButton] {
        let rows = capture.rows.filter { $0.label == label && $0.identifier.isEmpty && $0.action == "tap"
            && capture.buttonRefs.contains($0.ref) }
        try #require(rows.count == count && Set(rows.map(\.ref)).count == count)
        var buttons: [AnonymousButton] = []
        for row in rows {
            let detail = try await anonymousDetail(session, capture: capture, row: row, field: "id")
            try #require(detail.text.isEmpty && detail.totalLength == 0)
            let frame = try #require(detail.frame)
            try #require([frame.x, frame.y, frame.width, frame.height].allSatisfy(\.isFinite)
                && frame.width > 0 && frame.height > 0)
            buttons.append(AnonymousButton(row: row, frame: frame))
        }
        return buttons.sorted { left, right in
            if left.frame.x != right.frame.x { return left.frame.x < right.frame.x }
            return left.frame.y < right.frame.y
        }
    }

    private func tapAnonymous(_ session: PlaygroundAgentExamplesSession, button: AnonymousButton,
                              capture: AnonymousCapture, before: PlaygroundAgentExamplesDocument,
                              excluding otherFrames: [AnonymousFrame]) async throws -> PlaygroundAgentExamplesDocument {
        try capture.timed.requireUnexpired("before physical anonymous reference tap")
        let output = try await session.run(["tap", "--agent", "--expected-pid", String(session.pid),
            "--snapshot-id", capture.timed.capture.snapshotID.uuidString, "--ref", button.row.ref,
            "--tap-style", "physical"])
        let envelope = try session.decode(output.output)
        let action = try #require(envelope.data.action)
        try #require(output.exitCode == 0 && !envelope.didError && action.kind == "tap"
            && action.outcome == "enqueuedAndDrained" && action.enqueuedEventCount == 2
            && action.cleanup == "notNeeded" && !action.replayed)
        let after = try await session.document.waitFor("one anonymous button callback and release") {
            $0.taps == before.taps + 1 && $0.activeWindowTouches == 0
        }
        try #require(after.pid == before.pid && after.generation == before.generation
            && after.text == before.text && after.textChanges == before.textChanges && after.focused == before.focused
            && after.status == before.status && after.photosStatus == before.photosStatus
            && after.longVisible == before.longVisible && after.longLength == before.longLength
            && after.listOffset == before.listOffset && after.outerOffset == before.outerOffset)
        let dropped = after.windowTraceDropped - before.windowTraceDropped
        let appended = after.windowTouchTrace.count - before.windowTouchTrace.count + dropped
        try #require(dropped >= 0 && appended >= 2 && appended <= after.windowTouchTrace.count)
        let retained = after.windowTouchTrace.count - appended
        try #require(Array(after.windowTouchTrace.prefix(retained)) == Array(before.windowTouchTrace.suffix(retained)),
            "The retained contact trace does not match its pre-action suffix.")
        let added = Array(after.windowTouchTrace.suffix(appended))
        let began = try #require(added.first)
        let ended = try #require(added.last)
        try #require(Set(added.map(\.contactID)).count == 1
            && began.phase == "windowTouchBegan" && ended.phase == "windowTouchEnded"
            && began.activeTouches == 1 && ended.activeTouches == 0
            && added.filter { $0.phase == "windowTouchBegan" }.count == 1
            && added.filter { $0.phase == "windowTouchEnded" || $0.phase == "windowTouchCancelled" }.count == 1
            && added.dropFirst().dropLast().allSatisfy { $0.phase == "windowTouchMoved" })
        // The normal observer reports logical window coordinates. Compare both endpoints with the
        // selected current public frame, including on the rotated inner Duo display.
        let frame = button.frame
        let centerX = frame.x + frame.width / 2
        let centerY = frame.y + frame.height / 2
        for contact in [began, ended] {
            try #require(contact.x.isFinite && contact.y.isFinite
                && frame.x < contact.x && contact.x < frame.x + frame.width
                && frame.y < contact.y && contact.y < frame.y + frame.height
                && abs(contact.x - centerX) <= 1 && abs(contact.y - centerY) <= 1,
                "The physical touch did not reach the selected reference frame center.")
            for other in otherFrames {
                try #require(contact.x < other.x || contact.x > other.x + other.width
                    || contact.y < other.y || contact.y > other.y + other.height,
                    "The touch also lies inside another Same button frame.")
            }
        }
        let fresh = try await anonymousCapture(session)
        let counters = fresh.rows.filter { $0.label == "Target" && $0.action == "tap"
            && fresh.buttonRefs.contains($0.ref) }
        try #require(counters.count == 1)
        let counter = try #require(counters.first)
        let value = try await anonymousDetail(session, capture: fresh, row: counter, field: "value")
        try #require(value.text == String(after.taps))
        try #require(try session.document.read() == after, "Public counter readback sent input.")
        return after
    }

    @Test("A native change to ordinary text keeps a reference and types once without a retry")
    func exactNativeWhitespace() async throws {
        let session = try await PlaygroundAgentExamplesSession.open()
        try await session.tap("agent-examples.text")
        _ = try await session.run(["type", "q7", "--agent", "--expected-pid", String(session.pid),
            "--focus-id", "agent-examples.text"])
        _ = try await session.document.waitFor("seeded focused field") { $0.text == "q7" && $0.focused }
        let current = try await session.core.state()
        let space = try session.core.frame(of: session.core.element("agent-examples.space", in: current))
        _ = try await session.run(["tap", "-x", String(space.x + space.width / 2),
            "-y", String(space.y + space.height / 2), "--tap-style", "simulator"])
        let old = try await session.capture()
        let initial = try session.document.read()
        try #require(initial.status == "a")
        let changed = try await session.document.waitFor("normal delayed native trailing space", timeout: 12) { $0.status == "a " }
        try #require(changed.text == "q7" && changed.focused)
        // The status text gained a trailing space after the snapshot. It is ordinary text outside any
        // control, so input admission ignores its text and the unchanged field types at once.
        let result = try await session.run(["type", "z"] + (try session.arguments(old, id: "agent-examples.text")))
        let typed = try session.decode(result.output)
        let action = try #require(typed.data.action)
        try #require(!typed.didError && action.outcome == "enqueuedAndDrained" && !action.replayed
            && action.retried == nil && action.enqueuedEventCount > 0)
        let capture = try #require(typed.data.capture)
        try #require(capture.snapshotID != old.capture.snapshotID)
        let after = try await session.document.waitFor("typed once after the refresh") { $0.text == "q7z" }
        try #require(after.textChanges == changed.textChanges + 1)
    }

    @Test("A native trailing space changes the compact hash and replaces cached references")
    func nativeWhitespaceChangesHashAndRefreshesReferences() async throws {
        let session = try await PlaygroundAgentExamplesSession.open()
        try await session.tap("agent-examples.text")
        _ = try await session.run(["type", "q7", "--agent", "--expected-pid", String(session.pid),
            "--focus-id", "agent-examples.text"])
        _ = try await session.document.waitFor("seeded focused field") { $0.text == "q7" && $0.focused }
        let current = try await session.core.state()
        let space = try session.core.frame(of: session.core.element("agent-examples.space", in: current))
        _ = try await session.run(["tap", "-x", String(space.x + space.width / 2),
            "-y", String(space.y + space.height / 2), "--tap-style", "simulator"])
        let old = try await session.capture()
        try #require(try session.document.read().status == "a")
        let changed = try await session.document.waitFor("normal delayed native trailing space", timeout: 12) { $0.status == "a " }
        try #require(changed.text == "q7" && changed.focused && changed.activeWindowTouches == 0)

        let started = ProcessInfo.processInfo.systemUptime
        let output = try await session.run(["describe-ui", "--agent", "--expected-pid", String(session.pid),
            "--since-screen-hash", old.capture.screenHash])
        let result = try session.decode(output.output)
        let capture = try #require(result.data.capture)
        try #require(output.exitCode == 0 && !result.didError && result.data.action == nil)
        try #require(result.data.cache.status == "refreshed" && !result.data.cache.requiresRefresh)
        try #require(capture.type == "runtime-snapshot" && capture.rs == old.capture.rs)
        try #require(capture.applicationPID == session.pid && capture.screenHash != old.capture.screenHash)
        try #require(capture.snapshotID != old.capture.snapshotID && capture.seq > old.capture.seq)
        try #require(!capture.targets.isEmpty && capture.count == old.capture.count)
        let fresh = try AgentPlaygroundTimedCapture(capture: capture, requestStartedUptime: started)
        try #require(try session.document.read() == changed, "A cache read changed the app or sent input.")

        let stale = try await session.run(["type", "z"] + (try session.arguments(old, id: "agent-examples.text")), allowFailure: true)
        let refusal = try session.decode(stale.output)
        try #require(stale.exitCode != 0 && refusal.didError && refusal.error?.code == "snapshotMissing")
        try #require(refusal.data.action == nil && refusal.data.capture == nil && refusal.data.cache.requiresRefresh)
        try #require(try session.document.read() == changed)
        // Use the hash-miss capture itself after the old caller's refusal; do not recapture.
        let typed = try await session.run(["type", "z"] + (try session.arguments(fresh, id: "agent-examples.text")))
        let typedResult = try session.decode(typed.output)
        let action = try #require(typedResult.data.action)
        try #require(typed.exitCode == 0 && !typedResult.didError && action.kind == "typeText"
            && action.outcome == "enqueuedAndDrained" && action.enqueuedEventCount == 2
            && action.cleanup == "notNeeded" && !action.replayed)
        let after = try await session.document.waitFor("the refreshed reference typed once") { $0.text == "q7z" }
        try #require(after.pid == changed.pid && after.generation == changed.generation)
        try #require(after.textChanges == changed.textChanges + 1 && after.focused && after.activeWindowTouches == 0)
        try #require(after.windowTouchTrace == changed.windowTouchTrace && after.taps == changed.taps)
        try #require(after.status == changed.status && after.listOffset == changed.listOffset && after.outerOffset == changed.outerOffset)
        try old.requireUnexpired("after whitespace hash change and fresh input")
        try fresh.requireUnexpired("after using the whitespace replacement capture")
    }

    @Test("The parent scroll target cannot move its nested list; the child target can")
    func nestedScrollOwnership() async throws {
        let session = try await PlaygroundAgentExamplesSession.open()
        let capture = try await session.capture()
        let before = try session.document.read()
        let wrong = try await session.run(["swipe", "--direction", "up", "--distance", "1", "--duration", "0.7"]
            + (try session.arguments(capture, id: "agent-examples.outer")), allowFailure: true)
        let refusal = try session.decode(wrong.output)
        try #require(wrong.exitCode != 0 && refusal.didError)
        let action = try #require(refusal.data.action)
        try #require(action.kind == "swipe" && action.enqueuedEventCount == 0
            && action.outcome == "failedBeforeInput" && !action.replayed && action.cleanup == "notNeeded")
        let afterWrong = try session.document.read()
        try #require(afterWrong == before)
        let child = try await session.capture()
        let moved = try await session.run(["swipe", "--direction", "up", "--distance", "1", "--duration", "0.7"]
            + (try session.arguments(child, id: "agent-examples.list")))
        let movedResult = try session.decode(moved.output)
        try #require(movedResult.data.action?.outcome == "enqueuedAndDrained")
        let after = try await session.document.waitFor("only the nested list moved") {
            $0.listOffset > before.listOffset + 5 && abs($0.outerOffset - before.outerOffset) < 1
        }
        try #require(after.text == before.text && after.taps == before.taps)
        try await session.tap("agent-examples.tap")
        _ = try await session.document.waitFor("fresh button after nested scrolling") { $0.taps == before.taps + 1 }
    }

    @Test("A covered control rejects input beside large content with a bounded public failure")
    func boundedFailureReceipt() async throws {
        let session = try await PlaygroundAgentExamplesSession.open()
        try await session.tap("agent-examples.long")
        _ = try await session.document.waitFor("visible long content") { $0.longVisible && $0.longLength == 900_000 }
        _ = try await session.capture()
        let before = try session.document.read()
        let result = try await session.run(["tap", "--agent", "--expected-pid", String(session.pid),
            "--id", "agent-examples.covered"], allowFailure: true)
        let envelope = try session.decode(result.output)
        try #require(result.exitCode != 0 && envelope.didError && envelope.error?.code == "targetCovered")
        let publicFailure = try JSONDecoder().decode(BoundedPublicFailure.self, from: Data(result.output.utf8))
        try #require(publicFailure.schema == "axe.output.agent-result" && publicFailure.schemaVersion == "1"
            && publicFailure.didError && publicFailure.error.code == "targetCovered"
            && publicFailure.error.message == "Another control is at the tap point (yours is covered or has moved), so nothing was sent. Check the capture in this reply, then scroll it into view, close what covers it, or choose it again.")
        // The refusal returns the current screen, which in full view is the complete tree with the
        // long text. Everything else in the reply stays small and free of native diagnostics.
        var reply = try #require(try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
        var replyData = try #require(reply["data"] as? [String: Any])
        try #require(replyData.removeValue(forKey: "capture") != nil, "A refusal returns the current screen.")
        reply["data"] = replyData
        let rest = try #require(String(data: try JSONSerialization.data(withJSONObject: reply), encoding: .utf8))
        try #require(publicFailure.error.message.utf8.count < 256 && rest.utf8.count < 2 * 1024,
            "The public refusal must not include the large reflected native diagnostic.")
        for privateMarker in ["FBSimulatorAX", "nativeIdentity", "objectID", "nativeTarget", "fieldTarget",
                              "AXUniqueId", "AXLabel", "AXValue", "roots", "freshRoots", "confirmedRoots",
                              "rejectedHit", "verifiedTarget"] {
            try #require(!rest.contains(privateMarker), "A private native diagnostic escaped into public output.")
        }
        let action = try #require(envelope.data.action)
        try #require(action.kind == "tap" && action.outcome == "failedBeforeInput"
            && action.enqueuedEventCount == 0 && action.cleanup == "notNeeded" && !action.replayed)
        // The returned screen is the new current table, so it needs no further read.
        try #require(publicFailure.data.cache.status == "refreshed"
            && publicFailure.data.cache.reason == "targetCovered" && !envelope.data.cache.requiresRefresh)
        let after = try session.document.read()
        try #require(after == before)
        let state = try await session.core.state()
        let reset = try session.core.frame(of: session.core.element("agent-examples.reset", in: state))
        let clear = try await session.capture()
        _ = try await session.run(["tap", "--agent", "--expected-pid", String(session.pid),
            "--snapshot-id", clear.capture.snapshotID.uuidString, "-x", String(reset.x + reset.width / 2),
            "-y", String(reset.y + reset.height / 2), "--tap-style", "simulator"])
        _ = try await session.document.waitFor("normal Reset cleared long content") { !$0.longVisible && $0.taps == 0 }
        try await session.tap("agent-examples.tap")
        _ = try await session.document.waitFor("fresh real button callback") { $0.taps == 1 }
    }

    private struct BoundedPublicFailure: Decodable {
        struct Failure: Decodable {
            let code: String
            let message: String
        }
        struct Payload: Decodable {
            struct Cache: Decodable {
                let status: String
                let reason: String?
            }
            let cache: Cache
        }
        let schema: String
        let schemaVersion: String
        let didError: Bool
        let error: Failure
        let data: Payload
    }
}
