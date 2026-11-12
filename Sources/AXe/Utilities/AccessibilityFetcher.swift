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
        recoveryDependencies: AccessibilityRecoveryDependencies = .live,
        keys: Set<FBAXKeys> = accessibilityRequestKeys
    ) async throws -> Data {
        let simulatorSet = try await getSimulatorSet(deviceSetPath: nil, logger: logger, reporter: EmptyEventReporter.shared)
        
        guard let target = simulatorSet.allSimulators.first(where: { $0.udid == simulatorUDID }) else {
            throw CLIError.simulatorNotFound(udid: simulatorUDID)
        }

        if target.osVersion.version.majorVersion >= 27 {
            try await waitingForReadableDisplays(simulatorUDID: simulatorUDID, logger: logger) {
                try requireStartedDisplay(try await FBSimulatorDisplayInfoReader.read(for: target).rows)
            }
        }
        return try await retryingAfterTestManagerRecovery(
            simulatorUDID: simulatorUDID,
            logger: logger,
            dependencies: recoveryDependencies
        ) {
            if let point {
                // The Duo's default display query has no translation object; read on its measured panel.
                let observation = try await measuredDuoObservation(for: target)
                let element: @MainActor (Bool) async throws -> FBAccessibilityElement = { bootstrap in
                    if let observation {
                        return try await target.accessibilityElement(atLogicalPoint: point.cgPoint,
                            observation: observation, bootstrap: bootstrap)
                    }
                    return try await target.accessibilityElement(at: point.cgPoint, bootstrap: bootstrap)
                }
                return try await readingDirectlyFirst(direct: {
                    let handle = try await element(false)
                    defer { handle.close() }
                    return try serializedAccessibilityData(from: handle, keys: keys)
                }, isUsable: { try !isTransientPointFallback(in: $0, at: point) },
                    bootstrapped: { try await fetchAccessibilityInfoJSONData(at: point, keys: keys) { try await element(true) } })
            }
            return try await retryingMissingTranslation(logger: logger) {
                try await readingDirectlyFirst(direct: {
                    let element = try await target.accessibilityElementForFrontmostApplication(bootstrap: false)
                    defer { element.close() }
                    return try serializedAccessibilityData(from: element, keys: keys)
                }, isUsable: containsAccessibilityDescendant,
                    bootstrapped: { try await fetchFrontmostAccessibilityInfoJSONData(from: target, keys: keys) })
            }
        }
    }

    /// Just after boot, once a display has started, the first whole-tree read on the iPhone Duo still
    /// returned "No translation object" while the next one, a second later, returned the tree.
    /// A whole-tree read retries that error every 250 ms for at most 10 s. Point reads are not
    /// retried: for them the error can mean nothing is at the point.
    static func retryingMissingTranslation(
        logger: AxeLogger,
        maximumWait: Duration = .seconds(10),
        pollInterval: Duration = .milliseconds(250),
        clock: ContinuousClock = ContinuousClock(),
        wait: @MainActor (Duration) async throws -> Void = { duration in try await Task.sleep(for: duration) },
        read: @MainActor () async throws -> Data
    ) async throws -> Data {
        let deadline = clock.now.advanced(by: maximumWait)
        while true {
            do {
                return try await read()
            } catch let error as FBAccessibilityError {
                guard case .noTranslationObject = error, clock.now < deadline else { throw error }
                logger.info().log("No translation object for the frontmost application yet; reading again")
                try await wait(pollInterval)
            }
        }
    }

    /// Early in a boot the display report answers while every integrated display still reports
    /// backlight state "unknown" (measured on the iPhone and the Duo; the first known state was
    /// "activeOn"). Any known state passes, so a locked display ("inactiveOn") reads as before; a
    /// report without backlight states is accepted, so devices that omit them read as before.
    static func requireStartedDisplay(_ rows: [FBSimulatorDisplayInfoRow]) throws {
        let integrated = rows.filter(\.integrated)
        guard !integrated.isEmpty else { throw CLIError(errorDescription: "The simulator reported no built-in display.", code: .treeUnavailable) }
        try requireStartedDisplay(backlightStates: integrated.map(\.backlightState))
    }

    static func requireStartedDisplay(backlightStates: [String?]) throws {
        let states = backlightStates.compactMap { $0 }
        guard states.isEmpty || states.contains(where: { $0 != "unknown" }) else {
            throw CLIError(errorDescription: "No built-in display has started yet.", code: .notBooted)
        }
    }

    /// On iOS 27.2 an accessibility read made in the first seconds after boot, before the guest
    /// publishes its displays, left every later read on that simulator returning "No translation
    /// object" until it was rebooted; a first read made once the displays answered worked. A
    /// settled simulator answers the first display read. Otherwise this reads the displays every
    /// 250 ms for at most 60 s before any accessibility request.
    static func waitingForReadableDisplays(
        simulatorUDID: String,
        logger: AxeLogger,
        maximumWait: Duration = .seconds(60),
        pollInterval: Duration = .milliseconds(250),
        clock: ContinuousClock = ContinuousClock(),
        wait: @MainActor (Duration) async throws -> Void = { duration in try await Task.sleep(for: duration) },
        readDisplays: @MainActor () async throws -> Void
    ) async throws {
        let deadline = clock.now.advanced(by: maximumWait)
        var logged = false
        while true {
            do {
                try await readDisplays()
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard clock.now < deadline else {
                    throw CLIError(errorDescription: "Simulator \(simulatorUDID) is still starting: its displays could not be read, so AXe did not read accessibility. Accessibility read this early can stop working until the simulator is rebooted. Wait until `axe displays --udid \(simulatorUDID)` succeeds, then read again.", code: .notBooted)
                }
                if !logged {
                    logger.info().log("Waiting for the simulator displays before preparing accessibility")
                    logged = true
                }
                try await wait(pollInterval)
            }
        }
    }

    /// Simulator runtimes 27 and later need a short-lived accessibility bootstrap (0.15-0.45 s)
    /// only before the first read after boot. Read directly first; an empty tree, a transient
    /// point fallback or a failed read falls back to the bootstrapped reads unchanged.
    static func readingDirectlyFirst(
        direct: @MainActor () async throws -> Data,
        isUsable: (Data) throws -> Bool,
        bootstrapped: @MainActor () async throws -> Data
    ) async throws -> Data {
        do {
            let data = try await direct()
            if (try? isUsable(data)) == true { return data }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Fall through: the bootstrapped read reports its own error.
        }
        try Task.checkCancellation()
        return try await bootstrapped()
    }

    private static func fetchAccessibilityInfoJSONData(
        at point: AccessibilityPoint,
        keys: Set<FBAXKeys>,
        element: @MainActor () async throws -> FBAccessibilityElement
    ) async throws -> Data {
        try await retryingTransientPointFallback(at: point) {
            let accessibilityElement = try await element()
            defer { accessibilityElement.close() }
            return try serializedAccessibilityData(from: accessibilityElement, keys: keys)
        }
    }

    /// Nil for rigid devices, whose default display query already resolves points.
    private static func measuredDuoObservation(for target: FBSimulator) async throws -> FBSimulatorHIDSessionObservation? {
        guard target.device.deviceType?.identifier == "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo" else {
            return nil
        }
        let discovery = try await ActivePanelReader.discoverWithMetadata(for: target)
        let panel = discovery.readback.snapshot.activePanel.identity
        return try await FBSimulatorNativeContextReader(simulator: target, screenID: panel.displayID,
            screenUniqueID: panel.uniqueID).observation()
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
            throw CLIError(errorDescription: "Accessibility element at the requested point could not be serialized.", code: .treeUnavailable)
        }
        return latestData
    }

    private static func fetchFrontmostAccessibilityInfoJSONData(from target: FBSimulator,
                                                                keys: Set<FBAXKeys>) async throws -> Data {
        var latestData: Data?
        for attempt in 0..<5 {
            // IDB's former `accessibilityElements(withNestedFormat:)` API also serialized the
            // frontmost application internally. This explicit handle API preserves that scope.
            let accessibilityElement = try await target.accessibilityElementForFrontmostApplication()
            let data: Data
            do {
                data = try serializedAccessibilityData(from: accessibilityElement, keys: keys)
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
            throw CLIError(errorDescription: "Accessibility hierarchy could not be serialized.", code: .treeUnavailable)
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
            throw CLIError(
                errorDescription: "AXe could not restore accessibility automation for simulator \(simulatorUDID). Restart the simulator and try again.", code: .treeUnavailable
            )
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
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                terminateProcess(process)
                throw error
            }
        }
        if process.isRunning {
            terminateProcess(process)
            throw CLIError(errorDescription: "AXe timed out while restoring accessibility automation.", code: .timeout)
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

    private static func serializedAccessibilityData(from accessibilityElement: FBAccessibilityElement,
                                                    keys: Set<FBAXKeys>) throws -> Data {
        let response = try accessibilityElement.serialize(
            with: FBAccessibilityRequestOptions(
                nestedFormat: true,
                keys: keys
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
            throw CLIError(errorDescription: "AXe received an unsupported accessibility response from the simulator.", code: .treeUnavailable)
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
    nonisolated static let accessibilityOutputKeys: Set<FBAXKeys> = [
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
    nonisolated static let accessibilityRequestKeys = accessibilityOutputKeys.subtracting([.traits])

    /// `describe-ui --minimal-keys`: what UI-test drivers read. Every attribute is one read into the
    /// simulator per element, so leaving the rest out shortens the read (about 20% on Settings).
    nonisolated static let minimalRequestKeys: Set<FBAXKeys> = [
        .label, .frameDict, .value, .uniqueID, .type, .role, .roleDescription, .enabled,
    ]
}
