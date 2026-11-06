import Foundation

/// Opt-in phase timing for diagnosing slow commands.
///
/// A timer records nothing until a caller binds it with `PhaseTimer.$current.withValue`.
/// Code that runs without a bound timer pays one task-local read per phase.
/// Spans use `ProcessInfo.systemUptime`, which is shared by every process on the host,
/// so client and broker spans can be placed on one timeline.
final class PhaseTimer: @unchecked Sendable {
    struct Span: Codable, Sendable, Equatable {
        let name: String
        let depth: Int
        let startMilliseconds: Double
        let durationMilliseconds: Double
    }

    /// Bounds the wire payload. Phases after this many are not recorded.
    static let maximumSpans = 1024

    @TaskLocal static var current: PhaseTimer?
    @TaskLocal private static var depth = 0

    let originUptime: TimeInterval
    private let clock: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var entries: [(name: String, depth: Int, start: TimeInterval, end: TimeInterval?)] = []

    init(clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
        originUptime = clock()
    }

    /// Completed and open spans in start order. A parent precedes its children.
    /// An open span reports the time elapsed so far.
    var spans: [Span] {
        let now = clock()
        lock.lock()
        defer { lock.unlock() }
        return entries.map { entry in
            Span(name: entry.name, depth: entry.depth,
                 startMilliseconds: (entry.start - originUptime) * 1000,
                 durationMilliseconds: ((entry.end ?? now) - entry.start) * 1000)
        }
    }

    var payload: PhaseTimingPayload { PhaseTimingPayload(originUptime: originUptime, spans: spans) }

    @MainActor
    static func measure<T>(_ name: String, _ body: () async throws -> T) async rethrows -> T {
        guard let timer = current else { return try await body() }
        let level = depth
        let index = timer.begin(name, depth: level)
        defer { timer.end(index) }
        return try await $depth.withValue(level + 1) { try await body() }
    }

    /// For code that runs off the main actor, such as native context reads on the AX worker.
    /// The task-local timer and depth follow the task across actor hops.
    nonisolated static func measureNonisolated<T: Sendable>(_ name: String,
                                                          _ body: @Sendable () async throws -> T) async rethrows -> T {
        guard let timer = current else { return try await body() }
        let level = depth
        let index = timer.begin(name, depth: level)
        defer { timer.end(index) }
        return try await $depth.withValue(level + 1) { try await body() }
    }

    static func measureSync<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        guard let timer = current else { return try body() }
        let level = depth
        let index = timer.begin(name, depth: level)
        defer { timer.end(index) }
        return try $depth.withValue(level + 1) { try body() }
    }

    private func begin(_ name: String, depth: Int) -> Int? {
        let start = clock()
        lock.lock()
        defer { lock.unlock() }
        guard entries.count < Self.maximumSpans else { return nil }
        entries.append((name, depth, start, nil))
        return entries.count - 1
    }

    private func end(_ index: Int?) {
        guard let index else { return }
        let end = clock()
        lock.lock()
        defer { lock.unlock() }
        entries[index].end = end
    }
}

/// Broker phases returned only when the request asks for timing.
struct PhaseTimingPayload: Codable, Sendable, Equatable {
    let originUptime: TimeInterval
    let spans: [PhaseTimer.Span]
}

/// `AXE_TIMING=1` prints a phase table to standard error after each agent command.
/// `AXE_TIMING=/absolute/path.jsonl` appends one JSON record per command instead.
/// Standard output is unchanged in both modes.
enum PhaseTimingOutput {
    static let environmentKey = "AXE_TIMING"

    enum Destination: Equatable {
        case standardError
        case file(String)
    }

    struct Record: Codable, Equatable {
        let schema: String
        let schemaVersion: Int
        let command: String
        let requestID: UUID
        let totalMilliseconds: Double
        let brokerTimingReturned: Bool
        let spans: [PhaseTimer.Span]
    }

    static func destination(environment: [String: String] = ProcessInfo.processInfo.environment) -> Destination? {
        guard let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw != "0", raw.lowercased() != "false" else { return nil }
        return raw.hasPrefix("/") ? .file(raw) : .standardError
    }

    /// Places broker spans under the client exchange on one timeline.
    static func record(command: String, requestID: UUID, client: PhaseTimer,
                       broker: PhaseTimingPayload?) -> Record {
        let clientSpans = client.spans
        var merged: [PhaseTimer.Span] = []
        var inserted = false
        for span in clientSpans {
            merged.append(span)
            guard !inserted, span.name == "client.exchange", let broker else { continue }
            inserted = true
            let offset = (broker.originUptime - client.originUptime) * 1000
            merged += broker.spans.map {
                PhaseTimer.Span(name: $0.name, depth: $0.depth + span.depth + 1,
                    startMilliseconds: $0.startMilliseconds + offset,
                    durationMilliseconds: $0.durationMilliseconds)
            }
        }
        let total = clientSpans.map { $0.startMilliseconds + $0.durationMilliseconds }.max() ?? 0
        return Record(schema: "axe.timing", schemaVersion: 1, command: command, requestID: requestID,
            totalMilliseconds: total, brokerTimingReturned: broker != nil, spans: merged)
    }

    static func render(_ record: Record) -> String {
        var lines = ["axe timing: \(record.command) \(format(record.totalMilliseconds)) ms"]
        lines.append("  " + pad("start", 9) + pad("ms", 10) + "  phase")
        for span in record.spans {
            lines.append("  " + pad(format(span.startMilliseconds), 9) + pad(format(span.durationMilliseconds), 10)
                + "  " + String(repeating: "  ", count: span.depth) + span.name)
        }
        if !record.brokerTimingReturned {
            lines.append("  The broker returned no phases. It may be an older broker; wait for it to exit and retry.")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Never throws. A failed write reports one line on standard error.
    static func emit(_ record: Record, to destination: Destination) {
        switch destination {
        case .standardError:
            FileHandle.standardError.write(Data(render(record).utf8))
        case .file(let path):
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                var line = try encoder.encode(record)
                line.append(10)
                if !FileManager.default.fileExists(atPath: path) {
                    guard FileManager.default.createFile(atPath: path, contents: nil) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
                let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } catch {
                FileHandle.standardError.write(Data("axe timing: could not append to \(path): \(error)\n".utf8))
            }
        }
    }

    static var commandName: String {
        CommandLine.arguments.dropFirst().first ?? "axe"
    }

    private static func format(_ milliseconds: Double) -> String {
        String(format: "%.1f", milliseconds)
    }

    private static func pad(_ value: String, _ width: Int) -> String {
        value.count >= width ? value : String(repeating: " ", count: width - value.count) + value
    }
}
