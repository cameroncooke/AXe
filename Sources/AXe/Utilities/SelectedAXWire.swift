import Darwin
import Foundation

/// A distinct bound for selected AX replies. Legacy and request readers are unchanged.
enum SelectedAXWire {
    static func readResponse(from descriptor: Int32, maximumBytes: Int) throws -> Data {
        guard maximumBytes > 0, maximumBytes <= SelectedAXBounds.responseBytes else {
            throw SelectedHIDFailure.invalid("Invalid selected response bound")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw SelectedHIDFailure.invalid("Selected response read timed out") }
                throw HIDBroker.posixError("read selected response")
            }
            guard count > 0 else { throw SelectedHIDFailure.invalid("Selected response ended before its newline") }
            let end = buffer[..<count].firstIndex(of: 10)
            let part = buffer[..<(end ?? count)]
            guard part.count <= maximumBytes - data.count else {
                throw SelectedHIDFailure.invalid("Selected response exceeds its size bound")
            }
            data.append(contentsOf: part)
            if end != nil { return data }
        }
    }
    static func encodeResponse(_ response: SelectedHIDResponse, maximumBytes: Int) throws -> Data {
        var bytes = try JSONEncoder().encode(response)
        guard bytes.count <= maximumBytes else { throw SelectedHIDFailure.invalid("Selected response exceeds its size bound") }
        bytes.append(10)
        return bytes
    }
    static func boundedResponse(_ response: SelectedHIDResponse, maximumBytes: Int) throws -> Data {
        do { return try encodeResponse(response, maximumBytes: maximumBytes) }
        catch {
            // Diagnostic timing never changes whether the real response fits.
            if response.timing != nil {
                var untimed = response
                untimed.timing = nil
                return try boundedResponse(untimed, maximumBytes: maximumBytes)
            }
            if response.readingContinuation != nil {
                var original = response
                original.readingContinuation = nil
                if let bytes = try? encodeResponse(original, maximumBytes: maximumBytes) { return bytes }
            }
            if let agent = response.agent {
                let failure = AgentModeFailure("responseTooLarge",
                    "The agent response exceeds its size bound. Capture and error details were omitted. Inspect the action receipt before continuing.")
                let quarantine = agent.data.quarantine ?? response.quarantine
                var summary = SelectedHIDResponse(version: response.version, requestID: response.requestID,
                    brokerID: response.brokerID, outcome: response.outcome, token: response.token,
                    enqueuedEventCount: response.enqueuedEventCount, cleanup: response.cleanup,
                    error: failure.message, context: response.context, quarantine: response.quarantine)
                summary.agent = AgentModeResult(error: failure, action: agent.data.action, batch: agent.data.batch,
                    cache: AgentModeCacheState(status: quarantine == nil ? "invalidated" : "quarantined",
                        reason: failure.code, requiresRefresh: true),
                    context: agent.data.context ?? response.context, quarantine: quarantine,
                    nextSteps: [
                        "Input was not replayed. Do not repeat the action.",
                        quarantine == nil
                            ? "Inspect the action and cleanup receipt. Run describe-ui --agent before another reference action."
                            : "Inspect the action and quarantine receipts. Complete explicit input recovery before requesting a fresh agent snapshot.",
                    ])
                // Preserve the receipt or fail explicitly; never drop it to make a response fit.
                return try encodeResponse(summary, maximumBytes: maximumBytes)
            }
            // Do not emit partial JSON. Preserve input accounting and mark evidence omitted.
            var summary = response.ax.map { SelectedAXResult(kind: $0.kind, expectedPID: $0.expectedPID) }
            summary?.failure = .responseTooLarge
            // The scalar slider receipt is bounded before its first action.
            summary?.slider = response.ax?.slider
            let failure = SelectedHIDResponse(version: response.version, requestID: response.requestID,
                brokerID: response.brokerID, outcome: response.outcome, token: response.token,
                enqueuedEventCount: response.enqueuedEventCount, cleanup: response.cleanup,
                error: "Response exceeds its size bound; AX payload omitted. Original outcome: \(response.outcome). No request was replayed.",
                context: response.context, ax: summary, quarantine: response.quarantine, hinge: response.hinge)
            return try encodeResponse(failure, maximumBytes: maximumBytes)
        }
    }
}
