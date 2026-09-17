import AXeCore
import Foundation

struct SimulatorApplicationCatalog {
    private static let displayNameOverrides: [String: String] = [
        "com.apple.Preferences": "Settings",
        "com.apple.mobilesafari": "Safari",
        "com.apple.MobileSMS": "Messages",
        "com.apple.mobilenotes": "Notes",
        "com.apple.reminders": "Reminders",
        "com.apple.mobilecal": "Calendar",
        "com.apple.weather": "Weather",
        "com.apple.Maps": "Maps",
        "com.apple.mobilemail": "Mail",
        "com.apple.mobileslideshow": "Photos",
        "com.apple.camera": "Camera",
        "com.apple.mobiletimer": "Clock"
    ]

    static func applications(for simulatorUDID: String) async throws -> [AgentApplication] {
        let result = try await AgentProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["simctl", "listapps", simulatorUDID]
        )
        guard result.status == 0 else {
            throw CLIError(
                errorDescription: "Unable to list applications installed on simulator \(simulatorUDID): \(result.standardError)"
            )
        }

        let propertyList: Any
        do {
            propertyList = try PropertyListSerialization.propertyList(
                from: result.standardOutputData,
                options: [],
                format: nil
            )
        } catch {
            throw CLIError(
                errorDescription: "Unable to parse the simulator application list: \(error.localizedDescription)"
            )
        }

        guard let dictionary = propertyList as? [String: Any] else {
            throw CLIError(errorDescription: "The simulator returned an unexpected application list.")
        }

        var seen = Set<String>()
        return dictionary.compactMap { key, rawMetadata -> AgentApplication? in
            guard let metadata = rawMetadata as? [String: Any] else { return nil }
            let bundleIdentifier = (metadata["CFBundleIdentifier"] as? String) ?? key
            guard !bundleIdentifier.isEmpty, seen.insert(bundleIdentifier).inserted else { return nil }

            let applicationType = (metadata["ApplicationType"] as? String)?.lowercased()
            if applicationType == "hidden" {
                return nil
            }

            let rawName = (metadata["CFBundleDisplayName"] as? String)
                ?? (metadata["CFBundleName"] as? String)
                ?? Self.displayNameOverrides[bundleIdentifier]
                ?? bundleIdentifier.split(separator: ".").last.map(String.init)
                ?? bundleIdentifier
            let name = Self.displayNameOverrides[bundleIdentifier] ?? rawName
            let lowercasedName = name.lowercased()
            if lowercasedName.contains("viewservice")
                || lowercasedName.contains("uiservice")
                || lowercasedName.hasSuffix(" extension")
                || lowercasedName.hasSuffix(" widget") {
                return nil
            }

            return AgentApplication(name: name, bundleIdentifier: bundleIdentifier)
        }
        .sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    static func launch(
        _ application: AgentApplication,
        on simulatorUDID: String
    ) async throws {
        let result = try await AgentProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: [
                "simctl",
                "launch",
                "--terminate-running-process",
                simulatorUDID,
                application.bundleIdentifier,
            ]
        )
        guard result.status == 0 else {
            throw CLIError(
                errorDescription: "Unable to launch \(application.name) (\(application.bundleIdentifier)): \(result.standardError)"
            )
        }
    }
}

private struct AgentProcessResult: Sendable {
    let status: Int32
    let standardOutputData: Data
    let standardErrorData: Data

    var standardError: String {
        String(data: standardErrorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
    }
}

private enum AgentProcess {
    static func run(
        executableURL: URL,
        arguments: [String]
    ) async throws -> AgentProcessResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try process.run()
            // Read stdout while the process is running so a large `simctl listapps` plist cannot
            // fill the pipe and stall the child process. simctl writes only short diagnostics to stderr.
            let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let error = errorPipe.fileHandleForReading.readDataToEndOfFile()
            return AgentProcessResult(
                status: process.terminationStatus,
                standardOutputData: output,
                standardErrorData: error
            )
        }.value
    }
}
