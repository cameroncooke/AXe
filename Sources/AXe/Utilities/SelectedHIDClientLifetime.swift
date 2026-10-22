import Darwin
import Foundation

/// Agent actions, waiting taps and legacy Duo paths/touches use this scope. The caller must
/// keep it open until run returns, after both child tasks have finished.
@MainActor
enum SelectedHIDClientLifetime {
    enum PeerState: Equatable {
        case connected, closed, unexpectedData
        case failed(Int32)
    }

    static func peerState(descriptor: Int32) -> PeerState {
        var byte: UInt8 = 0
        let count = Darwin.recv(descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        if count == 0 { return .closed }
        if count > 0 { return .unexpectedData }
        let code = errno
        if code == EAGAIN || code == EWOULDBLOCK || code == EINTR { return .connected }
        return .failed(code)
    }

    static func run<Value: Sendable>(
        descriptor: Int32,
        inspectPeer: @escaping @MainActor (Int32) -> PeerState = { peerState(descriptor: $0) },
        operation: @escaping @MainActor () async -> Value
    ) async -> Value {
        let pending = Task { @MainActor in await operation() }
        // This check runs before either child can start on the main actor.
        if inspectPeer(descriptor) != .connected { pending.cancel() }
        let monitor = Task { @MainActor in
            while !Task.isCancelled {
                guard inspectPeer(descriptor) == .connected else {
                    pending.cancel()
                    return
                }
                do { try await Task.sleep(for: .milliseconds(25)) }
                catch { return }
            }
        }
        let value = await withTaskCancellationHandler(operation: {
            await pending.value
        }, onCancel: {
            pending.cancel()
        })
        monitor.cancel()
        await monitor.value
        return value
    }
}
