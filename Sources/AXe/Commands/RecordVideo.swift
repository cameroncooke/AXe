import ArgumentParser
import Foundation
import FBSimulatorControl
@preconcurrency import FBControlCore
import AVFoundation

struct RecordVideo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record-video",
        abstract: "Record the screen to an H.264 MP4 file.",
        discussion: """
        Stop with Ctrl+C or SIGTERM; AXe then finishes the file and prints its path. On a simulator, --follow-active-display follows folds and rotations in one movie, and --screen-id with --screen-uuid records one screen and fails if it stops being active.

        Examples:
          axe record-video --udid <UDID> --fps 15 --output recording.mp4
          axe record-video --udid <UDID> --fps 3 --scale 0.5 --output device.mp4
        """
    )

    @Option(name: .customLong("udid"), help: "UDID of the simulator or physical device.")
    var simulatorUDID: String

    @Option(help: "Frames per second, 1 to 30.")
    var fps: Int = 10

    @Option(help: "Encoding quality, 1 to 100; higher uses a higher bitrate.")
    var quality: Int = 80

    @Option(help: "Frame scale factor, 0.1 to 1.")
    var scale: Double = 1.0

    @Option(help: "MP4 file path or existing directory (default: axe-video-<timestamp>.mp4 in the current directory).")
    var output: String?

    @Flag(name: .customLong("follow-active-display"), help: "Simulators: follow screen changes, such as folds and rotations, in one fixed-size video.")
    var followActiveDisplay = false

    @Option(name: .customLong("screen-id"), help: "Simulators: record this screen; fail if it stops being active.")
    var screenID: UInt32?

    @Option(name: .customLong("screen-uuid"), help: "That screen's UUID from axe displays; pass both.")
    var screenUUID: String?

    @Option(name: .customLong("expected-boot"),
        help: ArgumentHelp("Selected or follow-active recording only: reject a different simulator boot identity.", visibility: .hidden))
    var expectedBoot: String?

    @Flag(name: .customLong("verbose"), help: "Print the full recording receipt as JSON (physical devices, --screen-id or --follow-active-display).")
    var verbose = false

    func validate() throws {
        if !AutomationTarget.isPhysicalInputUDID(simulatorUDID) {
            if followActiveDisplay, screenID != nil || screenUUID != nil {
                throw ValidationError("--follow-active-display cannot be combined with --screen-id or --screen-uuid.")
            }
            guard (screenID == nil) == (screenUUID == nil) else {
                throw ValidationError("Selected recording requires both --screen-id and --screen-uuid.")
            }
            if let screenUUID, UUID(uuidString: screenUUID) == nil {
                throw ValidationError("Selected recording requires a valid display UUID.")
            }
            if let expectedBoot, (!followActiveDisplay && screenID == nil) || expectedBoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError("--expected-boot requires selected or follow-active recording and a nonempty boot identity.")
            }
        }

        guard fps >= 1 && fps <= 30 else {
            throw ValidationError("FPS must be between 1 and 30")
        }

        guard quality >= 1 && quality <= 100 else {
            throw ValidationError("Quality must be between 1 and 100")
        }

        guard scale >= 0.1 && scale <= 1.0 else {
            throw ValidationError("Scale must be between 0.1 and 1.0")
        }
    }

    func run() async throws {
        if AutomationTarget.isPhysicalInputUDID(simulatorUDID) {
            guard !followActiveDisplay, screenID == nil, screenUUID == nil, expectedBoot == nil else {
                throw AutomationTarget.unsupportedOnDevice("Physical recording does not accept simulator display, boot, or follow options.")
            }
            guard let device = try await AutomationTarget.physicalDeviceRecord(udid: simulatorUDID) else {
                throw CLIOutputFailure(code: "targetNotFound", message: "Run axe list-devices and choose a physical device UDID.")
            }
            try await PhysicalDeviceMedia.record(device: device, output: output, fps: fps, quality: quality, scale: scale,
                verbose: verbose)
            return
        }

        if followActiveDisplay {
            try await FollowActiveVideoRecording.run(simulatorUDID: simulatorUDID, expectedBoot: expectedBoot,
                output: output, fps: fps, quality: quality, scale: scale, verbose: verbose)
            return
        }
        if let screenID, let screenUUID, let uuid = UUID(uuidString: screenUUID) {
            try await SelectedVideoRecording.run(simulatorUDID: simulatorUDID, screenID: screenID,
                screenUUID: uuid, expectedBoot: expectedBoot, output: output, fps: fps, quality: quality, scale: scale,
                verbose: verbose)
            return
        }

        let logger = AxeLogger()
        try await setup(logger: logger)
        try await performGlobalSetup(logger: logger)

        let trimmedUDID = simulatorUDID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUDID.isEmpty else {
            throw CLIError(errorDescription: "Simulator UDID cannot be empty. Use --udid to specify a simulator.", code: .invalidArguments)
        }

        let simulatorSet = try await getSimulatorSet(deviceSetPath: nil, logger: logger, reporter: EmptyEventReporter.shared)
        guard let targetSimulator = simulatorSet.allSimulators.first(where: { $0.udid == trimmedUDID }) else {
            throw CLIError.simulatorNotFound(udid: trimmedUDID)
        }

        guard targetSimulator.state == .booted else {
            let stateDescription = FBiOSTargetStateStringFromState(targetSimulator.state).rawValue
            throw CLIError(errorDescription: "Simulator \(trimmedUDID) is not booted. Current state: \(stateDescription)", code: .notBooted)
        }

        let outputURL = try prepareOutputURL()
        Self.progress("Recording simulator \(targetSimulator.udid) to \(outputURL.path)")
        Self.progress("Press Ctrl+C to stop recording")

        let cancellationFlag = CancellationFlag()
        let signalObserver = SignalObserver(signals: [SIGINT, SIGTERM]) {
            Task {
                await cancellationFlag.cancel()
            }
        }
        defer { signalObserver.invalidate() }

        do {
            let recorded = try await recordVideo(
                simulator: targetSimulator,
                outputURL: outputURL,
                fps: fps,
                quality: quality,
                scale: scale,
                cancellationFlag: cancellationFlag
            )
            Self.progress("Recording saved to \(outputURL.path)")
            try MediaOutput(path: outputURL.path, pixelWidth: recorded.width, pixelHeight: recorded.height,
                frames: recorded.frames).emit()
        } catch {
            throw CLIError(errorDescription: "Failed to record video: \(error.localizedDescription)", code: .captureFailed)
        }
    }

    private func recordVideo(
        simulator: FBSimulator,
        outputURL: URL,
        fps: Int,
        quality: Int,
        scale: Double,
        cancellationFlag: CancellationFlag
    ) async throws -> (width: Int, height: Int, frames: Int64) {
        let initialFrameData = try await VideoFrameUtilities.captureScreenshotData(from: simulator)
        guard let initialImage = VideoFrameUtilities.makeCGImage(from: initialFrameData) else {
            throw CLIError(errorDescription: "Failed to decode simulator screenshot", code: .captureFailed)
        }

        let dimensions = VideoFrameUtilities.computeDimensions(for: initialImage, scale: scale)
        let recorder = try H264StreamRecorder(
            outputURL: outputURL,
            width: dimensions.width,
            height: dimensions.height,
            fps: fps,
            quality: quality
        )
        defer { recorder.invalidate() }

        let frameInterval = 1.0 / Double(fps)
        var frameCount: Int64 = 1
        var lastLogFrame: Int64 = 0
        let startTime = Date()
        var lastPresentationTime = CMTime.zero

        try recorder.append(image: initialImage, presentationTime: .zero)
        let writerStartTime = Date()

        while true {
            if Task.isCancelled {
                break
            }
            if await cancellationFlag.isCancelled() {
                break
            }

            let frameStart = Date()

            do {
                let frameData = try await VideoFrameUtilities.captureScreenshotData(from: simulator)
                guard let cgImage = VideoFrameUtilities.makeCGImage(from: frameData) else {
                    FileHandle.standardError.write(Data("Unable to decode screenshot frame\n".utf8))
                    continue
                }

                let now = Date()
                var presentationTime = CMTime(seconds: now.timeIntervalSince(writerStartTime), preferredTimescale: 600)
                if presentationTime <= lastPresentationTime {
                    presentationTime = CMTimeAdd(lastPresentationTime, CMTime(value: 1, timescale: 600))
                }

                try recorder.append(image: cgImage, presentationTime: presentationTime)
                lastPresentationTime = presentationTime
                frameCount += 1

                if frameCount - lastLogFrame >= Int64(fps) {
                    lastLogFrame = frameCount
                    let elapsed = Date().timeIntervalSince(startTime)
                    let actualFPS = Double(frameCount) / max(elapsed, 0.0001)
                    Self.progress(String(format: "Captured %lld frames (%.1f FPS actual)", frameCount, actualFPS))
                }
            } catch {
                FileHandle.standardError.write(Data("Error capturing frame: \(error.localizedDescription)\n".utf8))
            }

            let elapsed = Date().timeIntervalSince(frameStart)
            let sleepTime = frameInterval - elapsed
            if sleepTime > 0 {
                try await Task.sleep(nanoseconds: UInt64(sleepTime * 1_000_000_000))
            }
        }

        try await recorder.finish()
        return (dimensions.width, dimensions.height, frameCount)
    }

    /// Progress on stderr in plain mode only, as `screenshot` does; `--output` keeps stderr for errors.
    static func progress(_ text: String) {
        guard !CLIOutput.isFormatted else { return }
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    private func prepareOutputURL() throws -> URL {
        let fileManager = FileManager.default
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let providedPath = output?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPath: String
        if let providedPath, !providedPath.isEmpty {
            resolvedPath = (providedPath as NSString).expandingTildeInPath
        } else {
            resolvedPath = "axe-video-\(formatter.string(from: Date())).mp4"
        }

        let baseURL: URL
        if resolvedPath.hasPrefix("/") {
            baseURL = URL(fileURLWithPath: resolvedPath)
        } else {
            baseURL = URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent(resolvedPath)
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: baseURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            let filename = "axe-video-\(formatter.string(from: Date())).mp4"
            let directoryURL = baseURL
            if !fileManager.fileExists(atPath: directoryURL.path) {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
            }
            return directoryURL.appendingPathComponent(filename)
        }

        let directoryURL = baseURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        }

        if fileManager.fileExists(atPath: baseURL.path) {
            var existingIsDirectory: ObjCBool = false
            fileManager.fileExists(atPath: baseURL.path, isDirectory: &existingIsDirectory)
            if existingIsDirectory.boolValue {
                throw CLIError(errorDescription: "Output path \(baseURL.path) is a directory. Provide a file name or point to a different location.", code: .outputFailed)
            }
            try fileManager.removeItem(at: baseURL)
        }

        return baseURL
    }
}
