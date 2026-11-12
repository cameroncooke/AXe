import ArgumentParser
import Foundation
import FBSimulatorControl
@preconcurrency import FBControlCore

struct Screenshot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "Save a PNG screenshot and print its path.",
        discussion: """
        Examples:
          axe screenshot --udid <UDID> --output screen.png
          axe screenshot --udid <UDID>
        """
    )

    @Option(help: "UDID of the simulator or physical device.")
    var udid: String

    @Option(help: "PNG file path or existing directory (default: a timestamped name in the current directory).")
    var output: String?

    @Option(name: .customLong("screen-id"), help: "Simulators: capture this screen only if it is active.")
    var screenID: UInt32?

    @Option(name: .customLong("screen-uuid"), help: "That screen's UUID from axe displays; pass both.")
    var screenUUID: String?

    @Option(name: .customLong("expected-boot"),
        help: ArgumentHelp("Selected capture only: reject a different simulator boot identity.", visibility: .hidden))
    var expectedBoot: String?

    @Flag(name: .customLong("verbose"), help: "With --screen-id: print the full capture receipt as JSON.")
    var verbose = false

    func validate() throws {
        guard (screenID == nil) == (screenUUID == nil) else {
            throw ValidationError("Selected screenshot requires both --screen-id and --screen-uuid.")
        }
        if let screenUUID, UUID(uuidString: screenUUID) == nil {
            throw ValidationError("Selected screenshot requires a valid display UUID.")
        }
        if let expectedBoot, screenID == nil || expectedBoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--expected-boot requires selected capture and a nonempty boot identity.")
        }
    }

    @MainActor
    func run() async throws {
        if screenID != nil {
            try await SelectedScreenshotSignals.run { try await capture() }
        } else {
            try await capture()
        }
    }

    @MainActor
    private func capture() async throws {
        let target = try await AutomationTarget.resolve(udid: udid)
        switch target {
        case let .simulator(simulator):
            try await captureSimulator(simulator)
        case let .device(device):
            guard screenID == nil else {
                throw CLIOutputFailure(code: "unsupportedOnDevice",
                    message: "Selected display options are only supported on simulators. Remove them to capture the device screen.")
            }
            try await captureDevice(device)
        }
    }

    @MainActor
    private func captureSimulator(_ targetSimulator: FBSimulator) async throws {
        let trimmedUDID = targetSimulator.udid
        guard targetSimulator.state == .booted else {
            let stateDescription = FBiOSTargetStateStringFromState(targetSimulator.state).rawValue
            throw CLIError(errorDescription: "Simulator \(trimmedUDID) is not booted. Current state: \(stateDescription). Boot it first, for example with xcrun simctl boot \(trimmedUDID).", code: .notBooted)
        }

        if let screenID, let screenUUID, let uuid = UUID(uuidString: screenUUID) {
            let lease = try HIDInputLease.acquire(simulatorUDID: trimmedUDID)
            defer { withExtendedLifetime(lease) {} }
            let capture = try await FBSimulatorSelectedScreenshotCapture.png(for: targetSimulator,
                screenID: screenID, screenUniqueID: uuid, expectedBootIdentity: expectedBoot)
            try Task.checkCancellation()
            let outputURL = try prepareOutputURL(targetName: targetSimulator.name, existingFile: .refuse)
            let receipt = SelectedScreenshotOutput.Receipt(output: outputURL.path,
                width: capture.pixelWidth, height: capture.pixelHeight,
                before: capture.before, after: capture.after, child: capture.child)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let receiptBytes = try encoder.encode(receipt)
            try SelectedScreenshotOutput.publish(capture.png, to: outputURL)
            if verbose { try CLIOutput.writeJSONData(receiptBytes) }
            else { try MediaOutput(path: outputURL.path, pixelWidth: capture.pixelWidth, pixelHeight: capture.pixelHeight).emit() }
            return
        }

        // An existing file is replaced only once the new image is complete.
        let outputURL = try prepareOutputURL(targetName: targetSimulator.name, existingFile: .atomicReplacement)

        let screenshotData: Data
        if let active = try await captureActiveDisplay(of: targetSimulator) {
            screenshotData = active
        } else {
            screenshotData = try await VideoFrameUtilities.captureScreenshotData(from: targetSimulator)
        }

        try screenshotData.write(to: outputURL, options: .atomic)

        try reportSaved(screenshotData, to: outputURL)
    }

    /// The simulator's default screenshot is always the Duo's inner display, which is off and
    /// black while the device is folded (measured on iOS 27.2). A plain screenshot of a Duo
    /// captures the active display instead. When the displays cannot be read, it keeps the
    /// default capture and says so.
    @MainActor
    private func captureActiveDisplay(of simulator: FBSimulator) async throws -> Data? {
        guard OrdinaryBrokerInput.isDuo(simulator) else { return nil }
        var png: Data?
        try await SelectedScreenshotSignals.run {
            // A plain screenshot has always worked beside running input, so a busy or quarantined
            // lease does not stop it. The capture still checks the display before and after.
            let lease = try? HIDInputLease.acquire(simulatorUDID: simulator.udid)
            defer { withExtendedLifetime(lease) {} }
            let discovery: ActivePanelDiscoveryResult
            do {
                discovery = try await DisplayTransition.settledDiscovery(for: simulator)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                FileHandle.standardError.write(Data(
                    "Warning: AXe could not tell which display is active, so this is the inner display, which is black while the device is folded.\n".utf8))
                return
            }
            let panel = discovery.readback.snapshot.activePanel.identity
            png = try await FBSimulatorSelectedScreenshotCapture.png(for: simulator,
                screenID: panel.displayID, screenUniqueID: panel.uniqueID,
                expectedBootIdentity: discovery.bootIdentity).png
        }
        return png
    }

    @MainActor
    private func captureDevice(_ device: CoreDevice) async throws {
        let inspection = try await DeviceInspection.inspect(device)
        guard let directory = inspection.directory else {
            throw inspection.report.failure
        }
        defer { directory.close() }

        guard let coreDeviceVersion = inspection.device.coreDeviceVersion else {
            throw CLIOutputFailure(code: "coreDeviceVersionUnavailable",
                message: "Xcode did not report the CoreDevice version. Check the selected Xcode installation.")
        }
        let screenshotData = try await directory.captureScreenshot(
            deviceIdentifier: inspection.device.identifier, coreDeviceVersion: coreDeviceVersion
        )
        try Task.checkCancellation()
        let targetName = (inspection.device.name ?? "iOS Device")
            .components(separatedBy: CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/")))
            .joined(separator: "-")
        let outputURL = try prepareOutputURL(targetName: targetName, filenamePrefix: "Device Screenshot",
                                             existingFile: .atomicReplacement)
        try screenshotData.write(to: outputURL, options: .atomic)
        try reportSaved(screenshotData, to: outputURL)
    }

    private func reportSaved(_ png: Data, to outputURL: URL) throws {
        if !CLIOutput.isFormatted {
            FileHandle.standardError.write(Data("Screenshot saved to \(outputURL.path)\n".utf8))
        }
        let size = VideoFrameUtilities.pixelSize(of: png)
        try MediaOutput(path: outputURL.path, pixelWidth: size.width, pixelHeight: size.height).emit()
    }

    private enum ExistingFile { case remove, refuse, atomicReplacement }

    private func prepareOutputURL(targetName: String, filenamePrefix: String = "Simulator Screenshot",
                                  existingFile: ExistingFile = .remove) throws -> URL {
        let fileManager = FileManager.default

        func defaultFilename() -> String {
            "\(filenamePrefix) - \(targetName) - \(Self.formatTimestamp(Date())).png"
        }
        let providedPath = output?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPath: String
        if let providedPath, !providedPath.isEmpty {
            resolvedPath = (providedPath as NSString).expandingTildeInPath
        } else {
            resolvedPath = defaultFilename()
        }

        let baseURL: URL
        if resolvedPath.hasPrefix("/") {
            baseURL = URL(fileURLWithPath: resolvedPath)
        } else {
            baseURL = URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent(resolvedPath)
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: baseURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            let directoryURL = baseURL
            if !fileManager.fileExists(atPath: directoryURL.path) {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
            }
            return directoryURL.appendingPathComponent(defaultFilename())
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
            guard existingFile != .refuse else {
                throw CLIError(errorDescription: "Selected screenshot will not replace an existing output file: \(baseURL.path)", code: .outputFailed)
            }
            if existingFile == .remove { try fileManager.removeItem(at: baseURL) }
        }

        return baseURL
    }

    private static func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: date)
    }
}
