import Darwin
import Foundation
import Testing

enum PlaygroundTapWaitKind: String, CaseIterable {
    case immediate, delayedID, delayedLabel, delayedValue, timeout, cancelINT, cancelTERM, fold, open, rotate, duplicate, samePanelHinge
    var interrupted: Bool { [.cancelINT, .cancelTERM, .fold, .open, .rotate, .samePanelHinge].contains(self) }
    var positive: Bool { [.immediate, .delayedID, .delayedLabel, .delayedValue].contains(self) }
}
struct PlaygroundTapWaitCase: CustomTestStringConvertible {
    let kind: PlaygroundTapWaitKind
    let batch: Bool
    var testDescription: String { kind.rawValue + (batch ? "-batch" : "-standalone") }
    static var cases: [Self] { PlaygroundTapWaitKind.allCases.flatMap { kind in
        (kind == .samePanelHinge ? [false] : [false, true]).map { Self(kind: kind, batch: $0) }
    } }
}

@Suite("Playground Duo Tap Wait", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundDuoTapWaitTests {
    @Test("Selected waits observe real delayed controls and never send late input", arguments: PlaygroundTapWaitCase.cases)
    func waitForTarget(test: PlaygroundTapWaitCase) async throws {
        let app = try await prepareDuoControls(test.kind == .open ? .outer0 : .inner90)
        try await app.show("feature.showWaits")
        try await app.show("wait.hide")
        if test.kind == .immediate || test.kind == .duplicate {
            try await app.show("wait.show")
            if test.kind == .duplicate { try await app.show("wait.duplicateControl") }
        } else if test.kind != .timeout {
            try await app.show(test.kind.positive ? "wait.start3" : "wait.start8")
        }
        let before = try app.documents.read()
        try before.requireClear()
        let selector: [String]
        switch test.kind {
        case .delayedLabel: selector = ["--label", "Delayed target"]
        case .delayedValue: selector = ["--value", "ready"]
        default: selector = ["--id", "wait.target"]
        }
        let timeout = test.kind == .immediate ? 0 : test.kind == .timeout ? 1 : 12
        let target = ["tap"] + selector + ["--element-type", "Button", "--expected-pid", String(app.pid),
            "--tap-style", "physical", "--wait-timeout", String(timeout), "--poll-interval", "0.25"]
        let arguments: [String]
        if test.batch {
            arguments = ["batch", "--step", target.map(controlsQuote).joined(separator: " "),
                "--step", "tap --id wait.sentinel --element-type Button --tap-style physical --expected-pid \(app.pid)"] + app.selection()
        } else { arguments = target + app.selection() }
        let process = try PlaygroundTestProcess(executable: TestHelpers.getAxePath(), arguments: arguments + ["--udid", app.app.udid],
            directory: app.artifacts, name: "wait-target")
        do {
            try process.start()
            var observationDeadline = ProcessInfo.processInfo.systemUptime + Double(timeout) + 1
            if test.kind != .immediate && test.kind != .duplicate {
                try await witnessWaitOwner(app, while: process)
                if test.kind.interrupted { observationDeadline = ProcessInfo.processInfo.systemUptime + Double(timeout) + 9 }
            }
            if test.kind == .cancelINT || test.kind == .cancelTERM {
                try process.signal(test.kind == .cancelINT ? SIGINT : SIGTERM)
            } else if test.kind == .fold || test.kind == .open || test.kind == .rotate {
                _ = try await changeDuoControls(app, change: test.kind == .fold ? .fold : test.kind == .open ? .open : .rotate)
            } else if test.kind == .samePanelHinge {
                try await changeSamePanelHinge(app)
            }
            try await process.wait(timeout: 40)
            try #require((process.exitCode == 0) == test.kind.positive)
            let text = try process.output()
            // Signal cancellation may close stdout before a broker reply. Physical state and owner readback remain required.
            if test.kind != .cancelINT && test.kind != .cancelTERM {
                let receipt: PlaygroundWaitResponse
                if test.batch {
                    let rows = try text.split(separator: "\n").filter { $0.first == "{" }.map {
                        try JSONDecoder().decode(PlaygroundWaitBatchResponse.self, from: Data($0.utf8))
                    }
                    try #require(rows.count == (test.kind.positive ? 2 : 1))
                    try #require(rows[0].index == 1 && rows[0].totalSteps == 2)
                    receipt = try #require(rows[0].response)
                    if test.kind.positive { try #require(rows.allSatisfy { $0.status == "completed" }) }
                } else {
                    receipt = try JSONDecoder().decode(PlaygroundWaitResponse.self, from: Data(text.utf8))
                }
                if test.kind.positive {
                    try #require(receipt.error == nil && receipt.outcome == "enqueuedAndDrained" && receipt.enqueuedEventCount == 2 && receipt.cleanup == "notNeeded")
                    if test.kind != .immediate { try #require(receipt.ax?.wait?.outcome == "matched" && (receipt.ax?.wait?.attempts ?? 0) >= 2) }
                } else {
                    try #require(receipt.error != nil && receipt.enqueuedEventCount == 0 && receipt.cleanup == "notNeeded" && receipt.quarantine == nil)
                    if test.kind == .timeout { try #require(receipt.ax?.wait?.outcome == "timedOut") }
                }
            }
            if test.kind.interrupted {
                var sawVisible = false
                repeat {
                    let current = try app.documents.read()
                    sawVisible = sawVisible || current.waitTargetVisible
                    try #require(current.count("target") == before.count("target") && current.count("sentinel") == before.count("sentinel"))
                    try #require(current.activeWindowTouches == 0 && current.windowTouchTrace.count == before.windowTouchTrace.count)
                    try await Task.sleep(nanoseconds: 100_000_000)
                } while ProcessInfo.processInfo.systemUptime < observationDeadline
                try #require(sawVisible, "The actual delayed target did not appear after cancellation.")
            }
            let after = try await app.documents.waitFor("target result and all releases") {
                $0.activeWindowTouches == 0 && (!test.kind.positive || $0.count("target") == before.count("target") + 1)
            }
            try after.requireClear()
            try #require(after.count("target") == before.count("target") + (test.kind.positive ? 1 : 0))
            try #require(after.count("sentinel") == before.count("sentinel") + (test.kind.positive && test.batch ? 1 : 0))
            if !test.kind.positive { try #require(after.windowTouchTrace.count == before.windowTouchTrace.count) }
            if test.kind.interrupted {
                let fresh = try await DuoPlaygroundSession().catalogue(boot: app.catalogue.bootIdentity)
                let panel = fresh.activePanel.identity
                let response = try await app.app.run(["tap", "--id", "wait.target", "--element-type", "Button", "--tap-style", "physical",
                    "--expected-pid", String(app.pid), "--input-mode", "selected", "--screen-id", String(panel.displayID), "--screen-uuid", panel.uniqueID.uuidString])
                let tap = try controlsReceipt(response.output)
                try tap.requireCompleted()
                _ = try await app.documents.waitFor("fresh same-element tap after interrupted wait") { $0.count("target") == before.count("target") + 1 && $0.activeWindowTouches == 0 }
            }
            try app.preserveState("wait-final")
        } catch { await process.finish(); throw error }
        await process.finish()
    }
}

private func witnessWaitOwner(_ app: PlaygroundControlsSession, while process: PlaygroundTestProcess) async throws {
    // This token was never returned by a retained DOWN. Idle admission must reject it
    // before opening a native session or taking the common input lease.
    let token = UUID().uuidString
    let witness = ["touch", "--up", "--contact-token", token, "-x", "0", "-y", "0"] + app.selection()
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    repeat {
        try #require(process.isRunning)
        let output = try await app.app.run(witness, allowFailure: true)
        let response = try controlsReceipt(output.output)
        try #require(output.exitCode != 0 && response.outcome == "rejectedBeforeInput"
            && response.enqueuedEventCount == 0 && response.cleanup == "notNeeded"
            && response.token == nil && response.quarantine == nil)
        if response.error == "busy" {
            try #require(process.isRunning, "The selected wait ended before its busy witness returned.")
            return
        }
        try #require(response.error == "invalidToken")
        try await Task.sleep(nanoseconds: 50_000_000)
    } while ProcessInfo.processInfo.systemUptime < deadline
    throw TestError.unexpectedState("No actual selected wait owner was observed.")
}

private func changeSamePanelHinge(_ app: PlaygroundControlsSession) async throws {
    let cli = try TestHelpers.getAxePath()
    let executable = try #require(ProcessInfo.processInfo.environment["AXE_DUO_STATE_CHANGE_PATH"])
    let panel = app.catalogue.activePanel.identity
    let operation = try PlaygroundTestProcess(executable: executable, arguments: ["fold", app.catalogue.bootIdentity,
        String(panel.displayID), panel.uniqueID.uuidString, "90", app.artifacts.appendingPathComponent("hinge90-marker.json").path,
        app.app.udid, URL(fileURLWithPath: cli).deletingLastPathComponent().appendingPathComponent("cadisplay-context").path],
        directory: app.artifacts, name: "same-panel-hinge")
    do {
        try operation.start()
        try await operation.wait(timeout: 20)
        try #require(operation.exitCode == 0)
        let response = try JSONDecoder().decode(PlaygroundWaitHingeChange.self, from: Data(try operation.output().utf8))
        try #require(response.mode == "fold" && response.hinge.requestedDegrees == 90 && response.hinge.outcome == "observedMechanicalTarget")
        try #require(response.hinge.matchingSamples.count == 2 && response.hinge.matchingSamples.allSatisfy { abs($0.mechanicalDegrees - 90) <= 0.5 })
        let current = try await DuoPlaygroundSession().catalogue(boot: app.catalogue.bootIdentity)
        try #require(current.activePanel.identity == panel)
    } catch { await operation.finish(); throw error }
    await operation.finish()
}
private struct PlaygroundWaitHingeChange: Decodable {
    let mode: String; let hinge: Hinge
    struct Hinge: Decodable { let outcome: String; let requestedDegrees: Double; let matchingSamples: [DuoCLIResponse.HingeSample] }
}
private struct PlaygroundWaitBatchResponse: Decodable {
    let index: Int; let totalSteps: Int; let status: String; let response: PlaygroundWaitResponse?
}
private struct PlaygroundWaitResponse: Decodable {
    let outcome: String; let error: String?; let enqueuedEventCount: Int; let cleanup: String; let quarantine: DuoCLIResponse.Quarantine?; let ax: AX?
    struct AX: Decodable { let wait: Wait? }
    struct Wait: Decodable { let outcome: String; let attempts: Int }
}
