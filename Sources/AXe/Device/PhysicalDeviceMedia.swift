import AVFoundation
import Darwin
import Foundation

@MainActor
enum PhysicalDeviceMedia {
    static func stream(device: CoreDevice, format: StreamVideo.OutputFormat,
                       fps: Int, quality: Int, scale: Double) async throws {
        try await SelectedMediaCapture.run { owner in
            let capture = try await PhysicalDeviceMediaCapture.open(device: device, fps: fps)
            defer { capture.close() }
            try await stream(capture: capture, owner: owner, format: format, fps: fps, quality: quality, scale: scale)
        }
    }

    static func record(device: CoreDevice, output: String?, fps: Int, quality: Int, scale: Double,
                       verbose: Bool) async throws {
        try await SelectedMediaCapture.run { owner in
            let capture = try await PhysicalDeviceMediaCapture.open(device: device, fps: fps)
            defer { capture.close() }
            try await record(capture: capture, owner: owner, output: output, fps: fps, quality: quality, scale: scale,
                verbose: verbose)
        }
    }

    private static func stream(capture: PhysicalDeviceMediaCapture, owner: SelectedMediaCapture,
                               format: StreamVideo.OutputFormat, fps: Int, quality: Int, scale: Double) async throws {
        guard let frame = try await capture.next(untilStop: owner) else { throw noFrames }
        var encoded = try await SelectedStreamFrame.encode(png: frame.png, format: format, scale: scale, quality: quality)
        let width = encoded.width
        let height = encoded.height
        try PhysicalDeviceMediaCapture.requireMatchingAspect(width: width, height: height, display: frame.display)

        let destination = try SelectedStreamOutput(descriptor: STDOUT_FILENO)
        var diagnostics: SelectedStreamOutput?
        do {
            let diagnosticOutput = try SelectedStreamOutput(descriptor: STDERR_FILENO)
            diagnostics = diagnosticOutput
            try await emit(StreamMetadata(format: format.rawValue, width: width, height: height,
                bytesPerRow: format == .bgra ? width * 4 : nil,
                pixelLayout: format == .bgra ? "BGRA-premultiplied-top-to-bottom-packed" : "JPEG",
                requestedFPS: fps), to: diagnosticOutput)

            var count = 0
            var firstWritten: Double?
            var lastWritten: Double?
            while !owner.stopRequested {
                var packet = count == 0 ? SelectedStreamFrame.header(format) : Data()
                packet.append(encoded.bytes)
                guard try await destination.write(packet, stopRequested: { owner.stopRequested }) else { break }
                let now = ProcessInfo.processInfo.systemUptime
                if firstWritten == nil { firstWritten = now }
                lastWritten = now
                count += 1
                _ = try await diagnosticOutput.write(Data("Device stream completed frames: \(count)\n".utf8))
                guard let next = try await capture.next(untilStop: owner) else { break }
                encoded = try await SelectedStreamFrame.encode(png: next.png, format: format, scale: scale, quality: quality)
                guard encoded.width == width, encoded.height == height else {
                    throw PhysicalDeviceMediaCapture.changedDisplay
                }
            }

            try Task.checkCancellation()
            guard let firstWritten, let lastWritten else { throw noFrames }
            _ = try await destination.write(SelectedStreamFrame.trailer(format))
            let span = lastWritten - firstWritten
            try await emit(StreamSummary(format: format.rawValue, completedFrames: count, requestedFPS: fps,
                hostWriteSpanSeconds: span, achievedFPS: rate(count: count, span: span)), to: diagnosticOutput)
            try diagnosticOutput.restore()
            try destination.restore()
        } catch {
            // Attempt both restorations even after a failed packet. The command owns no descriptor.
            var restorationFailed = false
            for output in [diagnostics, destination].compactMap({ $0 }) {
                do { try output.restore() } catch { restorationFailed = true }
            }
            if restorationFailed {
                throw CLIOutputFailure(code: "outputRestoreFailed",
                    message: "The device stream failed and AXe could not restore the output descriptor settings.")
            }
            throw error
        }
    }

    private static func record(capture: PhysicalDeviceMediaCapture, owner: SelectedMediaCapture, output: String?,
                               fps: Int, quality: Int, scale: Double, verbose: Bool) async throws {
        let destination = try SelectedVideoRecording.outputURL(output)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".axe-device-video-" + UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }

        guard let first = try await capture.next(untilStop: owner) else { throw noFrames }
        let image = try recordingImage(first.png)
        try PhysicalDeviceMediaCapture.requireMatchingAspect(width: image.width, height: image.height, display: first.display)
        let size = VideoFrameUtilities.computeDimensions(for: image, scale: scale)
        let recorder = try H264StreamRecorder(outputURL: temporary, width: size.width, height: size.height,
                                               fps: fps, quality: quality)
        defer { recorder.invalidate() }

        var count = 1
        var lastCaptured = first.hostCaptureTime
        var lastPresentation = CMTime.zero
        try await recorder.appendSelected(image: image, presentationTime: .zero)
        RecordVideo.progress("Device recording accepted frames: \(count)")
        while let next = try await capture.next(untilStop: owner) {
            let nextImage = try recordingImage(next.png)
            guard nextImage.width == image.width, nextImage.height == image.height else {
                throw PhysicalDeviceMediaCapture.changedDisplay
            }
            var presentation = CMTime(seconds: next.hostCaptureTime - first.hostCaptureTime, preferredTimescale: 600)
            if presentation <= lastPresentation {
                presentation = CMTimeAdd(lastPresentation, CMTime(value: 1, timescale: 600))
            }
            try await recorder.appendSelected(image: nextImage, presentationTime: presentation)
            lastPresentation = presentation
            lastCaptured = next.hostCaptureTime
            count += 1
            RecordVideo.progress("Device recording accepted frames: \(count)")
        }

        try await recorder.finishSelected()
        let span = lastCaptured - first.hostCaptureTime
        let receipt = RecordingReceipt(output: destination.path, width: size.width, height: size.height,
            requestedFPS: fps, acceptedFrames: count, hostCaptureSpanSeconds: span,
            achievedFPS: rate(count: count, span: span))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let receiptBytes = try encoder.encode(receipt)
        try SelectedVideoRecording.publish(temporary: temporary, destination: destination)
        if verbose { try CLIOutput.writeJSONData(receiptBytes) }
        else {
            try MediaOutput(path: destination.path, pixelWidth: size.width, pixelHeight: size.height,
                frames: Int64(count)).emit()
        }
    }

    private static func recordingImage(_ png: Data) throws -> CGImage {
        guard let image = VideoFrameUtilities.makeCGImage(from: png), image.width > 0, image.height > 0,
              Double(image.width) * Double(image.height) <= 64_000_000 else {
            throw VideoProcessingError.failedToDecodeImage
        }
        return image
    }

    private static func emit(_ value: some Encodable, to output: SelectedStreamOutput) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var bytes = try encoder.encode(value)
        bytes.append(0x0A)
        _ = try await output.write(bytes)
    }

    private static func rate(count: Int, span: Double) -> Double? {
        count > 1 && span > 0 ? Double(count - 1) / span : nil
    }

    private static var noFrames: CLIOutputFailure {
        CLIOutputFailure(code: "noMediaFrames", message: "Device capture stopped before a complete frame.")
    }

    private struct StreamMetadata: Encodable {
        let event = "deviceStreamMetadata"
        let source = "coreDeviceScreenshot"
        let format: String
        let width: Int
        let height: Int
        let bytesPerRow: Int?
        let pixelLayout: String
        let requestedFPS: Int
    }

    private struct StreamSummary: Encodable {
        let event = "deviceStreamComplete"
        let source = "coreDeviceScreenshot"
        let stopReason = "signal"
        let format: String
        let completedFrames: Int
        let requestedFPS: Int
        let hostWriteSpanSeconds: Double
        let achievedFPS: Double?
    }

    /// The `--verbose` receipt. Sizes are pixels.
    private struct RecordingReceipt: Encodable {
        let source = "coreDeviceScreenshotToH264"
        let stopReason = "signal"
        let output: String
        let width: Int
        let height: Int
        let requestedFPS: Int
        let acceptedFrames: Int
        let hostCaptureSpanSeconds: Double
        let achievedFPS: Double?
    }
}
