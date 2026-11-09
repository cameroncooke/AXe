import Darwin
import Foundation

/// Serial nonblocking descriptor writes. Does not close a caller-owned descriptor.
/// The deadline bounds userspace backpressure waits, not a stalled kernel/filesystem.
@MainActor
final class SelectedStreamOutput {
    private let descriptor: Int32
    private let originalFlags: Int32
    private let originalNoSIGPIPE: Int32
    private var restored = false
    private let writeTimeout: Double

    init(descriptor: Int32, writeTimeout: Double = 5) throws {
        guard writeTimeout.isFinite, writeTimeout > 0, writeTimeout <= 5 else {
            throw CLIError(errorDescription: "Invalid selected stream write timeout", code: .invalidArguments)
        }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0 else { throw Self.posixError() }
        let noSIGPIPE = fcntl(descriptor, F_GETNOSIGPIPE)
        guard noSIGPIPE >= 0 else { throw Self.posixError() }
        guard fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw Self.posixError() }
        guard fcntl(descriptor, F_SETNOSIGPIPE, Int32(1)) == 0 else {
            let failure = Self.posixError()
            guard fcntl(descriptor, F_SETFL, flags) == 0 else {
                throw CLIError(errorDescription: "Stream descriptor setup failed (\(failure)); flags could not be restored", code: .outputFailed)
            }
            throw failure
        }
        self.descriptor = descriptor
        originalFlags = flags
        originalNoSIGPIPE = noSIGPIPE
        self.writeTimeout = writeTimeout
    }

    /// False means stopped before any byte of this packet. Once started, finish the
    /// packet within the same finite deadline or throw; a partial packet is never success.
    func write(_ data: Data, stopRequested: @MainActor () -> Bool = { false }) async throws -> Bool {
        guard !restored else { throw CLIError(errorDescription: "Stream output is already restored", code: .outputFailed) }
        let deadline = ProcessInfo.processInfo.systemUptime + writeTimeout
        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            if offset == 0, stopRequested() { return false }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw CLIError(errorDescription: "Selected stream output timed out after \(offset) of \(data.count) bytes", code: .timeout)
            }
            let written = data.withUnsafeBytes { bytes in
                Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), min(65_536, data.count - offset))
            }
            if written > 0 {
                offset += written
                // Yield after every chunk so signals can cancel capture or stop the next frame.
                await Task.yield()
                continue
            }
            if written == 0 { throw CLIError(errorDescription: "Selected stream output made no progress", code: .outputFailed) }
            let code = errno
            if code == EINTR { await Task.yield(); continue }
            guard code == EAGAIN || code == EWOULDBLOCK else {
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try Task.checkCancellation()
        return true
    }

    /// Attempt both restorations even if one fails. Caller must propagate the error.
    func restore() throws {
        guard !restored else { return }
        let flagsResult = fcntl(descriptor, F_SETFL, originalFlags)
        let flagsError = flagsResult == 0 ? nil : Self.posixError()
        let signalResult = fcntl(descriptor, F_SETNOSIGPIPE, originalNoSIGPIPE)
        let signalError = signalResult == 0 ? nil : Self.posixError()
        if let flagsError { throw flagsError }
        if let signalError { throw signalError }
        restored = true
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
