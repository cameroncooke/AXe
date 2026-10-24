import Darwin
import Foundation
import Testing

enum PlaygroundHostWaitCase: String, CaseIterable {
    case zero, finite, negative, notANumber, infinite, missing, greatestFiniteINT, finiteTERM
    case beyondHIDCap, finiteINT, greatestFiniteTERM
    var seconds: String? {
        switch self {
        case .zero: return "0"; case .finite: return "0.125"; case .negative: return "-1"
        case .notANumber: return "nan"; case .infinite: return "inf"; case .missing: return nil
        case .greatestFiniteINT, .greatestFiniteTERM: return String(Double.greatestFiniteMagnitude)
        case .finiteINT, .finiteTERM: return "5"; case .beyondHIDCap: return "21"
        }
    }
    var cancelled: Bool { [.greatestFiniteINT, .greatestFiniteTERM, .finiteINT, .finiteTERM].contains(self) }
    var signal: Int32 { self == .greatestFiniteINT || self == .finiteINT ? SIGINT : SIGTERM }
    var hasSentinel: Bool { cancelled || self == .infinite }
}

@Suite("Playground Duo Batch Input", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundDuoBatchCoverageTests {
    @Test("Raw batch enters exact mixed text without duplicate characters")
    func exactMixedText() async throws {
        try await withDuoPlaygroundScreen(pose: .open, rotation: 90) {
            let app = try await PlaygroundControlsSession()
            let before = try app.documents.read()
            _ = try await app.app.run(batchArguments(["tap --id feature.text --element-type TextField", "type 'A!'", "key 20", "key 36"]))
            let after = try await app.documents.waitFor("exact four-character raw batch edit") { $0.text == "A!q7" }
            try #require(after.count("textChanged") == before.count("textChanged") + 4)
            try after.requireClear()
            try app.preserveState("mixed-text-final")
        }
    }

    @Test("Repeated raw modifiers release before the following lowercase key")
    func repeatedModifiers() async throws {
        try await withDuoPlaygroundScreen(pose: .open, rotation: 90) {
            let app = try await PlaygroundControlsSession()
            let before = try app.documents.read()
            _ = try await app.app.run(batchArguments(["tap --id feature.text --element-type TextField",
                "key-combo --modifiers 225,225 --key 4", "key 4", "key-combo --modifiers 225,225 --key 4", "key 4"]))
            let after = try await app.documents.waitFor("exact AaAa without held Shift or repeated text") { $0.text == "AaAa" }
            try #require(after.count("textChanged") == before.count("textChanged") + 4)
            try after.requireClear()
        }
    }

    @Test("Raw batch preserves one retained finger through move and release")
    func retainedTouchSteps() async throws {
        try await withDuoPlaygroundScreen(pose: .open, rotation: 90) {
            let app = try await PlaygroundControlsSession()
            let frame = try await app.frame("feature.pad")
            let start = (frame.x + frame.width / 2 - 30, frame.y + frame.height / 2)
            let end = (start.0 + 60, start.1)
            let before = try app.documents.read()
            _ = try await app.app.run(batchArguments(["touch -x \(start.0) -y \(start.1) --down", "sleep 0.2",
                "touch -x \(end.0) -y \(end.1) --down", "sleep 0.2", "touch -x \(end.0) -y \(end.1) --up"]))
            let after = try await app.documents.waitFor("one complete retained batch contact") { $0.activeWindowTouches == 0 && $0.count("pan") == before.count("pan") + 1 }
            try app.requireContact(after, since: before, start: start, end: end)
            try await app.freshTap()
        }
    }

    @Test("Raw batch reports an invalid agent step and omits the later Button action")
    func invalidRawStep() async throws { try await invalidStep(selected: false) }
    @Test("Selected batch reports a parse failure after the first real action")
    func invalidSelectedStep() async throws { try await invalidStep(selected: true) }

    private func invalidStep(selected: Bool) async throws {
        try await withDuoPlaygroundScreen(pose: .open, rotation: 90) {
            let app = try await PlaygroundControlsSession()
            let before = try app.documents.read()
            let tap = "tap --id feature.tap --element-type Button --expected-pid \(app.pid)"
            let steps = selected ? [tap, "tap --agent", tap] : ["tap --id feature.tap", "tap --agent", "tap --id feature.tap"]
            let output = try await app.app.run(batchArguments(steps) + (selected ? app.selection() : []), allowFailure: true)
            try #require(output.exitCode != 0)
            if selected {
                let rows = try controlsBatchReceipts(output.output)
                try #require(rows.count == 2 && rows[0].status == "completed" && rows[1].status == "rejectedBeforeSend")
                try #require(rows[1].index == 2 && rows[1].requestID == nil && rows[1].response == nil && rows[1].error != nil)
            } else { try #require(output.output.contains("Step 2 failed") && output.output.contains("tap")) }
            let after = try await app.documents.waitFor("only the first real Button action") { $0.count("tap") == before.count("tap") + 1 && $0.activeWindowTouches == 0 }
            try await Task.sleep(nanoseconds: 500_000_000)
            try #require(try app.documents.read().count("tap") == after.count("tap"))
            try after.requireClear()
        }
    }

    @Test("Selected batch input and host sleep produce two distinct released actions")
    func inputSleepInput() async throws {
        try await withDuoPlaygroundScreen(pose: .open, rotation: 90) {
            let app = try await PlaygroundControlsSession()
            let before = try app.documents.read()
            let tap = "tap --id feature.tap --element-type Button --tap-style physical --expected-pid \(app.pid)"
            let output = try await app.app.run(batchArguments([tap, "sleep 0.125", tap]) + app.selection())
            let rows = try controlsBatchReceipts(output.output)
            try #require(rows.count == 3 && rows.allSatisfy { $0.status == "completed" })
            try #require(rows[1].requestID == nil && rows[1].response == nil && rows[1].hostWait?.outcome == "completed")
            try #require((rows[1].hostWait?.elapsedSeconds ?? 0) >= 0.125)
            for index in [0, 2] {
                let receipt = try #require(rows[index].response)
                try #require(receipt.outcome == "enqueuedAndDrained" && receipt.enqueuedEventCount == 2 && receipt.cleanup == "notNeeded")
            }
            let after = try await app.documents.waitFor("two separate real Button callbacks") { $0.count("tap") == before.count("tap") + 2 && $0.activeWindowTouches == 0 }
            let contacts = Dictionary(grouping: after.windowTouchTrace.dropFirst(before.windowTouchTrace.count), by: \.contactID)
            try #require(contacts.count == 2)
            try requireReleasedContacts(after, before: before, count: 2)
        }
    }

    @Test("Selected batch host waits are bounded by explicit cancellation or validation", arguments: PlaygroundHostWaitCase.allCases)
    func hostWait(test: PlaygroundHostWaitCase) async throws {
        let app = try await prepareDuoControls(.inner90)
        let before = try app.documents.read()
        let step = "sleep" + (test.seconds.map { " " + $0 } ?? "")
        let steps = test.hasSentinel ? ["sleep 0", step, "sleep 0"] : [step]
        let process = try PlaygroundTestProcess(executable: TestHelpers.getAxePath(), arguments: batchArguments(steps) + app.selection() + ["--udid", app.app.udid],
            directory: app.artifacts, name: "host-wait")
        do {
            try process.start()
            if test.cancelled {
                try await Task.sleep(nanoseconds: 100_000_000)
                try #require(process.isRunning)
                // A read can complete during this host wait because it owns no simulator input lease.
                let read = try await app.app.run(["describe-ui", "--expected-pid", String(app.pid)] + app.selection())
                let response = try controlsReceipt(read.output)
                try #require(response.outcome == "ready" && response.enqueuedEventCount == 0)
                try #require(process.isRunning)
                try process.signal(test.signal)
            }
            try await process.wait(timeout: test == .beyondHIDCap ? 30 : 10)
            let rows = try controlsBatchReceipts(process.output())
            let row: PlaygroundControlsBatchReceipt
            if test.hasSentinel {
                try #require(rows.count == 2)
                let first = rows[0]
                try #require(first.index == 1 && first.totalSteps == 3 && first.status == "completed")
                try #require(first.requestID == nil && first.response == nil)
                try #require(first.hostWait?.outcome == "completed" && first.hostWait?.requestedSeconds == 0)
                row = rows[1]
                try #require(row.index == 2 && row.totalSteps == 3, "The later host-wait sentinel must be absent.")
            } else { row = try rows.only() }
            if test == .zero || test == .finite || test == .beyondHIDCap {
                try #require(process.exitCode == 0 && row.status == "completed" && row.requestID == nil && row.response == nil)
                let wait = try #require(row.hostWait)
                let expected = try #require(test.seconds.flatMap { Double($0) })
                try #require(wait.outcome == "completed" && wait.requestedSeconds == expected && wait.elapsedSeconds >= expected)
            } else if test.cancelled {
                try #require(process.exitCode != 0 && row.status == "waitInterrupted" && row.hostWait?.outcome == "interrupted")
                try #require(row.requestID == nil && row.response == nil)
                let requested = try #require(test.seconds.flatMap { Double($0) })
                try #require(row.hostWait?.requestedSeconds == requested)
            } else {
                try #require(process.exitCode != 0 && row.status == "rejectedBeforeSend" && row.requestID == nil && row.response == nil && row.hostWait == nil)
            }
            let after = try app.documents.read()
            try #require(after.counts == before.counts && after.text == before.text && after.windowTouchTrace.count == before.windowTouchTrace.count)
            try after.requireClear()
        } catch { await process.finish(); throw error }
        await process.finish()
    }

    @Test("Selected drag then invalid step omits its sentinel")
    func dragThenInvalid() async throws {
        try await withDuoPlaygroundScreen(pose: .open, rotation: 90) {
            let app = try await PlaygroundControlsSession()
            let frame = try await app.frame("feature.pad")
            let start = (frame.x + frame.width / 2 - 60, frame.y + frame.height / 2)
            let end = (start.0 + 120, start.1)
            let before = try app.documents.read()
            let steps = ["drag --start-x \(start.0) --start-y \(start.1) --end-x \(end.0) --end-y \(end.1) --duration 0.4 --steps 12",
                "not-a-command", "tap --id feature.tap --expected-pid \(app.pid)"]
            let output = try await app.app.run(batchArguments(steps) + app.selection(), allowFailure: true)
            let rows = try controlsBatchReceipts(output.output)
            try #require(output.exitCode != 0 && rows.count == 2 && rows[0].status == "completed" && rows[1].status == "rejectedBeforeSend")
            let after = try await app.documents.waitFor("first drag completed and sentinel absent") { $0.count("pan") == before.count("pan") + 1 && $0.activeWindowTouches == 0 }
            try app.requireContact(after, since: before, start: start, end: end)
            try #require(after.count("tap") == before.count("tap"))
        }
    }

    @Test("Selected slider endpoints then wrong type omit the later tap")
    func sliderThenWrongType() async throws {
        try await withDuoPlaygroundScreen(pose: .open, rotation: 90) {
            let app = try await PlaygroundControlsSession()
            let before = try app.documents.read()
            let steps = ["slider --id feature.slider --endpoint maximum --expected-pid \(app.pid)",
                "slider --id feature.slider --endpoint minimum --expected-pid \(app.pid)",
                "slider --id feature.slider --endpoint maximum --element-type Button --expected-pid \(app.pid)",
                "tap --id feature.tap --expected-pid \(app.pid)"]
            let output = try await app.app.run(batchArguments(steps) + app.selection(), allowFailure: true)
            let rows = try controlsBatchReceipts(output.output)
            try #require(output.exitCode != 0 && rows.count == 3 && rows[0].status == "completed" && rows[1].status == "completed" && rows[2].status == "failedResponse")
            let failed = try #require(rows[2].response)
            try #require(failed.enqueuedEventCount == 0 && failed.cleanup == "notNeeded" && failed.error != nil)
            let after = try app.documents.read()
            try #require(after.slider == 0 && after.count("tap") == before.count("tap"))
            try after.requireClear()
        }
    }
}

func batchArguments(_ steps: [String]) -> [String] { ["batch"] + steps.flatMap { ["--step", $0] } }
