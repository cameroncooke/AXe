import Darwin
import Foundation

/// Converts uncaught Objective-C exceptions into a clean CLI failure.
///
/// The simulator's remote-object stack (Apple's ROCKit, reached through
/// FBSimulatorControl) raises `NSInternalInconsistencyException` from its XPC
/// deserializer when the host process cannot claim the IOSurface carried by a
/// device-side message — observed when AXe runs inside a macOS sandbox. Without
/// a handler, that exception aborts the whole process with a crash report
/// instead of actionable output.
enum UncaughtExceptionGuard {
    /// `sysexits.h` code for internal software error: something in the process
    /// failed, distinct from usage errors handled by ArgumentParser.
    static let exitCode: Int32 = EX_SOFTWARE

    /// Advice for failures originating in the simulator's remote-object stack.
    static let remoteObjectRecoveryHint = "The failure came from the simulator's remote object connection, which cannot be used from inside a macOS sandbox. Re-run AXe from a non-sandboxed process; if it still fails outside a sandbox, reboot the simulator and try again."

    private static let reasonCharacterLimit = 500

    // Test seams: observing behaviour without ending the process. The real
    // defaults are a stderr write and `exit`.
    static var writeError: (String) -> Void = { message in
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
    static var terminate: (Int32) -> Void = { code in
        exit(code)
    }

    private static var isInstalled = false

    /// Registers the process-level handler. Safe to call more than once.
    static func install() {
        guard !isInstalled else { return }
        isInstalled = true
        NSSetUncaughtExceptionHandler { exception in
            UncaughtExceptionGuard.handle(exception)
        }
    }

    /// Entry point for the Obj-C runtime: converts a raised exception into a
    /// reported failure.
    static func handle(_ exception: NSException) {
        handle(
            name: exception.name.rawValue,
            reason: exception.reason ?? "No reason provided.",
            stack: exception.callStackSymbols
        )
    }

    /// Reports the failure and terminates through the seams. Split from
    /// `handle(_:)` so tests can drive arbitrary stack traces without raising.
    static func handle(name: String, reason: String, stack: [String]) {
        var lines = [
            "AXe encountered an uncaught Objective-C exception and must exit.",
            "Exception: \(name)",
            "Reason: \(truncate(reason, to: reasonCharacterLimit))",
        ]
        if stack.contains(where: { $0.contains("ROCKit") }) {
            lines.append(remoteObjectRecoveryHint)
        }
        if !stack.isEmpty {
            lines.append("Top frames:")
            lines.append(contentsOf: stack.prefix(3))
        }
        writeError(lines.joined(separator: "\n"))
        terminate(exitCode)
    }

    /// Elides the tail of over-long reasons so multi-kilobyte framework
    /// messages stay readable on stderr.
    private static func truncate(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }
}
