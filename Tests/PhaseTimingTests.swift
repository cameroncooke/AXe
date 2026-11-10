import Foundation
import Testing
@testable import AXe

private final class StepClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval
    private let step: TimeInterval
    init(start: TimeInterval = 100, step: TimeInterval = 0.001) { value = start; self.step = step }
    func next() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        let current = value
        value += step
        return current
    }
}

@Suite("Phase timing")
struct PhaseTimingTests {
    @Test("Phases outside a bound timer run without recording")
    func unboundRecordsNothing() throws {
        #expect(PhaseTimer.current == nil)
        let value = PhaseTimer.measureSync("ignored") { 7 }
        #expect(value == 7)
    }

    @Test("Nested phases keep start order and depth")
    func nestedSyncPhases() throws {
        let clock = StepClock()
        let timer = PhaseTimer(clock: { clock.next() })
        PhaseTimer.$current.withValue(timer) {
            PhaseTimer.measureSync("outer") {
                PhaseTimer.measureSync("first") {}
                PhaseTimer.measureSync("second") {}
            }
            PhaseTimer.measureSync("sibling") {}
        }
        let spans = timer.spans
        #expect(spans.map(\.name) == ["outer", "first", "second", "sibling"])
        #expect(spans.map(\.depth) == [0, 1, 1, 0])
        // Each clock read advances 1 ms. The outer phase spans both children.
        #expect(spans[0].durationMilliseconds > spans[1].durationMilliseconds + spans[2].durationMilliseconds)
        #expect(spans.allSatisfy { $0.durationMilliseconds >= 0 })
    }

    @Test("A throwing phase is still closed")
    func throwingPhaseIsRecorded() throws {
        struct Failure: Error {}
        let timer = PhaseTimer()
        PhaseTimer.$current.withValue(timer) {
            _ = try? PhaseTimer.measureSync("fails") { throw Failure() }
        }
        #expect(timer.spans.map(\.name) == ["fails"])
    }

    @MainActor
    @Test("Async phases nest across suspension")
    func nestedAsyncPhases() async throws {
        let timer = PhaseTimer()
        await PhaseTimer.$current.withValue(timer) {
            await PhaseTimer.measure("outer") {
                await PhaseTimer.measure("sleep") { try? await Task.sleep(for: .milliseconds(5)) }
                PhaseTimer.measureSync("work") {}
            }
        }
        let spans = timer.spans
        #expect(spans.map(\.name) == ["outer", "sleep", "work"])
        #expect(spans.map(\.depth) == [0, 1, 1])
        #expect(spans[1].durationMilliseconds >= 4)
    }

    @Test("Phases recorded off the main actor nest under the task-local phase")
    func nonisolatedPhases() async throws {
        let timer = PhaseTimer()
        await PhaseTimer.$current.withValue(timer) {
            await PhaseTimer.measureNonisolated("outer") {
                _ = await PhaseTimer.measureNonisolated("inner") { 1 }
            }
        }
        #expect(timer.spans.map(\.name) == ["outer", "inner"])
        #expect(timer.spans.map(\.depth) == [0, 1])
        let unbound = await PhaseTimer.measureNonisolated("ignored") { 2 }
        #expect(unbound == 2 && timer.spans.count == 2)
    }

    @Test("The span count is bounded")
    func spanCountIsBounded() throws {
        let timer = PhaseTimer()
        PhaseTimer.$current.withValue(timer) {
            for _ in 0..<(PhaseTimer.maximumSpans + 10) { PhaseTimer.measureSync("step") {} }
        }
        #expect(timer.spans.count == PhaseTimer.maximumSpans)
    }

    @Test("Broker phases are placed under the client exchange")
    func brokerPhasesMergeUnderExchange() throws {
        let clock = StepClock(start: 10, step: 0.010)
        let client = PhaseTimer(clock: { clock.next() })
        PhaseTimer.$current.withValue(client) {
            PhaseTimer.measureSync("client.connect") {}
            PhaseTimer.measureSync("client.exchange") {}
        }
        let broker = PhaseTimingPayload(originUptime: client.originUptime + 0.5, spans: [
            PhaseTimer.Span(name: "broker.agent", depth: 0, startMilliseconds: 1, durationMilliseconds: 40),
            PhaseTimer.Span(name: "agent.discover", depth: 1, startMilliseconds: 2, durationMilliseconds: 10),
        ])
        let record = PhaseTimingOutput.record(command: "tap", requestID: UUID(), client: client, broker: broker)
        #expect(record.brokerTimingReturned)
        #expect(record.spans.map(\.name) == ["client.connect", "client.exchange", "broker.agent", "agent.discover"])
        #expect(record.spans.map(\.depth) == [0, 0, 1, 2])
        #expect(abs(record.spans[2].startMilliseconds - 501) < 0.001)
        #expect(record.totalMilliseconds > 0)
        let text = PhaseTimingOutput.render(record)
        #expect(text.hasPrefix("axe timing: tap "))
        #expect(text.contains("      agent.discover"))
        #expect(!text.contains("older broker"))
    }

    @Test("A missing broker payload is reported")
    func missingBrokerPayloadIsReported() throws {
        let client = PhaseTimer()
        PhaseTimer.$current.withValue(client) { PhaseTimer.measureSync("client.exchange") {} }
        let record = PhaseTimingOutput.record(command: "describe-ui", requestID: UUID(), client: client, broker: nil)
        #expect(!record.brokerTimingReturned)
        #expect(record.spans.map(\.name) == ["client.exchange"])
        #expect(PhaseTimingOutput.render(record).contains("older broker"))
    }

    @Test("AXE_TIMING selects standard error, a JSONL file or nothing")
    func destinationParsing() throws {
        #expect(PhaseTimingOutput.destination(environment: [:]) == nil)
        #expect(PhaseTimingOutput.destination(environment: ["AXE_TIMING": ""]) == nil)
        #expect(PhaseTimingOutput.destination(environment: ["AXE_TIMING": "0"]) == nil)
        #expect(PhaseTimingOutput.destination(environment: ["AXE_TIMING": "false"]) == nil)
        #expect(PhaseTimingOutput.destination(environment: ["AXE_TIMING": "1"]) == .standardError)
        #expect(PhaseTimingOutput.destination(environment: ["AXE_TIMING": "/tmp/axe.jsonl"]) == .file("/tmp/axe.jsonl"))
    }

    @Test("JSONL output appends one decodable record per command")
    func jsonlAppends() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("axe-timing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("timing.jsonl").path
        let record = PhaseTimingOutput.Record(schema: "axe.timing", schemaVersion: 1, command: "tap",
            requestID: UUID(), totalMilliseconds: 12, brokerTimingReturned: false,
            spans: [PhaseTimer.Span(name: "client.exchange", depth: 0, startMilliseconds: 0, durationMilliseconds: 12)])
        PhaseTimingOutput.emit(record, to: .file(path))
        PhaseTimingOutput.emit(record, to: .file(path))
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        let decoded = try JSONDecoder().decode(PhaseTimingOutput.Record.self, from: Data(lines[0].utf8))
        #expect(decoded == record)
    }

    @Test("Requests and responses without timing still decode")
    func wireCompatibility() throws {
        let request = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
            screenID: 1, screenUUID: UUID(), operation: .close, token: UUID(), payload: .contact([]))
        let encoded = try JSONEncoder().encode(request)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("timing"))
        #expect(try JSONDecoder().decode(SelectedHIDRequest.self, from: encoded).timing == nil)
        let response = SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: request.requestID,
            brokerID: UUID(), outcome: "completed", token: nil, enqueuedEventCount: 0, cleanup: "notNeeded",
            error: nil, context: nil)
        let responseData = try JSONEncoder().encode(response)
        #expect(!String(decoding: responseData, as: UTF8.self).contains("timing"))
        #expect(try JSONDecoder().decode(SelectedHIDResponse.self, from: responseData).timing == nil)
    }

    @Test("Timing is dropped before a response would exceed its bound")
    func oversizedTimingIsDropped() throws {
        var response = SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: UUID(),
            brokerID: UUID(), outcome: "completed", token: nil, enqueuedEventCount: 2, cleanup: "notNeeded",
            error: nil, context: nil)
        let untimedSize = try JSONEncoder().encode(response).count
        response.timing = PhaseTimingPayload(originUptime: 1, spans: (0..<200).map {
            PhaseTimer.Span(name: "phase \($0)", depth: 0, startMilliseconds: Double($0), durationMilliseconds: 1)
        })
        let bytes = try SelectedAXWire.boundedResponse(response, maximumBytes: untimedSize + 16)
        let decoded = try JSONDecoder().decode(SelectedHIDResponse.self, from: bytes.dropLast())
        #expect(decoded.timing == nil)
        #expect(decoded.outcome == "completed")
        #expect(decoded.enqueuedEventCount == 2)
        #expect(decoded.error == nil)
    }
}
