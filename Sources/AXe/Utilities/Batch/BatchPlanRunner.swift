import Foundation
import FBSimulatorControl

@MainActor
struct BatchPlanRunner {
    private enum Executor {
        case legacy(HIDInteractor.Session)
        case duo(SelectedHIDOwner)
    }
    private let executor: Executor
    let logger: AxeLogger

    init(session: HIDInteractor.Session, logger: AxeLogger) {
        executor = .legacy(session); self.logger = logger
    }

    init(duoOwner: SelectedHIDOwner, logger: AxeLogger) {
        executor = .duo(duoOwner); self.logger = logger
    }

    func run(_ plan: BatchPlan) async throws {
        var pendingMergeable: [FBSimulatorHIDEvent] = []

        func flushPending() async throws {
            guard !pendingMergeable.isEmpty else { return }
            let event = pendingMergeable.count == 1 ? pendingMergeable[0] : FBSimulatorHIDEvent.composite(pendingMergeable)
            try await submit(event)
            pendingMergeable.removeAll(keepingCapacity: true)
        }

        for primitive in plan.primitives {
            switch primitive {
            case .hidMergeable(let event):
                pendingMergeable.append(event)
            case .hidBarrier(let event):
                try await flushPending()
                // A barrier prevents event coalescing; failures propagate without replaying
                // this event or any earlier event in the batch.
                try await submit(event)
            case .hostSleep(let seconds):
                try await flushPending()
                guard seconds > 0 else { continue }

                try await wait(seconds)
            case .physicalTap(let point, let preDelay, let postDelay):
                try await flushPending()
                switch executor {
                case .legacy(let session):
                    try await HIDInteractor.performPhysicalTap(at: point, preDelay: preDelay,
                        postDelay: postDelay, in: session, logger: logger)
                case .duo:
                    if let preDelay, preDelay > 0 { try await wait(preDelay) }
                    try await submit(.touch(direction: .down, x: point.x, y: point.y))
                    try await wait(TapTiming.defaultHoldDuration)
                    try await submit(.touch(direction: .up, x: point.x, y: point.y))
                    if let postDelay, postDelay > 0 { try await wait(postDelay) }
                }
            case .duoTouchUp(let point):
                try await flushPending()
                guard case .duo(let owner) = executor else {
                    throw SelectedHIDFailure.invalid("Duo touch release requires the measured batch owner")
                }
                try await owner.releaseOrdinaryBatchTouch(at: point)
            }
        }

        try await flushPending()
    }

    private func submit(_ event: FBSimulatorHIDEvent) async throws {
        switch executor {
        case .legacy(let session): try await HIDInteractor.performHIDEvent(event, in: session, logger: logger)
        case .duo(let owner): try await owner.submitOrdinaryBatchPart(event)
        }
    }

    private func wait(_ seconds: Double) async throws {
        switch executor {
        case .legacy: try await Task.sleep(for: .seconds(seconds))
        case .duo(let owner): try await owner.waitForOrdinaryBatch(seconds: seconds)
        }
    }
}
