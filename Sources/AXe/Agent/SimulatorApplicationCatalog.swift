import AXeCore
import Foundation
import FBSimulatorControl

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

    /// Lists installed applications in-process through CoreSimulator (about 10 ms, versus about
    /// 100 ms for spawning `simctl listapps`).
    static func applications(on simulator: FBSimulator) throws -> [AgentApplication] {
        let dictionary: [String: Any]
        do {
            dictionary = try FBSimDeviceWrapper.installedApps(onDevice: device(of: simulator))
        } catch {
            throw CLIError(
                errorDescription: "Unable to list applications installed on simulator \(simulator.udid): \(error.localizedDescription)"
            )
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

    /// Launches an application in-process, bringing it to the foreground without restarting it
    /// when it is already running.
    static func launch(
        _ application: AgentApplication,
        on simulator: FBSimulator
    ) async throws {
        let device = try device(of: simulator)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            FBSimDeviceWrapper.launchApplicationAsync(
                onDevice: device,
                bundleID: application.bundleIdentifier,
                options: [:],
                completionQueue: .main
            ) { error, _ in
                if let error {
                    continuation.resume(
                        throwing: CLIError(
                            errorDescription: "Unable to launch \(application.name) (\(application.bundleIdentifier)): \(error.localizedDescription)"
                        )
                    )
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private static func device(of simulator: FBSimulator) throws -> AnyObject {
        guard let device = simulator.value(forKey: "device") as AnyObject? else {
            throw CLIError(errorDescription: "Simulator \(simulator.udid) does not expose a CoreSimulator device.")
        }
        return device
    }
}
