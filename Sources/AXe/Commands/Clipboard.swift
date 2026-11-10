import ArgumentParser
import CryptoKit
import Darwin
import Foundation

struct Clipboard: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Copy text to a simulator's clipboard.",
        subcommands: [ClipboardCopy.self])
}

private struct ClipboardCopy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "copy",
        abstract: "Copy UTF-8 text from stdin to a booted simulator's clipboard.",
        discussion: """
        AXe copies the bytes unchanged, reads them back to verify, and prints the byte count and SHA-256. The copy replaces the clipboard, which can be shared with the Mac; it does not paste.

        Example:
          printf '%s' 'AXe sample' | axe clipboard copy --stdin --udid <UDID>
        """)

    @Flag(name: .customLong("stdin"), help: "Read the text from standard input, 1 to 65536 bytes (required).")
    var useStdin = false

    @Option(name: .customLong("udid"), help: "UDID of the booted simulator.")
    var simulatorUDID: String

    func validate() throws {
        if AutomationTarget.isPhysicalInputUDID(simulatorUDID) { return }
        guard useStdin, UUID(uuidString: simulatorUDID) != nil else {
            throw ValidationError("clipboard copy requires --stdin and --udid with one valid simulator UUID.")
        }
    }

    func run() async throws {
        try AutomationTarget.refuseOnDevice(simulatorUDID, "The clipboard is available on simulators only.")
        try validate()
        guard let udid = UUID(uuidString: simulatorUDID) else {
            throw ValidationError("clipboard copy requires one valid simulator UUID.")
        }
        let output = try await SimulatorClipboard.withSignals {
            try await SimulatorClipboard.copy(udid: udid)
        }
        try DeviceState.emit(output, text: [output.text])
    }
}

/// What was staged and verified: the byte count and SHA-256 of the exact readback.
struct ClipboardCopyOutput: Encodable, Sendable {
    let udid: String
    let bytes: Int
    let sha256: String

    var text: String { "Copied \(bytes) bytes to the clipboard of \(udid) (sha256 \(sha256))" }
}

/// One standalone public-tool operation. Clipboard bytes and child streams never enter logs or files.
@MainActor
private enum SimulatorClipboard {
    private static let maximumBytes = 65_536
    private static let childTimeout: TimeInterval = 30

    private struct DeviceList: Decodable {
        struct Device: Decodable {
            let udid: UUID
            let state: String
        }
        let devices: [String: [Device]]
    }

    static func withSignals(
        _ operation: @escaping @MainActor () async throws -> ClipboardCopyOutput
    ) async throws -> ClipboardCopyOutput {
        var previousINT = sigaction()
        var previousTERM = sigaction()
        guard sigaction(SIGINT, nil, &previousINT) == 0,
              sigaction(SIGTERM, nil, &previousTERM) == 0 else {
            throw CLIError(errorDescription: "Could not read clipboard command signal dispositions.")
        }
        let task = Task { @MainActor in try await operation() }
        var observer: SignalObserver? = SignalObserver(signals: [SIGINT, SIGTERM]) { task.cancel() }
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
        }
        let interrupted = task.isCancelled || Task.isCancelled
        observer?.invalidate()
        observer = nil
        let restoredINT = sigaction(SIGINT, &previousINT, nil) == 0
        let restoredTERM = sigaction(SIGTERM, &previousTERM, nil) == 0
        guard restoredINT && restoredTERM else {
            throw CLIError(errorDescription: "Could not restore clipboard command signal dispositions.")
        }
        let receipt = try result.get()
        if interrupted { throw CancellationError() }
        return receipt
    }

    static func copy(udid: UUID) async throws -> ClipboardCopyOutput {
        let bytes = try await readStdin()
        try await requireBooted(udid)
        // From this point any failure can follow a partial or completed clipboard change.
        do {
            _ = try await run(["devicectl", "device", "pasteboard", "copy", "--device", udid.uuidString,
                "--timeout", "8", "--quiet"], input: bytes, outputLimit: maximumBytes)
            let readback = try await run(["devicectl", "device", "pasteboard", "paste", "--device", udid.uuidString,
                "--timeout", "8", "--quiet"], outputLimit: maximumBytes)
            guard readback == bytes else {
                throw CLIError(errorDescription: "Clipboard readback does not match the supplied UTF-8 bytes.", code: .actionOutcomeUnknown)
            }
            try await requireBooted(udid)
        } catch {
            let detail: String
            switch error {
            case let failure as CLIError: detail = failure.errorDescription
            case is CancellationError: detail = "The command was cancelled."
            default: detail = "The public clipboard operation failed."
            }
            throw CLIError(errorDescription: "Clipboard copy completion is unverified: \(detail) The shared clipboard may already have changed. No request is replayed.", code: .actionOutcomeUnknown)
        }
        return ClipboardCopyOutput(udid: udid.uuidString, bytes: bytes.count,
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }

    private static func requireBooted(_ udid: UUID) async throws {
        let data = try await run(["simctl", "list", "devices", "--json"], outputLimit: 4 * 1024 * 1024)
        guard let inventory = try? JSONDecoder().decode(DeviceList.self, from: data) else {
            throw CLIError(errorDescription: "Could not decode the simulator inventory.", code: .readFailed)
        }
        let matches = inventory.devices.values.flatMap { $0 }.filter { $0.udid == udid }
        guard matches.count == 1, matches[0].state == "Booted" else {
            throw CLIError(errorDescription: "clipboard copy requires one existing simulator in the Booted state.", code: .notBooted)
        }
    }

    private static func readStdin() async throws -> Data {
        let descriptor = FileHandle.standardInput.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw CLIError(errorDescription: "Could not configure clipboard stdin.", code: .readFailed)
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        do {
            while true {
                try Task.checkCancellation()
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(descriptor, $0.baseAddress, min($0.count, maximumBytes + 1 - result.count))
                }
                if count == 0 { break }
                if count < 0 {
                    let code = errno
                    guard code == EINTR || code == EAGAIN || code == EWOULDBLOCK else {
                        throw CLIError(errorDescription: "Could not read clipboard stdin.", code: .readFailed)
                    }
                    try await Task.sleep(for: .milliseconds(10))
                    continue
                }
                guard result.count + count <= maximumBytes else {
                    throw CLIError(errorDescription: "Clipboard stdin exceeds 64 KiB.", code: .invalidArguments)
                }
                result.append(contentsOf: buffer.prefix(count))
                await Task.yield()
            }
        } catch {
            guard fcntl(descriptor, F_SETFL, flags) == 0 else {
                throw CLIError(errorDescription: "Clipboard stdin failed and its flags could not be restored.")
            }
            throw error
        }
        guard fcntl(descriptor, F_SETFL, flags) == 0 else {
            throw CLIError(errorDescription: "Could not restore clipboard stdin flags.", code: .readFailed)
        }
        guard !result.isEmpty, String(data: result, encoding: .utf8) != nil else {
            throw CLIError(errorDescription: "Clipboard stdin must contain 1...65536 valid UTF-8 bytes.", code: .invalidArguments)
        }
        return result
    }

    private struct PrivateStream {
        let limit: Int
        var data = Data()
        var ended = false

        mutating func drain(_ handle: FileHandle) throws {
            guard !ended else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count)
                }
                if count == 0 { ended = true; return }
                if count < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    if code == EAGAIN || code == EWOULDBLOCK { return }
                    throw CLIError(errorDescription: "Could not read a private clipboard child stream.")
                }
                guard data.count + count <= limit else {
                    throw CLIError(errorDescription: "A private clipboard child stream exceeded its byte limit.")
                }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
    }

    /// Nonblocking pipes drain both child streams while writing stdin. No raw content leaves this owner.
    private static func run(_ arguments: [String], input: Data? = nil, outputLimit: Int) async throws -> Data {
        try Task.checkCancellation()
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        let source = input == nil ? nil : Pipe()
        defer {
            for handle in [output.fileHandleForReading, output.fileHandleForWriting,
                           errors.fileHandleForReading, errors.fileHandleForWriting] {
                try? handle.close()
            }
            try? source?.fileHandleForReading.close()
            try? source?.fileHandleForWriting.close()
        }
        for descriptor in [output.fileHandleForReading.fileDescriptor, errors.fileHandleForReading.fileDescriptor] {
            try makeNonblocking(descriptor)
        }
        if let source {
            try makeNonblocking(source.fileHandleForWriting.fileDescriptor)
            guard fcntl(source.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, Int32(1)) == 0 else {
                throw CLIError(errorDescription: "Could not protect clipboard child stdin from SIGPIPE.")
            }
        }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        process.standardInput = source?.fileHandleForReading ?? FileHandle.nullDevice
        process.standardOutput = output.fileHandleForWriting
        process.standardError = errors.fileHandleForWriting
        do { try process.run() } catch {
            throw CLIError(errorDescription: "Could not launch the public clipboard child command.")
        }
        // Parent copies of child ends must close, so EOF can be observed after child exit.
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        try? source?.fileHandleForReading.close()
        defer { stopAndReap(process) }
        let deadline = ProcessInfo.processInfo.systemUptime + childTimeout
        var stdout = PrivateStream(limit: outputLimit)
        var stderr = PrivateStream(limit: maximumBytes)
        var offset = 0
        var inputClosed = source == nil
        while true {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw CLIError(errorDescription: "The public clipboard child exceeded its 30-second deadline.", code: .timeout)
            }
            try stdout.drain(output.fileHandleForReading)
            try stderr.drain(errors.fileHandleForReading)
            if let source, let input, !inputClosed {
                if offset < input.count {
                    let written = input.withUnsafeBytes {
                        Darwin.write(source.fileHandleForWriting.fileDescriptor,
                            $0.baseAddress!.advanced(by: offset), min(4096, input.count - offset))
                    }
                    if written > 0 { offset += written }
                    if written <= 0 {
                        let code = errno
                        guard written < 0 && (code == EINTR || code == EAGAIN || code == EWOULDBLOCK) else {
                            throw CLIError(errorDescription: "Could not complete clipboard child stdin.")
                        }
                    }
                }
                if offset == input.count {
                    try? source.fileHandleForWriting.close()
                    inputClosed = true
                }
            }
            if !process.isRunning && stdout.ended && stderr.ended { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        process.waitUntilExit()
        guard inputClosed, process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw CLIError(errorDescription: "The public clipboard child failed (exit \(process.terminationStatus)); private output was suppressed.")
        }
        return stdout.data
    }

    private static func makeNonblocking(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw CLIError(errorDescription: "Could not configure a private clipboard pipe.")
        }
    }

    private static func stopAndReap(_ process: Process) {
        if process.isRunning {
            process.terminate()
            let deadline = ProcessInfo.processInfo.systemUptime + 0.5
            while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
    }
}
