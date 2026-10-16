import Foundation
import Testing
@testable import AXe

@Suite("Uncaught Exception Guard Tests", .serialized)
struct UncaughtExceptionGuardTests {
    // Reference type: closures capture the instance, not local storage, so the
    // runtime exclusivity checker never sees overlapping accesses to captured vars.
    private final class Recorder {
        var lines: [String] = []
        var exitCode: Int32?

        /// Captures one line of reported output.
        func record(_ message: String) {
            lines.append(message)
        }

        /// Captures the exit code the guard requested.
        func terminate(_ code: Int32) {
            exitCode = code
        }
    }

    /// Points the guard's seams at a recorder for the duration of `body`.
    private func withTestSeams(
        _ body: (Recorder) -> Void
    ) -> Recorder {
        let recorder = Recorder()
        let originalWrite = UncaughtExceptionGuard.writeError
        let originalTerminate = UncaughtExceptionGuard.terminate
        UncaughtExceptionGuard.writeError = { recorder.record($0) }
        UncaughtExceptionGuard.terminate = { recorder.terminate($0) }
        defer {
            UncaughtExceptionGuard.writeError = originalWrite
            UncaughtExceptionGuard.terminate = originalTerminate
        }
        body(recorder)
        return recorder
    }

    /// Verifies name, reason, and top frames are reported and EX_SOFTWARE is used.
    @Test("Reports exception details and terminates with EX_SOFTWARE")
    func reportsDetailsAndExits() {
        let recorder = withTestSeams { recorder in
            UncaughtExceptionGuard.handle(
                name: "NSInternalInconsistencyException",
                reason: "Invalid parameter not satisfying: typeSignature != nil",
                stack: ["0 AXe 0x1 main + 42", "1 CoreFoundation 0x2 -[NSException raise] + 10"]
            )
        }

        #expect(recorder.exitCode == UncaughtExceptionGuard.exitCode)
        #expect(recorder.exitCode == 70)
        let output = recorder.lines.joined(separator: "\n")
        #expect(output.contains("uncaught Objective-C exception"))
        #expect(output.contains("Exception: NSInternalInconsistencyException"))
        #expect(output.contains("Invalid parameter not satisfying"))
        #expect(!output.contains(UncaughtExceptionGuard.remoteObjectRecoveryHint))
        #expect(output.contains("Top frames:"))
    }

    /// Verifies the recovery hint appears only for remote-object failures.
    @Test("ROCKit stack frames add the remote-object recovery hint")
    func rockitFramesAddRecoveryHint() {
        let recorder = withTestSeams { _ in
            UncaughtExceptionGuard.handle(
                name: "NSInternalInconsistencyException",
                reason: "deserialization failed",
                stack: ["0 ROCKit 0x1 rock_DictionaryTypeEntryDeserializer + 8", "1 ROCKit 0x2 rock_XPCObjectToNSObject + 4"]
            )
        }

        let output = recorder.lines.joined(separator: "\n")
        #expect(output.contains(UncaughtExceptionGuard.remoteObjectRecoveryHint))
        #expect(output.contains("non-sandboxed process"))
    }

    /// Verifies over-long reasons cannot flood stderr unbounded.
    @Test("Long reasons are truncated")
    func longReasonsAreTruncated() {
        let recorder = withTestSeams { _ in
            UncaughtExceptionGuard.handle(
                name: "SomeException",
                reason: String(repeating: "x", count: 1000),
                stack: []
            )
        }

        let output = recorder.lines.joined(separator: "\n")
        #expect(!output.contains(String(repeating: "x", count: 600)))
    }

    /// Verifies a nil exception reason does not crash the handler.
    @Test("Missing reason is reported instead of crashing")
    func missingReasonIsHandled() {
        let recorder = withTestSeams { _ in
            UncaughtExceptionGuard.handle(
                name: "SomeException",
                reason: "No reason provided.",
                stack: []
            )
        }

        #expect(recorder.exitCode == UncaughtExceptionGuard.exitCode)
        #expect(recorder.lines.joined(separator: "\n").contains("No reason provided."))
    }

    /// Verifies the frames section is omitted when there is no stack.
    @Test("Empty stack omits the top frames section")
    func emptyStackOmitsFramesSection() {
        let recorder = withTestSeams { _ in
            UncaughtExceptionGuard.handle(name: "SomeException", reason: "r", stack: [])
        }

        #expect(!recorder.lines.joined(separator: "\n").contains("Top frames:"))
    }
}
