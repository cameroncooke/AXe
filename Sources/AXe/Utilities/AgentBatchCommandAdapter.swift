import ArgumentParser
import Foundation

enum AgentBatchCommandAdapter {
    static func run(file: String, expectedPID: Int32?, simulatorUDID: String) throws {
        let url = URL(fileURLWithPath: file)
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw ValidationError("Agent batch --file must be a regular JSON file.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: 16_385) ?? Data()
        try run(data: bytes, expectedPID: expectedPID, simulatorUDID: simulatorUDID)
    }

    static func run(data: Data, expectedPID: Int32?, simulatorUDID: String) throws {
        try AgentModeCommandAdapter.send(request(data: data, expectedPID: expectedPID), simulatorUDID: simulatorUDID)
    }

    /// Both public input forms use the same bounded document and native request validation.
    static func request(data bytes: Data, expectedPID: Int32?) throws -> SelectedHIDRequest {
        guard !bytes.isEmpty, bytes.count <= 16_384 else {
            throw ValidationError("Agent batch JSON must contain 1...16384 bytes.")
        }
        let document: AgentBatchDocument
        do {
            document = try JSONDecoder().decode(AgentBatchDocument.self, from: bytes)
        } catch is DecodingError {
            // A malformed file is the caller's mistake, not a response AXe failed to read.
            throw ValidationError("Agent batch JSON is malformed or lacks a steps array.")
        }
        let batch = AgentBatchRequest(expectedPID: expectedPID, snapshotID: document.snapshotID, steps: document.steps)
        try batch.validate()
        var request = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
            screenID: nil, screenUUID: nil, operation: .complete, token: nil, primitives: [])
        request.agentBatch = batch
        try request.validate()
        return request
    }
}
