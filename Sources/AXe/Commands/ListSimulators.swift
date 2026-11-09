import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl

struct ListSimulators: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Lists all available simulators. Use axe displays --udid <UDID> for one simulator's screens and hinge."
    )

    func run() async throws {
        let logger = AxeLogger()

        try await performGlobalSetup(logger: logger)

        let simulatorSet = try await getSimulatorSet(
            deviceSetPath: nil,
            logger: logger,
            reporter: EmptyEventReporter.shared
        )

        let simulators = simulatorSet.allSimulators
        if CLIOutput.isFormatted {
            let inventory = SimulatorInventoryOutput(simulators: simulators.map {
                SimulatorSummaryOutput(udid: $0.udid, name: $0.name,
                    state: FBiOSTargetStateStringFromState($0.state).rawValue,
                    model: $0.deviceType.model.rawValue, osVersion: $0.osVersion.name.rawValue)
            })
            try CLIOutput.writeJSON(inventory)
        } else {
            simulators.forEach { CLIOutput.message($0.description) }
        }
    }
}

struct SimulatorInventoryOutput: Encodable {
    let simulators: [SimulatorSummaryOutput]
}

/// `state` is simctl's state name, such as `Booted` or `Shutdown`; `osVersion` is the runtime name,
/// such as `iOS 27.2`.
struct SimulatorSummaryOutput: Encodable {
    let udid: String
    let name: String
    let state: String
    let model: String
    let osVersion: String
}
