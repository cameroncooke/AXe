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

    private enum CodingKeys: String, CodingKey { case expectedPID, focusID, fieldTarget, events }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        expectedPID = try values.decodeIfPresent(Int32.self, forKey: .expectedPID)
        events = try values.decode([SelectedKeyboardPrimitive].self, forKey: .events)
        let identifier = try values.decodeIfPresent(String.self, forKey: .focusID)
        let target = try values.decodeIfPresent(SelectedNativeTarget.self, forKey: .fieldTarget)
        guard (identifier == nil) != (target == nil) else {
            throw SelectedHIDFailure.invalid("Selected keyboard requires one field identity")
        }
        if let target { fieldTarget = target }
        else if let identifier {
            fieldTarget = .semantic(kind: .id, value: identifier, elementType: "TextField")
        } else { throw SelectedHIDFailure.invalid("Selected keyboard field identity is missing") }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(expectedPID, forKey: .expectedPID)
        try values.encode(events, forKey: .events)
        if case let .semantic(kind, value, type) = fieldTarget,
           kind == .id, type == nil || type == "TextField" {
            try values.encode(value, forKey: .focusID)
        } else { try values.encode(fieldTarget, forKey: .fieldTarget) }
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
        try Self.validateEvents(events)
    }

    static func validateEvents(_ events: [SelectedKeyboardPrimitive]) throws {
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
        try validate(node, expectedPID: expectedPID,
            fieldTarget: .semantic(kind: .id, value: focusID, elementType: "TextField"))
    }

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
    let atomicRecipientGuarantee = false
}
