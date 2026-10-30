import Foundation

/// One request reservation, acquired by the socket worker before actor dispatch.
/// It does not own HID input or a retained contact. No native work runs under this lock.
final class HIDBrokerRequestAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var token: UUID?

    func reserve() -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        guard token == nil else { return nil }
        let next = UUID()
        token = next
        return next
    }

    func release(_ owned: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard token == owned else { return }
        token = nil
    }
}
