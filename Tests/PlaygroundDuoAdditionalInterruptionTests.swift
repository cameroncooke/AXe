import Darwin
import Foundation
import Testing

enum PlaygroundInterruptedMotion: String, CaseIterable { case swipe, drag }
enum PlaygroundMotionStop: String, CaseIterable { case fold, rotate, interrupt }

@Suite("Playground Duo Additional Input Interruption", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundDuoAdditionalInterruptionTests {
    @Test("Raw long swipe or drag stops, releases and permits fresh input", arguments: PlaygroundInterruptedMotion.allCases, PlaygroundMotionStop.allCases)
    func rawMotion(gesture: PlaygroundInterruptedMotion, stop: PlaygroundMotionStop) async throws {
        let app = try await prepareDuoControls(.inner90)
        let frame = try await app.frame("feature.pad")
        let start = (frame.x + frame.width / 2 - 80, frame.y + frame.height / 2)
        let end = (start.0 + 160, start.1)
        var arguments = [gesture.rawValue, "--start-x", String(start.0), "--start-y", String(start.1),
            "--end-x", String(end.0), "--end-y", String(end.1), "--duration", "8"]
        arguments += gesture == .drag ? ["--steps", "160"] : ["--delta", "1"]
        let before = try app.documents.read()
        let process = try PlaygroundTestProcess(executable: TestHelpers.getAxePath(), arguments: arguments + ["--udid", app.app.udid],
            directory: app.artifacts, name: "raw-motion")
        func requireStoppedInput() async throws {
            try await process.wait(timeout: 15)
            struct RawMotionExit: Encodable {
                let gesture: String
                let stop: String
                let exitCode: Int32
            }
            let exit = RawMotionExit(gesture: gesture.rawValue, stop: stop.rawValue, exitCode: process.exitCode)
            try JSONEncoder().encode(exit).write(
                to: app.artifacts.appendingPathComponent("raw-motion-exit.json"), options: .withoutOverwriting)
            try #require(process.exitCode != 0)
            let diagnostics = try process.diagnostics()
            if stop == .interrupt && diagnostics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // SIGINT can close the client before it receives the broker cleanup reply.
                // The physical release and no-late-input checks below remain required.
                try #require(process.exitCode == SIGINT)
            } else {
                try requireRawDuoRelease(diagnostics, changedLayout: stop != .interrupt)
            }
            let released = try await app.documents.waitFor("raw contact released after interruption") { $0.activeWindowTouches == 0 }
            try requireReleasedContacts(released, before: before, count: 1)
            let trace = released.windowTouchTrace.dropFirst(before.windowTouchTrace.count)
            let reachedEnd = trace.contains { $0.phase == "windowTouchMoved" && hypot($0.x - end.0, $0.y - end.1) <= 3 }
            try #require(!reachedEnd, "Interrupted input reached its old endpoint.")
            try await Task.sleep(nanoseconds: 500_000_000)
            try #require(try app.documents.read().windowTouchTrace.count == released.windowTouchTrace.count)
        }
        do {
            try process.start()
            _ = try await app.documents.waitFor("real moving raw contact before interruption") {
                $0.activeWindowTouches == 1 && $0.windowTouchTrace.dropFirst(before.windowTouchTrace.count).contains {
                    $0.phase == "windowTouchMoved" && $0.x > start.0 + 2 && $0.x < end.0 - 10
                }
            }
            try #require(process.isRunning)
            if stop == .interrupt { try process.signal(SIGINT) }
            else {
                _ = try await changeDuoControls(app, change: stop == .fold ? .fold : .rotate,
                    afterInputRelease: stop == .fold ? { try await requireStoppedInput() } : nil)
            }
            if stop != .fold { try await requireStoppedInput() }
            try await app.freshTap()
        } catch { await process.finish(); throw error }
        await process.finish()
    }

    @Test("Complete two-finger hold or moving twist stops on fold and turn", arguments: [false, true], [PlaygroundDuoChange.fold, .rotate])
    func selectedPair(twist: Bool, change: PlaygroundDuoChange) async throws {
        let app = try await prepareDuoControls(.inner90)
        let frame = try await app.frame("feature.pad")
        let x = frame.x + frame.width / 2
        let y = frame.y + frame.height / 2
        let starts = [PlaygroundPairPoint(x: x - 32, y: y), PlaygroundPairPoint(x: x + 32, y: y)]
        var arguments: [String]
        if twist { arguments = ["gesture", "rotate", "-x", String(x), "-y", String(y), "--radius", "32", "--degrees", "60", "--duration", "8", "--delta", "0.5"] }
        else { arguments = ["gesture", "two-finger-hold", "-x", String(starts[0].x), "-y", String(y), "--x2", String(starts[1].x), "--y2", String(y), "--hold", "8"] }
        let before = try app.documents.read()
        let process = try PlaygroundTestProcess(executable: TestHelpers.getAxePath(), arguments: arguments + app.selection() + ["--udid", app.app.udid],
            directory: app.artifacts, name: "selected-pair")
        do {
            try process.start()
            _ = try await app.documents.waitFor("both real contacts before layout change") { value in
                let groups = Dictionary(grouping: value.windowTouchTrace.dropFirst(before.windowTouchTrace.count), by: \.contactID)
                guard value.activeWindowTouches == 2, groups.count == 2 else { return false }
                if !twist { return true }
                return groups.values.allSatisfy { rows in
                    guard let first = rows.first else { return false }
                    return rows.contains { $0.phase == "windowTouchMoved" && hypot($0.x - first.x, $0.y - first.y) > 2 }
                }
            }
            try #require(process.isRunning)
            _ = try await changeDuoControls(app, change: change)
            try await process.wait(timeout: 15)
            try #require(process.exitCode != 0)
            let receipt = try process.receipt(PlaygroundControlsReceipt.self)
            try #require(receipt.outcome == "failedNoReplay" && receipt.error?.contains("staleContext") == true)
            try #require(receipt.cleanup == "releaseEnqueuedAndDrained" && receipt.quarantine == nil && receipt.enqueuedEventCount >= 1)
            let original = try #require(receipt.context)
            try original.requireMatch(app.catalogue)
            let released = try await app.documents.waitFor("both original contacts released") { $0.activeWindowTouches == 0 }
            try requireReleasedContacts(released, before: before, count: 2)
            if twist {
                let dy = 32 * sin(Double.pi / 3)
                let ends = [PlaygroundPairPoint(x: x - 16, y: y - dy), PlaygroundPairPoint(x: x + 16, y: y + dy)]
                let groups = Dictionary(grouping: released.windowTouchTrace.dropFirst(before.windowTouchTrace.count), by: \.contactID).values.sorted { ($0.first?.x ?? 0) < ($1.first?.x ?? 0) }
                for (index, rows) in groups.enumerated() {
                    let reached = rows.contains { $0.phase == "windowTouchMoved" && hypot($0.x - ends[index].x, $0.y - ends[index].y) <= 3 }
                    try #require(!reached)
                }
            } else { try #require(receipt.enqueuedEventCount == 1) }
            try await Task.sleep(nanoseconds: 500_000_000)
            try #require(try app.documents.read().windowTouchTrace.count == released.windowTouchTrace.count)
            try await app.freshTap()
        } catch { await process.finish(); throw error }
        await process.finish()
    }
}

private func requireRawDuoRelease(_ diagnostics: String, changedLayout: Bool) throws {
    let expression = try NSRegularExpression(pattern: #"Duo input failed: (.+); events=([0-9]+); cleanup=releaseEnqueuedAndDrained\. Input was not replayed\."#)
    let range = NSRange(diagnostics.startIndex..<diagnostics.endIndex, in: diagnostics)
    let match = try #require(expression.firstMatch(in: diagnostics, range: range), "No native owned release receipt: \(diagnostics)")
    let reasonRange = try #require(Range(match.range(at: 1), in: diagnostics))
    let countRange = try #require(Range(match.range(at: 2), in: diagnostics))
    let count = try #require(Int(diagnostics[countRange]))
    try #require(count > 0)
    if changedLayout { try #require(diagnostics[reasonRange].contains("staleContext")) }
    else { try #require(diagnostics[reasonRange].contains("cancelled") || diagnostics[reasonRange].contains("CancellationError")) }
}
