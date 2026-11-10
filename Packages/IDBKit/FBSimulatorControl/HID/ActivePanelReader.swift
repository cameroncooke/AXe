import Foundation
import FBControlCore

public enum ActivePanelReader {
    /// Read-only discovery. The result is a measured catalogue, not an input admission token.
    public static func discover(for simulator: FBSimulator) async throws -> ActivePanelReadback {
        let discovery = try await discoverWithMetadata(for: simulator)
        return discovery.readback
    }

    /// Includes the matched boot identity and host monotonic interval for the full discovery read.
    /// The metadata is observational; callers must still perform fresh capture or input admission.
    public static func discoverWithMetadata(for simulator: FBSimulator) async throws -> ActivePanelDiscoveryResult {
        let started = ProcessInfo.processInfo.systemUptime
        try Task.checkCancellation()
        guard simulator.state == .booted, let simulatorID = UUID(uuidString: simulator.udid) else {
            throw FBSimulatorContextError.unavailable("Display discovery requires a booted simulator")
        }
        let bootBefore = try FBSimulatorNativeContextReader.bootIdentity(simulator.udid)
        let capability = try FBSimulatorNativeContextReader.capability(for: simulator)
        let before = try FBSimulatorNativeContextReader.hostCatalog(
            await FBSimulatorDisplayDiscovery.displays(for: simulator), profileIDs: capability.integratedDigitizerIDs)
        let catalog = try before.map { display -> ActivePanelCatalogEntry in
            guard let uniqueID = display.uniqueID.flatMap(UUID.init(uuidString:)) else {
                throw ActivePanelValidationError.invalidExpectedCatalog
            }
            return ActivePanelCatalogEntry(identity: ActivePanelIdentity(displayID: display.screenID, uniqueID: uniqueID),
                nativePixelWidth: display.nativePixelSize.width, nativePixelHeight: display.nativePixelSize.height, scale: display.scale)
        }
        // The guest's own CoreDevice display report, read in-process. A lit inactive panel that
        // matches the hinge is read again until it has stayed unchanged for longer than a fold takes
        // (FBSimulatorLitInactivePolicy); a close's 3 s dwell ends first and reads as ordinary.
        var response = try await FBSimulatorDisplayInfoReader.read(for: simulator)
        let settleDeadline = started + FBSimulatorLitInactivePolicy.steadySeconds + 1
        var verdict = FBSimulatorLitInactiveVerdict.ordinary
        while true {
            verdict = await FBSimulatorDisplaySteadiness.shared.verdict(response,
                simulatorUDID: simulator.udid, bootIdentity: bootBefore) {
                capability.hinge == .supported ? try await FBSimulatorHingeReader.read(for: simulator) : nil
            }
            guard verdict == .settling, ProcessInfo.processInfo.systemUptime < settleDeadline else { break }
            try await Task.sleep(nanoseconds: 100_000_000)
            response = try await FBSimulatorDisplayInfoReader.read(for: simulator)
        }
        let readback = try FBSimulatorDisplayInfoReader.discovery(response, simulatorUDID: simulatorID,
            expectedCatalog: catalog, acceptSteadyLitInactive: verdict == .steady)
        let after = try FBSimulatorNativeContextReader.hostCatalog(
            await FBSimulatorDisplayDiscovery.displays(for: simulator), profileIDs: capability.integratedDigitizerIDs)
        let bootAfter = try FBSimulatorNativeContextReader.bootIdentity(simulator.udid)
        guard simulator.state == .booted, bootBefore == bootAfter,
              FBSimulatorNativeContextReader.sameCatalog(before, after) else {
            throw FBSimulatorContextError.changedDuringRead
        }
        try Task.checkCancellation()
        return ActivePanelDiscoveryResult(readback: readback, bootIdentity: bootBefore,
            startedUptime: started, finishedUptime: ProcessInfo.processInfo.systemUptime)
    }
}
