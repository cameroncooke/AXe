import Foundation
import ImageIO
import Testing

@Suite("Playground Duo Media Safety E2E", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundDuoMediaSafetyTests {
    // Display state is read in process, so the capture is the one owned child to interrupt.
    @Test("PNG cancellation by SIGINT or SIGTERM awaits the real capture child", arguments: ["capture-int", "capture-term"])
    func cancelledScreenshot(phase: String) async throws {
        let session = try MediaPlaygroundSession(name: "png-" + phase)
        let before = try await session.open(inner: true, rotation: 90)
        let file = session.directory.appendingPathComponent("must-not-publish.png")
        let process = try session.start(["screenshot", "--output", file.path] + session.selection(before.catalogue),
                                        name: "cancel", phase: phase)
        do {
            // The host observer signals only after it sees the actual owned child and its argv.
            try await process.wait(timeout: 35)
            let ownership = try PlaygroundMediaProcess.requireClean(directory: session.directory, name: "cancel", phase: phase)
            try #require(process.exitCode == 1 && ownership.cliExitCode == 1)
            let stdout = try process.output()
            let stderr = try session.stderr("cancel")
            try #require(stdout.isEmpty && !FileManager.default.fileExists(atPath: file.path))
            try #require(stderr.contains("Selected screenshot cancelled; awaited operation returned."))
            await process.finish()
        } catch { await process.finish(); throw error }
        // A fresh public capture proves that the old invocation has released the shared input lease.
        let fresh = session.directory.appendingPathComponent("fresh.png")
        try await session.command(["screenshot", "--output", fresh.path] + session.selection(before.catalogue))
        _ = try PlaygroundMediaAssertions.image(Data(contentsOf: fresh), type: "public.png")
        try await session.requireUnchanged(before)
    }

    @Test("A retained touch refuses PNG until the matching release, then PNG and fresh input work")
    func screenshotDuringRetainedContact() async throws {
        let session = try MediaPlaygroundSession(name: "png-retained")
        let controls = try await PlaygroundControlsSession()
        try await controls.show("feature.showPad")
        let initial = try controls.documents.read()
        try initial.requireClear()
        let frame = try await controls.frame("feature.pad")
        let point = (frame.x + frame.width / 2, frame.y + frame.height / 2)
        let position = ["-x", String(point.0), "-y", String(point.1)]
        let down = try await controls.selected(["touch"] + position + ["--down"])
        let token = try #require(down.token)
        try #require(down.outcome == "retained" && down.enqueuedEventCount == 1 && down.cleanup == "notNeeded")
        var releaseAttempted = false
        do {
            let held = try await controls.documents.waitFor("one retained contact and its normal long-press callback") {
                $0.activeWindowTouches == 1
                    && $0.windowTouchTrace.count == initial.windowTouchTrace.count + 1
                    && $0.count("longPress") == initial.count("longPress") + 1
                    && $0.count("touchBegan") == initial.count("touchBegan") + 1
            }
            let begins = Array(held.windowTouchTrace.dropFirst(initial.windowTouchTrace.count))
            try #require(begins.count == 1 && begins[0].phase == "windowTouchBegan")
            try #require(hypot(begins[0].x - point.0, begins[0].y - point.1) <= 2)
            let recognizers = Array(held.recognizerTrace.dropFirst(initial.recognizerTrace.count))
            try #require(recognizers.count == 1 && recognizers[0].name == "longPress"
                && recognizers[0].state == 1 && recognizers[0].touches == 1)
            try #require(held.windowTraceDropped == 0 && held.recognizerTraceDropped == 0)
            try controls.preserveState("retained-before-png")
            let refused = session.directory.appendingPathComponent("busy.png")
            let response = try await session.command(["screenshot", "--output", refused.path]
                + session.selection(controls.catalogue), allowFailure: true)
            try #require(response.exitCode == 1)
            try #require(response.output.contains("Simulator input is owned by another action or retained contact"))
            try #require(!FileManager.default.fileExists(atPath: refused.path))
            let stillHeld = try controls.documents.read()
            try #require(stillHeld.activeWindowTouches == 1)
            try #require(stillHeld.windowTouchTrace.count == held.windowTouchTrace.count)
            try #require(stillHeld.pid == held.pid && stillHeld.generation == held.generation)
            try #require(stillHeld.inputState == held.inputState)
            try controls.preserveState("retained-after-png-refusal")
            releaseAttempted = true
            let up = try await controls.selected(["touch"] + position + ["--up", "--contact-token", token.uuidString])
            try #require(up.outcome == "endedAndDrained" && up.enqueuedEventCount == 2 && up.cleanup == "notNeeded")
            let released = try await controls.documents.waitFor("matching retained contact release") { $0.activeWindowTouches == 0 }
            try controls.requireContact(released, since: initial, start: point, end: point)
            let contacts = Array(released.windowTouchTrace.dropFirst(initial.windowTouchTrace.count))
            // Token UP validates the same point with one MOVE, which UIKit can coalesce.
            try #require((contacts.count == 2 || contacts.count == 3) && contacts.last?.contactID == begins[0].contactID)
            try controls.preserveState("retained-released")
        } catch {
            if !releaseAttempted {
                // Release this test's original contact once. Never replay a failed release or touch down.
                _ = try await controls.selected(["touch"] + position + ["--up", "--contact-token", token.uuidString])
            }
            throw error
        }
        let fresh = session.directory.appendingPathComponent("released.png")
        let result = try await session.command(["screenshot", "--output", fresh.path] + session.selection(controls.catalogue))
        let line = result.output.split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
        let receipt = try JSONDecoder().decode(ReleasedPNGReceipt.self, from: Data(line.utf8))
        try #require(receipt.output == fresh.path && receipt.child.exitConfirmed && receipt.child.terminationStatus == 0)
        try validateControlsPNG(fresh, receipt: receipt, catalogue: controls.catalogue)
        let after = try await DuoPlaygroundSession().catalogue(boot: controls.catalogue.bootIdentity)
        try #require(after.activePanel == controls.catalogue.activePanel)
        // A new AX lookup followed by a real callback proves input is available on the same app page.
        try await controls.freshTap()
    }

    @Test("Recording rejects the seven audited option, output and initial-boot errors", arguments: [0, 1, 2, 3, 4, 5, 6])
    func followRecordingRefusal(caseIndex: Int) async throws {
        let session = try MediaPlaygroundSession(name: "follow-refusal-\(caseIndex)")
        let before = try await session.open(inner: false, rotation: 0)
        let file = session.directory.appendingPathComponent("refused.mp4")
        let sentinel = Data("preserve the existing movie".utf8)
        let panel = before.catalogue.activePanel.identity
        let options: [String]
        let expected: String
        switch caseIndex {
        case 0:
            options = ["--follow-active-display", "--screen-id", String(panel.displayID)]
            expected = "--follow-active-display cannot be combined with --screen-id or --screen-uuid."
        case 1:
            options = ["--follow-active-display", "--screen-uuid", panel.uniqueID.uuidString]
            expected = "--follow-active-display cannot be combined with --screen-id or --screen-uuid."
        case 2:
            options = ["--screen-id", String(panel.displayID)]
            expected = "Selected recording requires both --screen-id and --screen-uuid."
        case 3:
            options = ["--expected-boot", before.catalogue.bootIdentity]
            expected = "--expected-boot requires selected or follow-active recording and a nonempty boot identity."
        case 4:
            options = ["--follow-active-display", "--expected-boot", before.catalogue.bootIdentity]
            expected = "Selected recording will not replace an existing output"
            try sentinel.write(to: file, options: .withoutOverwriting)
        case 5:
            options = session.selection(before.catalogue)
            expected = "Selected recording will not replace an existing output"
            try sentinel.write(to: file, options: .withoutOverwriting)
        case 6:
            options = ["--follow-active-display", "--expected-boot", "1:1:1"]
            expected = "Follow-active recording stopped: simulator boot changed"
        default:
            throw TestError.unexpectedState("Unknown recording refusal case")
        }
        let process = try session.start(["record-video", "--output", file.path] + options, name: "refusal")
        do {
            try await process.wait(timeout: 35)
            let receipt = try PlaygroundMediaProcess.requireClean(directory: session.directory, name: "refusal")
            try #require(process.exitCode == (caseIndex < 4 ? 64 : 1) && receipt.cliExitCode == process.exitCode)
            let stdout = try process.output()
            let stderr = try session.stderr("refusal")
            try #require(stdout.isEmpty && stderr.contains(expected))
            try #require(!stderr.contains("accepted frames:"))
            if caseIndex == 4 || caseIndex == 5 {
                let retained = try Data(contentsOf: file)
                try #require(retained == sentinel)
            } else {
                try #require(!FileManager.default.fileExists(atPath: file.path))
            }
            await process.finish()
        } catch { await process.finish(); throw error }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: session.directory.path)
        try #require(!leftovers.contains { $0.hasPrefix(".axe-follow-video-") || $0.hasPrefix(".axe-selected-video-") })
        try await session.requireUnchanged(before)
    }

    private func validateControlsPNG(_ file: URL, receipt: ReleasedPNGReceipt, catalogue: DuoCatalogue) throws {
        let data = try Data(contentsOf: file)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        try #require(CGImageSourceGetCount(source) == 1 && CGImageSourceGetStatus(source) == .statusComplete)
        let type = try #require(CGImageSourceGetType(source))
        try #require(CFEqual(type, "public.png" as CFString))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let rotated = try catalogue.activePanel.rotationDegrees()
        let swapped = rotated == 90 || rotated == 270
        let width = swapped ? catalogue.activePanel.nativePixelHeight : catalogue.activePanel.nativePixelWidth
        let height = swapped ? catalogue.activePanel.nativePixelWidth : catalogue.activePanel.nativePixelHeight
        try #require(Double(image.width) == width && Double(image.height) == height)
        try #require(receipt.width == image.width && receipt.height == image.height)
    }
}

private struct ReleasedPNGReceipt: Decodable {
    let output: String
    let width: Int
    let height: Int
    let child: Child
    struct Child: Decodable { let exitConfirmed: Bool; let terminationStatus: Int32? }
}
