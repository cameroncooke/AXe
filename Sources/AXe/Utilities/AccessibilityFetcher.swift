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
            throw CLIError.simulatorNotFound(udid: simulatorUDID)
        }

        return try await retryingAfterAccessibilityRecovery(
            simulatorUDID: simulatorUDID,
            logger: logger,
            dependencies: recoveryDependencies,
            allowsCoreSimulatorBridgeRecovery: point == nil
        ) {
            if let point {
                return try await fetchAccessibilityInfoJSONData(from: target, at: point)
            }
            return try await fetchFrontmostAccessibilityInfoJSONData(from: target)
        }
    }

    private static func fetchAccessibilityInfoJSONData(
        from target: FBSimulator,
        at point: AccessibilityPoint
    ) async throws -> Data {
        try await retryingTransientPointFallback(at: point) {
            let accessibilityElement = try await target.accessibilityElement(at: point.cgPoint)
            defer { accessibilityElement.close() }
            return try serializedAccessibilityData(from: accessibilityElement)
        }
    }

    static func retryingTransientPointFallback(
        at point: AccessibilityPoint,
        maximumAttempts: Int = 5,
        fetch: @MainActor () async throws -> Data,
        wait: @MainActor (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) async throws -> Data {
        precondition(maximumAttempts > 0)
        var latestData: Data?
        for attempt in 0..<maximumAttempts {
            let data = try await fetch()
            latestData = data
            if try !isTransientPointFallback(in: data, at: point) {
                return data
            }
            if attempt < maximumAttempts - 1 {
                try await wait(.milliseconds(50 * (1 << attempt)))
            }
        }
        guard let latestData else {
            throw CLIError(errorDescription: "Accessibility element at the requested point could not be serialized.")
        }
        return latestData
    }

    private static func fetchFrontmostAccessibilityInfoJSONData(from target: FBSimulator) async throws -> Data {
        var latestData: Data?
        for attempt in 0..<5 {
            // IDB's former `accessibilityElements(withNestedFormat:)` API also serialized the
            // frontmost application internally. This explicit handle API preserves that scope.
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
            throw CLIError(
                errorDescription: "AXe could not restore accessibility automation for simulator \(simulatorUDID). Restart the simulator and try again."
            )
        }
        try await dependencies.wait(.milliseconds(250))
    }

    static func errorChain(from error: Error) -> [NSError] {
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
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                terminateProcess(process)
                throw error
            }
        }
        if process.isRunning {
            terminateProcess(process)
            throw CLIError(errorDescription: "AXe timed out while restoring accessibility automation.")
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func terminateProcess(_ process: Process) {
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(0.5)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
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

    static func isTransientPointFallback(in data: Data, at point: AccessibilityPoint) throws -> Bool {
        let object = try JSONSerialization.jsonObject(with: data)
        let root: [String: Any]?
        if let dictionary = object as? [String: Any] {
            root = dictionary
        } else if let dictionaries = object as? [[String: Any]], dictionaries.count == 1 {
            root = dictionaries.first
        } else {
            root = nil
        }
        let meaningfulKeys = [
            "AXLabel",
            "AXUniqueId",
            "AXIdentifier",
            "AXValue",
            "title",
            "help",
            "custom_actions",
            "children",
        ]
        guard let root,
              !meaningfulKeys.contains(where: { hasMeaningfulValue(root[$0]) }) else {
            return false
        }

        let decoder = JSONDecoder()
        let element: AccessibilityElement
        if let decoded = try? decoder.decode(AccessibilityElement.self, from: data) {
            element = decoded
        } else if let decoded = try? decoder.decode([AccessibilityElement].self, from: data),
                  let first = decoded.first,
                  decoded.count == 1 {
            element = first
        } else {
            return false
        }

        guard element.type == "Group",
              element.role == "AXGroup",
              element.normalizedLabel == nil,
              element.normalizedUniqueId == nil,
              element.normalizedValue == nil,
              element.children?.isEmpty != false,
              let frame = element.frame,
              abs(frame.x) < 1,
              abs(frame.y) < 1 else {
            return false
        }
        let containsPoint = point.x >= frame.x
            && point.x <= frame.x + frame.width
            && point.y >= frame.y
            && point.y <= frame.y + frame.height
        return containsPoint
            && min(frame.width, frame.height) >= 300
            && max(frame.width, frame.height) >= 600
    }

    private static func hasMeaningfulValue(_ value: Any?) -> Bool {
        switch value {
        case nil, is NSNull:
            return false
        case let string as String:
            return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case let array as [Any]:
            return !array.isEmpty
        case let dictionary as [String: Any]:
            return !dictionary.isEmpty
        default:
            return true
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
            throw CLIError(errorDescription: "AXe received an unsupported accessibility response from the simulator.")
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

    // AXe's former IDB serializer did not return traits. Xcode 27's private nested serializer also
    // returns an empty hierarchy when `.traits` is requested, so retain the existing public value
    // as an empty compatibility placeholder after requesting the safe subset on every Xcode version.
    static let accessibilityRequestKeys = accessibilityOutputKeys.subtracting([.traits])
}
