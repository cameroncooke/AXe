import FBSimulatorControl
import Foundation

/// Pass-through for a bounded read-only description. It changes no read and caches nothing;
/// it only records each full native context read under the current phase, so the cost of
/// repeated reads inside one accessibility acquisition is visible in `AXE_TIMING` output.
final class PhaseTimedFreshnessProvider: FBSimulatorHIDFreshnessProvider, FBSimulatorHIDCleanupIdentityProvider, Sendable {
    private let reader: FBSimulatorNativeContextReader

    init(_ reader: FBSimulatorNativeContextReader) { self.reader = reader }

    func observation() async throws -> FBSimulatorHIDSessionObservation {
        try await PhaseTimer.measureNonisolated("context.read") { try await reader.observation() }
    }

    func cleanupIdentity() async throws -> FBSimulatorHIDCleanupIdentity {
        try await reader.cleanupIdentity()
    }
}
