import Foundation
import Testing
@testable import AXe

@Suite("HID Broker Readiness Tests")
struct HIDBrokerReadinessTests {
    @Test("Broker sessions are scoped to one simulator boot")
    func bootIdentityScopesSession() {
        let original = HIDBrokerBootIdentity(
            processIdentifier: 42,
            startSeconds: 100,
            startMicroseconds: 200
        )
        let rebootedWithNewPID = HIDBrokerBootIdentity(
            processIdentifier: 43,
            startSeconds: 101,
            startMicroseconds: 200
        )
        let rebootedWithReusedPID = HIDBrokerBootIdentity(
            processIdentifier: 42,
            startSeconds: 101,
            startMicroseconds: 200
        )

        #expect(HIDBroker.shouldReuseSession(sessionBootIdentity: original, currentBootIdentity: original))
        #expect(!HIDBroker.shouldReuseSession(
            sessionBootIdentity: original,
            currentBootIdentity: rebootedWithNewPID
        ))
        #expect(!HIDBroker.shouldReuseSession(
            sessionBootIdentity: original,
            currentBootIdentity: rebootedWithReusedPID
        ))
    }

    @Test("Boot identity selects the newest launchd process during reboot overlap")
    func newestBootIdentityWins() {
        let oldProcess = HIDBrokerBootIdentity(
            processIdentifier: 42,
            startSeconds: 100,
            startMicroseconds: 900_000
        )
        let newProcess = HIDBrokerBootIdentity(
            processIdentifier: 43,
            startSeconds: 101,
            startMicroseconds: 100
        )

        #expect(HIDBroker.newestBootIdentity([newProcess, oldProcess]) == newProcess)
    }

    @Test("DTUHID waits only for the remaining simulator boot readiness window")
    func dtuhidReadinessDelay() {
        let bootIdentity = HIDBrokerBootIdentity(
            processIdentifier: 42,
            startSeconds: 100,
            startMicroseconds: 250_000
        )

        #expect(HIDBroker.dtuhidReadinessDelay(
            bootIdentity: bootIdentity,
            now: Date(timeIntervalSince1970: 105.25)
        ) == 5)
        #expect(HIDBroker.dtuhidReadinessDelay(
            bootIdentity: bootIdentity,
            now: Date(timeIntervalSince1970: 110.25)
        ) == 0)
        #expect(HIDBroker.dtuhidReadinessDelay(
            bootIdentity: bootIdentity,
            now: Date(timeIntervalSince1970: 120.25)
        ) == 0)
    }

    @Test("DTUHID readiness timing handles a clock earlier than process start")
    func dtuhidReadinessDelayWithEarlierClock() {
        let bootIdentity = HIDBrokerBootIdentity(
            processIdentifier: 42,
            startSeconds: 100,
            startMicroseconds: 0
        )

        #expect(HIDBroker.dtuhidReadinessDelay(
            bootIdentity: bootIdentity,
            now: Date(timeIntervalSince1970: 99)
        ) == HIDBroker.dtuhidMinimumBootUptime)
    }

    @Test("A selected Xcode does not imply DTUHID without a simulator process")
    func missingDTUHIDProcessSelectsIndigo() {
        #expect(!HIDBroker.isDTUHIDSelected(processIdentifier: 0))
    }

    @Test("A simulator DTUHID process selects DTUHID readiness")
    func dtuhidProcessSelectsDTUHID() {
        #expect(HIDBroker.isDTUHIDSelected(processIdentifier: 42))
    }

    @Test("DTUHID readiness uses the injected boot identity and clock")
    func dtuhidReadinessWait() async throws {
        let bootIdentity = HIDBrokerBootIdentity(
            processIdentifier: 42,
            startSeconds: 100,
            startMicroseconds: 250_000
        )
        var delays: [TimeInterval] = []

        try await HIDBroker.waitForHIDReadiness(
            bootIdentity: bootIdentity,
            isDTUHIDSelected: true,
            now: { Date(timeIntervalSince1970: 106.25) },
            sleep: { delays.append($0) }
        )

        #expect(delays == [4])
    }

    @Test("Legacy Indigo transport is never delayed")
    func indigoReadinessDoesNotWait() async throws {
        let bootIdentity = HIDBrokerBootIdentity(
            processIdentifier: 42,
            startSeconds: 100,
            startMicroseconds: 0
        )
        var didSleep = false

        try await HIDBroker.waitForHIDReadiness(
            bootIdentity: bootIdentity,
            isDTUHIDSelected: false,
            now: { Date(timeIntervalSince1970: 100) },
            sleep: { _ in didSleep = true }
        )

        #expect(!didSleep)
    }
}
