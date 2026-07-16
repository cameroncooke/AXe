import Darwin
import Foundation
import FBControlCore

extension HIDBroker {
    static func currentBootIdentity(simulatorUDID: String) throws -> HIDBrokerBootIdentity {
        let processes = FBProcessFetcher().processes(withProcessName: "launchd_sim").filter {
            $0.arguments.contains { $0.contains(simulatorUDID) }
        }
        let identities = processes.compactMap { bootIdentity(processIdentifier: $0.processIdentifier) }
        guard let identity = newestBootIdentity(identities) else {
            throw CLIError(
                errorDescription: "Simulator \(simulatorUDID) is not ready for input. Wait for it to finish booting and try again."
            )
        }

        return identity
    }

    private static func bootIdentity(processIdentifier: pid_t) -> HIDBrokerBootIdentity? {
        var processInfo = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.size
        let actualSize = proc_pidinfo(
            processIdentifier,
            PROC_PIDTBSDINFO,
            0,
            &processInfo,
            Int32(expectedSize)
        )
        guard actualSize == Int32(expectedSize) else { return nil }

        return HIDBrokerBootIdentity(
            processIdentifier: processIdentifier,
            startSeconds: processInfo.pbi_start_tvsec,
            startMicroseconds: processInfo.pbi_start_tvusec
        )
    }

    static func newestBootIdentity(_ identities: [HIDBrokerBootIdentity]) -> HIDBrokerBootIdentity? {
        identities.max { lhs, rhs in
            if lhs.startSeconds != rhs.startSeconds {
                return lhs.startSeconds < rhs.startSeconds
            }
            if lhs.startMicroseconds != rhs.startMicroseconds {
                return lhs.startMicroseconds < rhs.startMicroseconds
            }
            return lhs.processIdentifier < rhs.processIdentifier
        }
    }

    static func dtuhidReadinessDelay(
        bootIdentity: HIDBrokerBootIdentity,
        now: Date,
        minimumUptime: TimeInterval = dtuhidMinimumBootUptime
    ) -> TimeInterval {
        let startTime = TimeInterval(bootIdentity.startSeconds)
            + (TimeInterval(bootIdentity.startMicroseconds) / 1_000_000)
        let uptime = max(0, now.timeIntervalSince1970 - startTime)
        return max(0, minimumUptime - uptime)
    }

    static func waitForHIDReadiness(
        bootIdentity: HIDBrokerBootIdentity,
        isDTUHIDSelected: Bool,
        now: () -> Date,
        sleep: (TimeInterval) async throws -> Void
    ) async throws {
        guard isDTUHIDSelected else {
            return
        }
        let delay = dtuhidReadinessDelay(bootIdentity: bootIdentity, now: now())
        guard delay > 0 else {
            return
        }
        try await sleep(delay)
    }

    static func shouldReuseSession(
        sessionBootIdentity: HIDBrokerBootIdentity,
        currentBootIdentity: HIDBrokerBootIdentity
    ) -> Bool {
        sessionBootIdentity == currentBootIdentity
    }
}
