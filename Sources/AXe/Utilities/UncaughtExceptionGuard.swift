import Darwin
import Foundation

/// Converts an uncaught Objective-C exception into a reported CLI failure.
///
/// The simulator's remote-object stack (Apple's ROCKit, reached through FBSimulatorControl) raises
/// `NSInternalInconsistencyException` from its XPC deserializer when the process cannot claim an
/// IOSurface carried by a device message, which happens inside a macOS sandbox. Without a handler
/// the exception aborts AXe with SIGABRT and a crash report instead of a message a caller can act on.
enum UncaughtExceptionGuard {
    /// `sysexits.h` internal software error, distinct from ArgumentParser's usage errors.
    static let exitCode: Int32 = EX_SOFTWARE

    static let remoteObjectRecoveryHint = "The failure came from the simulator's remote object connection, which cannot be used from inside a macOS sandbox. Run AXe from a process that is not sandboxed; if it still fails outside a sandbox, reboot the simulator and try again."

    private static let reasonCharacterLimit = 500

    // Test seams; the defaults write to stderr and end the process.
    static var writeError: (String) -> Void = { message in
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
    static var terminate: (Int32) -> Void = { code in
        exit(code)
    }

    private static var isInstalled = false

    /// Registers the process-wide handler. Repeated calls keep the first registration.
    static func install() {
        guard !isInstalled else { return }
        isInstalled = true
        NSSetUncaughtExceptionHandler { exception in
            UncaughtExceptionGuard.handle(exception)
        }
    }

    static func handle(_ exception: NSException) {
        handle(name: exception.name.rawValue, reason: exception.reason ?? "No reason provided.",
               stack: exception.callStackSymbols)
    }

    /// Reports the failure and terminates through the seams.
    static func handle(name: String, reason: String, stack: [String]) {
        var lines = [
            "AXe stopped after an uncaught Objective-C exception.",
            "Exception: \(name)",
            "Reason: \(truncated(reason))",
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

    private static func truncated(_ text: String) -> String {
        text.count <= reasonCharacterLimit ? text : String(text.prefix(reasonCharacterLimit)) + "..."
    }
}
