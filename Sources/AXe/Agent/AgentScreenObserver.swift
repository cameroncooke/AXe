import AXeCore
import Foundation
import FBControlCore
import FBSimulatorControl

@MainActor
final class AgentScreenObserver {
    enum HandlePolicy {
        /// Acquire a new frontmost-application handle (~110 ms). Use after actions that may change the frontmost app.
        case refresh
        /// Re-serialize the cached handle (~130 ms total). An empty result means another app is
        /// frontmost, which falls back to a refresh.
        case reuse
    }

    /// Attributes rs/1 needs. Serialization cost scales with requested attributes: on a Calendar
    /// screen these take ~130 ms, against ~205 ms with role_description, subrole and help, which rs/1
    /// can derive from `type` and `role` or use only as label fallbacks.
    static let requestKeys: Set<FBAXKeys> = [
        .label, .value, .uniqueID, .type, .frameDict, .enabled, .customActions, .role, .title,
    ]

    let simulatorUDID: String
    let logger: AxeLogger
    private var simulator: FBSimulator?
    private var handle: FBAccessibilityElement?
    /// Raw hierarchy of the most recent observation, used for coordinate mapping.
    private(set) var latestRoots: [AccessibilityElement] = []

    init(simulatorUDID: String, logger: AxeLogger) {
        self.simulatorUDID = simulatorUDID
        self.logger = logger
    }

    func observe(
        currentApplication: AgentApplication?,
        handle policy: HandlePolicy = .refresh
    ) async throws -> AgentScreenSnapshot {
        let roots = try await fetchRoots(policy)
        latestRoots = roots

        let elements = RuntimeSnapshotBuilder.elements(from: roots.map(Self.snapshotNode))
        let applicationName = currentApplication?.name
            ?? elements.first(where: { $0.role == .application })?.label

        return AgentScreenSnapshot(
            applicationName: applicationName,
            bundleIdentifier: currentApplication?.bundleIdentifier,
            elements: elements
        )
    }

    func target() async throws -> FBSimulator {
        if let simulator {
            return simulator
        }
        let simulator = try await DeviceState.bootedSimulator(udid: simulatorUDID, logger: logger)
        self.simulator = simulator
        return simulator
    }

    func close() {
        handle?.close()
        handle = nil
    }

    private func fetchRoots(_ policy: HandlePolicy) async throws -> [AccessibilityElement] {
        do {
            return try await AccessibilityFetcher.retryingAfterTestManagerRecovery(
                simulatorUDID: simulatorUDID,
                logger: logger,
                dependencies: .live
            ) {
                if policy == .reuse, let handle, let roots = try Self.populatedRoots(from: handle) {
                    return roots
                }
                for attempt in 0..<5 {
                    close()
                    let acquired = try await target().accessibilityElementForFrontmostApplication()
                    handle = acquired
                    if let roots = try Self.populatedRoots(from: acquired) {
                        return roots
                    }
                    if attempt < 4 {
                        try await Task.sleep(for: .milliseconds(50 * (1 << attempt)))
                    }
                }
                throw CLIError(errorDescription: "The frontmost application returned an empty accessibility hierarchy.")
            }
        } catch {
            close()
            throw error
        }
    }

    /// Serializes a handle, returning nil when it has no descendants (for example, a handle whose
    /// application is no longer frontmost).
    private static func populatedRoots(from handle: FBAccessibilityElement) throws -> [AccessibilityElement]? {
        let response = try handle.serialize(
            with: FBAccessibilityRequestOptions(
                nestedFormat: true,
                keys: requestKeys
            )
        )
        let data = try JSONSerialization.data(withJSONObject: response.elements)
        let decoder = JSONDecoder()
        let roots: [AccessibilityElement]
        if let array = try? decoder.decode([AccessibilityElement].self, from: data) {
            roots = array
        } else {
            roots = [try decoder.decode(AccessibilityElement.self, from: data)]
        }
        return roots.contains(where: { !($0.children ?? []).isEmpty }) ? roots : nil
    }

    private static func snapshotNode(_ element: AccessibilityElement) -> RuntimeSnapshotNode {
        RuntimeSnapshotNode(
            type: element.type,
            role: element.role,
            subrole: element.subrole,
            roleDescription: element.roleDescription,
            label: [element.AXLabel, element.title, element.help]
                .lazy
                .compactMap(RuntimeSnapshotBuilder.normalizedText)
                .first,
            value: element.AXValue,
            identifier: [element.AXUniqueId, element.AXIdentifier]
                .lazy
                .compactMap(RuntimeSnapshotBuilder.normalizedText)
                .first,
            frame: element.frame.map {
                AgentFrame(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
            },
            enabled: element.enabled,
            customActions: element.customActions ?? [],
            children: (element.children ?? []).map(snapshotNode)
        )
    }
}
