import ArgumentParser
import FBControlCore

struct HIDBrokerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hid-broker",
        shouldDisplay: false
    )

    @Option(name: .customLong("udid"))
    var simulatorUDID: String

    func run() async throws {
        let logger = AxeLogger()
        try await setup(logger: logger)
        try await performGlobalSetup(logger: logger)
        try await HIDBroker.serve(simulatorUDID: simulatorUDID, logger: logger)
    }
}
