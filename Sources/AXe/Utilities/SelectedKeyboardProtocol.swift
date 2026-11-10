import Foundation
import FBSimulatorControl

/// A complete keyboard sequence. No touch, button, retained contact or implicit focus action.
struct SelectedKeyboardRequest: Codable, Sendable {
    static let maximumTextBytes = 256
    static let maximumEvents = 1024
    /// Nil asks the broker to bind the app that is frontmost when the operation starts.
    let expectedPID: Int32?
    let fieldTarget: SelectedNativeTarget
    let events: [SelectedKeyboardPrimitive]

    var focusID: String? { fieldTarget.semanticID }

    init(expectedPID: Int32?, focusID: String, events: [SelectedKeyboardPrimitive]) {
        self.init(expectedPID: expectedPID,
            fieldTarget: .semantic(kind: .id, value: focusID, elementType: "TextField"), events: events)
    }

    init(expectedPID: Int32?, fieldTarget: SelectedNativeTarget, events: [SelectedKeyboardPrimitive]) {
        self.expectedPID = expectedPID
        self.fieldTarget = fieldTarget
        self.events = events
    }

    /// The same request bound to one process; every focus read then requires it.
    func bound(to pid: Int32) -> SelectedKeyboardRequest {
        SelectedKeyboardRequest(expectedPID: pid, fieldTarget: fieldTarget, events: events)
    }

    func validate() throws {
        try fieldTarget.validate()
        if let expectedPID, expectedPID <= 0 {
            throw SelectedHIDFailure.invalid("Selected keyboard requires a positive PID")
        }
        switch fieldTarget {
        case let .semantic(kind, value, type):
            guard kind == .id, !value.isEmpty, value.utf8.count <= 4096,
                  value == value.trimmingCharacters(in: .whitespacesAndNewlines),
                  type == nil || type == "TextField" else {
                throw SelectedHIDFailure.invalid("Selected keyboard requires an exact nonempty focus ID")
            }
        case let .nativeObject(identity, type):
            guard expectedPID != nil, identity.pid == expectedPID, type == "TextField" else {
                throw SelectedHIDFailure.invalid("Selected keyboard requires an exact native TextField in the expected process")
            }
        }
        try KeyboardPrimitives.validate(events, limits: .selected)
    }

    var event: FBSimulatorHIDEvent { .composite(events.map(\.event)) }

    static func textEvent(_ text: String) throws -> FBSimulatorHIDEvent {
        guard !text.isEmpty, text.utf8.count <= maximumTextBytes else {
            throw SelectedHIDFailure.invalid("Selected text requires 1...256 UTF-8 bytes")
        }
        return .composite(try TextToHIDEvents.convertTextToHIDEvents(text))
    }
}

/// Keyboard primitives from a HID event, and their one validator. Each route passes its limits.
enum KeyboardPrimitives {
    struct Limits {
        /// Starts every refusal, such as "Selected keyboard".
        let name: String
        /// Nil allows any number of events.
        let maximumEvents: Int?
        /// Ordinary input keeps repeated modifier downs, each released by its own up.
        let allowsRepeatedDown: Bool
        /// Nil allows any delay the native clock can represent.
        let maximumDelay: Double?
        let maximumTotalDelay: Double?

        static let selected = Limits(name: "Selected keyboard", maximumEvents: SelectedKeyboardRequest.maximumEvents,
            allowsRepeatedDown: false, maximumDelay: 10, maximumTotalDelay: 20)
        /// One complete key or key-combo command: at most eight modifiers and one target key.
        static let rawBroker = Limits(name: "Raw keyboard", maximumEvents: 18, allowsRepeatedDown: true,
            maximumDelay: 10, maximumTotalDelay: 10)
        /// The ordinary commands' contract: long text, repeated modifiers and long key-sequence delays.
        static let ordinary = Limits(name: "Ordinary keyboard", maximumEvents: nil, allowsRepeatedDown: true,
            maximumDelay: nil, maximumTotalDelay: nil)
    }

    static func from(_ event: FBSimulatorHIDEvent, limits: Limits = .selected) throws -> [SelectedKeyboardPrimitive] {
        var result: [SelectedKeyboardPrimitive] = []
        func append(_ value: FBSimulatorHIDEvent, depth: Int) throws {
            guard depth <= 8, result.count < limits.maximumEvents ?? .max else {
                throw SelectedHIDFailure.invalid("\(limits.name) event exceeds its bounds")
            }
            switch value {
            case .keyboard(.down, let code): result.append(.down(code))
            case .keyboard(.up, let code): result.append(.up(code))
            case .delay(let seconds): result.append(.delay(seconds))
            default:
                guard let children = value.subEvents else {
                    throw SelectedHIDFailure.invalid("\(limits.name) cannot contain non-keyboard input")
                }
                for child in children { try append(child, depth: depth + 1) }
            }
        }
        try append(event, depth: 0)
        return result
    }

    /// At least one key, every key released, and delays within the limits.
    static func validate(_ events: [SelectedKeyboardPrimitive], limits: Limits) throws {
        let name = limits.name
        if let maximum = limits.maximumEvents {
            guard !events.isEmpty, events.count <= maximum else {
                throw SelectedHIDFailure.invalid("\(name) requires 1...\(maximum) events")
            }
        }
        var held: [UInt32: Int] = [:]
        var delay = 0.0
        var downs = 0
        for event in events {
            switch event {
            case .down(let code):
                guard code <= 255, limits.allowsRepeatedDown || held[code] == nil else {
                    throw SelectedHIDFailure.invalid("\(name) key down is invalid or already held")
                }
                held[code, default: 0] += 1
                downs += 1
            case .up(let code):
                guard code <= 255, let count = held[code] else {
                    throw SelectedHIDFailure.invalid("\(name) key up has no matching down")
                }
                held[code] = count == 1 ? nil : count - 1
            case .delay(let seconds):
                guard seconds.isFinite, seconds >= 0,
                      seconds <= limits.maximumDelay ?? Double(UInt64.max) / 1_000_000_000 else {
                    throw SelectedHIDFailure.invalid(limits.maximumDelay.map {
                        "\(name) delay must be finite and in 0...\(Int($0)) seconds"
                    } ?? "\(name) delay is invalid")
                }
                delay += seconds
            }
        }
        guard held.isEmpty, downs > 0, delay <= limits.maximumTotalDelay ?? .infinity else {
            throw SelectedHIDFailure.invalid("\(name) must release every key within a bounded complete sequence")
        }
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
    static func validate(_ node: FBSimulatorAXNode, expectedPID: Int32,
                         fieldTarget: SelectedNativeTarget) throws {
        try validateIdentity(node, expectedPID: expectedPID, fieldTarget: fieldTarget)
        guard node.focused == true, node.enabled == true, node.hidden == false else {
            throw SelectedHIDFailure.invalid("Selected keyboard requires the exact focused, enabled, non-hidden TextField in the expected process")
        }
    }

    /// The composite focus action checks this same identity before focus exists.
    /// This does not grant typing capability or relax the ordinary focused-field gate.
    static func validateIdentity(_ node: FBSimulatorAXNode, expectedPID: Int32,
                                 fieldTarget: SelectedNativeTarget) throws {
        try fieldTarget.validate()
        let matches: Bool
        switch fieldTarget {
        case let .semantic(kind, value, type):
            matches = kind == .id && node.identifier == value && (type == nil || type == "TextField")
        case let .nativeObject(identity, type):
            matches = identity.pid == expectedPID && node.nativeIdentity == identity && type == "TextField" &&
                node.identifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        }
        guard matches, node.pid == expectedPID, node.type == "TextField" else {
            throw SelectedHIDFailure.invalid("Selected keyboard requires the exact focused, enabled, non-hidden TextField in the expected process")
        }
    }
}

struct SelectedKeyboardResult: Codable, Sendable {
    let expectedPID: Int32?
    let focusID: String?
    var initialTarget: FBSimulatorAXNode?
    var lastValidatedTarget: FBSimulatorAXNode?
    var validatedKeyDownCount = 0
}
