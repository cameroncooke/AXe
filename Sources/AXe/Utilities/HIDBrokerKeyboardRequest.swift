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
            throw CLIError(errorDescription: "The keyboard request exceeds one complete key command.", code: .invalidArguments)
        }
        var held: [UInt32: Int] = [:]
        var totalDelay = 0.0
        for event in events {
            switch event {
            case .down(let code):
                guard code <= 255 else { throw CLIError(errorDescription: "The keycode is invalid.", code: .invalidArguments) }
                held[code, default: 0] += 1
            case .up(let code):
                guard code <= 255, let count = held[code], count > 0 else {
                    throw CLIError(errorDescription: "A key up has no matching key down.", code: .invalidArguments)
                }
                if count == 1 { held.removeValue(forKey: code) }
                else { held[code] = count - 1 }
            case .delay(let seconds):
                guard seconds.isFinite, (0...10).contains(seconds) else {
                    throw CLIError(errorDescription: "The key delay is invalid.", code: .invalidArguments)
                }
                totalDelay += seconds
            }
        }
        guard held.isEmpty, totalDelay <= 10 else {
            throw CLIError(errorDescription: "The keyboard request must release each key within ten seconds.", code: .invalidArguments)
        }
    }

    var event: FBSimulatorHIDEvent { .composite(events.map(\.event)) }
}
