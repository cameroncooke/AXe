import ArgumentParser
import Foundation
import FBSimulatorControl
@preconcurrency import FBControlCore
#if os(macOS)
import AppKit
#endif

struct StreamVideo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stream-video",
        abstract: "Stream video from a simulator to stdout using screenshot capture",
        discussion: """
        Captures screenshots from a simulator at a specified frame rate and outputs them as a video stream.
        This approach is similar to how browser-based simulator services work.
        
        Supported output formats:
        - mjpeg: Motion JPEG stream (recommended for browser compatibility)
        - raw: Raw JPEG images with boundary markers
        - ffmpeg: Pipe to ffmpeg for encoding (requires ffmpeg installed)
        - bgra: Raw BGRA pixel data (legacy format, not recommended)
        
        Examples:
        # Stream MJPEG at 10 FPS
        axe stream-video --udid <UDID> --fps 10 --format mjpeg > stream.mjpeg
        
        # Pipe to ffmpeg for H264 encoding
        axe stream-video --udid <UDID> --fps 30 --format ffmpeg | \\
          ffmpeg -f image2pipe -framerate 30 -i - -c:v libx264 -preset ultrafast output.mp4
        
        # Stream to a WebSocket server
        axe stream-video --udid <UDID> --fps 15 --format raw | node mjpeg-server.js
        
        # Legacy BGRA format (for compatibility)
        axe stream-video --udid <UDID> --format bgra | \\
          ffmpeg -f rawvideo -pixel_format bgra -video_size 393x852 -i - output.mp4
        """
    )
    
    @Option(name: .customLong("udid"), help: "The UDID of the simulator.")
    var simulatorUDID: String
    
    @Option(help: "Output format: mjpeg, raw, ffmpeg, bgra (default: mjpeg)")
    var format: String = "mjpeg"
    
    @Option(help: "Frames per second (1-30, default: 10)")
    var fps: Int = 10
    
    @Option(help: "JPEG quality (1-100, default: 80)")
    var quality: Int = 80
    
    @Option(help: "Scale factor (0.1-1.0, default: 1.0)")
    var scale: Double = 1.0
    
    func validate() throws {
        // Validate format
        let validFormats = ["mjpeg", "raw", "ffmpeg", "bgra"]
        guard validFormats.contains(format.lowercased()) else {
            throw ValidationError("Invalid format. Must be one of: \(validFormats.joined(separator: ", "))")
        }
        
        // Validate FPS
        guard fps >= 1 && fps <= 30 else {
            throw ValidationError("FPS must be between 1 and 30")
        }
        
        // Validate quality
        guard quality >= 1 && quality <= 100 else {
            throw ValidationError("Quality must be between 1 and 100")
        }
        
        // Validate scale
        guard scale >= 0.1 && scale <= 1.0 else {
            throw ValidationError("Scale must be between 0.1 and 1.0")
        }
    }
    
    func run() async throws {
        let logger = AxeLogger()
        try await setup(logger: logger)
        try await performGlobalSetup(logger: logger)
        
        // Validate UDID is not empty
        guard !simulatorUDID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError(errorDescription: "Simulator UDID cannot be empty. Use --udid to specify a simulator.")
        }
        
        // Get simulator set
        let simulatorSet = try await getSimulatorSet(deviceSetPath: nil, logger: logger, reporter: EmptyEventReporter.shared)
        
        // Find target simulator
        guard let targetSimulator = simulatorSet.allSimulators.first(where: { $0.udid == simulatorUDID }) else {
            throw CLIError(errorDescription: "Simulator with UDID \(simulatorUDID) not found.")
        }
        
        // Ensure simulator is booted
        guard targetSimulator.state == .booted else {
            throw CLIError(errorDescription: "Simulator \(simulatorUDID) is not booted. Current state: \(FBiOSTargetStateStringFromState(targetSimulator.state))")
        }
        
        // Handle legacy BGRA format using the old implementation
        if format.lowercased() == "bgra" {
            try await streamBGRAFormat(targetSimulator: targetSimulator, logger: logger)
            return
        }
        
        // Log to stderr so it doesn't mix with video data on stdout
        FileHandle.standardError.write(Data("Starting screenshot-based video stream from simulator \(targetSimulator.udid)...\n".utf8))
        FileHandle.standardError.write(Data("Format: \(format), FPS: \(fps), Quality: \(quality), Scale: \(scale)\n".utf8))
        FileHandle.standardError.write(Data("Press Ctrl+C to stop streaming\n".utf8))
        
        // Calculate frame interval
        let frameInterval = 1.0 / Double(fps)
        
        // MJPEG boundary for multipart stream
        let mjpegBoundary = "--mjpegstream"
        
        // Start capture loop
        do {
            var frameCount: UInt64 = 0
            let startTime = Date()
            
            // Write MJPEG header if needed
            if format == "mjpeg" {
                let header = "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=\(mjpegBoundary)\r\n\r\n"
                FileHandle.standardOutput.write(Data(header.utf8))
            }
            
            // Set up cancellation handler
            await withTaskCancellationHandler {
                while !Task.isCancelled {
                    let frameStartTime = Date()
                    
                    do {
                        // Take screenshot
                        let screenshotFuture = targetSimulator.takeScreenshot(.JPEG)
                        let screenshotNSData = try await FutureBridge.value(screenshotFuture)
                        let screenshotData = screenshotNSData as Data
                        
                        // Apply scaling if needed
                        let processedData: Data
                        if scale < 1.0 {
                            processedData = try await scaleJPEGData(screenshotData, scale: scale, quality: quality)
                        } else if quality != 80 {
                            // Re-encode with different quality
                            processedData = try await reencodeJPEGData(screenshotData, quality: quality)
                        } else {
                            processedData = screenshotData
                        }
                        
                        // Output based on format
                        switch format {
                        case "mjpeg":
                            // Write MJPEG frame with boundary
                            let frameHeader = "\(mjpegBoundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(processedData.count)\r\n\r\n"
                            FileHandle.standardOutput.write(Data(frameHeader.utf8))
                            FileHandle.standardOutput.write(processedData)
                            FileHandle.standardOutput.write(Data("\r\n".utf8))
                            
                        case "raw":
                            // Write raw JPEG with 4-byte length prefix (big-endian)
                            var length = UInt32(processedData.count).bigEndian
                            FileHandle.standardOutput.write(Data(bytes: &length, count: 4))
                            FileHandle.standardOutput.write(processedData)
                            
                        case "ffmpeg":
                            // Write raw JPEG data for ffmpeg's image2pipe
                            FileHandle.standardOutput.write(processedData)
                            
                        default:
                            break
                        }
                        
                        frameCount += 1
                        
                        // Log progress every second
                        if frameCount % UInt64(fps) == 0 {
                            let elapsed = Date().timeIntervalSince(startTime)
                            let actualFPS = Double(frameCount) / elapsed
                            FileHandle.standardError.write(Data(String(format: "Captured %llu frames (%.1f FPS actual)\n", frameCount, actualFPS).utf8))
                        }
                        
                    } catch {
                        FileHandle.standardError.write(Data("Error capturing frame: \(error.localizedDescription)\n".utf8))
                    }
                    
                    // Calculate time to next frame
                    let frameElapsed = Date().timeIntervalSince(frameStartTime)
                    let sleepTime = frameInterval - frameElapsed
                    
                    if sleepTime > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(sleepTime * 1_000_000_000))
                    }
                }
            } onCancel: {
                FileHandle.standardError.write(Data("\nStopping video stream...\n".utf8))
                
                // Write final boundary for MJPEG
                if format == "mjpeg" {
                    let footer = "\(mjpegBoundary)--\r\n"
                    FileHandle.standardOutput.write(Data(footer.utf8))
                }
                
                let elapsed = Date().timeIntervalSince(startTime)
                let avgFPS = Double(frameCount) / elapsed
                FileHandle.standardError.write(Data(String(format: "Streamed %llu frames in %.1f seconds (%.1f FPS average)\n", frameCount, elapsed, avgFPS).utf8))
            }
            
        } catch {
            throw CLIError(errorDescription: "Failed to stream video: \(error.localizedDescription)")
        }
    }
    
    // Legacy BGRA streaming implementation
    private func streamBGRAFormat(targetSimulator: FBSimulator, logger: AxeLogger) async throws {
        FileHandle.standardError.write(Data("Starting BGRA video stream from simulator \(targetSimulator.udid)...\n".utf8))
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
            let videoStreamFuture = targetSimulator.createStream(with: config)
            let videoStream = try await FutureBridge.value(videoStreamFuture)
            let startFuture = videoStream.startStreaming(stdoutConsumer)
            
            startFuture.onQueue(BridgeQueues.videoStreamQueue, notifyOfCompletion: { future in
                if let error = future.error {
                    FileHandle.standardError.write(Data("Stream initialization error: \(error)\n".utf8))
                }
            })
            
            try await Task.sleep(nanoseconds: 1_000_000_000)
            FileHandle.standardError.write(Data("BGRA stream is now running...\n".utf8))
            
            await withTaskCancellationHandler {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            } onCancel: {
                FileHandle.standardError.write(Data("\nStopping BGRA stream...\n".utf8))
                let semaphore = DispatchSemaphore(value: 0)
                
                BridgeQueues.videoStreamQueue.async {
                    let stopFuture = videoStream.stopStreaming()
                    stopFuture.onQueue(BridgeQueues.videoStreamQueue, notifyOfCompletion: { _ in
                        FileHandle.standardError.write(Data("BGRA stream stopped\n".utf8))
                        semaphore.signal()
                    })
                }
                
                _ = semaphore.wait(timeout: .now() + .seconds(5))
            }
        } catch {
            throw CLIError(errorDescription: "Failed to stream BGRA video: \(error.localizedDescription)")
        }
    }
    
    // Helper function to scale JPEG data
    private func scaleJPEGData(_ data: Data, scale: Double, quality: Int) async throws -> Data {
        #if os(macOS)
        guard let image = NSImage(data: data) else {
            throw CLIError(errorDescription: "Failed to decode JPEG data")
        }
        
        let newSize = NSSize(
            width: image.size.width * scale,
            height: image.size.height * scale
        )
        
        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize))
        newImage.unlockFocus()
        
        guard let tiffData = newImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [NSBitmapImageRep.PropertyKey.compressionFactor: Double(quality) / 100.0]) else {
            throw CLIError(errorDescription: "Failed to re-encode scaled image")
        }
        
        return jpegData
        #else
        // For non-macOS platforms, return original data
        return data
        #endif
    }
    
    // Helper function to re-encode JPEG with different quality
    private func reencodeJPEGData(_ data: Data, quality: Int) async throws -> Data {
        #if os(macOS)
        guard let image = NSImage(data: data),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [NSBitmapImageRep.PropertyKey.compressionFactor: Double(quality) / 100.0]) else {
            throw CLIError(errorDescription: "Failed to re-encode image with new quality")
        }
        
        return jpegData
        #else
        // For non-macOS platforms, return original data
        return data
        #endif
    }
}