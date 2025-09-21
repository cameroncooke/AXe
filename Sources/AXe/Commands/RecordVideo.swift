import ArgumentParser
import Foundation
import FBSimulatorControl
@preconcurrency import FBControlCore
import AVFoundation

struct RecordVideo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record-video",
        abstract: "Record the simulator display to an MP4 file using H.264 encoding"
    )

    @Option(name: .customLong("udid"), help: "The UDID of the simulator.")
    var simulatorUDID: String

    @Option(help: "Frames per second (1-30, default: 10)")
    var fps: Int = 10

    @Option(help: "Quality factor (1-100) controlling bitrate (default: 80)")
    var quality: Int = 80

    @Option(help: "Scale factor (0.1-1.0, default: 1.0)")
    var scale: Double = 1.0

    @Option(help: "Output MP4 file path. Defaults to axe-video-<timestamp>.mp4 in the current directory.")
    var output: String?

    func validate() throws {
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
        let logger = AxeLogger()
        try await setup(logger: logger)
        try await performGlobalSetup(logger: logger)

        let trimmedUDID = simulatorUDID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUDID.isEmpty else {
            throw CLIError(errorDescription: "Simulator UDID cannot be empty. Use --udid to specify a simulator.")
        }

        let simulatorSet = try await getSimulatorSet(deviceSetPath: nil, logger: logger, reporter: EmptyEventReporter.shared)
        guard let targetSimulator = simulatorSet.allSimulators.first(where: { $0.udid == trimmedUDID }) else {
            throw CLIError(errorDescription: "Simulator with UDID \(trimmedUDID) not found.")
        }

        guard targetSimulator.state == .booted else {
            let stateDescription = FBiOSTargetStateStringFromState(targetSimulator.state)
            throw CLIError(errorDescription: "Simulator \(trimmedUDID) is not booted. Current state: \(stateDescription)")
        }

        let outputURL = try prepareOutputURL()
        FileHandle.standardError.write(Data("Recording simulator \(targetSimulator.udid) to \(outputURL.path)\n".utf8))
        FileHandle.standardError.write(Data("Press Ctrl+C to stop recording\n".utf8))

        let cancellationFlag = CancellationFlag()
        let signalObserver = SignalObserver(signals: [SIGINT, SIGTERM]) {
            Task {
                await cancellationFlag.cancel()
            }
        }
        defer { signalObserver.invalidate() }

        do {
            try await recordVideo(
                simulator: targetSimulator,
                outputURL: outputURL,
                fps: fps,
                quality: quality,
                scale: scale,
                cancellationFlag: cancellationFlag
            )
            FileHandle.standardError.write(Data("Recording saved to \(outputURL.path)\n".utf8))
            print(outputURL.path)
        } catch {
            throw CLIError(errorDescription: "Failed to record video: \(error.localizedDescription)")
        }
    }

    private func recordVideo(
        simulator: FBSimulator,
        outputURL: URL,
        fps: Int,
        quality: Int,
        scale: Double,
        cancellationFlag: CancellationFlag
    ) async throws {
        let initialFrameData = try await VideoFrameUtilities.captureScreenshotData(from: simulator)
        guard let initialImage = VideoFrameUtilities.makeCGImage(from: initialFrameData) else {
            throw CLIError(errorDescription: "Failed to decode simulator screenshot")
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
                    FileHandle.standardError.write(Data(String(format: "Captured %lld frames (%.1f FPS actual)\n", frameCount, actualFPS).utf8))
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
                throw CLIError(errorDescription: "Output path \(baseURL.path) is a directory. Provide a file name or point to a different location.")
            }
            try fileManager.removeItem(at: baseURL)
        }

        return baseURL
    }
}
