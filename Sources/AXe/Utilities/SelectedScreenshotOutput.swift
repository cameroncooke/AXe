import Darwin
import Foundation
import FBSimulatorControl

/// Publish only bytes returned after selected capture validation and feed close.
enum SelectedScreenshotOutput {
    /// The `--verbose` receipt. Sizes are pixels.
    struct Receipt: Encodable {
        let output: String
        let width: Int
        let height: Int
        let before: FBSimulatorContextReadback
        let after: FBSimulatorContextReadback
        let child: FBSimulatorScreenshotChildReceipt
    }

    static func publish(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".axe-selected-png-" + UUID().uuidString)
        try data.write(to: temporary, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        // A hard link publishes the complete same-directory file without replacing any existing
        // destination, including a path created after admission. Failure never deletes that path.
        guard link(temporary.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
