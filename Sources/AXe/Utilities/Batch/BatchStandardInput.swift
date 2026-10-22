import Darwin
import Foundation

/// Read the ordered type step without blocking the main actor while stdin waits for data.
/// Preserve readFromStdin's line joining, including its treatment of leading empty lines.
@MainActor
enum BatchStandardInput {
    static func read(context: BatchContext) async throws -> String {
        let descriptor = FileHandle.standardInput.fileDescriptor
        var pending = Data()
        var input = ""
        var buffer = [UInt8](repeating: 0, count: 4096)

        func appendLine(_ bytes: Data, terminatedByNewline: Bool) {
            var line = bytes
            if terminatedByNewline, line.last == 13 { line.removeLast() }
            if !input.isEmpty { input += "\n" }
            input += String(decoding: line, as: UTF8.self)
        }

        while true {
            try await context.validateCurrentContext()
            var source = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&source, 1, 0)
            if ready < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if source.revents & Int16(POLLERR | POLLNVAL) != 0 {
                throw CLIError(errorDescription: "Could not read batch type input from stdin.")
            }
            guard ready > 0 else {
                try await Task.sleep(for: .milliseconds(25))
                continue
            }
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 {
                if !pending.isEmpty { appendLine(pending, terminatedByNewline: false) }
                return input
            }
            // Scan each new byte once, including an arbitrarily long unterminated line.
            var lineStart = 0
            for index in 0..<count where buffer[index] == 10 {
                pending.append(contentsOf: buffer[lineStart..<index])
                appendLine(pending, terminatedByNewline: true)
                pending.removeAll(keepingCapacity: true)
                lineStart = index + 1
            }
            pending.append(contentsOf: buffer[lineStart..<count])
        }
    }
}
