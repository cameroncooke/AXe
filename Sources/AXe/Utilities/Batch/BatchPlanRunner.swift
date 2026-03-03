import Foundation
import FBSimulatorControl

@MainActor
struct BatchPlanRunner {
    let session: HIDInteractor.Session
    let logger: AxeLogger

    func run(_ plan: BatchPlan) async throws {
        var pendingMergeable: [FBSimulatorHIDEvent] = []

        func flushPending() async throws {
            guard !pendingMergeable.isEmpty else { return }
            let event = pendingMergeable.count == 1 ? pendingMergeable[0] : FBSimulatorHIDEvent(events: pendingMergeable)
            try await HIDInteractor.performHIDEvent(event, in: session, logger: logger)
            pendingMergeable.removeAll(keepingCapacity: true)
        }

        for primitive in plan.primitives {
            switch primitive {
            case .hidMergeable(let event):
                pendingMergeable.append(event)
            case .hidBarrier(let event):
                try await flushPending()
                try await HIDInteractor.performHIDEvent(event, in: session, logger: logger)
            case .hostSleep(let seconds):
                try await flushPending()
                guard seconds > 0 else { continue }
                let nanoseconds = UInt64(seconds * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
            }
        }

        try await flushPending()
    }
}

