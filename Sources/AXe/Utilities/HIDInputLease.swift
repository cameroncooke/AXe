import Darwin
import Foundation

/// A process-wide protocol is not enough: every candidate raw input path takes this same lock.
/// The reference is retained for the complete HID session lifetime.
final class HIDInputLease {
    private let descriptor: Int32
    private init(descriptor: Int32) { self.descriptor = descriptor }
    static func acquire(simulatorUDID: String) throws -> HIDInputLease {
        guard let udid = UUID(uuidString: simulatorUDID) else { throw CLIError(errorDescription: "Invalid simulator UUID") }
        let endpoint = try HIDBroker.endpointPath(simulatorUDID: udid.uuidString, developerDirectory: "/candidate-device-input", version: 3)
        do {
            let lease = HIDInputLease(descriptor: try HIDBroker.acquireLifetimeLock(endpoint: endpoint))
            try HIDInputQuarantine.requireClear(simulatorUDID: udid.uuidString)
            return lease
        }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EWOULDBLOCK) {
            throw SelectedHIDFailure.busy
        }
    }
    deinit { _ = flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}
