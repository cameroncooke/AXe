import Foundation
import FBSimulatorControl

/// Ordinary keyboard input for the broker route in a compact form, so the text of a long `type` fits
/// one message on the broker socket. It keeps the ordinary contract: any length, repeated modifiers
/// and long key-sequence delays.
struct LegacyDuoKeyboard: Codable, Sendable, Equatable {
    /// `code` presses a key, `code + 256` releases it, and `delayMarker` waits for the next value of `delays`.
    let keys: [Int]
    let delays: [Double]

    static let delayMarker = -1
    /// The broker accepts a message this large only for ordinary keyboard input; others keep 64 KiB.
    static let maximumMessageBytes = 8 * 1024 * 1024

    init(_ event: FBSimulatorHIDEvent) throws {
        let events = try KeyboardPrimitives.from(event, limits: .ordinary)
        try KeyboardPrimitives.validate(events, limits: .ordinary)
        var keys: [Int] = []
        var delays: [Double] = []
        keys.reserveCapacity(events.count)
        for event in events {
            switch event {
            case .down(let code): keys.append(Int(code))
            case .up(let code): keys.append(Int(code) + 256)
            case .delay(let seconds):
                keys.append(Self.delayMarker)
                delays.append(seconds)
            }
        }
        self.keys = keys
        self.delays = delays
    }

    /// The primitives in order, checked against the ordinary limits.
    func primitives() throws -> [SelectedKeyboardPrimitive] {
        var events: [SelectedKeyboardPrimitive] = []
        events.reserveCapacity(keys.count)
        var nextDelay = delays.makeIterator()
        for key in keys {
            switch key {
            case 0...255: events.append(.down(UInt32(key)))
            case 256...511: events.append(.up(UInt32(key - 256)))
            case Self.delayMarker:
                guard let seconds = nextDelay.next() else {
                    throw SelectedHIDFailure.invalid("Ordinary keyboard delay is missing")
                }
                events.append(.delay(seconds))
            default: throw SelectedHIDFailure.invalid("Ordinary keyboard keycode is invalid")
            }
        }
        guard nextDelay.next() == nil else { throw SelectedHIDFailure.invalid("Ordinary keyboard has an unused delay") }
        try KeyboardPrimitives.validate(events, limits: .ordinary)
        return events
    }

    func validate() throws {
        _ = try primitives()
    }
}
