import ArgumentParser
import Foundation
import FBSimulatorControl
@preconcurrency import FBControlCore

struct StreamVideo: AsyncParsableCommand {
    enum OutputFormat: String, ExpressibleByArgument {
        case mjpeg
        case raw
        case ffmpeg
        case bgra
    }

    static let configuration = CommandConfiguration(
        commandName: "stream-video",
        abstract: "Stream simulator frames to stdout using screenshot capture"
    )

    @Option(name: .customLong("udid"), help: "The UDID of the simulator.")
    var simulatorUDID: String

    @Option(help: "Output format: mjpeg, raw, ffmpeg, bgra (default: mjpeg)")
    var format: OutputFormat = .mjpeg

    @Option(help: "Frames per second (1-30, default: 10)")
    var fps: Int = 10

    @Option(help: "JPEG quality (1-100, default: 80)")
    var quality: Int = 80

    @Option(help: "Scale factor (0.1-1.0, default: 1.0)")
    var scale: Double = 1.0

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

        let cancellationFlag = CancellationFlag()
        let signalObserver = SignalObserver(signals: [SIGINT, SIGTERM]) {
            Task {
                await cancellationFlag.cancel()
            }
        }
        defer { signalObserver.invalidate() }

        switch format {
        case .bgra:
            try await streamBGRA(to: targetSimulator, cancellationFlag: cancellationFlag)
        default:
            try await streamCompressedFrames(from: targetSimulator, format: format, cancellationFlag: cancellationFlag)
        }
    }

    // MARK: - Screenshot-based streaming

    private func streamCompressedFrames(
        from simulator: FBSimulator,
        format: OutputFormat,
        cancellationFlag: CancellationFlag
    ) async throws {
        FileHandle.standardError.write(Data("Starting screenshot-based video stream from simulator \(simulator.udid)...\n".utf8))
        FileHandle.standardError.write(Data("Format: \(format.rawValue), FPS: \(fps), Quality: \(quality), Scale: \(scale)\n".utf8))
        FileHandle.standardError.write(Data("Press Ctrl+C to stop streaming\n".utf8))

        let frameInterval = 1.0 / Double(fps)
        let mjpegBoundary = "--mjpegstream"
        let destination = FileHandle.standardOutput

        if format == .mjpeg {
            let header = "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=\(mjpegBoundary)\r\n\r\n"
            destination.write(Data(header.utf8))
        }

        var frameCount: UInt64 = 0
        let startTime = Date()

        while true {
            if Task.isCancelled {
                break
            }
            if await cancellationFlag.isCancelled() {
                break
            }

            let frameStartTime = Date()

            do {
                let screenshotData = try await VideoFrameUtilities.captureScreenshotData(from: simulator)
                let processedData = try await VideoFrameUtilities.processJPEGData(screenshotData, scale: scale, quality: quality)

                switch format {
                case .mjpeg:
                    let frameHeader = "\(mjpegBoundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(processedData.count)\r\n\r\n"
                    destination.write(Data(frameHeader.utf8))
                    destination.write(processedData)
                    destination.write(Data("\r\n".utf8))
                case .raw:
                    var length = UInt32(processedData.count).bigEndian
                    destination.write(Data(bytes: &length, count: 4))
                    destination.write(processedData)
                case .ffmpeg:
                    destination.write(processedData)
                case .bgra:
                    break
                }

                frameCount += 1

                if frameCount % UInt64(max(1, fps)) == 0 {
                    let elapsed = Date().timeIntervalSince(startTime)
                    if elapsed > 0 {
                        let actualFPS = Double(frameCount) / elapsed
                        FileHandle.standardError.write(Data(String(format: "Captured %llu frames (%.1f FPS actual)\n", frameCount, actualFPS).utf8))
                    }
                }
            } catch {
                FileHandle.standardError.write(Data("Error capturing frame: \(error.localizedDescription)\n".utf8))
            }

            let elapsed = Date().timeIntervalSince(frameStartTime)
            let sleepTime = frameInterval - elapsed
            if sleepTime > 0 {
                try? await Task.sleep(nanoseconds: UInt64(sleepTime * 1_000_000_000))
            }
        }

        if format == .mjpeg {
            destination.write(Data("\(mjpegBoundary)--\r\n".utf8))
        }

        let elapsed = Date().timeIntervalSince(startTime)
        if frameCount > 0 && elapsed > 0 {
            let avgFPS = Double(frameCount) / elapsed
            FileHandle.standardError.write(Data(String(format: "Streamed %llu frames in %.1f seconds (%.1f FPS average)\n", frameCount, elapsed, avgFPS).utf8))
        }
    }

    // MARK: - Legacy BGRA streaming

    private func streamBGRA(
        to simulator: FBSimulator,
        cancellationFlag: CancellationFlag
    ) async throws {
        FileHandle.standardError.write(Data("Starting BGRA video stream from simulator \(simulator.udid)...\n".utf8))
        FileHandle.standardError.write(Data("Format: bgra, Quality: \(quality), Scale: \(scale)\n".utf8))
        FileHandle.standardError.write(Data("Note: This is raw pixel data. Use ffmpeg to convert:\n".utf8))
        FileHandle.standardError.write(Data("  axe stream-video --format bgra --udid <UDID> | ffmpeg -f rawvideo -pixel_format bgra -video_size WIDTHxHEIGHT -i - output.mp4\n".utf8))
        FileHandle.standardError.write(Data("Press Ctrl+C to stop streaming\n".utf8))

        do {
            let config = FBVideoStreamConfiguration(
                encoding: .BGRA,
                framesPerSecond: nil,
                compressionQuality: NSNumber(value: Double(quality) / 100.0),
                scaleFactor: NSNumber(value: scale),
                avgBitrate: nil,
                keyFrameRate: nil
            )

            let stdoutConsumer = FBFileWriter.syncWriter(withFileDescriptor: STDOUT_FILENO, closeOnEndOfFile: false)
            let videoStreamFuture = simulator.createStream(with: config)
            let videoStream = try await FutureBridge.value(videoStreamFuture)
            let startFuture = videoStream.startStreaming(stdoutConsumer)

            startFuture.onQueue(BridgeQueues.videoStreamQueue, notifyOfCompletion: { future in
                if let error = future.error {
                    FileHandle.standardError.write(Data("Stream initialization error: \(error)\n".utf8))
                }
            })

            try await Task.sleep(nanoseconds: 1_000_000_000)
            FileHandle.standardError.write(Data("BGRA stream is now running...\n".utf8))

            while true {
                if Task.isCancelled {
                    break
                }
                if await cancellationFlag.isCancelled() {
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }

            FileHandle.standardError.write(Data("\nStopping BGRA stream...\n".utf8))
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                BridgeQueues.videoStreamQueue.async {
                    let stopFuture = videoStream.stopStreaming()
                    stopFuture.onQueue(BridgeQueues.videoStreamQueue, notifyOfCompletion: { future in
                        FileHandle.standardError.write(Data("BGRA stream stopped\n".utf8))
                        if let error = future.error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: ())
                        }
                    })
                }
            }
        } catch {
            throw CLIError(errorDescription: "Failed to stream BGRA video: \(error.localizedDescription)")
        }
    }
}
