import Foundation

/// Read-only publication after an agent swipe. Input admission remains separate.
@MainActor
enum AgentPostSwipePublication {
    static let maximumSampleStarts = 3
    static let startWindowSeconds = 3.0
    /// Separates each compared pair of reads after a swipe. Each read takes about 0.3 s, so equal
    /// reads still span about half a second. Agent swipes end at rest, so no fling outlasts the
    /// pair.
    static let pause = Duration.milliseconds(100)

    struct Sample {
        let snapshot: AgentModeSnapshot
        let context: SelectedHIDContext
        let pid: Int32
        let brokerID: UUID
    }

    /// The window bounds new read starts, not completion of an existing native read.
    static func capture(context: SelectedHIDContext, pid: Int32, brokerID: UUID,
                        startedAt: Double, now: () -> Double,
                        maximumStarts: Int,
                        pause: () async throws -> Void,
                        sample: (Double) async throws -> Sample) async throws -> Sample {
        let deadline = startedAt + startWindowSeconds
        var previous: Sample?
        for _ in 0..<maximumStarts {
            try requireMayStart(now: now(), deadline: deadline)
            // The first sample is only a baseline. Every compared pair keeps the pause between them.
            if previous != nil { try await pause() }
            try requireMayStart(now: now(), deadline: deadline)
            let current = try await sample(deadline)
            try Task.checkCancellation()
            guard current.context == context, current.pid == pid, current.brokerID == brokerID else {
                throw AgentModeFailure("postSwipeContextChanged", "The swipe completed, but its observation owner or context changed.")
            }
            if let previous, AgentModeController.canReuseSnapshot(previous.snapshot, with: current.snapshot) {
                return current
            }
            previous = current
        }
        throw unsettled()
    }

    /// Also used between discovery and the native read, which can each suspend.
    static func requireMayStart(now: Double, deadline: Double) throws {
        try Task.checkCancellation()
        guard now < deadline else { throw unsettled() }
    }

    private static func unsettled() -> AgentModeFailure {
        AgentModeFailure("postSwipeSnapshotUnsettled", "The swipe completed, but no stable replacement snapshot was confirmed. Read the screen again; do not replay the swipe.")
    }
}
