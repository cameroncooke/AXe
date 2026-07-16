import Foundation
import FBControlCore
import Testing
@testable import AXe

@Suite("Accessibility Fetcher Tests")
@MainActor
struct AccessibilityFetcherTests {
    @Test("Serializes nested accessibility arrays without changing their schema")
    func serializesNestedAccessibilityArrays() throws {
        let hierarchy: [[String: Any]] = [
            [
                "AXLabel": "Fixture",
                "type": "Application",
                "frame": ["x": 0, "y": 0, "width": 390, "height": 844],
                "traits": ["Button"],
                "children": [["AXLabel": "Tap Count: 0", "type": "StaticText"]],
            ],
        ]

        let data = try AccessibilityFetcher.serializeAccessibilityInfo(hierarchy)
        let serialized = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let root = try #require(serialized.first)

        #expect(root["AXLabel"] as? String == "Fixture")
        #expect(root["type"] as? String == "Application")
        #expect(root["traits"] as? [String] == ["Button"])
        #expect((root["children"] as? [[String: Any]])?.first?["AXLabel"] as? String == "Tap Count: 0")
        #expect(root["elements"] == nil)
    }

    @Test("Requests the complete legacy accessibility compatibility key set")
    func requestsLegacyAccessibilityCompatibilityKeys() {
        #expect(AccessibilityFetcher.accessibilityOutputKeys == [
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
        ])
        #expect(!AccessibilityFetcher.accessibilityRequestKeys.contains(.traits))
        #expect(
            AccessibilityFetcher.accessibilityRequestKeys.union([.traits])
                == AccessibilityFetcher.accessibilityOutputKeys
        )
    }

    @Test("Defaults unavailable traits recursively without changing non-element dictionaries")
    func defaultsUnavailableTraitsRecursively() throws {
        let hierarchy: [[String: Any]] = [[
            "type": "Application",
            "frame": ["x": 0, "y": 0, "width": 390, "height": 844],
            "children": [["type": "Button", "traits": ["Button"]]],
        ]]

        let compatible = try #require(
            AccessibilityFetcher.addingCompatibilityDefaults(to: hierarchy) as? [[String: Any]]
        )
        let root = try #require(compatible.first)
        let frame = try #require(root["frame"] as? [String: Any])
        let child = try #require((root["children"] as? [[String: Any]])?.first)

        #expect(root["traits"] as? [String] == [])
        #expect(frame["traits"] == nil)
        #expect(child["traits"] as? [String] == ["Button"])
    }

    @Test("Distinguishes transient root-only responses from populated hierarchies")
    func detectsAccessibilityDescendants() throws {
        let rootOnly = try JSONSerialization.data(withJSONObject: [[
            "type": "Application",
            "children": [],
        ]])
        let populated = try JSONSerialization.data(withJSONObject: [[
            "type": "Application",
            "children": [["type": "Button", "children": []]],
        ]])

        #expect(try !AccessibilityFetcher.containsAccessibilityDescendant(in: rootOnly))
        #expect(try AccessibilityFetcher.containsAccessibilityDescendant(in: populated))
    }

    @Test("Serializes point lookup dictionaries without adding a response envelope")
    func serializesPointLookupDictionary() throws {
        let element: [String: Any] = [
            "AXLabel": "Tap Count: 0",
            "AXUniqueId": "tap-count",
            "type": "StaticText",
        ]

        let data = try AccessibilityFetcher.serializeAccessibilityInfo(element)
        let serialized = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(serialized["AXLabel"] as? String == "Tap Count: 0")
        #expect(serialized["AXUniqueId"] as? String == "tap-count")
        #expect(serialized["elements"] == nil)
    }

    @Test("Classifies a screen-sized group as a transient point fallback")
    func classifiesTransientPointFallback() throws {
        let portraitFallback = try JSONSerialization.data(withJSONObject: [
            "type": "Group",
            "role": "AXGroup",
            "frame": ["x": 0, "y": 0, "width": 402, "height": 874],
        ])
        let landscapeFallback = try JSONSerialization.data(withJSONObject: [
            "type": "Group",
            "role": "AXGroup",
            "frame": ["x": 0, "y": 0, "width": 874, "height": 402],
        ])
        let button = try JSONSerialization.data(withJSONObject: [
            "type": "Button",
            "role": "AXButton",
            "frame": ["x": 16, "y": 62, "width": 44, "height": 44],
        ])
        let point = AccessibilityPoint(x: 38, y: 84)

        #expect(try AccessibilityFetcher.isTransientPointFallback(in: portraitFallback, at: point))
        #expect(try AccessibilityFetcher.isTransientPointFallback(in: landscapeFallback, at: point))
        #expect(try !AccessibilityFetcher.isTransientPointFallback(in: button, at: point))
    }

    @Test("Preserves legitimate compact groups returned by point lookup")
    func preservesCompactPointGroup() throws {
        let group = try JSONSerialization.data(withJSONObject: [[
            "type": "Group",
            "role": "AXGroup",
            "frame": ["x": 20, "y": 60, "width": 120, "height": 80],
        ]])

        #expect(try !AccessibilityFetcher.isTransientPointFallback(
            in: group,
            at: AccessibilityPoint(x: 40, y: 80)
        ))
    }

    @Test("Preserves meaningful large groups returned by point lookup")
    func preservesMeaningfulLargePointGroups() throws {
        let point = AccessibilityPoint(x: 40, y: 80)
        let variants: [[String: Any]] = [
            [
                "type": "Group",
                "role": "AXGroup",
                "AXLabel": "Content",
                "frame": ["x": 0, "y": 0, "width": 402, "height": 874],
            ],
            [
                "type": "Group",
                "role": "AXGroup",
                "title": "Content",
                "frame": ["x": 0, "y": 0, "width": 402, "height": 874],
            ],
            [
                "type": "Group",
                "role": "AXGroup",
                "help": "Interactive content",
                "frame": ["x": 0, "y": 0, "width": 402, "height": 874],
            ],
            [
                "type": "Group",
                "role": "AXGroup",
                "custom_actions": ["Activate"],
                "frame": ["x": 0, "y": 0, "width": 402, "height": 874],
            ],
            [
                "type": "Group",
                "role": "AXGroup",
                "frame": ["x": 0, "y": 0, "width": 402, "height": 874],
                "children": [["type": "Button"]],
            ],
            [
                "type": "Group",
                "role": "AXGroup",
                "frame": ["x": 20, "y": 40, "width": 360, "height": 700],
            ],
        ]

        for variant in variants {
            let data = try JSONSerialization.data(withJSONObject: variant)
            #expect(try !AccessibilityFetcher.isTransientPointFallback(in: data, at: point))
        }
    }

    @Test("Retries transient point fallbacks until a target appears")
    func retriesTransientPointFallback() async throws {
        let fallback = try JSONSerialization.data(withJSONObject: [
            "type": "Group",
            "role": "AXGroup",
            "frame": ["x": 0, "y": 0, "width": 402, "height": 874],
        ])
        let button = try JSONSerialization.data(withJSONObject: [
            "type": "Button",
            "role": "AXButton",
            "frame": ["x": 16, "y": 62, "width": 44, "height": 44],
        ])
        var responses = [fallback, button]
        var waits: [Duration] = []

        let result = try await AccessibilityFetcher.retryingTransientPointFallback(
            at: AccessibilityPoint(x: 38, y: 84),
            fetch: { responses.removeFirst() },
            wait: { waits.append($0) }
        )

        #expect(result == button)
        #expect(responses.isEmpty)
        #expect(waits == [.milliseconds(50)])
    }

    @Test("Bounds transient point fallback retries and preserves the final response")
    func boundsTransientPointFallbackRetries() async throws {
        let fallback = try JSONSerialization.data(withJSONObject: [
            "type": "Group",
            "role": "AXGroup",
            "frame": ["x": 0, "y": 0, "width": 402, "height": 874],
        ])
        var fetchCount = 0
        var waitCount = 0

        let result = try await AccessibilityFetcher.retryingTransientPointFallback(
            at: AccessibilityPoint(x: 38, y: 84),
            fetch: {
                fetchCount += 1
                return fallback
            },
            wait: { _ in waitCount += 1 }
        )

        #expect(result == fallback)
        #expect(fetchCount == 5)
        #expect(waitCount == 4)
    }

    @Test("Returns point targets without retrying")
    func returnsPointTargetWithoutRetrying() async throws {
        let button = try JSONSerialization.data(withJSONObject: [
            "type": "Button",
            "role": "AXButton",
            "frame": ["x": 16, "y": 62, "width": 44, "height": 44],
        ])
        var fetchCount = 0

        let result = try await AccessibilityFetcher.retryingTransientPointFallback(
            at: AccessibilityPoint(x: 38, y: 84),
            fetch: {
                fetchCount += 1
                return button
            },
            wait: { _ in Issue.record("A non-fallback target should not wait") }
        )

        #expect(result == button)
        #expect(fetchCount == 1)
    }

    @Test("Rejects accessibility payloads that are not dictionaries or arrays")
    func rejectsInvalidAccessibilityPayload() {
        #expect(throws: CLIError.self) {
            try AccessibilityFetcher.serializeAccessibilityInfo("invalid")
        }
    }

    @Test("Restarts the canonical testmanagerd service with direct simctl arguments")
    func restartsCanonicalTestManagerService() async throws {
        var executableURL: URL?
        var arguments: [String] = []
        var timeout: TimeInterval?
        var waits: [Duration] = []
        let dependencies = AccessibilityRecoveryDependencies(
            runProcess: { receivedURL, receivedArguments, receivedTimeout in
                executableURL = receivedURL
                arguments = receivedArguments
                timeout = receivedTimeout
                return 0
            },
            wait: { duration in waits.append(duration) }
        )

        try await AccessibilityFetcher.recoverTestManagerDaemon(
            simulatorUDID: "TEST-UDID",
            dependencies: dependencies
        )

        #expect(executableURL?.path == "/usr/bin/xcrun")
        #expect(arguments == [
            "simctl",
            "spawn",
            "TEST-UDID",
            "launchctl",
            "kickstart",
            "-k",
            "user/foreground/com.apple.testmanagerd",
        ])
        #expect(timeout == 3)
        #expect(waits == [.milliseconds(250)])
    }

    @Test("Cancelling recovery process polling terminates promptly")
    func cancellationStopsRecoveryProcess() async throws {
        let startedAt = ContinuousClock.now
        let task = Task {
            try await AccessibilityFetcher.runProcess(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["10"],
                timeout: 10
            )
        }

        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(startedAt.duration(to: .now) < .seconds(1))
    }

    @Test("Classifies only confirmed accessibility channel failures as recoverable")
    func classifiesRecoverableChannelFailures() {
        let disconnected = NSError(
            domain: "Accessibility",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Channel disconnected"]
        )
        let fileDescriptorExhaustion = NSError(
            domain: "DTXConnectionServicesErrorDomain",
            code: 24,
            userInfo: nil
        )
        let unrelatedPOSIXError = NSError(domain: NSPOSIXErrorDomain, code: 24)
        let unrelatedDTXError = NSError(domain: "DTXConnectionServicesErrorDomain", code: 7)
        let nearMatch = NSError(
            domain: "Accessibility",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Previous channel disconnected unexpectedly"]
        )
        let normalizedMatch = NSError(
            domain: "Accessibility",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "  CHANNEL\n  DISCONNECTED  "]
        )

        #expect(AccessibilityFetcher.shouldRecoverTestManagerDaemon(from: disconnected))
        #expect(AccessibilityFetcher.shouldRecoverTestManagerDaemon(from: normalizedMatch))
        #expect(AccessibilityFetcher.shouldRecoverTestManagerDaemon(from: fileDescriptorExhaustion))
        #expect(!AccessibilityFetcher.shouldRecoverTestManagerDaemon(from: unrelatedPOSIXError))
        #expect(!AccessibilityFetcher.shouldRecoverTestManagerDaemon(from: unrelatedDTXError))
        #expect(!AccessibilityFetcher.shouldRecoverTestManagerDaemon(from: nearMatch))
    }

    @Test("Recovers and reacquires the frontmost hierarchy once")
    func retriesFrontmostHierarchyOnce() async throws {
        var operationCount = 0
        var recoveryCount = 0
        let dependencies = AccessibilityRecoveryDependencies(
            runProcess: { _, _, _ in
                recoveryCount += 1
                return 0
            },
            wait: { _ in }
        )
        let disconnected = NSError(
            domain: "Accessibility",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Channel disconnected"]
        )

        let result = try await AccessibilityFetcher.retryingAfterTestManagerRecovery(
            simulatorUDID: "TEST-UDID",
            logger: AxeLogger(),
            dependencies: dependencies
        ) {
            operationCount += 1
            if operationCount == 1 {
                throw disconnected
            }
            return "reacquired"
        }

        #expect(result == "reacquired")
        #expect(operationCount == 2)
        #expect(recoveryCount == 1)
    }

    @Test("Does not loop when the retry also disconnects")
    func boundsRecoveryToOneRetry() async {
        var operationCount = 0
        var recoveryCount = 0
        let dependencies = AccessibilityRecoveryDependencies(
            runProcess: { _, _, _ in
                recoveryCount += 1
                return 0
            },
            wait: { _ in }
        )
        let disconnected = NSError(
            domain: "Accessibility",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Channel disconnected"]
        )

        do {
            _ = try await AccessibilityFetcher.retryingAfterTestManagerRecovery(
                simulatorUDID: "TEST-UDID",
                logger: AxeLogger(),
                dependencies: dependencies
            ) {
                operationCount += 1
                throw disconnected
            } as String
            Issue.record("Expected the retry to fail")
        } catch {
            #expect(error.localizedDescription == "Channel disconnected")
        }

        #expect(operationCount == 2)
        #expect(recoveryCount == 1)
    }

    @Test("Preserves unrelated errors without recovery")
    func preservesUnrelatedErrors() async {
        var recoveryCount = 0
        let dependencies = AccessibilityRecoveryDependencies(
            runProcess: { _, _, _ in
                recoveryCount += 1
                return 0
            },
            wait: { _ in }
        )
        let unrelated = NSError(
            domain: "Accessibility",
            code: 99,
            userInfo: [NSLocalizedDescriptionKey: "Unrelated failure"]
        )

        do {
            _ = try await AccessibilityFetcher.retryingAfterTestManagerRecovery(
                simulatorUDID: "TEST-UDID",
                logger: AxeLogger(),
                dependencies: dependencies
            ) {
                throw unrelated
            } as String
            Issue.record("Expected the operation to fail")
        } catch {
            #expect(error.localizedDescription == "Unrelated failure")
        }

        #expect(recoveryCount == 0)
    }
}
