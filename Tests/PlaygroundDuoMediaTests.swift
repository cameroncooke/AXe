import CoreGraphics
import Darwin
import Foundation
import Testing

@Suite("Playground Duo Media E2E", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundDuoMediaTests {
    @Test("Selected PNG has upright visible content on either display", arguments: [false, true])
    func screenshot(inner: Bool) async throws {
        let session = try MediaPlaygroundSession(name: "png")
        let before = try await session.open(inner: inner, rotation: inner ? 90 : 270)
        let url = session.directory.appendingPathComponent("selected.png")
        try await session.command(["screenshot", "--output", url.path] + session.selection(before.catalogue))
        let image = try PlaygroundMediaAssertions.image(Data(contentsOf: url), type: "public.png")
        try #require(image.width > 100 && image.height > 100)
        try await session.requireUnchanged(before)
    }

    @Test("A plain PNG is the active display, like the selected one", arguments: [false, true])
    func plainScreenshot(inner: Bool) async throws {
        let session = try MediaPlaygroundSession(name: "png-plain")
        let before = try await session.open(inner: inner, rotation: inner ? 90 : 270)
        let selectedURL = session.directory.appendingPathComponent("selected.png")
        let plainURL = session.directory.appendingPathComponent("plain.png")
        try await session.command(["screenshot", "--output", selectedURL.path] + session.selection(before.catalogue))
        try await session.command(["screenshot", "--output", plainURL.path])
        let selected = try PlaygroundMediaAssertions.image(Data(contentsOf: selectedURL), type: "public.png")
        let plain = try PlaygroundMediaAssertions.image(Data(contentsOf: plainURL), type: "public.png")
        try #require(plain.width == selected.width && plain.height == selected.height)
        try await session.requireUnchanged(before)
    }

    @Test("Malformed, inactive, wrong-boot and existing PNG outputs are refused")
    func screenshotRefusals() async throws {
        let session = try MediaPlaygroundSession(name: "png-refusals")
        let before = try await session.open(inner: true, rotation: 90)
        let inactive = try #require(before.catalogue.panels.first { $0.identity != before.catalogue.activePanel.identity })
        let invalid = [
            ["--screen-id", String(before.catalogue.activePanel.identity.displayID)],
            ["--screen-id", String(inactive.identity.displayID), "--screen-uuid", inactive.identity.uniqueID.uuidString],
            Array(session.selection(before.catalogue).dropLast(2)) + ["--expected-boot", "1:1:1"],
        ]
        for (index, options) in invalid.enumerated() {
            let output = session.directory.appendingPathComponent("refused-\(index).png")
            let result = try await session.command(["screenshot", "--output", output.path] + options, allowFailure: true)
            try #require(result.exitCode != 0 && !FileManager.default.fileExists(atPath: output.path))
        }
        let existing = session.directory.appendingPathComponent("keep.png")
        let sentinel = Data("preserve existing output".utf8)
        try sentinel.write(to: existing, options: .withoutOverwriting)
        let result = try await session.command(["screenshot", "--output", existing.path] + session.selection(before.catalogue), allowFailure: true)
        try #require(result.exitCode != 0)
        let retained = try Data(contentsOf: existing)
        try #require(retained == sentinel)
        try await session.requireUnchanged(before)
    }

    @Test("Four stream formats deliver two upright frames and stop cleanly", arguments: [0, 1, 2, 3, 4, 5, 6, 7])
    func selectedStream(caseIndex: Int) async throws {
        let formats = ["raw", "mjpeg", "ffmpeg", "bgra"]
        let format = formats[caseIndex % 4]
        let inner = caseIndex >= 4
        let session = try MediaPlaygroundSession(name: "stream-" + format)
        let before = try await session.open(inner: inner, rotation: inner ? 270 : 90)
        let process = try session.start(["stream-video", "--format", format, "--fps", "2", "--quality", "90", "--scale", "0.25"]
            + session.selection(before.catalogue), name: "stream")
        do {
            try await session.waitForFrames(process, name: "stream", prefix: "Selected stream completed frames: ", minimum: 2)
            try process.signal(inner ? SIGTERM : SIGINT)
            try await process.wait(timeout: 15)
            _ = try PlaygroundMediaProcess.requireClean(directory: session.directory, name: "stream")
            let stopDiagnostics = try session.stderr("stream")
            try #require(process.exitCode == 0, "Stream stop failed: \(stopDiagnostics)")
            let text = try session.stderr("stream")
            let records = text.split(separator: "\n").compactMap { line -> StreamRecord? in
                try? JSONDecoder().decode(StreamRecord.self, from: Data(line.utf8))
            }
            let metadata = try #require(records.first { $0.event == "selectedStreamMetadata" })
            let summary = try #require(records.first { $0.event == "selectedStreamComplete" })
            let width = try #require(metadata.width), height = try #require(metadata.height)
            try #require(metadata.format == format && summary.format == format && summary.stopReason == "signal")
            let data = try Data(contentsOf: session.directory.appendingPathComponent("stream.stdout"))
            let frames = try PlaygroundMediaAssertions.streamFrames(data, format: format, width: width, height: height, complete: true)
            try #require(frames.count >= 2 && summary.completedFrames == frames.count)
            for frame in frames {
                if format == "bgra" {
                    try #require(metadata.bytesPerRow == width * 4 && metadata.pixelLayout == "BGRA-premultiplied-top-to-bottom-packed")
                    _ = try PlaygroundMediaAssertions.markers(frame, width: width, height: height, bytesPerRow: width * 4)
                } else {
                    let decoded = try PlaygroundMediaAssertions.image(frame, type: "public.jpeg")
                    try #require(decoded.width == width && decoded.height == height)
                }
            }
            try await session.requireUnchanged(before)
        } catch { await process.finish(); throw error }
        await process.finish()
    }

    @Test("Streaming rejects malformed selection, bad options and wrong boot before media")
    func streamRefusals() async throws {
        let session = try MediaPlaygroundSession(name: "stream-refusals")
        let before = try await session.open(inner: false, rotation: 90)
        let options = [
            ["--screen-id", "1"], Array(session.selection(before.catalogue).dropLast(2)) + ["--expected-boot", "1:1:1"],
            session.selection(before.catalogue) + ["--fps", "0"],
            session.selection(before.catalogue) + ["--scale", "0.01"],
            session.selection(before.catalogue) + ["--quality", "101"],
        ]
        for (index, flags) in options.enumerated() {
            let name = "refusal-\(index)"
            let process = try session.start(["stream-video"] + flags, name: name)
            do {
                try await process.wait(timeout: 15)
                _ = try PlaygroundMediaProcess.requireClean(directory: session.directory, name: name)
                try #require(process.exitCode != 0)
                let bytes = try Data(contentsOf: session.directory.appendingPathComponent(name + ".stdout"))
                try #require(bytes.isEmpty, "Refused stream wrote media bytes.")
            } catch { await process.finish(); throw error }
            await process.finish()
        }
        try await session.requireUnchanged(before)
    }

    @Test("Fixed-display recording decodes every upright frame", arguments: [false, true])
    func fixedRecording(inner: Bool) async throws {
        let session = try MediaPlaygroundSession(name: "fixed-movie")
        let before = try await session.open(inner: inner, rotation: 90)
        let file = session.directory.appendingPathComponent("fixed.mp4")
        let process = try session.start(["record-video", "--verbose", "--output", file.path, "--fps", "2", "--scale", "0.25"]
            + session.selection(before.catalogue), name: "record")
        do {
            try await session.waitForFrames(process, name: "record", prefix: "Selected recording accepted frames: ", minimum: 2)
            try process.signal(inner ? SIGINT : SIGTERM)
            try await process.wait(timeout: 20)
            _ = try PlaygroundMediaProcess.requireClean(directory: session.directory, name: "record")
            let stopDiagnostics = try session.stderr("record")
            try #require(process.exitCode == 0, "Recording stop failed: \(stopDiagnostics)")
            let receipt: MovieReceipt = try process.receipt(MovieReceipt.self)
            try #require(receipt.output == file.path && receipt.acceptedFrames >= 2)
            try await PlaygroundMediaAssertions.movie(file, width: receipt.width, height: receipt.height, expectedFrames: receipt.acceptedFrames)
            try await session.requireUnchanged(before)
        } catch { await process.finish(); throw error }
        await process.finish()
    }

    @Test("Fixed recording stops on layout change and a fresh PNG works", arguments: ["fold", "rotate"])
    func fixedRecordingTransition(change: String) async throws {
        let session = try MediaPlaygroundSession(name: "fixed-" + change)
        let before = try await session.open(inner: true, rotation: 90)
        let file = session.directory.appendingPathComponent("must-not-publish.mp4")
        let process = try session.start(["record-video", "--output", file.path, "--fps", "2", "--scale", "0.25"]
            + session.selection(before.catalogue), name: "record")
        do {
            try await session.waitForFrames(process, name: "record", prefix: "Selected recording accepted frames: ", minimum: 1)
            try await session.external(change, before: before.catalogue)
            try await process.wait(timeout: 20)
            _ = try PlaygroundMediaProcess.requireClean(directory: session.directory, name: "record")
            try #require(process.exitCode != 0 && !FileManager.default.fileExists(atPath: file.path))
            let after = try await session.device.catalogue(boot: before.catalogue.bootIdentity)
            let fresh = session.directory.appendingPathComponent("fresh.png")
            try await session.command(["screenshot", "--output", fresh.path] + session.selection(after))
            _ = try PlaygroundMediaAssertions.image(Data(contentsOf: fresh), type: "public.png")
            try await session.requireSameApp(before.pid)
        } catch { await process.finish(); throw error }
        await process.finish()
    }

    @Test("Recording follows opening and two rotations on one fixed canvas")
    func followOpeningAndRotation() async throws { try await followActive(opening: true) }

    @Test("Recording follows closing onto the outer display")
    func followClosing() async throws { try await followActive(opening: false) }

    private func followActive(opening: Bool) async throws {
        let session = try MediaPlaygroundSession(name: opening ? "follow-open" : "follow-close")
        let before = try await session.open(inner: !opening, rotation: opening ? 0 : 90)
        var layouts = [try await session.markerLayout(catalogue: before.catalogue, pid: before.pid)]
        let file = session.directory.appendingPathComponent("follow.mp4")
        let process = try session.start(["record-video", "--verbose", "--follow-active-display", "--expected-boot", before.catalogue.bootIdentity,
            "--output", file.path, "--fps", "2", "--scale", "0.25"], name: "record")
        do {
            try await session.waitForFrames(process, name: "record", prefix: "Follow-active recording accepted frames: ", minimum: 2)
            try await session.external(opening ? "open" : "fold", before: before.catalogue)
            var after = try await session.device.catalogue(boot: before.catalogue.bootIdentity)
            layouts.append(try await session.markerLayout(catalogue: after, pid: before.pid))
            try await session.waitForFrames(process, name: "record", prefix: "Follow-active recording accepted frames: ", minimum: 4)
            if opening {
                for _ in 0..<2 {
                    try await session.external("rotate", before: after)
                    after = try await session.device.catalogue(boot: before.catalogue.bootIdentity)
                    layouts.append(try await session.markerLayout(catalogue: after, pid: before.pid))
                    let count = try session.acceptedFrames("record", prefix: "Follow-active recording accepted frames: ")
                    try await session.waitForFrames(process, name: "record", prefix: "Follow-active recording accepted frames: ", minimum: count + 1)
                }
            }
            try process.signal(SIGINT)
            try await process.wait(timeout: 20)
            _ = try PlaygroundMediaProcess.requireClean(directory: session.directory, name: "record")
            let stopDiagnostics = try session.stderr("record")
            try #require(process.exitCode == 0, "Recording stop failed: \(stopDiagnostics)")
            let receipt: MovieReceipt = try process.receipt(MovieReceipt.self)
            try #require((receipt.observedContextChanges ?? 0) > 0)
            try await PlaygroundMediaAssertions.movie(file, width: receipt.width, height: receipt.height,
                expectedFrames: receipt.acceptedFrames, layouts: layouts)
            try await session.requireSameApp(before.pid)
        } catch { await process.finish(); throw error }
        await process.finish()
    }
}

struct MediaPlaygroundSession {
    let app: CorePlaygroundSession
    let device: DuoPlaygroundSession
    let udid: String
    let cli: String
    let directory: URL

    init(name: String) throws {
        app = try CorePlaygroundSession(); device = try DuoPlaygroundSession()
        udid = try TestHelpers.requireSimulatorUDID(); cli = try TestHelpers.getAxePath()
        let root = try #require(ProcessInfo.processInfo.environment["AXE_E2E_ARTIFACT_DIR"])
        directory = URL(fileURLWithPath: root).appendingPathComponent(name + "-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    func open(inner: Bool, rotation: Int) async throws -> MediaPrepared {
        let original = try await device.catalogue()
        let current = try await device.position(inner ? .open : .closed, rotation: rotation, boot: original.bootIdentity)
        let target = DuoPlaygroundLaunchTarget(bootIdentity: current.bootIdentity, panel: current.activePanel)
        let pid = try await DuoPlaygroundLaunchTarget.$current.withValue(target) {
            let pid = try await device.launch(screen: "media-pattern")
            _ = try await app.waitFor("visible capture markers") { app.value("media-pattern-phase", in: $0) == "0" }
            _ = try await DuoPlaygroundLaunchTarget.prepareIfNeeded()
            return pid
        }
        return MediaPrepared(catalogue: try await device.catalogue(boot: original.bootIdentity), pid: pid)
    }

    func markerLayout(catalogue: DuoCatalogue, pid: Int32) async throws -> PlaygroundMediaLayout {
        // The legacy read does not compete for the recording's selected input lease.
        let state = try await requireSameApp(pid)
        let panel = catalogue.activePanel
        let rotation = try panel.rotationDegrees()
        try #require(panel.pointScale > 0 && panel.nativePixelWidth.isFinite && panel.nativePixelHeight.isFinite
            && panel.nativePixelWidth > 0 && panel.nativePixelHeight > 0)
        let scale = Double(panel.pointScale), sideways = rotation == 90 || rotation == 270
        let width = (sideways ? panel.nativePixelHeight : panel.nativePixelWidth) / scale
        let height = (sideways ? panel.nativePixelWidth : panel.nativePixelHeight) / scale
        var cells: [CGRect] = []
        for index in 0..<4 {
            let cell = try app.element("media-pattern-cell-\(index)", in: state)
            let frame = try app.frame(of: cell)
            try #require(cell.value == String(index) && frame.x >= 0 && frame.y >= 0
                && frame.x + frame.width <= width && frame.y + frame.height <= height)
            cells.append(CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height))
        }
        let fresh = try await device.catalogue(boot: catalogue.bootIdentity)
        try #require(fresh.activePanel == catalogue.activePanel)
        let name = "display\(panel.identity.displayID)-rot\(rotation)"
        print("Visible media layout \(name): source=\(width)x\(height), cells=\(cells)")
        return PlaygroundMediaLayout(name: name, width: width, height: height, cells: cells)
    }

    func selection(_ value: DuoCatalogue) -> [String] {
        ["--screen-id", String(value.activePanel.identity.displayID), "--screen-uuid", value.activePanel.identity.uniqueID.uuidString,
         "--expected-boot", value.bootIdentity]
    }

    func start(_ arguments: [String], name: String, phase: String? = nil) throws -> PlaygroundTestProcess {
        try PlaygroundMediaProcess.start(cli: cli, arguments: arguments + ["--udid", udid],
                                         directory: directory, name: name, phase: phase)
    }

    @discardableResult
    func command(_ arguments: [String], allowFailure: Bool = false) async throws -> CommandOutput {
        let name = "capture-" + UUID().uuidString
        let process = try start(arguments, name: name)
        do {
            try await process.wait(timeout: 35)
            _ = try PlaygroundMediaProcess.requireClean(directory: directory, name: name)
            let output = try process.diagnostics()
            let result = CommandOutput(output: output, exitCode: process.exitCode)
            if !allowFailure { try #require(result.exitCode == 0, "Media command failed: \(output)") }
            await process.finish()
            return result
        } catch { await process.finish(); throw error }
    }

    func stderr(_ name: String) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(name + ".stderr"), encoding: .utf8)
    }

    func acceptedFrames(_ name: String, prefix: String) throws -> Int {
        try stderr(name).split(separator: "\n").compactMap { $0.hasPrefix(prefix) ? Int($0.dropFirst(prefix.count)) : nil }.max() ?? 0
    }

    func waitForFrames(_ process: PlaygroundTestProcess, name: String, prefix: String, minimum: Int) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        repeat {
            let diagnostics = try stderr(name)
            try #require(process.isRunning, "Capture ended before the required frames: \(diagnostics)")
            if try acceptedFrames(name, prefix: prefix) >= minimum { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw TestError.unexpectedState("No \(minimum) accepted frames: \(try stderr(name))")
    }

    func requireUnchanged(_ before: MediaPrepared) async throws {
        let after = try await device.catalogue(boot: before.catalogue.bootIdentity)
        try #require(after.activePanel == before.catalogue.activePanel)
        try await requireSameApp(before.pid)
    }

    @discardableResult
    func requireSameApp(_ pid: Int32) async throws -> UIElement {
        let result = try await CommandRunner.run(["xcrun", "simctl", "spawn", udid, "launchctl", "list"].map(shellQuote).joined(separator: " "), timeout: 10)
        let rows = result.output.split(separator: "\n").filter { $0.contains("com.cameroncooke.AxePlayground") }
        try #require(rows.count == 1 && rows[0].split(whereSeparator: \.isWhitespace).first == Substring(String(pid)))
        let state = try await app.state()
        try #require(app.value("media-pattern-phase", in: state) == "0")
        return state
    }

    func external(_ change: String, before: DuoCatalogue) async throws {
        let tool = try #require(ProcessInfo.processInfo.environment["AXE_DUO_STATE_CHANGE_PATH"])
        let panel = before.activePanel.identity
        let args = [change == "open" ? "fold" : change, before.bootIdentity, String(panel.displayID), panel.uniqueID.uuidString, change == "open" ? "180" : "0",
            directory.appendingPathComponent("change-" + UUID().uuidString + ".json").path, udid]
        let result = try await CommandRunner.run(([tool] + args).map(shellQuote).joined(separator: " "), timeout: 20)
        try #require(result.exitCode == 0)
    }
}

struct MediaPrepared { let catalogue: DuoCatalogue; let pid: Int32 }
private struct StreamRecord: Decodable {
    let event: String
    let format: String
    let width: Int?
    let height: Int?
    let bytesPerRow: Int?
    let pixelLayout: String?
    let completedFrames: Int?
    let stopReason: String?
}
/// The `--verbose` recording receipt.
private struct MovieReceipt: Decodable {
    let output: String
    let width: Int
    let height: Int
    let acceptedFrames: Int
    let observedContextChanges: Int?
}
