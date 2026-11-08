import Foundation
import Testing
@testable import AXe

@Suite("Uncaught exception guard", .serialized)
struct UncaughtExceptionGuardTests {
    private final class Recorder {
        var lines: [String] = []
        var exitCode: Int32?
    }

    private func report(name: String = "NSInternalInconsistencyException", reason: String,
                        stack: [String]) -> Recorder {
        let recorder = Recorder()
        let originalWrite = UncaughtExceptionGuard.writeError
        let originalTerminate = UncaughtExceptionGuard.terminate
        UncaughtExceptionGuard.writeError = { recorder.lines.append($0) }
        UncaughtExceptionGuard.terminate = { recorder.exitCode = $0 }
        defer {
            UncaughtExceptionGuard.writeError = originalWrite
            UncaughtExceptionGuard.terminate = originalTerminate
        }
        UncaughtExceptionGuard.handle(name: name, reason: reason, stack: stack)
        return recorder
    }

    @Test("Reports the exception and exits with EX_SOFTWARE")
    func reportsAndExits() {
        let recorder = report(reason: "Invalid parameter not satisfying: typeSignature != nil",
                              stack: ["0 AXe 0x1 main + 42", "1 CoreFoundation 0x2 -[NSException raise] + 10"])
        let output = recorder.lines.joined(separator: "\n")
        #expect(recorder.exitCode == 70)
        #expect(output.contains("uncaught Objective-C exception"))
        #expect(output.contains("Exception: NSInternalInconsistencyException"))
        #expect(output.contains("Invalid parameter not satisfying"))
        #expect(output.contains("Top frames:"))
        #expect(!output.contains(UncaughtExceptionGuard.remoteObjectRecoveryHint))
    }

    @Test("ROCKit frames add the sandbox recovery hint")
    func rockitHint() {
        let recorder = report(reason: "API VIOLATION: Deserializer for class IOSurface failed without setting an error.",
                              stack: ["0 ROCKit 0x1 rock_DictionaryTypeEntryDeserializer + 8"])
        #expect(recorder.lines.joined(separator: "\n").contains(UncaughtExceptionGuard.remoteObjectRecoveryHint))
    }

    @Test("Long reasons are truncated and an empty stack prints no frames")
    func boundedOutput() {
        let recorder = report(name: "SomeException", reason: String(repeating: "x", count: 1000), stack: [])
        let output = recorder.lines.joined(separator: "\n")
        #expect(!output.contains(String(repeating: "x", count: 501)))
        #expect(output.contains(String(repeating: "x", count: 500) + "..."))
        #expect(!output.contains("Top frames:"))
        #expect(recorder.exitCode == 70)
    }
}
