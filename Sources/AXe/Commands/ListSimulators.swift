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
                SimulatorSummaryOutput(udid: $0.udid, name: $0.name, description: $0.description)
            })
            try CLIOutput.writeJSON(inventory)
        } else {
            simulators.forEach { CLIOutput.message($0.description) }
        }
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
