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
    @OptionGroup var agentMode: AgentModeOptions

    @Option(name: .customLong("since-screen-hash"), help: "Agent only: return an unchanged capture when a fresh screen hash matches.")
    var sinceScreenHash: String?

    @Option(name: .customLong("row-offset"), help: "Agent only: first row in the snapshot table, in 0...4096. Reuse --snapshot-id for the next page.")
    var rowOffset: Int?

    @Option(name: .customLong("row-limit"), help: "Agent only: maximum rows in this page, in 1...64 (default 64).")
    var rowLimit: Int?

    func validate() throws {
        try agentMode.validate()
        if agentMode.enabled {
            guard point == nil, agentMode.elementRef == nil, selectedAX.preparation == nil else {
                throw ValidationError("Agent describe-ui does not accept --point, --ref or --ax-preparation.")
            }
            try AgentModeCommandAdapter.validateContext(input: selectedInput, expectedPID: selectedAX.expectedPID)
            if let sinceScreenHash, sinceScreenHash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError("--since-screen-hash must not be empty.")
            }
            guard (0...4096).contains(rowOffset ?? 0), (1...64).contains(rowLimit ?? 64) else {
                throw ValidationError("Agent rows require --row-offset in 0...4096 and --row-limit in 1...64.")
            }
            guard agentMode.snapshotID == nil || sinceScreenHash == nil else {
                throw ValidationError("Choose --snapshot-id for a current snapshot page or --since-screen-hash for a fresh capture.")
            }
            return
        }
        guard sinceScreenHash == nil, rowOffset == nil, rowLimit == nil else {
            throw ValidationError("--since-screen-hash, --row-offset and --row-limit require --agent.")
        }
        try selectedInput.validate()
        try selectedAX.validate(required: selectedInput.mode == .selected)
        _ = try parsedPoint()
    }

    func run() async throws {
        if agentMode.enabled {
            try AgentModeCommandAdapter.send(agentRequest(), simulatorUDID: simulatorUDID)
            return
        }
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

    func agentRequest() throws -> SelectedHIDRequest {
        try AgentModeCommandAdapter.request(AgentModeRequest(kind: .describe,
            expectedPID: selectedAX.expectedPID, snapshotID: agentMode.snapshotID, sinceScreenHash: sinceScreenHash,
            rowOffset: rowOffset ?? 0, rowLimit: rowLimit ?? 64), input: selectedInput)
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
