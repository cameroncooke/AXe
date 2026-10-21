import ArgumentParser
import Foundation

struct DescribeUI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Describes the UI hierarchy of a booted simulator using accessibility information."
    )

    @Option(name: .customLong("udid"), help: "The UDID of the simulator.")
    var simulatorUDID: String

    @Option(
        name: .customLong("point"),
        help: ArgumentHelp(
            "Describe one element at x,y. Selected mode uses oriented logical display points.",
            valueName: "x,y"
        )
    )
    var point: String?

    @OptionGroup var selectedInput: SelectedInputOptions
    @OptionGroup var selectedAX: SelectedAXOptions

    func validate() throws {
        try selectedInput.validate()
        try selectedAX.validate(required: selectedInput.mode == .selected)
        _ = try parsedPoint()
    }

    func run() async throws {
        if selectedInput.mode == .selected {
            let request = try selectedRequest()
            try SelectedHIDBroker.printResponse(SelectedHIDBroker.send(request, simulatorUDID: simulatorUDID))
            return
        }
        let logger = AxeLogger()
        try await performGlobalSetup(logger: logger)

        let jsonData = try await AccessibilityFetcher.fetchAccessibilityInfoJSONData(
            for: simulatorUDID,
            point: try parsedPoint(),
            logger: logger
        )
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw CLIError(errorDescription: "Failed to convert accessibility info to JSON string.")
        }
        print(jsonString)
    }

    func selectedRequest() throws -> SelectedHIDRequest {
        let point = try parsedPoint().map { SelectedAXPoint(x: $0.x, y: $0.y) }
        return try selectedAX.request(input: selectedInput,
            kind: point == nil ? .describe : .describePoint, point: point)
    }

    private func parsedPoint() throws -> AccessibilityPoint? {
        guard let point else {
            return nil
        }

        let coordinates = point
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard coordinates.count == 2,
              let x = Double(coordinates[0]),
              let y = Double(coordinates[1]),
              x.isFinite,
              y.isFinite,
              x >= 0,
              y >= 0
        else {
            throw ValidationError("--point must be in the form x,y using non-negative numbers.")
        }

        return AccessibilityPoint(x: x, y: y)
    }
}
