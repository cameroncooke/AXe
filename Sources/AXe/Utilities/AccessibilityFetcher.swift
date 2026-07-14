import Foundation
import FBControlCore
import FBSimulatorControl

struct AccessibilityRecoveryDependencies {
    typealias ProcessRunner = @MainActor (
        _ executableURL: URL,
        _ arguments: [String],
        _ timeout: TimeInterval
    ) async throws -> Int32
    typealias Waiter = @MainActor (_ duration: Duration) async throws -> Void

    let runProcess: ProcessRunner
    let wait: Waiter

    static let live = AccessibilityRecoveryDependencies(
        runProcess: AccessibilityFetcher.runProcess,
        wait: { duration in try await Task.sleep(for: duration) }
    )
}

struct AccessibilityPoint: Equatable {
    let x: Double
    let y: Double

    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}

// MARK: - Accessibility Fetcher
@MainActor
struct AccessibilityFetcher {
    static func fetchAccessibilityInfoJSONData(
        for simulatorUDID: String,
        point: AccessibilityPoint? = nil,
        logger: AxeLogger,
        recoveryDependencies: AccessibilityRecoveryDependencies = .live
    ) async throws -> Data {
        let simulatorSet = try await getSimulatorSet(deviceSetPath: nil, logger: logger, reporter: EmptyEventReporter.shared)
        
        guard let target = simulatorSet.allSimulators.first(where: { $0.udid == simulatorUDID }) else {
            throw CLIError(errorDescription: "Simulator with UDID \(simulatorUDID) not found in set.")
        }

        return try await retryingAfterTestManagerRecovery(
            simulatorUDID: simulatorUDID,
            logger: logger,
            dependencies: recoveryDependencies
        ) {
            if let point {
                let accessibilityElement = try await target.accessibilityElement(at: point.cgPoint)
                defer { accessibilityElement.close() }
                return try serializedAccessibilityData(from: accessibilityElement)
            }
            return try await fetchFrontmostAccessibilityInfoJSONData(from: target)
        }
    }

    private static func fetchFrontmostAccessibilityInfoJSONData(from target: FBSimulator) async throws -> Data {
        var latestData: Data?
        for attempt in 0..<5 {
            let accessibilityElement = try await target.accessibilityElementForFrontmostApplication()
            let data: Data
            do {
                data = try serializedAccessibilityData(from: accessibilityElement)
                accessibilityElement.close()
            } catch {
                accessibilityElement.close()
                throw error
            }
            latestData = data
            if try containsAccessibilityDescendant(in: data) {
                return data
            }
            if attempt < 4 {
                try await Task.sleep(for: .milliseconds(50 * (1 << attempt)))
            }
        }
        guard let latestData else {
            throw CLIError(errorDescription: "Accessibility hierarchy could not be serialized.")
        }
        return latestData
    }

    static func retryingAfterTestManagerRecovery<T>(
        simulatorUDID: String,
        logger: AxeLogger,
        dependencies: AccessibilityRecoveryDependencies,
        operation: @MainActor () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch {
            guard shouldRecoverTestManagerDaemon(from: error) else {
                throw error
            }
            logger.info().log("Accessibility transport failed; restarting testmanagerd and retrying once")
            try await recoverTestManagerDaemon(
                simulatorUDID: simulatorUDID,
                dependencies: dependencies
            )
            return try await operation()
        }
    }

    static func shouldRecoverTestManagerDaemon(from error: Error) -> Bool {
        let errors = errorChain(from: error)
        let details = errors.flatMap { error in
            [
                error.domain,
                error.localizedDescription,
                error.localizedFailureReason,
                error.localizedRecoverySuggestion,
                error.userInfo[NSDebugDescriptionErrorKey] as? String,
            ].compactMap { $0?.lowercased() }
        }
        if details.contains(where: { normalizedErrorText($0) == "channel disconnected" }) {
            return true
        }
        let identifiesDTX = details.contains(where: { $0.contains("dtx") })
        let identifiesFileDescriptorExhaustion = errors.contains { error in
            error.code == 24
                || error.localizedDescription.localizedCaseInsensitiveContains("errno 24")
                || error.localizedDescription.localizedCaseInsensitiveContains("too many open files")
        }
        return identifiesDTX && identifiesFileDescriptorExhaustion
    }

    private static func normalizedErrorText(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func recoverTestManagerDaemon(
        simulatorUDID: String,
        dependencies: AccessibilityRecoveryDependencies
    ) async throws {
        let arguments = [
            "simctl",
            "spawn",
            simulatorUDID,
            "launchctl",
            "kickstart",
            "-k",
            "user/foreground/com.apple.testmanagerd",
        ]
        let status = try await dependencies.runProcess(
            URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments,
            3
        )
        guard status == 0 else {
            throw CLIError(errorDescription: "Could not restart testmanagerd for simulator \(simulatorUDID) (simctl exited with status \(status)).")
        }
        try await dependencies.wait(.milliseconds(250))
    }

    private static func errorChain(from error: Error) -> [NSError] {
        var errors: [NSError] = []
        var current: NSError? = error as NSError
        var visited: Set<ObjectIdentifier> = []
        while let next = current, visited.insert(ObjectIdentifier(next)).inserted {
            errors.append(next)
            current = next.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return errors
    }

    static func runProcess(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> Int32 {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning, Date() < terminationDeadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            throw CLIError(errorDescription: "Timed out waiting for \(executableURL.path) to finish.")
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func serializedAccessibilityData(from accessibilityElement: FBAccessibilityElement) throws -> Data {
        let response = try accessibilityElement.serialize(
            with: FBAccessibilityRequestOptions(
                nestedFormat: true,
                keys: accessibilityRequestKeys
            )
        )
        return try serializeAccessibilityInfo(addingCompatibilityDefaults(to: response.elements))
    }

    static func containsAccessibilityDescendant(in data: Data) throws -> Bool {
        let object = try JSONSerialization.jsonObject(with: data)
        let roots: [[String: Any]]
        if let array = object as? [[String: Any]] {
            roots = array
        } else if let root = object as? [String: Any] {
            roots = [root]
        } else {
            return false
        }
        return roots.contains { root in
            guard let children = root["children"] as? [Any] else { return false }
            return !children.isEmpty
        }
    }

    static func fetchAccessibilityElements(for simulatorUDID: String, logger: AxeLogger) async throws -> [AccessibilityElement] {
        let jsonData = try await fetchAccessibilityInfoJSONData(for: simulatorUDID, point: nil, logger: logger)
        let decoder = JSONDecoder()
        
        if let roots = try? decoder.decode([AccessibilityElement].self, from: jsonData) {
            return roots
        }
        
        let root = try decoder.decode(AccessibilityElement.self, from: jsonData)
        return [root]
    }

    static func serializeAccessibilityInfo(_ accessibilityInfo: Any) throws -> Data {
        guard accessibilityInfo is [String: Any] || accessibilityInfo is [[String: Any]] else {
            throw CLIError(errorDescription: "Accessibility info was not a dictionary or array as expected.")
        }
        return try JSONSerialization.data(withJSONObject: accessibilityInfo, options: [.prettyPrinted])
    }

    static func addingCompatibilityDefaults(to accessibilityInfo: Any) -> Any {
        if let elements = accessibilityInfo as? [Any] {
            return elements.map(addingCompatibilityDefaults)
        }
        guard var element = accessibilityInfo as? [String: Any] else {
            return accessibilityInfo
        }
        for (key, value) in element {
            element[key] = addingCompatibilityDefaults(to: value)
        }
        if element["type"] != nil, element["traits"] == nil {
            element["traits"] = [String]()
        }
        return element
    }

    // This key set preserves AXe's legacy public JSON schema; update it only with explicit schema coverage.
    static let accessibilityOutputKeys: Set<FBAXKeys> = [
        .label,
        .frame,
        .value,
        .uniqueID,
        .type,
        .title,
        .frameDict,
        .help,
        .enabled,
        .customActions,
        .role,
        .roleDescription,
        .subrole,
        .contentRequired,
        .pid,
        .traits,
    ]

    // Xcode 27's private nested serializer returns an empty hierarchy when `.traits` is requested.
    // Preserve the public schema by defaulting the missing field after requesting the safe subset.
    static let accessibilityRequestKeys = accessibilityOutputKeys.subtracting([.traits])
}
