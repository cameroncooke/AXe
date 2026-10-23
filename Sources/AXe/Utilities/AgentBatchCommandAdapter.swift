import ArgumentParser
import Foundation

enum AgentBatchCommandAdapter {
    static func run(file: String, expectedPID: Int32, simulatorUDID: String) throws {
        let url = URL(fileURLWithPath: file)
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw ValidationError("Agent batch --file must be a regular JSON file.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: 16_385) ?? Data()
        guard !bytes.isEmpty, bytes.count <= 16_384 else {
            throw ValidationError("Agent batch JSON must contain 1...16384 bytes.")
        }
        let document = try JSONDecoder().decode(AgentBatchDocument.self, from: bytes)
        let batch = AgentBatchRequest(expectedPID: expectedPID, steps: document.steps)
        try batch.validate()
        var request = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
            screenID: nil, screenUUID: nil, operation: .complete, token: nil, primitives: [])
        request.agentBatch = batch
        try request.validate()
        try AgentModeCommandAdapter.send(request, simulatorUDID: simulatorUDID)
    }
}
