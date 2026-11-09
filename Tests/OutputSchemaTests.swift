import Foundation
import Testing
import FBSimulatorControl
@testable import AXe

/// The published schemas in `schemas/` must describe what the CLI renders, field for field.
/// Each case renders through `CLIOutput.rendered`, the same path the CLI writes to stdout.
@Suite("Published output schemas")
struct OutputSchemaTests {
    private static let snapshotID = UUID(uuidString: "3FF70D78-26DA-4314-B37B-4CB57D2A1A85")!

    @Test("Each schema loads, uses only supported keywords and names its own file and version")
    func schemasDescribeThemselves() throws {
        for (key, file) in OutputSchemas.files {
            let data = try Data(contentsOf: OutputSchemas.directory.appendingPathComponent(file))
            let schema = try OutputSchemaJSON(json: data)
            _ = try OutputSchemaValidator(schema: schema)
            let parts = key.split(separator: "/").map(String.init)
            #expect(schema["$id"]?.stringValue?.hasSuffix("/schemas/" + file) == true)
            #expect(schema["properties"]?["schema"]?["const"]?.stringValue == parts[0])
            #expect(schema["properties"]?["schemaVersion"]?["const"]?.stringValue == parts[1])
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: OutputSchemas.directory.path)
        #expect(Set(files.filter { $0.hasSuffix(".schema.json") }) == Set(OutputSchemas.files.values))
    }

    @Test("Snapshot captures match the schema of every view", arguments: AgentOutputView.allCases)
    func capturesMatch(view: AgentOutputView) throws {
        let (snapshot, context) = try makeSnapshot()
        var first = snapshot.capture(id: Self.snapshotID, sequence: 1, udid: "fixture",
            request: .init(kind: .describe), applicationPID: 1234, context: context, unchanged: false, expiresIn: 59.6)
        #expect(first.scrollPreview != nil && first.nextRowOffset != nil)
        first.customActions = ["e2": ["Delete", "Share"], "e3": ["Delete", "Share"]]
        first.truncatedCustomActionRefs = ["e3"]
        let later = snapshot.capture(id: Self.snapshotID, sequence: 1, udid: "fixture",
            request: .init(kind: .describe, rowOffset: 64, rowLimit: 8), applicationPID: 1234, context: context,
            unchanged: false, expiresIn: 30)
        let unchanged = snapshot.capture(id: Self.snapshotID, sequence: 2, udid: "fixture",
            request: .init(kind: .describe), applicationPID: 1234, context: context, unchanged: true, expiresIn: 12.9)
        for capture in [first, later, unchanged] {
            let output = try render(AgentModeResult(capture: capture, cache: refreshed), view: view)
            #expect(output["schemaVersion"]?.stringValue == (view == .full ? "1" : "2"))
            try OutputSchemas.validate(json(output))
        }
        let rendered = try render(AgentModeResult(capture: first, cache: refreshed), view: view)
        if view == .full {
            #expect(rendered["data"]?["capture"]?["customActions"] != nil)
        } else {
            #expect(rendered["data"]?["capture"]?["areas"] != nil)
            #expect(rendered["data"]?["capture"]?["truncatedFields"] != nil)
            #expect(rendered["data"]?["capture"]?["customActionGroups"] != nil)
        }
    }

    @Test("Action receipts, read-ref chunks and refusals match the schema of every view", arguments: AgentOutputView.allCases)
    func receiptsAndFailuresMatch(view: AgentOutputView) throws {
        let (snapshot, context) = try makeSnapshot()
        let capture = snapshot.capture(id: Self.snapshotID, sequence: 1, udid: "fixture",
            request: .init(kind: .describe), applicationPID: 1234, context: context, unchanged: false, expiresIn: 60)
        let quarantine = SelectedHIDQuarantine(recordPath: "/tmp/quarantine.json", persisted: true, error: "native")
        let sliderValue = SelectedSliderValueResult(outcome: "completed", reason: nil, delivery: "physical",
            requestedPercent: 50, initialValue: 0.1, finalValue: 0.5, nativeTarget: 0.5, domainMinimum: 0,
            domainMaximum: 1, tolerance: 0.01, moves: 3, pickupReadPhases: 1, elapsedSeconds: 1.25,
            nativeReadDiagnostic: nil)
        let slider = try JSONDecoder().decode(SelectedSliderResult.self, from: Data(#"""
            {"outcome":"completed","reasonTruncated":false,"delivery":"semantic","endpoint":"maximum",
             "actionAttempts":1,"actionsReturned":1,"startedUptime":10.5,"deadlineUptime":25.5,"elapsedSeconds":0.75,
             "samples":[{"phase":"before","elapsedSeconds":0,"snapshotID":"3FF70D78-26DA-4314-B37B-4CB57D2A1A85",
               "elementType":"Slider","minimum":0,"maximum":1,"tolerance":0.01,"value":0.25}],
             "actions":[{"action":"increment","valueBeforeAction":0.25,"elementType":"Slider",
               "callStartedUptime":10.6,"callReturnedUptime":10.7,"guestAcknowledged":true}]}
            """#.utf8))
        let observation = try JSONDecoder().decode(AgentModeObservationEvidence.self, from: Data(#"""
            {"expectedPID":1234,"observedPID":5678,"outcome":"processChanged",
             "attempts":[{"index":1,"startUptime":1.5,"endUptime":2.25,"rootPID":5678,"outcome":"processChanged"}]}
            """#.utf8))
        let detail = try snapshot.detail(ref: "e2", query: .init(field: .label, offset: 0, limit: 4))
        let longMessage = String(repeating: "native diagnostic ", count: 100)
        let results = [
            AgentModeResult(capture: capture, action: AgentModeActionReceipt(kind: .tap, outcome: "enqueuedAndDrained",
                enqueuedEventCount: 2, cleanup: "notNeeded", replayed: false, quarantine: nil, retried: true),
                cache: refreshed, nextSteps: ["The action completed. Do not replay this action."]),
            AgentModeResult(action: AgentModeActionReceipt(kind: .sliderEndpoint, outcome: "enqueuedAndDrained",
                enqueuedEventCount: 0, cleanup: "notNeeded", replayed: false, quarantine: nil, slider: slider),
                cache: invalidated, context: context),
            AgentModeResult(action: AgentModeActionReceipt(kind: .sliderPercentage, outcome: "enqueuedAndDrained",
                enqueuedEventCount: 12, cleanup: "notNeeded", replayed: false, quarantine: nil, sliderValue: sliderValue),
                cache: invalidated, context: context),
            AgentModeResult(capture: capture, cache: refreshed, detail: detail),
            AgentModeResult(error: AgentModeFailure("screenChanged", "The screen changed before input."),
                capture: capture, cache: invalidated, nextSteps: ["Input was not sent."]),
            AgentModeResult(error: AgentModeFailure("failedNoReplay", longMessage),
                action: AgentModeActionReceipt(kind: .swipe, outcome: "failedNoReplay", enqueuedEventCount: 4,
                    cleanup: "uncertain", replayed: false, quarantine: quarantine),
                cache: invalidated, context: context, quarantine: quarantine),
            AgentModeResult(error: AgentModeFailure("observationFailed", "The accessibility read failed."),
                cache: invalidated, context: context, observation: observation),
        ]
        for result in results { try OutputSchemas.validate(json(try render(result, view: view))) }

        // An argument failure before any agent result uses the same envelope.
        let failure = try render(nil, view: view, failure: CLIOutputFailure(code: "invalidArgument", message: "Bad ref."))
        #expect(failure["didError"]?.boolValue == true)
        try OutputSchemas.validate(json(failure))
    }

    @Test("Completed and stopped batches match the schema of every view", arguments: AgentOutputView.allCases)
    func batchesMatch(view: AgentOutputView) throws {
        let (snapshot, context) = try makeSnapshot()
        let capture = snapshot.capture(id: Self.snapshotID, sequence: 3, udid: "fixture",
            request: .init(kind: .describe), applicationPID: 1234, context: context, unchanged: false, expiresIn: 60)
        let inProgress = AgentModeCacheState(status: "invalidated", reason: "batchInProgress", requiresRefresh: true)
        func step(_ index: Int, _ action: AgentBatchStep.Action, kind: AgentModeRequest.Kind) -> AgentBatchStepReceipt {
            AgentBatchStepReceipt(index: index, action: action, status: "completed", requestID: UUID(),
                receipt: AgentModeActionReceipt(kind: kind, outcome: "enqueuedAndDrained", enqueuedEventCount: 2,
                    cleanup: "notNeeded", replayed: false, quarantine: nil),
                error: nil, cache: inProgress, context: context)
        }
        let completed = AgentBatchReceipt(totalSteps: 2, completedSteps: 2,
            steps: [step(1, .tap, kind: .tap), step(2, .type, kind: .typeText)], stoppedAt: nil)
        let stoppedStep = AgentBatchStepReceipt(index: 2, action: .tap, status: "failed", requestID: UUID(),
            receipt: nil, error: AgentModeFailure("targetChanged", "The target moved."), cache: invalidated, context: context)
        let stopped = AgentBatchReceipt(totalSteps: 3, completedSteps: 1,
            steps: [step(1, .type, kind: .focusAndType), stoppedStep], stoppedAt: 2)
        let completedOutput = try render(AgentModeResult(capture: capture, batch: completed, cache: refreshed), view: view)
        if view != .full {
            #expect(completedOutput["data"]?["batch"]?["totalSteps"] == nil)
            #expect(completedOutput["data"]?["batch"]?["steps"]?.arrayValue?.first?["requestID"] == nil)
        }
        try OutputSchemas.validate(json(completedOutput))
        try OutputSchemas.validate(json(try render(AgentModeResult(error: AgentModeFailure("batchStopped", "Stopped."),
            capture: capture, batch: stopped, cache: invalidated,
            nextSteps: [AgentModeFailure.batchRest]), view: view)))
    }

    @Test("Ordinary command results match their schema")
    func commandResultsMatch() throws {
        let payload = CLIOutputValue.object(["udid": .string("fixture"), "state": .string("Booted")])
        let cases: [([CLIOutputValue], [String], CLIOutputFailure?)] = [
            ([], [], nil),
            ([payload], [], nil),
            ([payload, payload], ["Tapped."], nil),
            ([], ["Partial output."], CLIOutputFailure(code: "commandFailed", message: "Simulator not found.")),
        ]
        for (values, messages, failure) in cases {
            let context = CLIOutputContext(format: .json, command: "list-simulators", agent: false)
            for value in values { context.append(value) }
            for message in messages { context.append(message: message) }
            let output = try JSONDecoder().decode(CLIOutputValue.self,
                from: CLIOutput.rendered(context, failure: failure))
            #expect(output["didError"]?.boolValue == (failure != nil))
            try OutputSchemas.validate(json(output))
        }
    }

    @Test("Strict validation rejects undeclared, missing and malformed fields")
    func validatorRejectsDrift() throws {
        let (snapshot, context) = try makeSnapshot()
        let capture = snapshot.capture(id: Self.snapshotID, sequence: 1, udid: "fixture",
            request: .init(kind: .describe), applicationPID: 1234, context: context, unchanged: false, expiresIn: 60)
        let valid = try render(AgentModeResult(capture: capture, cache: refreshed), view: .reading)
        try OutputSchemas.validate(json(valid))
        let validator = try #require(try OutputSchemas.validator(schema: "axe.output.agent-result", version: "2"))

        let undeclared = try replacing(valid, path: ["data", "capture", "newField"], with: .bool(true))
        #expect(try validator.validate(json(undeclared), strict: false).isEmpty)
        #expect(try validator.validate(json(undeclared), strict: true) == ["$.data.capture: field newField is not declared in the schema."])

        let missing = try replacing(valid, path: ["data", "cache"], with: nil)
        #expect(try validator.validate(json(missing), strict: false) == ["$.data: missing required field cache."])

        let wrongVersion = try replacing(valid, path: ["schemaVersion"], with: .string("1"))
        #expect(try !validator.validate(json(wrongVersion), strict: false).isEmpty)

        let sixColumnRow = try replacing(valid, path: ["data", "capture", "rows"],
            with: .array([.string("e2|tap|button|Save||save")]))
        #expect(try validator.validate(json(sixColumnRow), strict: false).contains { $0.hasPrefix("$.data.capture.rows[0]:") })

        let unchangedWithRows = try replacing(valid, path: ["data", "capture", "unchanged"], with: .bool(true))
        #expect(try validator.validate(json(unchangedWithRows), strict: false).contains { $0.contains("oneOf") })

        let unknownVersion = try replacing(valid, path: ["schemaVersion"], with: .string("3"))
        #expect(throws: OutputSchemaValidator.SchemaError.self) { try OutputSchemas.validate(json(unknownVersion)) }
        #expect(throws: OutputSchemaValidator.SchemaError.self) {
            _ = try OutputSchemaValidator(schema: .object(["format": .string("uuid")]))
        }
    }

    // MARK: - Fixtures

    private let refreshed = AgentModeCacheState(status: "refreshed", reason: nil, requiresRefresh: false)
    private let invalidated = AgentModeCacheState(status: "invalidated", reason: "screenChanged", requiresRefresh: true)

    private func render(_ result: AgentModeResult?, view: AgentOutputView,
                        failure: CLIOutputFailure? = nil) throws -> CLIOutputValue {
        let context = CLIOutputContext(format: .json, command: "describe-ui", agent: true)
        context.setAgentView(view)
        if let result {
            context.append(try JSONDecoder().decode(CLIOutputValue.self, from: JSONEncoder().encode(result)))
        }
        return try JSONDecoder().decode(CLIOutputValue.self, from: CLIOutput.rendered(context, failure: failure))
    }

    private func json(_ value: CLIOutputValue) throws -> OutputSchemaJSON {
        try OutputSchemaJSON(json: JSONEncoder().encode(value))
    }

    private func replacing(_ value: CLIOutputValue, path: [String], with replacement: CLIOutputValue?) throws -> CLIOutputValue {
        guard case var .object(fields) = value, let key = path.first else {
            throw OutputSchemaValidator.SchemaError(description: "Cannot replace a field outside an object.")
        }
        if path.count == 1 {
            fields[key] = replacement
        } else {
            fields[key] = try replacing(fields[key] ?? .object([:]), path: Array(path.dropFirst()), with: replacement)
        }
        return .object(fields)
    }

    /// Seventy buttons push the scroll area past the first page, so the first page carries an
    /// area preview and a cursor. The first button's label is long enough to be clipped in compact views.
    private func makeSnapshot() throws -> (AgentModeSnapshot, SelectedHIDContext) {
        let context = try JSONDecoder().decode(SelectedHIDContext.self, from: Data(
            #"{"bootIdentity":"1:2:3","screenID":3,"screenUUID":"DFEBAD86-C7D4-45CA-BB20-2F2D73B355B0","logicalWidth":402,"logicalHeight":874,"rotationDegrees":0,"nativePixelWidth":1206,"nativePixelHeight":2622,"scale":3,"poseRevision":"static"}"#.utf8))
        let buttons = (1...70).map { Fixture(type: "Button", id: "button.\($0)", label: "Button \($0)") }
        let long = Fixture(type: "Button", id: "button.long", label: String(repeating: "long|label ", count: 30))
        let field = Fixture(type: "TextField", id: "field", label: "Name", value: "Ada")
        let scroll = Fixture(type: "ScrollView", id: "scroll", label: "List", children:
            (1...3).map { Fixture(type: "StaticText", id: "", label: "Row \($0)") })
        let roots = [Fixture(type: "Application", id: "fixture", label: "Fixture",
            children: [long, field] + buttons + [scroll])]
        let nodes = try JSONDecoder().decode([FBSimulatorAXNode].self, from: JSONEncoder().encode(roots))
        return (try AgentModeSnapshot(roots: nodes, context: context), context)
    }

    private struct Fixture: Encodable {
        struct Frame: Encodable {
            let x = 10.0
            let y = 100.0
            let width = 300.0
            let height = 44.0
        }
        let type: String
        let id: String
        let label: String
        var value: String? = nil
        var children: [Fixture] = []
        let frame = Frame()
        let pid: Int32 = 1234
        let enabled = true
        let hidden = false
        let focused = false
        private enum CodingKeys: String, CodingKey {
            case type, id = "AXUniqueId", label = "AXLabel", value = "AXValue", children, frame, pid, enabled, hidden, focused
        }
    }
}
