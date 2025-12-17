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

    func run() async throws {
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

        let outputURL = try prepareOutputURL(simulator: targetSimulator)

        let screenshotData = try await VideoFrameUtilities.captureScreenshotData(from: targetSimulator)

        try screenshotData.write(to: outputURL)

        FileHandle.standardError.write(Data("Screenshot saved to \(outputURL.path)\n".utf8))
        print(outputURL.path)
    }

    private func prepareOutputURL(simulator: FBSimulator) throws -> URL {
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
