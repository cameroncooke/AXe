import AXeCore
import Foundation
import FBSimulatorControl

struct AgentModeRequest: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case describe, tap, typeText, swipe, drag, hold, doubleTap, keyPress, keyCombo, keySequence, complete }
    let kind: Kind
    var expectedPID: Int32? = nil
    var snapshotID: UUID? = nil
    var ref: String? = nil
    var sinceScreenHash: String? = nil
    var point: SelectedAXPoint? = nil
    var selectorKind: SelectedAXRequest.SelectorKind? = nil
    var selectorValue: String? = nil
    var tapSelector: AgentModeTapSelector? = nil
    var elementType: String? = nil
    var text: String? = nil
    var keyEvents: [SelectedKeyboardPrimitive]? = nil
    var direction: RuntimeSwipeDirection? = nil
    var distance: Double = 1
    var destination: SelectedAXPoint? = nil
    var steps: Int? = nil
    var duration: Double = 1
    var preDelay: Double = 0
    var postDelay: Double = 0
    var tapStyle: SelectedTapStyle? = nil
    var doubleTapTiming: SelectedAXDoubleTapTiming? = nil
    var rowOffset: Int = 0
    var rowLimit: Int = 64

    func validate() throws {
        guard let expectedPID, expectedPID > 0 else {
            throw AgentModeFailure("expectedPIDRequired", "Agent mode requires a positive --expected-pid.")
        }
        guard rowOffset >= 0, rowOffset <= 4096, (1...64).contains(rowLimit),
              distance.isFinite, distance > 0, distance <= 1,
              duration.isFinite, duration > 0, duration <= 10,
              preDelay.isFinite, (0...10).contains(preDelay),
              postDelay.isFinite, (0...10).contains(postDelay) else {
            throw AgentModeFailure("invalidBounds", "Agent query and timing limits are invalid.")
        }
        if kind == .doubleTap {
            guard ref != nil, snapshotID != nil, let doubleTapTiming,
                  point == nil, selectorKind == nil, selectorValue == nil, tapSelector == nil,
                  elementType == nil, text == nil, keyEvents == nil, direction == nil, tapStyle == nil,
                  sinceScreenHash == nil, destination == nil, steps == nil,
                  duration == 1, distance == 1, rowOffset == 0, rowLimit == 64 else {
                throw AgentModeFailure("invalidDoubleTap", "A reference double-tap requires one snapshot/ref and timing, without other targets or payloads.")
            }
            try doubleTapTiming.validate(preDelay: preDelay, postDelay: postDelay)
        } else if doubleTapTiming != nil {
            throw AgentModeFailure("mixedPayload", "Double-tap timing applies only to a reference double-tap.")
        }
        if kind == .keyPress {
            guard let keyEvents, keyEvents.count == 2,
                  case let .down(code) = keyEvents[0], case let .up(released) = keyEvents[1],
                  code <= 255, code == released, ref != nil, snapshotID != nil,
                  point == nil, selectorKind == nil, selectorValue == nil, tapSelector == nil,
                  elementType == nil, text == nil, direction == nil, tapStyle == nil,
                  sinceScreenHash == nil, destination == nil, steps == nil,
                  duration == 1, preDelay == 0, postDelay == 0, distance == 1,
                  rowOffset == 0, rowLimit == 64 else {
                throw AgentModeFailure("invalidKeyPress", "An agent key requires one snapshot/ref and one matching key down/up in 0...255, without other payloads or timing options.")
            }
        } else if kind == .keyCombo {
            guard let keyEvents, ref != nil, snapshotID != nil,
                  point == nil, selectorKind == nil, selectorValue == nil, tapSelector == nil,
                  elementType == nil, text == nil, direction == nil, tapStyle == nil,
                  sinceScreenHash == nil, destination == nil, steps == nil,
                  duration == 1, preDelay == 0, postDelay == 0, distance == 1,
                  rowOffset == 0, rowLimit == 64 else {
                throw AgentModeFailure("invalidKeyCombo", "An agent key combination requires one snapshot/ref and a complete modifier/key sequence, without other payloads or timing options.")
            }
            try validateKeyCombo(keyEvents)
        } else if kind == .keySequence {
            guard let keyEvents, ref != nil, snapshotID != nil,
                  point == nil, selectorKind == nil, selectorValue == nil, tapSelector == nil,
                  elementType == nil, text == nil, direction == nil, tapStyle == nil,
                  sinceScreenHash == nil, destination == nil, steps == nil,
                  duration == 1, preDelay == 0, postDelay == 0, distance == 1,
                  rowOffset == 0, rowLimit == 64 else {
                throw AgentModeFailure("invalidKeySequence", "An agent key sequence requires one snapshot/ref and complete key presses, without other payloads or timing options.")
            }
            try validateKeySequence(keyEvents)
        } else if keyEvents != nil {
            throw AgentModeFailure("mixedPayload", "Key events apply only to an agent key press, key combination or key sequence.")
        }
        if kind == .hold {
            guard ref != nil, snapshotID != nil, point == nil,
                  selectorKind == nil, selectorValue == nil, tapSelector == nil,
                  elementType == nil, text == nil, direction == nil, tapStyle == nil,
                  sinceScreenHash == nil, preDelay == 0, postDelay == 0, distance == 1 else {
                throw AgentModeFailure("invalidHold", "A reference hold requires one snapshot/ref and a duration in (0,10], without other targets, styles or delays.")
            }
        }
        if kind == .drag {
            guard ref != nil, snapshotID != nil, let destination,
                  destination.x.isFinite, destination.y.isFinite, destination.x >= 0, destination.y >= 0,
                  let steps, (1...1000).contains(steps),
                  preDelay + duration + 0.1 + postDelay <= 20,
                  point == nil, selectorKind == nil, selectorValue == nil, tapSelector == nil,
                  elementType == nil, text == nil, direction == nil, tapStyle == nil,
                  sinceScreenHash == nil else {
                throw AgentModeFailure("invalidDrag", "A reference drag requires one snapshot/ref, a finite non-negative destination, 1...1000 steps and at most 20 seconds of total delay.")
            }
        } else if destination != nil || steps != nil {
            throw AgentModeFailure("mixedPayload", "Drag destination and steps apply only to a reference drag.")
        }
        if let ref {
            guard snapshotID != nil, ref.utf8.count <= 32, ref.first == "e",
                  let number = Int(ref.dropFirst()), number > 0 else {
                throw AgentModeFailure("invalidReference", "A reference requires its immutable --snapshot-id and an eN name.")
            }
        }
        guard [point != nil, ref != nil, selectorValue != nil, tapSelector != nil].filter({ $0 }).count <= 1 else {
            throw AgentModeFailure("mixedTargets", "Select one reference, selector, or point.")
        }
        if let point {
            guard point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0,
                  snapshotID != nil else {
                throw AgentModeFailure("invalidPoint", "Agent coordinates require a snapshot ID and finite non-negative points.")
            }
        }
        guard (selectorKind == nil) == (selectorValue == nil) else {
            throw AgentModeFailure("invalidSelector", "A selector requires both its kind and text.")
        }
        if let selectorValue {
            guard !selectorValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  selectorValue.utf8.count <= 4096 else {
                throw AgentModeFailure("invalidSelector", "The native selector is empty or too large.")
            }
        }
        if let tapSelector {
            guard kind == .tap else {
                throw AgentModeFailure("invalidTapSelector", "Rich selectors and frame filters apply to agent tap only.")
            }
            if let elementType {
                guard !elementType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      elementType.utf8.count <= 256 else {
                    throw AgentModeFailure("invalidElementType", "An agent selector type must be nonblank and at most 256 UTF-8 bytes.")
                }
            }
            try tapSelector.validate()
        }
        if snapshotID != nil, sinceScreenHash != nil {
            throw AgentModeFailure("mixedSnapshotQuery", "Snapshot paging cannot be combined with since-screen-hash.")
        }
        if kind == .describe {
            guard ref == nil, point == nil, selectorValue == nil, tapSelector == nil, text == nil, direction == nil else {
                throw AgentModeFailure("invalidDescribe", "Agent description accepts no action target or text.")
            }
        } else if kind == .typeText {
            guard let text, !text.isEmpty, text.utf8.count <= SelectedKeyboardRequest.maximumTextBytes,
                  point == nil, ref != nil || selectorKind == .id else {
                throw AgentModeFailure("invalidTextTarget", "Typing requires an observed reference or exact focused field ID and 1...256 UTF-8 bytes.")
            }
        } else if kind == .swipe {
            guard ref != nil, direction != nil else {
                throw AgentModeFailure("invalidSwipe", "A reference swipe requires a snapshot, reference, and direction.")
            }
        } else if kind == .tap {
            guard ref != nil || selectorValue != nil || tapSelector != nil || point != nil else {
                throw AgentModeFailure("missingTarget", "Agent tap requires a reference, selector, or point.")
            }
        }
    }
    private func validateKeySequence(_ events: [SelectedKeyboardPrimitive]) throws {
        let failure = AgentModeFailure("invalidKeySequence", "An agent key sequence requires 1...100 matching key down/up pairs in 0...255, optional finite inter-key delays in 0...5 seconds and at most 20 seconds of total delay.")
        guard !events.isEmpty, events.count <= SelectedKeyboardRequest.maximumEvents else { throw failure }
        var index = 0
        var keyCount = 0
        var totalDelay = 0.0
        while index < events.count {
            guard index + 1 < events.count,
                  case let .down(code) = events[index],
                  case let .up(released) = events[index + 1],
                  code <= 255, code == released else { throw failure }
            keyCount += 1
            index += 2
            if index < events.count, case let .delay(seconds) = events[index] {
                guard seconds.isFinite, (0...5).contains(seconds),
                      index + 1 < events.count else { throw failure }
                totalDelay += seconds
                index += 1
            }
        }
        guard keyCount <= 100, totalDelay <= 20 else { throw failure }
    }

    private func validateKeyCombo(_ events: [SelectedKeyboardPrimitive]) throws {
        let failure = AgentModeFailure("invalidKeyCombo", "An agent key combination requires 1...8 unique modifiers in 224...231, one different key in 0...255, and matching releases in reverse order.")
        guard (4...18).contains(events.count), events.count.isMultiple(of: 2) else { throw failure }
        let modifierCount = (events.count - 2) / 2
        var modifiers: [UInt32] = []
        for event in events.prefix(modifierCount) {
            guard case let .down(code) = event, (224...231).contains(code),
                  !modifiers.contains(code) else { throw failure }
            modifiers.append(code)
        }
        guard case let .down(key) = events[modifierCount],
              case let .up(released) = events[modifierCount + 1],
              key <= 255, key == released, !modifiers.contains(key) else { throw failure }
        for (event, modifier) in zip(events.suffix(modifierCount), modifiers.reversed()) {
            guard case let .up(code) = event, code == modifier else { throw failure }
        }
    }
}

struct AgentModeFailure: Error, Codable, Sendable, LocalizedError {
    let code: String
    let message: String
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
    var errorDescription: String? { message }
}

/// Keep native cleanup and quarantine evidence when a read fails before an action.
struct AgentModeNativeFailure: Error, Sendable {
    let response: SelectedHIDResponse
}

struct AgentModeCapture: Codable, Sendable {
    let type: String
    let rs: String
    let snapshotID: UUID
    let screenHash: String
    let seq: Int
    let count: Int
    let targets: [String]
    let scroll: [String]
    let text: [String]
    let udid: String
    let applicationPID: Int32
    let context: SelectedHIDContext
    let rowOffset: Int
    let rowLimit: Int
    let targetCount: Int
    let scrollCount: Int
    let textCount: Int
    let truncated: Bool
    let expiresInSeconds: Double
    let keyboard: AgentModeKeyboardObservation?
}

struct AgentModeActionReceipt: Codable, Sendable {
    let kind: AgentModeRequest.Kind
    let outcome: String
    let enqueuedEventCount: Int
    let cleanup: String
    let replayed: Bool
    let quarantine: SelectedHIDQuarantine?
}

struct AgentModeCacheState: Codable, Sendable {
    let status: String
    let reason: String?
    let requiresRefresh: Bool
}

struct AgentModeResult: Codable, Sendable {
    struct Data: Codable, Sendable {
        let capture: AgentModeCapture?
        let action: AgentModeActionReceipt?
        let cache: AgentModeCacheState
        let context: SelectedHIDContext?
        let quarantine: SelectedHIDQuarantine?
    }
    let schema: String
    let schemaVersion: String
    let didError: Bool
    let error: AgentModeFailure?
    let data: Data
    let nextSteps: [String]

    init(error: AgentModeFailure? = nil, capture: AgentModeCapture? = nil,
         action: AgentModeActionReceipt? = nil, cache: AgentModeCacheState,
         context: SelectedHIDContext? = nil, quarantine: SelectedHIDQuarantine? = nil,
         nextSteps: [String] = []) {
        schema = "axe.output.agent-result"
        schemaVersion = "1"
        didError = error != nil
        self.error = error
        data = Data(capture: capture, action: action, cache: cache,
                    context: capture?.context ?? context, quarantine: quarantine)
        self.nextSteps = nextSteps
    }
}

/// Optional agent evidence. Nil preserves the existing selected command route.
struct AgentModeAdmission: Codable, Sendable {
    let context: SelectedHIDContext
    let expectedPID: Int32
    let screenHash: String
    let nativeFingerprint: String
    let target: AgentModeTarget?
    var selectorKind: SelectedAXRequest.SelectorKind? = nil
    var selectorValue: String? = nil

    func validateContext(_ observation: FBSimulatorHIDSessionObservation) throws {
        guard context == SelectedHIDContext(observation) else {
            throw AgentModeFailure("contextChanged", "The simulator boot, display, geometry, orientation, or pose changed. Refresh the snapshot.")
        }
    }

    func validateScreen(_ roots: [FBSimulatorAXNode]) throws {
        guard try AgentModeSnapshot(roots: roots).nativeFingerprint == nativeFingerprint else {
            throw AgentModeFailure("screenChanged", "The screen changed before input. Refresh the snapshot.")
        }
    }
}

struct AgentModeTarget: Codable, Sendable {
    let type: String?
    let identifier: String?
    let label: String?
    let value: FBSimulatorAXValue?
    let frame: AgentFrame
    let pid: Int32?

    init(_ node: FBSimulatorAXNode) throws {
        guard let frame = node.frame else { throw AgentModeFailure("missingFrame", "The selected target has no native frame.") }
        type = node.type; identifier = node.identifier; label = node.label; value = node.value; pid = node.pid
        self.frame = AgentFrame(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
    }

    func validate(_ node: FBSimulatorAXNode, allowingValueChange: Bool = false) throws {
        let fresh = try AgentModeTarget(node)
        guard type == fresh.type, identifier == fresh.identifier, label == fresh.label, pid == fresh.pid,
              frame == fresh.frame, allowingValueChange || value == fresh.value else {
            throw AgentModeFailure("targetChanged", "The native target identity or frame changed before input. Refresh the snapshot.")
        }
    }
}
