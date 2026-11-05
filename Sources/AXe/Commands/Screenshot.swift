import ArgumentParser
import Foundation
import FBSimulatorControl
@preconcurrency import FBControlCore

struct Screenshot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "Capture a screenshot from the simulator display and save it as a PNG file"
    )

    @Option(name: .customLong("udid"), help: "The UDID of the simulator.")
    var simulatorUDID: String

    @Option(help: "Output PNG file path. Defaults to 'Simulator Screenshot - <device name> - <timestamp>.png' in the current directory.")
    var output: String?

    @Option(name: .customLong("screen-id"), help: "Capture this measured active display; requires --screen-uuid.")
    var screenID: UInt32?

    @Option(name: .customLong("screen-uuid"), help: "Exact display UUID from list-simulators --displays; no retargeting.")
    var screenUUID: String?

    @Option(name: .customLong("expected-boot"), help: "Selected capture only: reject a different simulator boot identity.")
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
        let logger = AxeLogger()
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

        if let screenID, let screenUUID, let uuid = UUID(uuidString: screenUUID) {
            let lease = try HIDInputLease.acquire(simulatorUDID: trimmedUDID)
            defer { withExtendedLifetime(lease) {} }
            guard let executable = Bundle.main.executableURL else {
                throw CLIError(errorDescription: "Missing executable URL")
            }
            let helper = executable.deletingLastPathComponent().appendingPathComponent("cadisplay-context")
            let capture = try await FBSimulatorSelectedScreenshotCapture.png(for: targetSimulator,
                helperURL: helper, screenID: screenID, screenUniqueID: uuid, expectedBootIdentity: expectedBoot)
            try Task.checkCancellation()
            let outputURL = try prepareOutputURL(simulator: targetSimulator, replaceExisting: false)
            let receipt = SelectedScreenshotOutput.Receipt(output: outputURL.path,
                width: capture.pixelWidth, height: capture.pixelHeight,
                before: capture.before, after: capture.after, child: capture.child)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let receiptBytes = try encoder.encode(receipt)
            try SelectedScreenshotOutput.publish(capture.png, to: outputURL)
            try CLIOutput.writeJSONData(receiptBytes)
            return
        }

        let outputURL = try prepareOutputURL(simulator: targetSimulator)

        let screenshotData = try await VideoFrameUtilities.captureScreenshotData(from: targetSimulator)

        try screenshotData.write(to: outputURL)

        if !CLIOutput.isFormatted {
            FileHandle.standardError.write(Data("Screenshot saved to \(outputURL.path)\n".utf8))
        }
        CLIOutput.message(outputURL.path)
    }

    private func prepareOutputURL(simulator: FBSimulator, replaceExisting: Bool = true) throws -> URL {
        let fileManager = FileManager.default

        let providedPath = output?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPath: String
        if let providedPath, !providedPath.isEmpty {
            resolvedPath = (providedPath as NSString).expandingTildeInPath
        } else {
            let timestamp = Self.formatTimestamp(Date())
            resolvedPath = "Simulator Screenshot - \(simulator.name) - \(timestamp).png"
        }

        let baseURL: URL
        if resolvedPath.hasPrefix("/") {
            baseURL = URL(fileURLWithPath: resolvedPath)
        } else {
            baseURL = URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent(resolvedPath)
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: baseURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            let timestamp = Self.formatTimestamp(Date())
            let filename = "Simulator Screenshot - \(simulator.name) - \(timestamp).png"
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
            guard replaceExisting else {
                throw CLIError(errorDescription: "Selected screenshot will not replace an existing output file: \(baseURL.path)")
            }
            try fileManager.removeItem(at: baseURL)
        }

        return baseURL
    }

    private static func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: date)
    }
}
