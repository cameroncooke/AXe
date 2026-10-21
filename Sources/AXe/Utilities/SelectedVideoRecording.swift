import AVFoundation
import Darwin
import Foundation
import FBSimulatorControl
@preconcurrency import FBControlCore

/// Fixed-pose MP4 encoding and publication; SelectedMediaCapture owns capture lifetime.
@MainActor
enum SelectedVideoRecording {
    static func run(simulatorUDID: String, screenID: UInt32, screenUUID: UUID,
                    expectedBoot: String?, output: String?, fps: Int, quality: Int, scale: Double) async throws {
        try await SelectedMediaCapture.run { owner in
            try await record(owner: owner, simulatorUDID: simulatorUDID, screenID: screenID,
                screenUUID: screenUUID, expectedBoot: expectedBoot, output: output,
                fps: fps, quality: quality, scale: scale)
        }
    }

    private static func record(owner: SelectedMediaCapture, simulatorUDID: String, screenID: UInt32, screenUUID: UUID,
                        expectedBoot: String?, output: String?, fps: Int, quality: Int, scale: Double) async throws {
        let logger = AxeLogger()
        try await performGlobalSetup(logger: logger)
        try Task.checkCancellation()
        let udid = simulatorUDID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !udid.isEmpty else { throw CLIError(errorDescription: "Simulator UDID cannot be empty") }
        let set = try await getSimulatorSet(deviceSetPath: nil, logger: logger, reporter: EmptyEventReporter.shared)
        guard let simulator = set.allSimulators.first(where: { $0.udid == udid }), simulator.state == .booted else {
            throw CLIError(errorDescription: "Selected recording requires the requested booted simulator")
        }
        guard let executable = Bundle.main.executableURL else {
            throw CLIError(errorDescription: "Missing executable URL")
        }
        let helper = executable.deletingLastPathComponent().appendingPathComponent("cadisplay-context")
        let destination = try Self.outputURL(output)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".axe-selected-video-" + UUID().uuidString + ".mp4")
        // No final file exists until successful writer completion and publication.
        defer { try? FileManager.default.removeItem(at: temporary) }
        FileHandle.standardError.write(Data("Recording selected display; Ctrl+C stops and saves accepted frames.\n".utf8))
        guard let first = try await owner.capture(simulator: simulator, helper: helper, screenID: screenID,
            screenUUID: screenUUID, expectedBoot: expectedBoot, initial: nil) else {
            throw CLIError(errorDescription: "Recording stopped before a complete selected frame")
        }
        let initial = try first.before.observation.sessionObservation()
        guard let image = VideoFrameUtilities.makeCGImage(from: first.png) else {
            throw VideoProcessingError.failedToDecodeImage
        }
        let dimensions = VideoFrameUtilities.computeDimensions(for: image, scale: scale)
        let writer = try H264StreamRecorder(outputURL: temporary, width: dimensions.width,
            height: dimensions.height, fps: fps, quality: quality)
        defer { writer.invalidate() }
        let firstAccepted = ProcessInfo.processInfo.systemUptime
        var lastAccepted = firstAccepted
        var lastPresentation = CMTime.zero
        var last = first
        var count: Int64 = 1
        try await writer.appendSelected(image: image, presentationTime: .zero)
        FileHandle.standardError.write(Data("Selected recording accepted frames: \(count)\n".utf8))
        while !owner.stopRequested {
            try Task.checkCancellation()
            let remaining = 1 / Double(fps) - (ProcessInfo.processInfo.systemUptime - lastAccepted)
            if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
            guard !owner.stopRequested else { break }
            guard let frame = try await owner.capture(simulator: simulator, helper: helper, screenID: screenID,
                screenUUID: screenUUID, expectedBoot: initial.bootIdentity, initial: initial) else { break }
            guard frame.pixelWidth == first.pixelWidth, frame.pixelHeight == first.pixelHeight,
                  let image = VideoFrameUtilities.makeCGImage(from: frame.png) else {
                throw FBSimulatorSelectedScreenshotError.wrongDimensions
            }
            lastAccepted = ProcessInfo.processInfo.systemUptime
            var time = CMTime(seconds: lastAccepted - firstAccepted, preferredTimescale: 600)
            if time <= lastPresentation { time = CMTimeAdd(lastPresentation, CMTime(value: 1, timescale: 600)) }
            try await writer.appendSelected(image: image, presentationTime: time)
            lastPresentation = time
            last = frame
            count += 1
            FileHandle.standardError.write(Data("Selected recording accepted frames: \(count)\n".utf8))
        }
        try Task.checkCancellation()
        try await writer.finishSelected()
        let span = lastAccepted - firstAccepted
        let receipt = Receipt(output: destination.path, width: dimensions.width, height: dimensions.height,
            requestedFPS: fps, acceptedFrames: count, hostAcceptanceSpanSeconds: span,
            achievedFPS: count > 1 && span > 0 ? Double(count - 1) / span : nil,
            first: first.before, last: last.after)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(receipt)
        try Self.publish(temporary: temporary, destination: destination)
        print(String(decoding: bytes, as: UTF8.self))
    }

    struct Receipt: Encodable {
        let source = "appleSimctlSelectedPNGToH264"
        let surfaceIdentity = "unavailable"
        let framePresentationTime = "unavailable"
        let continuousTransitionCoverage = false
        let stopReason = "signal"
        let output: String
        let width: Int
        let height: Int
        let requestedFPS: Int
        let acceptedFrames: Int64
        let hostAcceptanceSpanSeconds: Double
        let achievedFPS: Double?
        let first: FBSimulatorContextReadback
        let last: FBSimulatorContextReadback
    }

    /// Hard-link publication cannot replace a raced file or symlink. Caller removes temporary.
    static func publish(temporary: URL, destination: URL) throws {
        try Task.checkCancellation()
        guard temporary.deletingLastPathComponent().standardizedFileURL == destination.deletingLastPathComponent().standardizedFileURL else {
            throw CLIError(errorDescription: "Selected recording temporary must share the output directory")
        }
        guard Darwin.link(temporary.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func outputURL(_ provided: String?) throws -> URL {
        let manager = FileManager.default
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let filename = "axe-video-\(timestamp).mp4"
        let text = provided?.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen: String
        if let text, !text.isEmpty { chosen = text } else { chosen = filename }
        let path = (chosen as NSString).expandingTildeInPath
        var url = path.hasPrefix("/") ? URL(fileURLWithPath: path)
            : URL(fileURLWithPath: manager.currentDirectoryPath).appendingPathComponent(path)
        var directory: ObjCBool = false
        if manager.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue {
            url.appendPathComponent(filename)
        }
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var info = stat()
        if lstat(url.path, &info) == 0 { throw CLIError(errorDescription: "Selected recording will not replace an existing output") }
        guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return url
    }
}
