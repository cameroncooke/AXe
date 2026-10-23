import ArgumentParser

/// Internal process boundary for isolated, read-only Slider acquisition.
struct SliderReadWorkerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "slider-read-worker", shouldDisplay: false)

    @Argument(parsing: .unconditionalRemaining)
    var arguments: [String] = []

    func run() async {
        await SliderPickupReadPhase.run(arguments: arguments)
    }
}
