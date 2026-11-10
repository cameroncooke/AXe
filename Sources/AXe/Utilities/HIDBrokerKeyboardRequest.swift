import Foundation
import FBSimulatorControl

/// Internal wire format for one complete ordinary key or key-combo command.
/// Raw key ranges and repeated modifier codes retain their existing behavior.
struct HIDBrokerKeyboardRequest: Codable {
    let events: [SelectedKeyboardPrimitive]

    init(event: FBSimulatorHIDEvent) throws {
        events = try KeyboardPrimitives.from(event)
        try validate()
    }

    func validate() throws {
        try KeyboardPrimitives.validate(events, limits: .rawBroker)
    }

    var event: FBSimulatorHIDEvent { .composite(events.map(\.event)) }
}
