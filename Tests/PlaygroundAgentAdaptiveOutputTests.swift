import Foundation
import Testing
@testable import AXe

/// Run alone against one existing warm simulator. Normal playground UI supplies all state.
@Suite("Playground Agent Adaptive Output E2E", .serialized, .enabled(if: isE2EEnabled))
struct PlaygroundAgentAdaptiveOutputTests {
    @Test("Default reading and navigation retain all canonical control references and capabilities")
    func defaultAndNavigationKeepControlCoverage() async throws {
        let session = try await open()
        let before = try session.document.read()
        let full = try await capture(session, view: "full")
        #expect(full.value["schemaVersion"]?.stringValue == "1")
        let canonical = try #require(full.value["data"]?["capture"])
        let snapshot = try #require(canonical["snapshotID"]?.stringValue)
        let allCanonical = try await collect(session, first: canonical, view: "full", snapshot: snapshot)
        let controls = allCanonical.filter { $0.action != "text" }
        let expected = capabilities(controls)
        #expect(!expected.isEmpty)
        for view in [Optional<String>.none, "navigation"] {
            let reply = try await capture(session, view: view, snapshot: snapshot)
            #expect(reply.value["schemaVersion"]?.stringValue == "2")
            let current = try #require(reply.value["data"]?["capture"])
            #expect(current["snapshotID"]?.stringValue == snapshot)
            let compact = try await collect(session, first: current, view: view, snapshot: snapshot)
            let actual = capabilities(compact)
            for (ref, actions) in expected {
                let returned = try #require(actual[ref], "Compact output omitted control \(ref).")
                #expect(actions.isSubset(of: returned))
            }
            if view == nil {
                let redundantValues = canonical["redundantTextRefs"]?.arrayValue ?? []
                let redundant = Set(redundantValues.compactMap(\.stringValue))
                let requiredText = Set(allCanonical.filter { $0.action == "text" && !redundant.contains($0.ref) }.map(\.ref))
                let returnedRefs = Set(compact.map(\.ref))
                #expect(requiredText.isSubset(of: returnedRefs))
                #expect(current["view"]?.stringValue == "reading")
            }
        }
        #expect(try session.document.read() == before)
    }

    @Test("Unchanged default reads retain the same table without renewing its lifetime or resending rows")
    func unchangedHashRetainsTableAndDeadline() async throws {
        let session = try await open()
        let before = try session.document.read()
        let initial = try await capture(session)
        let original = try #require(initial.value["data"]?["capture"])
        let snapshot = try #require(original["snapshotID"]?.stringValue)
        let hash = try #require(original["screenHash"]?.stringValue)
        let sequence = try scalar(original["seq"])
        let expiry = try scalar(original["expiresInSeconds"])
        try await Task.sleep(for: .milliseconds(1100))
        let reply = try await command(session, ["describe-ui", "--agent", "--since-screen-hash", hash])
        let reused = try #require(reply.value["data"]?["capture"])
        #expect(reused["snapshotID"]?.stringValue == snapshot)
        #expect(reused["unchanged"]?.boolValue == true)
        #expect(try scalar(reused["seq"]) > sequence)
        #expect(try scalar(reused["expiresInSeconds"]) < expiry)
        #expect(reused["rows"] == nil)
        #expect(reply.value["data"]?["cache"]?["requiresRefresh"]?.boolValue == false)
        #expect(try session.document.read() == before)
    }

    @Test("Separate default calls use replacement references and refuse stale native reads without input")
    func realTapReplacementAndStaleReadRefusal() async throws {
        let session = try await open()
        let initial = try await capture(session)
        let first = try #require(initial.value["data"]?["capture"])
        let oldSnapshot = try #require(first["snapshotID"]?.stringValue)
        let oldRef = try target(in: first)
        let before = try session.document.read()
        let one = try await command(session, ["tap", "--agent", "--snapshot-id", oldSnapshot,
            "--ref", oldRef, "--tap-style", "physical"])
        try requireCompletedTap(one)
        let afterOne = try await session.document.waitFor("one adaptive Target tap") {
            $0.taps == before.taps + 1 && $0.activeWindowTouches == 0
        }
        let replacement = try #require(one.value["data"]?["capture"])
        let newSnapshot = try #require(replacement["snapshotID"]?.stringValue)
        #expect(newSnapshot != oldSnapshot)
        let newRef = try target(in: replacement)
        let two = try await command(session, ["tap", "--agent", "--snapshot-id", newSnapshot,
            "--ref", newRef, "--tap-style", "physical"])
        try requireCompletedTap(two)
        let afterTwo = try await session.document.waitFor("replacement adaptive Target tap") {
            $0.taps == before.taps + 2 && $0.activeWindowTouches == 0
        }
        #expect(afterTwo.generation == before.generation && afterTwo.pid == before.pid)
        #expect(afterTwo.text == before.text && afterTwo.textChanges == before.textChanges)
        #expect(afterTwo.listOffset == before.listOffset && afterTwo.outerOffset == before.outerOffset)
        #expect(afterOne.windowTouchTrace.count > before.windowTouchTrace.count)
        #expect(afterTwo.windowTouchTrace.count > afterOne.windowTouchTrace.count)

        let stale = try await command(session, ["describe-ui", "--agent", "--snapshot-id", oldSnapshot,
            "--read-ref", oldRef, "--text-field", "label", "--text-limit", "64"], failure: true)
        let code = try #require(stale.value["error"]?["code"]?.stringValue)
        #expect(["snapshotMissing", "snapshotExpired", "screenChanged"].contains(code))
        #expect(stale.value["data"]?["action"] == nil && stale.value["data"]?["detail"] == nil)
        #expect(try session.document.read() == afterTwo)
        let current = try #require(two.value["data"]?["capture"])
        let currentSnapshot = try #require(current["snapshotID"]?.stringValue)
        let currentRef = try target(in: current)
        let detail = try await command(session, ["describe-ui", "--agent", "--snapshot-id", currentSnapshot,
            "--read-ref", currentRef, "--text-field", "label", "--text-limit", "64"])
        #expect(detail.value["data"]?["detail"]?["text"]?.stringValue == "Target")
        #expect(try session.document.read() == afterTwo)
    }

    @Test("The normal long-content control gives bounded default output and exact native chunks")
    func longContentRemainsBoundedAndRecoverable() async throws {
        let session = try await open()
        do {
            let stable = try await stableCapture(session)
            let ready = try #require(stable.value["data"]?["capture"])
            let readySnapshot = try #require(ready["snapshotID"]?.stringValue)
            let readyRows = try parsedRows(ready)
            let longControls = readyRows.filter { $0.label == "Long content" && $0.action.split(separator: ",").contains("tap") }
            try #require(longControls.count == 1, "One Long content control must be in the stable adaptive table.")
            let longControl = try #require(longControls.first)
            let shown = try await command(session, ["tap", "--agent", "--snapshot-id", readySnapshot,
                "--ref", longControl.ref, "--tap-style", "physical"])
            try requireCompletedTap(shown)
            #expect(shown.output.output.utf8.count < 20 * 1024)
            _ = try await session.document.waitFor("normal long-content label") { $0.longVisible && $0.longLength == 900_000 }
            let reply = try await capture(session)
            #expect(reply.output.output.utf8.count < 20 * 1024)
            let capture = try #require(reply.value["data"]?["capture"])
            let snapshot = try #require(capture["snapshotID"]?.stringValue)
            let markers = try #require(capture["truncatedFields"]?.arrayValue)
            let longMarkers = markers.filter {
                $0["field"]?.stringValue == "label" && $0["displayScalarLength"]?.scalarText == "900000"
            }
            #expect(longMarkers.count == 1)
            let marker = try #require(longMarkers.first)
            let ref = try #require(marker["ref"]?.stringValue)
            for offset in [0, 899_936] {
                let chunk = try await command(session, ["describe-ui", "--agent", "--snapshot-id", snapshot,
                    "--read-ref", ref, "--text-field", "label", "--text-offset", String(offset), "--text-limit", "64"])
                let detail = try #require(chunk.value["data"]?["detail"])
                #expect(detail["ref"]?.stringValue == ref && detail["field"]?.stringValue == "label")
                #expect(detail["text"]?.stringValue == String(repeating: "\"", count: 64))
                #expect(detail["totalLength"]?.scalarText == "900000")
                #expect(detail["offset"]?.scalarText == String(offset))
                if offset == 0 { #expect(detail["nextOffset"]?.scalarText == "64") }
                else { #expect(detail["nextOffset"] == nil) }
            }
            #expect(try session.document.read().activeWindowTouches == 0)
        } catch {
            let original = error
            do { try await reset(session) }
            catch { Issue.record("Normal Reset cleanup failed: \(error)") }
            throw original
        }
        try await reset(session)
    }

    @Test("Normal field input keeps spaces in compact/detail values and replaces the cache after whitespace edits")
    func exactWhitespaceValuesAndCache() async throws {
        let session = try await open()
        try await session.tap("agent-examples.text")
        let initial = try await session.capture()
        let seed = "  a b"
        let typed = try await command(session, ["type", seed] + (try session.arguments(initial, id: "agent-examples.text")))
        let before = try await session.document.waitFor("exact spaced field input") {
            $0.text == seed && $0.textChanges == seed.count && $0.focused && $0.activeWindowTouches == 0
        }
        func field(_ capture: CLIOutputValue, expected: String) throws -> (snapshot: String, ref: String, hash: String) {
            let rows = try #require(capture["rows"]?.arrayValue).compactMap(\.stringValue)
            let fields = rows.map { $0.split(separator: "|", omittingEmptySubsequences: false).map(String.init) }
                .filter { $0.count == 5 && $0[2] == "text-field" && $0[1].split(separator: ",").contains("typeText") }
            try #require(fields.count == 1)
            let current = try #require(fields.first)
            try #require(current[4] == expected, "Compact output changed exact field whitespace.")
            return (try #require(capture["snapshotID"]?.stringValue), current[0],
                try #require(capture["screenHash"]?.stringValue))
        }
        let typedCapture = try #require(typed.value["data"]?["capture"])
        let old = try field(typedCapture, expected: seed)
        let detail = try await command(session, ["describe-ui", "--agent", "--snapshot-id", old.snapshot,
            "--read-ref", old.ref, "--text-field", "value"])
        #expect(detail.value["data"]?["detail"]?["text"]?.stringValue == seed)
        #expect(detail.value["data"]?["detail"]?["totalLength"]?.scalarText == String(seed.count))
        #expect(try session.document.read() == before)

        let rows = try await collect(session, first: typedCapture, view: nil, snapshot: old.snapshot)
        let summaries = rows.filter { $0.action == "text" && $0.label.contains("Log: Documents/agent-examples.json") }
        try #require(summaries.count == 1)
        let summary = try #require(summaries.first)
        let expectedSummary = "Target taps 0, text edits \(seed.count), Photos \(before.photosStatus) Log: Documents/agent-examples.json"
        #expect(summary.label == expectedSummary)
        let summaryDetail = try await command(session, ["describe-ui", "--agent", "--snapshot-id", old.snapshot,
            "--read-ref", summary.ref, "--text-field", "label"])
        #expect(summaryDetail.value["data"]?["detail"]?["text"]?.stringValue == expectedSummary)
        #expect(try session.document.read() == before)

        let space = try await command(session, ["key", "44", "--agent", "--snapshot-id", old.snapshot, "--ref", old.ref])
        let action = try #require(space.value["data"]?["action"])
        try #require(action["outcome"]?.stringValue == "enqueuedAndDrained" && action["replayed"]?.boolValue == false)
        let spacedState = try await session.document.waitFor("one normal trailing-space key") {
            $0.text == seed + " " && $0.textChanges == before.textChanges + 1 && $0.activeWindowTouches == 0
        }
        let spaced = try field(try #require(space.value["data"]?["capture"]), expected: seed + " ")
        #expect(spaced.snapshot != old.snapshot && spaced.hash != old.hash)
        let spacedDetail = try await command(session, ["describe-ui", "--agent", "--snapshot-id", spaced.snapshot,
            "--read-ref", spaced.ref, "--text-field", "value"])
        #expect(spacedDetail.value["data"]?["detail"]?["text"]?.stringValue == seed + " ")
        #expect(try session.document.read() == spacedState)

        let backspace = try await command(session, ["key", "42", "--agent", "--snapshot-id", spaced.snapshot, "--ref", spaced.ref])
        let deleted = try #require(backspace.value["data"]?["action"])
        try #require(deleted["outcome"]?.stringValue == "enqueuedAndDrained" && deleted["replayed"]?.boolValue == false)
        let finalState = try await session.document.waitFor("one normal backspace restores exact spaces") {
            $0.text == seed && $0.textChanges == spacedState.textChanges + 1 && $0.activeWindowTouches == 0
        }
        let restored = try field(try #require(backspace.value["data"]?["capture"]), expected: seed)
        #expect(restored.snapshot != spaced.snapshot && restored.hash != spaced.hash)
        #expect(finalState.taps == before.taps && finalState.listOffset == before.listOffset && finalState.outerOffset == before.outerOffset)
        #expect(finalState.windowTouchTrace == before.windowTouchTrace)
    }

    private func open() async throws -> PlaygroundAgentExamplesSession {
        try await PlaygroundAgentExamplesSession.open(position: isDuoPlaygroundE2EEnabled ? .inner90 : .outer0)
    }

    private struct Reply {
        let output: CommandOutput
        let value: CLIOutputValue
    }

    private struct Row {
        let ref: String
        let action: String
        let label: String
    }

    private func command(_ session: PlaygroundAgentExamplesSession, _ arguments: [String],
                         failure: Bool = false, timeout: TimeInterval = 30) async throws -> Reply {
        let name = "adaptive-" + UUID().uuidString
        let before = try Data(contentsOf: session.document.url)
        try before.write(to: session.artifacts.appendingPathComponent(name + "-before.json"))
        let executable = try TestHelpers.getAxePath()
        let argv = arguments + ["--udid", session.app.udid]
        try JSONEncoder().encode([executable] + argv).write(to: session.artifacts.appendingPathComponent(name + "-argv.json"))
        // Separate existing process streams; test the actual default without the canonical helper.
        let process = try PlaygroundTestProcess(executable: executable, arguments: argv,
            directory: session.artifacts, name: name)
        do {
            try process.start()
            try await process.wait(timeout: timeout)
            let output = CommandOutput(output: try process.output(), exitCode: process.exitCode)
            let timing = ["startedUptime": String(process.startedUptime),
                "finishedUptime": String(ProcessInfo.processInfo.systemUptime), "exitCode": String(output.exitCode),
                "timeoutSeconds": String(timeout)]
            try JSONEncoder().encode(timing).write(to: session.artifacts.appendingPathComponent(name + "-receipt.json"))
            try Data(contentsOf: session.document.url).write(to: session.artifacts.appendingPathComponent(name + "-after.json"))
            // Decode all stdout: extra text or a second JSON object must fail. Stderr is retained separately.
            let value = try JSONDecoder().decode(CLIOutputValue.self, from: Data(output.output.utf8))
            try #require(value["schema"]?.stringValue == "axe.output.agent-result")
            try #require(value["didError"]?.boolValue == failure)
            try #require(failure ? output.exitCode != 0 : output.exitCode == 0)
            await process.finish()
            return Reply(output: output, value: value)
        } catch {
            await process.finish()
            throw error
        }
    }

    private func capture(_ session: PlaygroundAgentExamplesSession, view: String? = nil,
                         snapshot: String? = nil, offset: Int? = nil, timeout: TimeInterval = 30) async throws -> Reply {
        var args = ["describe-ui", "--agent"]
        if let view { args += ["--view", view] }
        if let snapshot { args += ["--snapshot-id", snapshot] }
        if let offset { args += ["--row-offset", String(offset)] }
        return try await command(session, args, timeout: timeout)
    }

    /// Read-only polling proves the same table survived a fresh observation. No input is retried.
    private func stableCapture(_ session: PlaygroundAgentExamplesSession) async throws -> Reply {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        var candidate = try await capture(session, timeout: 10)
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                throw TestError.unexpectedState("The normal UI did not retain one stable reference table within ten seconds; no input was sent.")
            }
            let capture = try #require(candidate.value["data"]?["capture"])
            let snapshot = try #require(capture["snapshotID"]?.stringValue)
            let hash = try #require(capture["screenHash"]?.stringValue)
            let observed = try await command(session, ["describe-ui", "--agent", "--since-screen-hash", hash],
                timeout: remaining)
            let current = try #require(observed.value["data"]?["capture"])
            if current["unchanged"]?.boolValue == true {
                try #require(current["snapshotID"]?.stringValue == snapshot,
                    "An unchanged observation must retain the candidate's immutable table.")
                // The acknowledgement has no rows. Keep the original rows owned by this UUID.
                return candidate
            }
            try #require(current["rows"]?.arrayValue != nil,
                "A changed observation must return its replacement reference rows.")
            candidate = observed
        }
    }

    private func parsedRows(_ capture: CLIOutputValue) throws -> [Row] {
        if let compact = capture["rows"]?.arrayValue {
            return try compact.map { value in
                let raw = try #require(value.stringValue)
                let fields = raw.split(separator: "|", omittingEmptySubsequences: false)
                try #require(fields.count == 5)
                return Row(ref: String(fields[0]), action: String(fields[1]), label: String(fields[3]))
            }
        }
        let entries = (capture["targets"]?.arrayValue ?? []) + (capture["scroll"]?.arrayValue ?? []) + (capture["text"]?.arrayValue ?? [])
        return try entries.map { value in
            let raw = try #require(value.stringValue)
            let fields = raw.split(separator: "|", omittingEmptySubsequences: false)
            try #require(fields.count == 6)
            return Row(ref: String(fields[0]), action: String(fields[1]), label: String(fields[3]))
        }
    }

    private func collect(_ session: PlaygroundAgentExamplesSession, first: CLIOutputValue,
                         view: String?, snapshot: String) async throws -> [Row] {
        var current = first
        var collected: [Row] = []
        var seen: Set<Int> = []
        for _ in 0..<32 {
            collected += try parsedRows(current)
            let nextValue = current["page"]?["nextOffset"] ?? current["nextRowOffset"]
            guard let nextValue else { return collected }
            let next = try scalar(nextValue)
            let firstVisit = seen.insert(next).inserted
            try #require(next > 0 && firstVisit, "The row cursor did not advance.")
            let reply = try await capture(session, view: view, snapshot: snapshot, offset: next)
            current = try #require(reply.value["data"]?["capture"])
            try #require(current["snapshotID"]?.stringValue == snapshot)
        }
        throw TestError.unexpectedState("Adaptive page bound exceeded; remaining controls are unverified.")
    }

    private func capabilities(_ rows: [Row]) -> [String: Set<String>] {
        var answer: [String: Set<String>] = [:]
        for row in rows { answer[row.ref, default: []].formUnion(row.action.split(separator: ",").map(String.init)) }
        return answer
    }

    private func target(in capture: CLIOutputValue) throws -> String {
        let rows = try parsedRows(capture)
        let targets = rows.filter { $0.label == "Target" && $0.action.split(separator: ",").contains("tap") }
        try #require(targets.count == 1, "One Target button must be in the returned adaptive rows.")
        return try #require(targets.first).ref
    }

    private func requireCompletedTap(_ reply: Reply) throws {
        let action = try #require(reply.value["data"]?["action"])
        try #require(action["kind"]?.stringValue == "tap" && action["outcome"]?.stringValue == "enqueuedAndDrained")
        try #require(action["cleanup"]?.stringValue != "uncertain" && action["replayed"]?.boolValue == false)
        try #require(action["enqueuedEventCount"]?.scalarText == "2")
    }

    private func reset(_ session: PlaygroundAgentExamplesSession) async throws {
        // The giant fixture deliberately exceeds selector-action admission bounds.
        // Use the supported snapshot-bound coordinate path, with a fresh native frame and ID.
        let before = try session.document.read()
        let fresh = try await capture(session)
        let current = try #require(fresh.value["data"]?["capture"])
        let snapshot = try #require(current["snapshotID"]?.stringValue)
        let rows = try parsedRows(current)
        let resets = rows.filter { $0.label == "Reset" && $0.action.split(separator: ",").contains("tap") }
        try #require(resets.count == 1, "One normal Reset control must be in the fresh adaptive rows.")
        let resetRow = try #require(resets.first)
        let read = try await command(session, ["describe-ui", "--agent", "--snapshot-id", snapshot,
            "--read-ref", resetRow.ref, "--text-field", "id", "--text-limit", "64"])
        let detail = try #require(read.value["data"]?["detail"])
        try #require(detail["ref"]?.stringValue == resetRow.ref && detail["field"]?.stringValue == "id")
        try #require(detail["text"]?.stringValue == "agent-examples.reset" && detail["nextOffset"] == nil)
        let frame = try #require(detail["frame"])
        let x = try coordinate(frame["x"])
        let y = try coordinate(frame["y"])
        let width = try coordinate(frame["width"])
        let height = try coordinate(frame["height"])
        try #require(width > 0 && height > 0)
        let centerX = x + width / 2
        let centerY = y + height / 2
        let screen = try #require(current["screen"]?.arrayValue)
        try #require(screen.count == 4)
        let screenWidth = try coordinate(screen[1])
        let screenHeight = try coordinate(screen[2])
        try #require(centerX >= 0 && centerX < screenWidth && centerY >= 0 && centerY < screenHeight)
        let result = try await command(session, ["tap", "--agent", "--snapshot-id", snapshot,
            "-x", String(centerX), "-y", String(centerY), "--tap-style", "physical"])
        try requireCompletedTap(result)
        let after = try await session.document.waitFor("normal coordinate Reset cleared long-content fixture") {
            !$0.longVisible && $0.longLength == 0 && $0.taps == 0 && $0.activeWindowTouches == 0
        }
        #expect(after.pid == before.pid && after.generation == before.generation)
    }

    private func coordinate(_ value: CLIOutputValue?) throws -> Double {
        let text = try #require(value?.scalarText)
        let number = try #require(Double(text))
        try #require(number.isFinite)
        return number
    }

    private func scalar(_ value: CLIOutputValue?) throws -> Int {
        let text = try #require(value?.scalarText)
        return try #require(Int(text))
    }
}
