import Foundation
import FBSimulatorControl

/// Internal wire format for one complete ordinary key or key-combo command.
/// Raw key ranges and repeated modifier codes retain their existing behavior.
struct HIDBrokerKeyboardRequest: Codable {
    let events: [SelectedKeyboardPrimitive]

    init(event: FBSimulatorHIDEvent) throws {
        events = try SelectedKeyboardRequest.primitives(from: event)
        try validate()
    }

    func validate() throws {
        // Key-combo has at most eight modifiers and one complete target key.
        guard (2...18).contains(events.count) else {
            throw CLIError(errorDescription: "HID broker keyboard request exceeds one complete key command.")
        }
        var held: [UInt32: Int] = [:]
        var totalDelay = 0.0
        for event in events {
            switch event {
            case .down(let code):
                guard code <= 255 else { throw CLIError(errorDescription: "HID broker keycode is invalid.") }
                held[code, default: 0] += 1
            case .up(let code):
                guard code <= 255, let count = held[code], count > 0 else {
                    throw CLIError(errorDescription: "HID broker key up has no matching down.")
                }
                if count == 1 { held.removeValue(forKey: code) }
                else { held[code] = count - 1 }
            case .delay(let seconds):
                guard seconds.isFinite, (0...10).contains(seconds) else {
                    throw CLIError(errorDescription: "HID broker key delay is invalid.")
                }
                totalDelay += seconds
            }
        }
        guard held.isEmpty, totalDelay <= 10 else {
            throw CLIError(errorDescription: "HID broker keyboard request must release each key within ten seconds.")
        }
    }

    var event: FBSimulatorHIDEvent { .composite(events.map(\.event)) }
}
