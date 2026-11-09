import Foundation

/// The device accessibility service. `DeviceAccessibilitySession` owns the DTX subscription and tree reads.
enum DeviceAccessibilityTransport {
    static let service = "com.apple.accessibility.axAuditDaemon.remoteAXService"
}
