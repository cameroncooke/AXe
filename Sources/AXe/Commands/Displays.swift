import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl

struct Displays: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show a simulator's screens: which one is active, its size in points, its orientation, and the hinge angle on iPhone Duo.",
        discussion: """
        Waits for a fold or rotation to finish before reading. Sizes are logical points, the units
        every AXe coordinate uses. Pass the active screen's id and uuid to --screen-id and
        --screen-uuid when a command should refuse to act on any other screen.
        """
    )

    @Option(name: .customLong("udid"), help: "The simulator UDID.")
    var simulatorUDID: String

    @Flag(name: .customLong("verbose"), help: "Print the full display measurements as JSON: pixels, native orientation, boot identity and read times.")
    var verbose = false

    func validate() throws {
        if AutomationTarget.isPhysicalInputUDID(simulatorUDID) { return }
        guard UUID(uuidString: simulatorUDID) != nil else {
            throw ValidationError("--udid must be a simulator UDID.")
        }
    }

    func run() async throws {
        try AutomationTarget.refuseOnDevice(simulatorUDID, "Displays are available on simulators only.")
        let logger = AxeLogger()
        let simulator = try await DeviceState.bootedSimulator(udid: simulatorUDID, logger: logger)
        let discovery = try await DeviceState.settledDiscovery(for: simulator)
        if verbose {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let output = DisplayDiscoveryOutput(snapshot: discovery.readback.snapshot,
                bootIdentity: discovery.bootIdentity, startedUptime: discovery.startedUptime,
                finishedUptime: discovery.finishedUptime)
            try CLIOutput.writeJSONText(String(decoding: try encoder.encode(output), as: UTF8.self))
            return
        }
        let (_, output) = try await DeviceState.displays(for: simulator, discovery: discovery)
        try DeviceState.emit(output, text: output.textLines)
    }
}

/// The complete measured catalogue printed by `displays --verbose`.
struct DisplayDiscoveryOutput: Encodable {
    let snapshot: ActivePanelSnapshot
    let bootIdentity: String
    let startedUptime: Double
    let finishedUptime: Double

    private enum CodingKeys: String, CodingKey { case bootIdentity, readInterval }
    private struct ReadInterval: Encodable {
        let startedUptime: Double
        let finishedUptime: Double
    }

    func encode(to encoder: Encoder) throws {
        try snapshot.encode(to: encoder)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(bootIdentity, forKey: .bootIdentity)
        try values.encode(ReadInterval(startedUptime: startedUptime, finishedUptime: finishedUptime),
            forKey: .readInterval)
    }
}

/// A fold or unfold changes the display configuration for a while: on iOS 27.3 the catalogue
/// reads as changing for about a second. Observation commands wait for the change to finish
/// instead of failing, and never report a catalogue read across the change.
enum DisplayTransition {
    /// The default display coherence budget, shared with `hinge set --readiness-timeout`.
    static let settleBudgetSeconds: Double = 8
    /// The pause between reads, matching the hinge rotation observation interval.
    static let rereadIntervalNanoseconds: UInt64 = 100_000_000

    static func settledDiscovery(for simulator: FBSimulator) async throws -> ActivePanelDiscoveryResult {
        let deadline = ProcessInfo.processInfo.systemUptime + settleBudgetSeconds
        while true {
            do {
                return try await ActivePanelReader.discoverWithMetadata(for: simulator)
            } catch FBSimulatorContextError.changedDuringRead
                where ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(nanoseconds: rereadIntervalNanoseconds)
            }
        }
    }
}
