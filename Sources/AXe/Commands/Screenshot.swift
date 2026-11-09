import ArgumentParser
import Foundation
import FBSimulatorControl
@preconcurrency import FBControlCore

struct Screenshot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "Capture a PNG screenshot from a simulator or physical device."
    )

    @Option(help: "The UDID of the simulator or physical device.")
    var udid: String

    @Option(help: "Output PNG file path. Defaults to a name based on the target and timestamp in the current directory.")
    var output: String?

    @Option(name: .customLong("screen-id"), help: "Capture this measured active display; requires --screen-uuid.")
    var screenID: UInt32?

    @Option(name: .customLong("screen-uuid"), help: "Exact display UUID from axe displays; no retargeting.")
    var screenUUID: String?

    @Option(name: .customLong("expected-boot"),
        help: ArgumentHelp("Selected capture only: reject a different simulator boot identity.", visibility: .hidden))
    var expectedBoot: String?

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
            let stateDescription = FBiOSTargetStateStringFromState(targetSimulator.state)
            throw CLIError(errorDescription: "Simulator \(trimmedUDID) is not booted. Current state: \(stateDescription)")
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
            try CLIOutput.writeJSONData(receiptBytes)
            return
        }

        let outputURL = try prepareOutputURL(targetName: targetSimulator.name)

        let screenshotData = try await VideoFrameUtilities.captureScreenshotData(from: targetSimulator)

        try screenshotData.write(to: outputURL)

        reportSaved(to: outputURL)
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
        reportSaved(to: outputURL)
    }

    private func reportSaved(to outputURL: URL) {
        if !CLIOutput.isFormatted {
            FileHandle.standardError.write(Data("Screenshot saved to \(outputURL.path)\n".utf8))
        }
        CLIOutput.message(outputURL.path)
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
                throw CLIError(errorDescription: "Output path \(baseURL.path) is a directory. Provide a file name or point to a different location.")
            }
            guard existingFile != .refuse else {
                throw CLIError(errorDescription: "Selected screenshot will not replace an existing output file: \(baseURL.path)")
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
