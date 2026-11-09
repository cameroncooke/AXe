import Foundation

/// Holds a read-only service directory for media. It does not take the input broker lease.
@MainActor
final class PhysicalDeviceMediaCapture {
    struct Frame {
        let png: Data
        let display: PhysicalDeviceDisplay
        let hostCaptureTime: Double
    }

    private let directory: DeviceServiceDirectory
    private let deviceIdentifier: String
    private let coreDeviceVersion: String
    private let interval: Duration
    private let clock = ContinuousClock()
    private var previousStart: ContinuousClock.Instant?
    private var initialDisplay: PhysicalDeviceDisplay?

    private init(directory: DeviceServiceDirectory, deviceIdentifier: String,
                 coreDeviceVersion: String, fps: Int) {
        self.directory = directory
        self.deviceIdentifier = deviceIdentifier
        self.coreDeviceVersion = coreDeviceVersion
        self.interval = .seconds(1 / Double(fps))
    }

    static func open(device: CoreDevice, fps: Int) async throws -> PhysicalDeviceMediaCapture {
        guard (1...30).contains(fps) else {
            throw CLIOutputFailure(code: "invalidArguments", message: "Device media FPS must be between 1 and 30.")
        }
        let inspection = try await DeviceInspection.inspect(device)
        guard let directory = inspection.directory else { throw inspection.report.failure }
        guard let version = inspection.device.coreDeviceVersion else {
            directory.close()
            throw CLIOutputFailure(code: "coreDeviceVersionUnavailable",
                message: "Xcode did not report the CoreDevice version.")
        }
        return PhysicalDeviceMediaCapture(directory: directory, deviceIdentifier: inspection.device.identifier,
                                          coreDeviceVersion: version, fps: fps)
    }

    func next(untilStop owner: SelectedMediaCapture) async throws -> Frame? {
        try Task.checkCancellation()
        guard !owner.stopRequested else { return nil }
        if let previousStart { try await clock.sleep(until: previousStart + interval) }
        guard !owner.stopRequested else { return nil }
        let started = clock.now
        previousStart = started
        let deadline = started + .seconds(8)
        func remaining() throws -> TimeInterval {
            let duration = clock.now.duration(to: deadline)
            guard duration > .zero else {
                throw CLIOutputFailure(code: "deviceFrameTimedOut", message: "The physical device frame timed out.")
            }
            return duration.timeInterval
        }

        let before = try await display(timeout: remaining())
        // Upright output needs a resolved interface orientation.
        try before.requireResolvedOrientation()
        guard !owner.stopRequested else { return nil }
        if let initialDisplay, initialDisplay != before { throw Self.changedDisplay }
        let png = try await directory.captureScreenshot(deviceIdentifier: deviceIdentifier,
            coreDeviceVersion: coreDeviceVersion, timeout: remaining())
        guard !owner.stopRequested else { return nil }
        let after = try await display(timeout: remaining())
        guard !owner.stopRequested else { return nil }
        _ = try remaining()
        guard before == after else { throw Self.changedDisplay }
        // An incomplete PNG may still produce a partial ImageIO decode.
        let end: [UInt8] = [0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130]
        guard png.suffix(end.count).elementsEqual(end) else { throw VideoProcessingError.failedToDecodeImage }
        initialDisplay = before
        return Frame(png: png, display: before, hostCaptureTime: ProcessInfo.processInfo.systemUptime)
    }

    func close() { directory.close() }

    static func requireMatchingAspect(width: Int, height: Int, display: PhysicalDeviceDisplay) throws {
        let aspect = try display.width / display.height
        // Scaling rounds both axes down. Allow the resulting one-pixel difference.
        guard abs(Double(width) - Double(height) * aspect) <= max(1, aspect) + 0.000_001 else {
            throw changedDisplay
        }
    }

    static var changedDisplay: CLIOutputFailure {
        CLIOutputFailure(code: "screenChanged",
            message: "The physical device display changed during capture. Start a new capture in the current orientation.")
    }

    private func display(timeout: TimeInterval) async throws -> PhysicalDeviceDisplay {
        try await directory.readDisplay(deviceIdentifier: deviceIdentifier, coreDeviceVersion: coreDeviceVersion,
                                        timeout: timeout)
    }
}
