import FBSimulatorControl
import Foundation
import Testing
import XPC

/// Reports measured on the iPhone Duo iOS 27.2 simulator (Xcode 27.2 beta 3). Under heavy host load
/// CoreDevice's display report can miss one update after a close and stay stale for minutes.
@Suite("Steady lit inactive display reports")
struct DisplaySteadinessTests {
    private let simulator = UUID(uuidString: "1B900C0E-B873-4A62-8CAA-3E28756DA335")!
    private let outer = UUID(uuidString: "95E0E222-93FB-4087-B4EA-99892B40C1B0")!
    private let inner = UUID(uuidString: "07C504E8-FBBB-4DD7-8AD4-45281006E998")!
    private let boot = "101:202:303"

    private struct Hinge {
        var mechanical = 0.0, sensed = 0.0, velocity = 0.0, maximum = 180.0
    }

    // MARK: Fixtures

    /// The persistent report: closed, outer active and lit, inner inactive but still reported lit
    /// although SpringBoard turned it off. The outer panel shows the home screen.
    private var staleInnerBacklight: [FBSimulatorDisplayInfoRow] {
        rows(outerActive: true, outerLight: "activeOn", innerLight: "activeOn")
    }

    /// The other persistent report: SpringBoard swapped to the outer panel, but the report still
    /// flags the inner panel active although it is off. Binding it would hit the wrong panel.
    private var staleActiveFlag: [FBSimulatorDisplayInfoRow] {
        rows(outerActive: false, outerLight: "activeOn", innerLight: "off")
    }

    /// The first read after a close: the outgoing inner panel is still active, the outer one is lit.
    private var closingOutgoingStillActive: [FBSimulatorDisplayInfoRow] {
        rows(outerActive: false, outerLight: "activeOn", innerLight: "activeOn")
    }

    // MARK: Policy

    @Test func persistentStaleBacklightIsTrustedOnlyWhenClosedAtRest() throws {
        #expect(FBSimulatorLitInactivePolicy.hasLitInactivePanel(staleInnerBacklight))
        #expect(fingerprint(staleInnerBacklight) != nil)
        for hinge in [Hinge(velocity: 12), Hinge(mechanical: 90, sensed: 88.4), Hinge(mechanical: 0, sensed: 0.6),
                      Hinge(mechanical: 0.6, sensed: 0), Hinge(mechanical: 180, sensed: 180)] {
            #expect(fingerprint(staleInnerBacklight, hinge) == nil)
        }
    }

    @Test func reportsThatCouldBindTheWrongPanelAreNeverTrusted() throws {
        // The active panel is off: the flag is stale.
        #expect(fingerprint(staleActiveFlag) == nil)
        // Closed, but the inner panel is still active: a close in progress, or a boot.
        #expect(fingerprint(closingOutgoingStillActive) == nil)
        // Two active panels, or none.
        #expect(fingerprint(rows(outerActive: true, innerActive: true, outerLight: "activeOn", innerLight: "activeOn")) == nil)
        #expect(fingerprint(rows(outerActive: false, innerActive: false, outerLight: "activeOn", innerLight: "activeOn")) == nil)
        // Open, with the outer panel still active.
        #expect(fingerprint(staleInnerBacklight, Hinge(mechanical: 180, sensed: 180)) == nil)
        // Open with the inner panel active and the outer one reported lit is the mirror image.
        let open = rows(outerActive: false, innerActive: true, outerLight: "activeOn", innerLight: "activeOn")
        #expect(fingerprint(open, Hinge(mechanical: 180, sensed: 180)) != nil)
        // An ordinary report has no lit inactive panel.
        #expect(fingerprint(rows(outerActive: true, outerLight: "activeOn", innerLight: "off")) == nil)
    }

    // MARK: Steadiness

    @Test func reportMustStayTheSameForLongerThanAFold() throws {
        let clock = TestClock()
        let steadiness = FBSimulatorDisplaySteadiness(clock: { clock.now })
        let value = try #require(fingerprint(staleInnerBacklight))
        // Reads every 100 ms, as `axe displays` does; the measured close dwell ends by 3.8 s.
        while clock.now < FBSimulatorLitInactivePolicy.steadySeconds - 0.05 {
            #expect(!steadiness.observe(value, simulatorUDID: simulator.uuidString))
            clock.now += 0.1
        }
        clock.now = FBSimulatorLitInactivePolicy.steadySeconds
        #expect(steadiness.observe(value, simulatorUDID: simulator.uuidString))
        // Proven once, the same report is accepted at once, as in a long-lived broker.
        clock.now += 60
        #expect(steadiness.observe(value, simulatorUDID: simulator.uuidString.lowercased()))
        // Any other report forgets it.
        steadiness.forget(simulatorUDID: simulator.uuidString)
        #expect(!steadiness.observe(value, simulatorUDID: simulator.uuidString))
    }

    @Test func gapsAndChangesRestartTheWait() throws {
        let clock = TestClock()
        let steadiness = FBSimulatorDisplaySteadiness(clock: { clock.now })
        let value = try #require(fingerprint(staleInnerBacklight))
        #expect(!steadiness.observe(value, simulatorUDID: simulator.uuidString))
        // Reads more than a second apart do not prove the report stayed the same in between.
        clock.now = 4
        #expect(!steadiness.observe(value, simulatorUDID: simulator.uuidString))
        clock.now = 8.9
        #expect(!steadiness.observe(value, simulatorUDID: simulator.uuidString))
        // A different hinge reading, orientation or boot is a different report.
        let moved = try #require(fingerprint(staleInnerBacklight, Hinge(mechanical: 0.2, sensed: 0.2)))
        let rebooted = try #require(fingerprint(staleInnerBacklight, boot: "404:505:606"))
        let rotated = try #require(fingerprint(rows(outerActive: true, outerLight: "activeOn", innerLight: "activeOn",
            outerRotation: "rot90")))
        for other in [moved, rebooted, rotated] {
            clock.now += 0.5
            #expect(other != value)
            #expect(!steadiness.observe(other, simulatorUDID: simulator.uuidString))
        }
        // Each simulator is tracked on its own.
        clock.now = 20
        #expect(!steadiness.observe(value, simulatorUDID: simulator.uuidString))
        clock.now = 25
        #expect(!steadiness.observe(value, simulatorUDID: UUID().uuidString))
    }

    @Test func ordinaryReportsNeverReadTheHinge() async throws {
        let steadiness = FBSimulatorDisplaySteadiness()
        let ordinary = response(rows(outerActive: true, outerLight: "activeOn", innerLight: "off"))
        let verdict = await steadiness.verdict(ordinary, simulatorUDID: simulator.uuidString, bootIdentity: boot) {
            Issue.record("An ordinary report must not read the hinge")
            return nil
        }
        #expect(verdict == .ordinary)
        // Without a hinge reading a lit inactive report is never admitted.
        let unread = await steadiness.verdict(response(staleInnerBacklight),
            simulatorUDID: simulator.uuidString, bootIdentity: boot) { nil }
        #expect(unread == .untrusted)
    }

    @Test func fileStoreSharesTheProofBetweenProcesses() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("axe-steady-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try #require(FBSimulatorDisplaySteadinessFileStore(directory: directory))
        let clock = TestClock()
        let value = try #require(fingerprint(staleInnerBacklight))
        // The CLI process proves the report steady...
        let cli = FBSimulatorDisplaySteadiness(store: store, clock: { clock.now })
        for step in 0...50 {
            clock.now = Double(step) / 10
            _ = cli.observe(value, simulatorUDID: simulator.uuidString)
        }
        // ...and the broker, a separate process with its own store object, accepts it at once.
        let broker = FBSimulatorDisplaySteadiness(store: try #require(FBSimulatorDisplaySteadinessFileStore(directory: directory)),
            clock: { clock.now })
        clock.now = 30
        #expect(broker.observe(value, simulatorUDID: simulator.uuidString))
        broker.forget(simulatorUDID: simulator.uuidString)
        #expect(store.load(simulator.uuidString) == nil)
        #expect(!cli.observe(value, simulatorUDID: simulator.uuidString))
        // A directory other users can open is not used.
        let shared = directory.appendingPathComponent("open")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755])
        #expect(FBSimulatorDisplaySteadinessFileStore(directory: shared) == nil)
    }

    // MARK: Reader

    @Test func readerRefusesUntilTheCallerProvesTheReportSteady() throws {
        let stale = response(staleInnerBacklight)
        #expect(throws: FBSimulatorContextError.self) { _ = try discover(stale) }
        let readback = try discover(stale, steady: true)
        #expect(readback.snapshot.activePanel.identity == .init(displayID: 1, uniqueID: outer))
        #expect(readback.snapshot.selectionBasis == .steadyExplicitActiveFlag)
        let selected = try FBSimulatorDisplayInfoReader.snapshot(stale, simulatorUDID: simulator,
            expectedPanels: catalog.map(\.identity), selected: expectation(1, outer, 1398, 2034, .rot0),
            acceptSteadyLitInactive: true)
        #expect(selected.snapshot.activePanel.identity.displayID == 1)
        do {
            _ = try FBSimulatorDisplayInfoReader.snapshot(stale, simulatorUDID: simulator,
                expectedPanels: catalog.map(\.identity), selected: expectation(3, inner, 2007, 2853, .rot90),
                acceptSteadyLitInactive: true)
            Issue.record("The inactive inner panel was selected")
        } catch let error as ActivePanelReadError {
            #expect(error.validationFailure == .inactiveSelection(requested: .init(displayID: 3, uniqueID: inner),
                observed: .init(displayID: 1, uniqueID: outer)))
        }
        // Even when told to, the reader never accepts an active panel that is off.
        #expect(throws: FBSimulatorContextError.self) { _ = try discover(response(staleActiveFlag), steady: true) }
        // An ordinary report keeps its basis.
        let ordinary = try discover(response(rows(outerActive: true, outerLight: "activeOn", innerLight: "off")))
        #expect(ordinary.snapshot.selectionBasis == .explicitActiveFlag)
    }

    // MARK: Helpers

    private final class TestClock: @unchecked Sendable {
        var now: TimeInterval = 0
    }

    private var catalog: [ActivePanelCatalogEntry] {
        [.init(identity: .init(displayID: 1, uniqueID: outer), nativePixelWidth: 1398, nativePixelHeight: 2034, scale: 3),
         .init(identity: .init(displayID: 3, uniqueID: inner), nativePixelWidth: 2007, nativePixelHeight: 2853, scale: 3)]
    }

    private func fingerprint(_ rows: [FBSimulatorDisplayInfoRow], _ hinge: Hinge = Hinge(),
                             boot: String? = nil) -> FBSimulatorDisplayFingerprint? {
        FBSimulatorLitInactivePolicy.fingerprint(rows, bootIdentity: boot ?? self.boot,
            mechanicalDegrees: hinge.mechanical, sensedDegrees: hinge.sensed,
            velocityDegreesPerSecond: hinge.velocity, maximumDegrees: hinge.maximum)
    }

    private func discover(_ response: FBSimulatorDisplayInfoResponse, steady: Bool = false) throws -> ActivePanelReadback {
        try FBSimulatorDisplayInfoReader.discovery(response, simulatorUDID: simulator, expectedCatalog: catalog,
            acceptSteadyLitInactive: steady)
    }

    private func expectation(_ id: UInt32, _ uuid: UUID, _ w: Double, _ h: Double,
                             _ rotation: ActivePanelRotation) -> ActivePanelExpectation {
        .init(identity: .init(displayID: id, uniqueID: uuid), nativePixelWidth: w, nativePixelHeight: h,
              scale: 3, rotation: rotation)
    }

    private func response(_ rows: [FBSimulatorDisplayInfoRow]) -> FBSimulatorDisplayInfoResponse {
        FBSimulatorDisplayInfoResponse(rows: rows, coreDeviceVersion: "689.2", startedUptime: 1, finishedUptime: 2)
    }

    /// Decodes a CoreDevice reply with the Duo's five displays, as the reader receives it.
    private func rows(outerActive: Bool, innerActive: Bool? = nil, outerLight: String, innerLight: String,
                      outerRotation: String = "rot0") -> [FBSimulatorDisplayInfoRow] {
        let innerIsActive = innerActive ?? !outerActive
        let displays = xpc_array_create(nil, 0)
        let values: [(UInt64, UUID, String, Bool, Bool, String, (Double, Double), String)] = [
            (1, outer, "integrated", true, outerActive, outerRotation, (1398, 2034), outerLight),
            (2, UUID(), "external", false, false, "rot0", (0, 0), "off"),
            (3, inner, "integrated", false, innerIsActive, "rot90", (2007, 2853), innerLight),
            (4, UUID(), "wireless", false, false, "rot0", (0, 0), "off"),
            (5, UUID(), "virtual", false, false, "rot0", (0, 0), "off"),
        ]
        for (id, uuid, kind, primary, active, rotation, size, light) in values {
            let row = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_uint64(row, "displayId", id)
            xpc_dictionary_set_string(row, "uniqueId", uuid.uuidString)
            let type = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_value(type, kind, xpc_dictionary_create(nil, nil, 0))
            xpc_dictionary_set_value(row, "type", type)
            xpc_dictionary_set_bool(row, "primary", primary)
            xpc_dictionary_set_bool(row, "active", active)
            xpc_dictionary_set_string(row, "currentOrientation", rotation)
            xpc_dictionary_set_string(row, "nativeOrientation", "rot0")
            xpc_dictionary_set_value(row, "nativeSize", pair(size.0, size.1))
            let bounds = xpc_array_create(nil, 0)
            xpc_array_append_value(bounds, pair(0, 0))
            xpc_array_append_value(bounds, pair(size.0, size.1))
            xpc_dictionary_set_value(row, "bounds", bounds)
            xpc_dictionary_set_int64(row, "pointScale", kind == "integrated" ? 3 : 1)
            xpc_dictionary_set_string(row, "backlightState", light)
            xpc_array_append_value(displays, row)
        }
        let output = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_bool(output, "current", true)
        xpc_dictionary_set_value(output, "displays", displays)
        let reply = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_value(reply, "CoreDevice.output", output)
        return try! FBSimulatorDisplayInfoReader.decode(reply)
    }

    private func pair(_ a: Double, _ b: Double) -> xpc_object_t {
        let value = xpc_array_create(nil, 0)
        xpc_array_append_value(value, xpc_double_create(a))
        xpc_array_append_value(value, xpc_double_create(b))
        return value
    }
}
