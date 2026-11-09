import Darwin
import Foundation

struct PhysicalDeviceInput: Sendable {
    private let client: PhysicalDeviceBrokerClient

    @MainActor
    static func withSession<T: Sendable>(
        for device: CoreDevice,
        _ work: @escaping @MainActor (PhysicalDeviceInput) async throws -> T
    ) async throws -> T {
        var previousInterrupt = sigaction()
        var previousTerminate = sigaction()
        guard sigaction(SIGINT, nil, &previousInterrupt) == 0,
              sigaction(SIGTERM, nil, &previousTerminate) == 0 else {
            throw CLIOutputFailure(code: "inputUnavailable", message: "Could not read input signal dispositions.")
        }

        let task = Task { @MainActor in
            guard let udid = device.udid else {
                throw CLIOutputFailure(code: "targetNotReady", message: "The device has no hardware UDID.")
            }
            let client = try await PhysicalDeviceBrokerClient.connect(udid: udid)
            let input = PhysicalDeviceInput(client: client)
            let result: Result<T, Error>
            do {
                result = .success(try await work(input))
            } catch {
                result = .failure(error)
            }
            try await client.close()
            return try result.get()
        }
        var signals: SignalObserver? = SignalObserver(signals: [SIGINT, SIGTERM]) { task.cancel() }
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
        }
        let interrupted = task.isCancelled || Task.isCancelled
        signals?.invalidate()
        signals = nil
        let restoredInterrupt = sigaction(SIGINT, &previousInterrupt, nil) == 0
        let restoredTerminate = sigaction(SIGTERM, &previousTerminate, nil) == 0
        guard restoredInterrupt, restoredTerminate else {
            throw CLIOutputFailure(code: "inputUnavailable", message: "Could not restore input signal dispositions.")
        }
        let value = try result.get()
        if interrupted { throw CancellationError() }
        return value
    }

    func keepAlive() async throws {
        try await requireDone(.keepAlive)
    }

    func display() async throws -> PhysicalDeviceDisplay {
        guard case let .display(value) = try await client.exchange(.display) else { throw Self.badReply }
        return value
    }

    func tap(at point: CGPoint, count: Int = 1, hold: TimeInterval = 0.05,
             interval: TimeInterval = 0.1) async throws {
        guard (1...100).contains(count) else {
            throw CLIOutputFailure(code: "invalidArguments", message: "Device tap count must be between 1 and 100.")
        }
        let plan = (0..<count).flatMap { index in
            [
                PhysicalTouchStep(points: [point], phase: .down, delayAfter: hold),
                PhysicalTouchStep(points: [point], phase: .up, delayAfter: index + 1 < count ? interval : 0),
            ]
        }
        try await perform(plan)
    }

    func perform(_ steps: [PhysicalTouchStep], on display: PhysicalDeviceDisplay? = nil,
                 allowPartial: Bool = false, admissionDeadline: ContinuousClock.Instant? = nil) async throws {
        let deadline: UInt64?
        if let admissionDeadline {
            let remaining = ContinuousClock.now.duration(to: admissionDeadline)
            guard remaining > .zero, remaining <= .seconds(30) else {
                throw CLIOutputFailure(code: "waitTimedOut", message: "The element selection expired before input.")
            }
            let parts = remaining.components
            let nanos = UInt64(parts.seconds) * 1_000_000_000 + UInt64(parts.attoseconds / 1_000_000_000)
            deadline = DispatchTime.now().uptimeNanoseconds + nanos
        } else {
            deadline = nil
        }
        try await requireDone(.touch(steps, display: display, allowPartial: allowPartial, deadlineUptime: deadline))
    }

    func keys(_ steps: [PhysicalKeyStep]) async throws {
        try await requireDone(.keys(steps))
    }

    func pressButton(_ button: PhysicalDeviceButton, hold: TimeInterval = 0.08, allowLock: Bool = false) async throws {
        try await requireDone(.button(button, hold: hold, allowLock: allowLock))
    }

    func rotate(_ direction: PhysicalRotationDirection, timeout: TimeInterval = 8) async throws {
        try await requireDone(.rotate(direction, timeout: timeout))
    }

    func readAccessibility(timeout: TimeInterval = PhysicalAccessibility.readBudget) async throws -> PhysicalAccessibilitySnapshot {
        guard case let .tree(json, display) = try await client.exchange(.tree(timeout: timeout)) else {
            throw Self.badReply
        }
        return PhysicalAccessibilitySnapshot(json: json,
            roots: try JSONDecoder().decode([AccessibilityElement].self, from: json), display: display)
    }

    func semanticPress(identifier: String) async throws -> PhysicalSemanticPressReceipt {
        guard case let .semanticPress(receipt) = try await client.exchange(.semanticPress(identifier: identifier)) else {
            throw Self.badReply
        }
        return receipt
    }

    private func requireDone(_ operation: PhysicalDeviceBrokerOperation) async throws {
        guard case .done = try await client.exchange(operation) else { throw Self.badReply }
    }

    private static var badReply: CLIOutputFailure {
        CLIOutputFailure(code: "deviceBrokerProtocolError", message: "The device broker returned an unexpected response.")
    }
}
