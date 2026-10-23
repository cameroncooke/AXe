import CoreGraphics
import FBSimulatorControl

/// One pickup check for one fixed native session and one exact first DOWN.
/// The body runs on the existing MainActor owner and must not call this HID session.
actor SliderPickupAdmissionGuard: FBSimulatorHIDInputAdmissionGuard {
    enum Failure: Error { case alreadyConsumed, wrongObservation, wrongFirstEvent }
    let expectedObservation: FBSimulatorHIDSessionObservation
    let pickup: CGPoint
    let validatePickup: @MainActor @Sendable () async throws -> Void
    private var consumed = false

    init(observation: FBSimulatorHIDSessionObservation, pickup: CGPoint,
         validatePickup: @escaping @MainActor @Sendable () async throws -> Void) {
        expectedObservation = observation
        self.pickup = pickup
        self.validatePickup = validatePickup
    }

    func validate(observation: FBSimulatorHIDSessionObservation,
                  firstEvent: FBSimulatorHIDEvent) async throws {
        guard !consumed else { throw Failure.alreadyConsumed }
        consumed = true
        guard observation == expectedObservation else { throw Failure.wrongObservation }
        guard case let .touch(.down, x, y) = firstEvent,
              x == Double(pickup.x), y == Double(pickup.y) else { throw Failure.wrongFirstEvent }
        try await validatePickup()
    }
}
