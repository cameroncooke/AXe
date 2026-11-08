import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl

struct ListSimulators: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Lists all available simulators."
    )

    @Flag(name: .customLong("displays"), help: "Print the measured integrated display catalogue and active panel as JSON. Requires --udid and a booted simulator.")
    var displays = false

    @Option(name: .customLong("udid"), help: "The simulator to inspect with --displays.")
    var simulatorUDID: String?

    func validate() throws {
        if displays {
            guard let simulatorUDID, UUID(uuidString: simulatorUDID) != nil else {
                throw ValidationError("--displays requires a valid --udid.")
            }
        } else if simulatorUDID != nil {
            throw ValidationError("--udid requires --displays for list-simulators.")
        }
    }

    func run() async throws {
        let logger = AxeLogger()

        try await performGlobalSetup(logger: logger)

        let simulatorSet = try await getSimulatorSet(
            deviceSetPath: nil,
            logger: logger,
            reporter: EmptyEventReporter.shared
        )

        if displays {
            guard let simulatorUDID,
                  let simulator = simulatorSet.allSimulators.first(where: { UUID(uuidString: $0.udid) == UUID(uuidString: simulatorUDID) }),
                  simulator.state == .booted else {
                throw CLIError(errorDescription: "--displays requires the requested simulator to be booted.")
            }
            let discovery = try await DisplayTransition.settledDiscovery(for: simulator)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let output = DisplayDiscoveryOutput(snapshot: discovery.readback.snapshot,
                bootIdentity: discovery.bootIdentity, startedUptime: discovery.startedUptime,
                finishedUptime: discovery.finishedUptime)
            let data = try encoder.encode(output)
            guard let json = String(data: data, encoding: .utf8) else {
                throw CLIError(errorDescription: "Could not encode the display catalogue.")
            }
            try CLIOutput.writeJSONText(json)
            return
        }

        let simulators = simulatorSet.allSimulators
        if CLIOutput.isFormatted {
            let inventory = SimulatorInventoryOutput(simulators: simulators.map {
                SimulatorSummaryOutput(udid: $0.udid, name: $0.name, description: $0.description)
            })
            try CLIOutput.writeJSON(inventory)
        } else {
            simulators.forEach { CLIOutput.message($0.description) }
        }
    }
}

/// Preserve the existing top-level snapshot fields and add read-only discovery metadata.
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

private struct SimulatorInventoryOutput: Encodable {
    let simulators: [SimulatorSummaryOutput]
}

private struct SimulatorSummaryOutput: Encodable {
    let udid: String
    let name: String
    let description: String
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
