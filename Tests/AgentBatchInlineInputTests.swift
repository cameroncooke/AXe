import ArgumentParser
import Foundation
import Testing
@testable import AXe

@Suite("Agent inline batch input")
struct AgentBatchInlineInputTests {
    @Test("Inline JSON preserves literal text rather than interpreting shell steps")
    func literalJSONText() throws {
        let json = #"{"steps":[{"action":"type","id":"field","text":"A 'quoted' $(echo never) `literal` | \\ \n"}]}"#
        let command = try Batch.parse(["--agent", "--steps-json", json, "--udid", "fixture"])
        #expect(command.stepsJSON == json && command.file == nil)
        let request = try AgentBatchCommandAdapter.request(data: Data(json.utf8), expectedPID: nil)
        let batch = try #require(request.agentBatch)
        #expect(batch.steps.count == 1 && batch.steps[0].action == .type)
        #expect(batch.steps[0].text == "A 'quoted' $(echo never) `literal` | \\ \n")
    }

    @Test("Inline agent input is exclusive while legacy and file sources remain valid")
    func sourceValidation() throws {
        let json = #"{"steps":[{"action":"tap","id":"clear"}]}"#
        let base = ["--udid", "fixture"]
        for options in [
            ["--steps-json", json],
            ["--agent"],
            ["--agent", "--steps-json", json, "--file", "/unused/steps.json"],
            ["--agent", "--steps-json", json, "--step", "tap --id clear"],
            ["--agent", "--steps-json", json, "--stdin"],
            ["--agent", "--steps-json", json, "--continue-on-error"],
            ["--agent", "--steps-json", json, "--input-mode", "selected"],
        ] {
            #expect(throws: (any Error).self) { try Batch.parse(base + options) }
        }
        #expect(try Batch.parse(base + ["--agent", "--file", "/unused/steps.json"]).stepsJSON == nil)
        #expect(try Batch.parse(base + ["--step", "tap -x 10 -y 20"]).steps.count == 1)
        #expect(try Batch.parse(base + ["--file", "/unused/legacy.steps"]).file == "/unused/legacy.steps")
        #expect(try Batch.parse(base + ["--stdin"]).useStdin)
    }

    @Test("The common parser enforces the byte limit, including multibyte input")
    func boundedBytes() throws {
        let valid = Data(#"{"steps":[{"action":"tap","id":"clear"}]}"#.utf8)
        let boundary = valid + Data(repeating: 0x20, count: 16_384 - valid.count)
        #expect(try AgentBatchCommandAdapter.request(data: boundary, expectedPID: nil).agentBatch?.steps.count == 1)
        for invalid in [Data(), boundary + Data([0x20]), Data([0xFF])] {
            #expect(throws: (any Error).self) {
                try AgentBatchCommandAdapter.request(data: invalid, expectedPID: nil)
            }
        }
        let identifier = String(repeating: "é", count: 1030)
        let step = "{\"action\":\"tap\",\"id\":\"\(identifier)\"}"
        let json = "{\"steps\":[" + Array(repeating: step, count: 8).joined(separator: ",") + "]}"
        #expect(json.count < 16_384 && json.utf8.count > 16_384)
        #expect(throws: (any Error).self) {
            try AgentBatchCommandAdapter.request(data: Data(json.utf8), expectedPID: nil)
        }
    }

    @Test("Malformed JSON is reported as an invalid argument that names JSON")
    func malformedJSON() {
        for text in ["{", "[]", #"{"steps":"tap"}"#, #"{"snapshotID":"x","steps":[]}"#] {
            do {
                _ = try AgentBatchCommandAdapter.request(data: Data(text.utf8), expectedPID: nil)
                Issue.record("Accepted \(text)")
            } catch {
                let failure = CLIErrorMapping.failure(for: error)
                #expect(failure.code == "invalidArguments", "\(text): \(failure.code)")
                #expect(failure.message.contains("JSON"), "\(text): \(failure.message)")
            }
        }
    }

    @Test("Inline preparation keeps the existing reference, schema and step limits")
    func existingDocumentContract() throws {
        let snapshot = "3FF70D78-26DA-4314-B37B-4CB57D2A1A85"
        let steps = Array(repeating: #"{"action":"tap","ref":"e2"}"#, count: 8).joined(separator: ",")
        let valid = "{\"snapshotID\":\"\(snapshot)\",\"steps\":[\(steps)]}"
        let request = try AgentBatchCommandAdapter.request(data: Data(valid.utf8), expectedPID: 1234)
        let batch = try #require(request.agentBatch)
        #expect(batch.snapshotID == UUID(uuidString: snapshot) && batch.steps.count == 8)
        #expect(batch.expectedPID == 1234 && batch.usesReferences)
        for json in [
            "{\"snapshotID\":\"\(snapshot)\",\"steps\":[\(steps),{\"action\":\"tap\",\"ref\":\"e2\"}]}",
            #"{"steps":[{"action":"tap","ref":"e2"}]}"#,
            #"{"steps":[{"action":"tap","id":"clear","x":10}]}"#,
            #"tap --id clear"#,
        ] {
            #expect(throws: (any Error).self) {
                try AgentBatchCommandAdapter.request(data: Data(json.utf8), expectedPID: nil)
            }
        }
    }
}
