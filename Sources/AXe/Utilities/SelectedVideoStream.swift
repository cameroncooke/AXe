import Darwin
import Foundation
import FBSimulatorControl
@preconcurrency import FBControlCore

/// Fixed initial pose. No fallback, retries, or output on stdout except framed media bytes.
@MainActor
enum SelectedVideoStream {
    static func run(simulatorUDID: String, screenID: UInt32, screenUUID: UUID,
                    expectedBoot: String?, format: StreamVideo.OutputFormat,
                    fps: Int, quality: Int, scale: Double) async throws {
        try await SelectedMediaCapture.run { owner in
            try await stream(owner: owner, simulatorUDID: simulatorUDID, screenID: screenID,
                screenUUID: screenUUID, expectedBoot: expectedBoot, format: format,
                fps: fps, quality: quality, scale: scale)
        }
    }

    private static func stream(owner: SelectedMediaCapture, simulatorUDID: String,
                               screenID: UInt32, screenUUID: UUID, expectedBoot: String?,
                               format: StreamVideo.OutputFormat, fps: Int, quality: Int, scale: Double) async throws {
        let logger = AxeLogger(debugLogging: false, writeToStdErr: true)
        try await performGlobalSetup(logger: logger)
        try Task.checkCancellation()
        let udid = simulatorUDID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !udid.isEmpty else { throw CLIError(errorDescription: "Simulator UDID cannot be empty") }
        let set = try await getSimulatorSet(deviceSetPath: nil, logger: logger, reporter: EmptyEventReporter.shared)
        guard let simulator = set.allSimulators.first(where: { $0.udid == udid }), simulator.state == .booted else {
            throw CLIError(errorDescription: "Selected streaming requires the requested booted simulator")
        }
        guard let first = try await owner.capture(simulator: simulator, screenID: screenID,
            screenUUID: screenUUID, expectedBoot: expectedBoot, initial: nil) else {
            throw CLIError(errorDescription: "Stream stopped before a complete selected frame")
        }
        let initial = try first.before.observation.sessionObservation()
        var frame = first
        var encoded = try await SelectedStreamFrame.encode(png: first.png, format: format, scale: scale, quality: quality)
        let width = encoded.width
        let height = encoded.height
        let destination = try SelectedStreamOutput(descriptor: STDOUT_FILENO)
        var diagnostics: SelectedStreamOutput?
        do {
            let diagnosticOutput = try SelectedStreamOutput(descriptor: STDERR_FILENO)
            diagnostics = diagnosticOutput
            try await emit(Metadata(format: format.rawValue, width: width, height: height,
                bytesPerRow: format == .bgra ? width * 4 : nil,
                pixelLayout: format == .bgra ? "BGRA-premultiplied-top-to-bottom-packed" : "JPEG",
                qualityApplied: format != .bgra, requestedFPS: fps, initial: first.before), to: diagnosticOutput)
            var count: Int64 = 0
            var firstWritten: Double?
            var lastWritten: Double?
            var last: FBSimulatorContextReadback?
            while true {
                try Task.checkCancellation()
                guard !owner.stopRequested else { break }
                var packet = count == 0 ? SelectedStreamFrame.header(format) : Data()
                packet.append(encoded.bytes)
                guard try await destination.write(packet, stopRequested: { owner.stopRequested }) else { break }
                let now = ProcessInfo.processInfo.systemUptime
                if firstWritten == nil { firstWritten = now }
                lastWritten = now
                last = frame.after
                count += 1
                _ = try await diagnosticOutput.write(Data("Selected stream completed frames: \(count)\n".utf8))
                guard !owner.stopRequested else { break }
                let remaining = 1 / Double(fps) - (ProcessInfo.processInfo.systemUptime - now)
                if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
                guard !owner.stopRequested else { break }
                guard let next = try await owner.capture(simulator: simulator, screenID: screenID,
                    screenUUID: screenUUID, expectedBoot: initial.bootIdentity, initial: initial) else { break }
                guard next.pixelWidth == first.pixelWidth, next.pixelHeight == first.pixelHeight else {
                    throw FBSimulatorSelectedScreenshotError.wrongDimensions
                }
                let nextEncoded = try await SelectedStreamFrame.encode(png: next.png, format: format, scale: scale, quality: quality)
                guard nextEncoded.width == width, nextEncoded.height == height else {
                    throw FBSimulatorSelectedScreenshotError.wrongDimensions
                }
                frame = next
                encoded = nextEncoded
            }
            try Task.checkCancellation()
            guard count > 0, let firstWritten, let lastWritten, let last else {
                throw CLIError(errorDescription: "Stream stopped before a complete output frame")
            }
            // A trailer is part of successful stream completion. Backpressure or EPIPE fails.
            _ = try await destination.write(SelectedStreamFrame.trailer(format))
            let span = lastWritten - firstWritten
            try await emit(Summary(format: format.rawValue, completedFrames: count, requestedFPS: fps,
                hostWriteSpanSeconds: span, achievedFPS: count > 1 && span > 0 ? Double(count - 1) / span : nil,
                first: first.before, last: last), to: diagnosticOutput)
            // Reverse construction order also restores shared open-file descriptions (2>&1).
            try diagnosticOutput.restore()
            try destination.restore()
        } catch {
            // Restoration is attempted for both descriptors even after output/capture failure.
            // The caller-owned descriptors stay open. No replay and no success summary on this path.
            var restoreErrors: [String] = []
            for output in [diagnostics, destination].compactMap({ $0 }) {
                do { try output.restore() }
                catch { restoreErrors.append(error.localizedDescription) }
            }
            if !restoreErrors.isEmpty {
                throw CLIError(errorDescription: "Selected stream failed: \(error.localizedDescription); descriptor restoration failed: \(restoreErrors.joined(separator: "; "))")
            }
            throw error
        }
    }

    private static func emit<T: Encodable>(_ value: T, to output: SelectedStreamOutput) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(value)
        data.append(0x0a)
        _ = try await output.write(data)
    }

    struct Metadata: Encodable {
        let event = "selectedStreamMetadata"
        let source = "appleSimctlSelectedPNG"
        let surfaceIdentity = "unavailable"
        let framePresentationTime = "unavailable"
        let continuousTransitionCoverage = false
        let format: String
        let width: Int
        let height: Int
        let bytesPerRow: Int?
        let pixelLayout: String
        let qualityApplied: Bool
        let requestedFPS: Int
        let initial: FBSimulatorContextReadback
    }

    struct Summary: Encodable {
        let event = "selectedStreamComplete"
        let stopReason = "signal"
        let continuousTransitionCoverage = false
        let format: String
        let completedFrames: Int64
        let requestedFPS: Int
        let hostWriteSpanSeconds: Double
        let achievedFPS: Double?
        let first: FBSimulatorContextReadback
        let last: FBSimulatorContextReadback
    }
}
