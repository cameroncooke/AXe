import ArgumentParser
import Foundation

struct DescribeUI: PhysicalDeviceCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the accessibility tree as JSON.",
        discussion: """
        --point prints only the element at one point. With --agent it prints a compact snapshot whose refs other agent commands act on; see the AXe skill.

        Examples:
          axe describe-ui --udid <UDID>
          axe describe-ui --point 200,400 --udid <UDID>
          axe describe-ui --agent --view navigation --udid <UDID>
        """
    )

    @Option(name: .customLong("udid"), help: "UDID of the simulator or physical device.")
    var simulatorUDID: String

    @Option(
        name: .customLong("point"),
        help: ArgumentHelp(
            "Describe only the element at x,y in points.",
            valueName: "x,y"
        )
    )
    var point: String?

    @Flag(name: .customLong("minimal-keys"), help: "Read only label, identifier, value, frame, role, role description, type and enabled state, which is faster.")
    var minimalKeys: Bool = false

    @OptionGroup var selectedInput: SelectedInputOptions
    @OptionGroup var selectedAX: SelectedAXOptions
    @OptionGroup var agentMode: AgentModeOptions
    @OptionGroup var selectedOutput: SelectedOutputOptions

    @Option(name: .customLong("since-screen-hash"), help: "Agent only: return a short unchanged result while the screen still has this hash.")
    var sinceScreenHash: String?

    @Option(name: .customLong("row-offset"), help: "Agent only: first row to return, 0 to 12288; pass --snapshot-id for later pages.")
    var rowOffset: Int?

    @Option(name: .customLong("row-limit"), help: "Agent only: rows to return, 1 to 64 (default 64).")
    var rowLimit: Int?

    @Option(name: .customLong("read-ref"), help: "Agent only: read one field of this ref without input; needs --snapshot-id.")
    var readRef: String?

    @Option(name: .customLong("text-field"), help: "--read-ref field: label (default), value, id or custom-actions.")
    var textField: AgentModeTextQuery.Field?

    @Option(name: .customLong("text-offset"), help: "--read-ref: first Unicode scalar to return (default 0).")
    var textOffset: Int?

    @Option(name: .customLong("text-limit"), help: "--read-ref: Unicode scalars to return, 1 to 4096 (default 1024).")
    var textLimit: Int?

    func validate() throws {
        if AutomationTarget.isPhysicalInputUDID(simulatorUDID), hasSimulatorOnlyOptions { return }
        try agentMode.validate()
        if minimalKeys, agentMode.enabled || selectedInput.mode == .selected {
            throw ValidationError("--minimal-keys applies to the plain describe-ui read, not to --agent or selected input.")
        }
        if agentMode.enabled {
            guard point == nil, agentMode.elementRef == nil else {
                throw ValidationError("Agent describe-ui does not accept --point or --ref.")
            }
            try AgentModeCommandAdapter.validateContext(input: selectedInput, expectedPID: selectedAX.expectedPID)
            if let sinceScreenHash, sinceScreenHash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError("--since-screen-hash must not be empty.")
            }
            guard (0...AgentModeRequest.maximumRows).contains(rowOffset ?? 0), (1...64).contains(rowLimit ?? 64) else {
                throw ValidationError("Agent rows require --row-offset in 0...12288 and --row-limit in 1...64.")
            }
            guard agentMode.snapshotID == nil || sinceScreenHash == nil else {
                throw ValidationError("Choose --snapshot-id for a current snapshot page or --since-screen-hash for a fresh capture.")
            }
            if let readRef {
                try agentMode.requireSnapshot()
                guard !readRef.isEmpty, sinceScreenHash == nil, rowOffset == nil, rowLimit == nil else {
                    throw ValidationError("--read-ref requires one snapshot reference, without hash polling or row paging.")
                }
                try AgentModeTextQuery(field: textField ?? .label, offset: textOffset ?? 0,
                    limit: textLimit ?? 1024).validate()
            } else if textField != nil || textOffset != nil || textLimit != nil {
                throw ValidationError("--text-field, --text-offset and --text-limit require --read-ref.")
            }
            return
        }
        guard sinceScreenHash == nil, rowOffset == nil, rowLimit == nil, readRef == nil,
              textField == nil, textOffset == nil, textLimit == nil else {
            throw ValidationError("Agent hash, row and reference-read options require --agent.")
        }
        try selectedInput.validate()
        try selectedAX.validate(allowed: selectedInput.mode == .selected)
        _ = try parsedPoint()
    }

    private var hasSimulatorOnlyOptions: Bool {
        PhysicalAccessibilityCommands.usesSimulatorOptions(input: selectedInput, ax: selectedAX, agent: agentMode)
            || minimalKeys || sinceScreenHash != nil || rowOffset != nil || rowLimit != nil || readRef != nil
            || textField != nil || textOffset != nil || textLimit != nil
    }

    func validateOnDevice(inBatch: Bool) throws {
        guard !hasSimulatorOnlyOptions else {
            throw AutomationTarget.unsupportedOnDevice("Physical describe-ui does not accept agent mode or simulator display and process options.")
        }
    }

    func runOnDevice(_ input: PhysicalDeviceInput) async throws -> PhysicalAccessibilitySnapshot {
        try await input.readAccessibility()
    }

    func reportOnDevice(_ snapshot: PhysicalAccessibilitySnapshot) throws {
        let data: Data
        if let point = try parsedPoint() {
            data = try PhysicalAccessibilityCommands.pointJSON(at: point.cgPoint, in: snapshot)
        } else {
            data = snapshot.json
        }
        try CLIOutput.writeJSONData(data)
    }

    func run() async throws {
        if try await runOnDeviceIfTargeted() { return }
        if agentMode.enabled {
            try AgentModeCommandAdapter.send(agentRequest(), simulatorUDID: simulatorUDID)
            return
        }
        if selectedInput.mode == .selected {
            let request = try selectedRequest()
            try SelectedHIDBroker.printResponse(SelectedHIDBroker.send(request, simulatorUDID: simulatorUDID),
                verbose: selectedOutput.verbose)
            return
        }
        let logger = AxeLogger()
        try await performGlobalSetup(logger: logger)

        let jsonData = try await AccessibilityFetcher.fetchAccessibilityInfoJSONData(
            for: simulatorUDID,
            point: try parsedPoint(),
            logger: logger,
            keys: minimalKeys ? AccessibilityFetcher.minimalRequestKeys : AccessibilityFetcher.accessibilityRequestKeys
        )
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw CLIError(errorDescription: "Failed to convert accessibility info to JSON string.", code: .treeUnavailable)
        }
        try CLIOutput.writeJSONText(jsonString)
    }

    func agentRequest() throws -> SelectedHIDRequest {
        try AgentModeCommandAdapter.request(AgentModeRequest(kind: readRef == nil ? .describe : .read,
            expectedPID: selectedAX.expectedPID, snapshotID: agentMode.snapshotID, sinceScreenHash: sinceScreenHash,
            rowOffset: rowOffset ?? 0, rowLimit: rowLimit ?? 64,
            readReference: readRef, textQuery: readRef.map { _ in AgentModeTextQuery(
                field: textField ?? .label, offset: textOffset ?? 0, limit: textLimit ?? 1024) }), input: selectedInput)
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
