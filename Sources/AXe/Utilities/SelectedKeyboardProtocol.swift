import Foundation
import FBSimulatorControl

/// A complete keyboard sequence. No touch, button, retained contact or implicit focus action.
struct SelectedKeyboardRequest: Codable, Sendable {
    static let maximumTextBytes = 256
    static let maximumEvents = 1024
    let expectedPID: Int32
    let focusID: String
    let events: [SelectedKeyboardPrimitive]

    func validate() throws {
        guard expectedPID > 0, !focusID.isEmpty, focusID.utf8.count <= 4096,
              focusID == focusID.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw SelectedHIDFailure.invalid("Selected keyboard requires a positive PID and an exact nonempty focus ID")
        }
        guard !events.isEmpty, events.count <= Self.maximumEvents else {
            throw SelectedHIDFailure.invalid("Selected keyboard requires 1...1024 events")
        }
        var held = Set<UInt32>()
        var delay = 0.0
        var downs = 0
        for event in events {
            switch event {
            case .down(let code):
                guard code <= 255, held.insert(code).inserted else {
                    throw SelectedHIDFailure.invalid("Selected keyboard key down is invalid or already held")
                }
                downs += 1
            case .up(let code):
                guard code <= 255, held.remove(code) != nil else {
                    throw SelectedHIDFailure.invalid("Selected keyboard key up has no matching down")
                }
            case .delay(let seconds):
                guard seconds.isFinite, (0...10).contains(seconds) else {
                    throw SelectedHIDFailure.invalid("Selected keyboard delay must be finite and in 0...10 seconds")
                }
                delay += seconds
            }
        }
        guard held.isEmpty, downs > 0, delay <= 20 else {
            throw SelectedHIDFailure.invalid("Selected keyboard must release every key within a bounded complete sequence")
        }
    }

    var event: FBSimulatorHIDEvent { .composite(events.map(\.event)) }

    static func primitives(from event: FBSimulatorHIDEvent) throws -> [SelectedKeyboardPrimitive] {
        var result: [SelectedKeyboardPrimitive] = []
        func append(_ value: FBSimulatorHIDEvent, depth: Int) throws {
            guard depth <= 8, result.count < maximumEvents else {
                throw SelectedHIDFailure.invalid("Selected keyboard event exceeds its bounds")
            }
            switch value {
            case .keyboard(.down, let code): result.append(.down(code))
            case .keyboard(.up, let code): result.append(.up(code))
            case .delay(let seconds): result.append(.delay(seconds))
            default:
                guard let children = value.subEvents else {
                    throw SelectedHIDFailure.invalid("Selected keyboard cannot contain non-keyboard input")
                }
                for child in children { try append(child, depth: depth + 1) }
            }
        }
        try append(event, depth: 0)
        return result
    }

    static func textEvent(_ text: String) throws -> FBSimulatorHIDEvent {
        guard !text.isEmpty, text.utf8.count <= maximumTextBytes else {
            throw SelectedHIDFailure.invalid("Selected text requires 1...256 UTF-8 bytes")
        }
        return .composite(try TextToHIDEvents.convertTextToHIDEvents(text))
    }
}

enum SelectedKeyboardPrimitive: Codable, Sendable {
    case down(UInt32), up(UInt32), delay(Double)
    var event: FBSimulatorHIDEvent {
        switch self {
        case .down(let code): return .keyboard(direction: .down, keyCode: code)
        case .up(let code): return .keyboard(direction: .up, keyCode: code)
        case .delay(let seconds): return .delay(seconds)
        }
    }
}

/// These checks admit one observed field, not an atomic OS keyboard recipient.
enum SelectedKeyboardFocusPolicy {
    static func validate(_ node: FBSimulatorAXNode, expectedPID: Int32, focusID: String) throws {
        guard node.pid == expectedPID, node.identifier == focusID, node.type == "TextField",
              node.focused == true, node.enabled == true, node.hidden == false else {
            throw SelectedHIDFailure.invalid("Selected keyboard requires the exact focused, enabled, non-hidden TextField in the expected process")
        }
    }
}

struct SelectedKeyboardResult: Codable, Sendable {
    let expectedPID: Int32
    let focusID: String
    var initialTarget: FBSimulatorAXNode?
    var lastValidatedTarget: FBSimulatorAXNode?
    var validatedKeyDownCount = 0
    let atomicRecipientGuarantee = false
}
