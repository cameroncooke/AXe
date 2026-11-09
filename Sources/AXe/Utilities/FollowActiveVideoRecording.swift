import AVFoundation
import Foundation
import FBSimulatorControl
@preconcurrency import FBControlCore

/// One boot and one fixed canvas; each accepted frame has its own measured active display.
@MainActor
enum FollowActiveVideoRecording {
    static func run(simulatorUDID: String, expectedBoot: String?, output: String?,
                    fps: Int, quality: Int, scale: Double) async throws {
        try await SelectedMediaCapture.run { owner in
            try await record(owner: owner, simulatorUDID: simulatorUDID, expectedBoot: expectedBoot,
                output: output, fps: fps, quality: quality, scale: scale)
        }
    }

    private static func record(owner: SelectedMediaCapture, simulatorUDID: String,
                               expectedBoot: String?, output: String?, fps: Int,
                               quality: Int, scale: Double) async throws {
        let udid = simulatorUDID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: udid) != nil else {
            throw CLIError(errorDescription: "Follow-active recording requires a simulator UUID")
        }
        let simulator = try await DeviceState.bootedSimulator(udid: udid, logger: AxeLogger())
        try Task.checkCancellation()
        let destination = try SelectedVideoRecording.outputURL(output)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".axe-follow-video-" + UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let recovery = Recovery()
        log("Recording the measured active display; Ctrl+C stops and saves accepted frames.")
        guard let first = try await recovery.capture(owner: owner, simulator: simulator,
            expectedBoot: expectedBoot) else {
            throw CLIError(errorDescription: "Recording stopped before a complete active-display frame")
        }
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
        var changes: Int64 = 0
        var maximumGap: Double = 0
        try await writer.appendSelected(image: image, presentationTime: .zero, aspectFit: true)
        log("Follow-active recording accepted frames: 1")
        while !owner.stopRequested {
            try Task.checkCancellation()
            let remaining = 1 / Double(fps) - (ProcessInfo.processInfo.systemUptime - lastAccepted)
            if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
            guard !owner.stopRequested else { break }
            guard let frame = try await recovery.capture(owner: owner, simulator: simulator,
                expectedBoot: first.before.observation.bootIdentity) else { break }
            guard let image = VideoFrameUtilities.makeCGImage(from: frame.png) else {
                throw VideoProcessingError.failedToDecodeImage
            }
            let accepted = ProcessInfo.processInfo.systemUptime
            maximumGap = max(maximumGap, accepted - lastAccepted)
            if try frame.before.observation.sessionObservation() != last.after.observation.sessionObservation() {
                changes += 1
            }
            var time = CMTime(seconds: accepted - firstAccepted, preferredTimescale: 600)
            if time <= lastPresentation { time = CMTimeAdd(lastPresentation, CMTime(value: 1, timescale: 600)) }
            try await writer.appendSelected(image: image, presentationTime: time, aspectFit: true)
            lastPresentation = time
            lastAccepted = accepted
            last = frame
            count += 1
            log("Follow-active recording accepted frames: \(count)")
        }
        try Task.checkCancellation()
        try await writer.finishSelected()
        let span = lastAccepted - firstAccepted
        let receipt = Receipt(output: destination.path, width: dimensions.width, height: dimensions.height,
            requestedFPS: fps, acceptedFrames: count, hostAcceptanceSpanSeconds: span,
            achievedFPS: count > 1 && span > 0 ? Double(count - 1) / span : nil,
            observedContextChanges: changes, maximumFrameGapSeconds: maximumGap,
            recoveryAttempts: recovery.attempts, recoveryWaitSeconds: recovery.waitSeconds,
            first: first.before, last: last.after)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(receipt)
        try SelectedVideoRecording.publish(temporary: temporary, destination: destination)
        try CLIOutput.writeJSONData(bytes)
    }

    private struct Receipt: Encodable {
        let source = "appleSimctlActivePNGToH264"
        let followsActiveDisplay = true
        let canvas = "firstFrameAspectFitBlackBars"
        let surfaceIdentity = "unavailable"
        let framePresentationTime = "unavailable"
        let smoothAnimationCapture = false
        let stopReason = "signal"
        let output: String
        let width: Int
        let height: Int
        let requestedFPS: Int
        let acceptedFrames: Int64
        let hostAcceptanceSpanSeconds: Double
        let achievedFPS: Double?
        let observedContextChanges: Int64
        let maximumFrameGapSeconds: Double
        let recoveryAttempts: Int64
        let recoveryWaitSeconds: Double
        let first: FBSimulatorContextReadback
        let last: FBSimulatorContextReadback
    }

    /// Retries read-only acquisition only after a typed, cleaned-up transition or lease refusal.
    /// The window, not an attempt count, bounds recovery: a fold can read as changing for several
    /// seconds, longer than a few 250 ms waits.
    @MainActor
    private final class Recovery {
        static let windowSeconds: Double = 30
        private(set) var attempts: Int64 = 0
        private(set) var waitSeconds: Double = 0

        func capture(owner: SelectedMediaCapture, simulator: FBSimulator,
                     expectedBoot: String?) async throws -> FBSimulatorSelectedScreenshot? {
            var firstFailure: Double?
            while true {
                try Task.checkCancellation()
                guard !owner.stopRequested else { return nil }
                if let firstFailure, ProcessInfo.processInfo.systemUptime - firstFailure >= Self.windowSeconds {
                    throw CLIError(errorDescription: "Active-display transition recovery window expired")
                }
                do {
                    return try await owner.captureActive(simulator: simulator, expectedBoot: expectedBoot)
                } catch {
                    guard !owner.stopRequested, Self.canRecover(error) else { throw error }
                    let now = ProcessInfo.processInfo.systemUptime
                    let started = firstFailure ?? now
                    firstFailure = started
                    guard now - started < Self.windowSeconds else {
                        throw CLIError(errorDescription: "Active-display transition did not settle: \(error)")
                    }
                    attempts += 1
                    log("Waiting for active-display capture after: \(error)")
                    // captureActive has returned and released the common lease before this wait.
                    let waitStarted = ProcessInfo.processInfo.systemUptime
                    try await Task.sleep(nanoseconds: 250_000_000)
                    waitSeconds += ProcessInfo.processInfo.systemUptime - waitStarted
                }
            }
        }

        private static func canRecover(_ error: Error) -> Bool {
            if let failure = error as? SelectedHIDFailure, case .busy = failure { return true }
            if let failure = error as? FBSimulatorContextError, case .changedDuringRead = failure { return true }
            if let failure = error as? FBSimulatorSelectedScreenshotError, case .changedContext = failure { return true }
            if let failure = error as? FBSimulatorHIDSessionError,
               case .interrupted(reason: .staleContext, cleanup: .notNeeded) = failure {
                return true
            }
            // The in-process display-info read launches no child; its receipt has no exit status.
            guard let error = error as? ActivePanelReadError, error.childFailure == nil,
                  let receipt = error.receipt, receipt.exitConfirmed,
                  receipt.terminationStatus == 0 || !receipt.launchAttempted,
                  let validation = error.validationFailure else { return false }
            switch validation {
            case .inactiveSelection, .selectedRotationMismatch: return true
            default: return false
            }
        }
    }

    private static func log(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
