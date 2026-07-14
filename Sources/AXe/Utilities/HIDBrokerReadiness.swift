import Darwin
import Foundation
import FBControlCore

extension HIDBroker {
    static func currentBootIdentity(simulatorUDID: String) throws -> HIDBrokerBootIdentity {
        guard let process = FBProcessFetcher().processes(withProcessName: "launchd_sim").first(where: {
            $0.arguments.contains { $0.contains(simulatorUDID) }
        }) else {
            throw CLIError(errorDescription: "Simulator with UDID \(simulatorUDID) has no active launchd_sim process.")
        }

        var processInfo = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.size
        let actualSize = proc_pidinfo(
            process.processIdentifier,
            PROC_PIDTBSDINFO,
            0,
            &processInfo,
            Int32(expectedSize)
        )
        guard actualSize == Int32(expectedSize) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "HID broker proc_pidinfo failed: \(String(cString: strerror(errno)))"
            ])
        }

        return HIDBrokerBootIdentity(
            processIdentifier: process.processIdentifier,
            startSeconds: processInfo.pbi_start_tvsec,
            startMicroseconds: processInfo.pbi_start_tvusec
        )
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
