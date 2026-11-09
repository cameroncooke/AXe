import AXeCore
import Foundation
import FBSimulatorControl

struct AgentModeRequest: Codable, Sendable {
    static let maximumRows = 12_288
    enum Kind: String, Codable, Sendable { case describe, read, tap, typeText, focusAndType, swipe, drag, hold, doubleTap, keyPress, keyCombo, keySequence, sliderEndpoint, sliderPercentage, pinch, complete }
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
    var sliderEndpoint: FBSimulatorSliderEndpoint? = nil
    var sliderPercentage: Double? = nil
    var pinch: AgentModePinch? = nil
    var rowOffset: Int = 0
    var rowLimit: Int = 64
    var readReference: String? = nil
    var textQuery: AgentModeTextQuery? = nil

    func validate() throws {
        _ = try AgentModePIDPolicy.expectedPID(assertion: expectedPID, snapshot: nil)
        if kind == .focusAndType {
            guard snapshotID != nil, ref != nil, let text,
                  point == nil, selectorKind == nil, selectorValue == nil, tapSelector == nil,
                  elementType == nil, keyEvents == nil, direction == nil, sinceScreenHash == nil,
                  destination == nil, steps == nil, tapStyle == nil, doubleTapTiming == nil,
                  sliderEndpoint == nil, sliderPercentage == nil, pinch == nil,
                  readReference == nil, textQuery == nil, rowOffset == 0, rowLimit == 64,
                  duration == 1, preDelay == 0, postDelay == 0, distance == 1 else {
                throw AgentModeFailure("invalidFocusAndType", "Focus and type requires one snapshot/ref and text, without other targets, actions or timing options.")
            }
            // Validate all text before a focus tap, including private broker callers.
            let events = try SelectedKeyboardRequest.primitives(from: SelectedKeyboardRequest.textEvent(text))
            try SelectedKeyboardRequest.validateEvents(events)
        }
        if kind == .read {
            guard snapshotID != nil, let readReference, let textQuery,
                  readReference.first == "e", readReference.utf8.count <= 32,
                  let number = Int(readReference.dropFirst()), number > 0,
                  ref == nil, point == nil, selectorKind == nil, selectorValue == nil,
                  tapSelector == nil, elementType == nil, text == nil, keyEvents == nil,
                  direction == nil, sinceScreenHash == nil, destination == nil, steps == nil,
                  tapStyle == nil, doubleTapTiming == nil, sliderEndpoint == nil,
                  sliderPercentage == nil, pinch == nil, rowOffset == 0, rowLimit == 64,
                  duration == 1, preDelay == 0, postDelay == 0, distance == 1 else {
                throw AgentModeFailure("invalidReadReference", "Read-ref requires one snapshot and reference, without input or row options.")
            }
            try textQuery.validate()
            return
        }
        guard readReference == nil, textQuery == nil else {
            throw AgentModeFailure("mixedPayload", "Text read options apply only to a reference read.")
        }
        guard rowOffset >= 0, rowOffset <= Self.maximumRows, (1...64).contains(rowLimit),
              distance.isFinite, distance > 0, distance <= 1,
              duration.isFinite, duration > 0, duration <= 10,
              preDelay.isFinite, (0...10).contains(preDelay),
              postDelay.isFinite, (0...10).contains(postDelay) else {
            throw AgentModeFailure("invalidBounds", "Agent query and timing limits are invalid.")
        }
        if kind == .pinch {
            guard ref != nil, snapshotID != nil, let pinch,
                  point == nil, selectorKind == nil, selectorValue == nil, tapSelector == nil,
                  elementType == nil, text == nil, keyEvents == nil, direction == nil, tapStyle == nil,
                  doubleTapTiming == nil, sliderEndpoint == nil, sinceScreenHash == nil,
                  destination == nil, steps == nil, distance == 1, rowOffset == 0, rowLimit == 64 else {
                throw AgentModeFailure("invalidPinch", "An agent pinch requires one snapshot/area reference and pinch geometry, without other targets or payloads.")
            }
            try pinch.selected(at: .zero, duration: duration, preDelay: preDelay, postDelay: postDelay).validate()
        } else if pinch != nil {
            throw AgentModeFailure("mixedPayload", "Reference pinch geometry applies only to an agent pinch.")
        }
        if kind == .sliderPercentage {
            guard let sliderPercentage, sliderPercentage.isFinite, (0...100).contains(sliderPercentage) else {
                throw AgentModeFailure("invalidSliderPercentage", "An agent slider percentage requires a finite value in 0...100.")
            }
        } else if sliderPercentage != nil {
            throw AgentModeFailure("mixedPayload", "Slider percentages apply only to a reference slider percentage action.")
        }
        if kind == .sliderEndpoint || kind == .sliderPercentage {
            guard ref != nil, snapshotID != nil,
                  (kind == .sliderEndpoint ? sliderEndpoint != nil : sliderEndpoint == nil),
                  point == nil, selectorKind == nil, selectorValue == nil, tapSelector == nil,
                  elementType == nil, text == nil, keyEvents == nil, direction == nil, tapStyle == nil,
                  doubleTapTiming == nil, sinceScreenHash == nil, destination == nil, steps == nil,
                  duration == 1, preDelay == 0, postDelay == 0, distance == 1,
                  rowOffset == 0, rowLimit == 64 else {
                throw AgentModeFailure("invalidSliderEndpoint", "An agent slider requires one snapshot/ref and exactly one endpoint or percentage, without other targets, payloads or timing options.")
            }
        } else if sliderEndpoint != nil {
            throw AgentModeFailure("mixedPayload", "Slider endpoints apply only to a reference slider action.")
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
                throw AgentModeFailure("missingTarget", "Tap needs a target: pass --ref with --snapshot-id, a selector such as --label, or -x and -y.")
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

/// The caller may assert an app; the snapshot and native read establish its owner.
enum AgentModePIDPolicy {
    static func expectedPID(assertion: Int32?, snapshot: Int32?) throws -> Int32? {
        if let assertion, assertion <= 0 {
            throw AgentModeFailure("invalidExpectedPID", "--expected-pid must be positive when provided.")
        }
        guard let snapshot else { return assertion }
        guard snapshot > 0 else {
            throw AgentModeFailure("processEvidenceMissing", "AXe could not confirm which app owns this snapshot, so nothing was sent. Run describe-ui --agent again and act from that capture.")
        }
        if let assertion, assertion != snapshot {
            throw AgentModeFailure("contextChanged", "This snapshot belongs to another app than the one expected, so nothing was sent. \(AgentModeFailure.actFromCapture)")
        }
        return snapshot
    }

    static func verifiedPID(_ observedPID: Int32, expected: Int32?) throws -> Int32 {
        guard observedPID > 0 else {
            throw AgentModeFailure("processEvidenceMissing", "AXe could not confirm which app owns the screen, so nothing was sent. The app may still be launching: run describe-ui --agent again.")
        }
        if let expected, expected != observedPID {
            throw AgentModeFailure("contextChanged", "Another app is now in front, so nothing was sent. Refs never carry over to another app: run describe-ui --agent and act from that capture.")
        }
        return observedPID
    }
}

struct AgentModeFailure: Error, Codable, Sendable, LocalizedError {
    let code: String
    let message: String
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
    var errorDescription: String? { message }
    /// The next step after a refusal before input. Refusal replies usually carry the current screen.
    static let actFromCapture = "Act again from the capture in this reply, or run describe-ui --agent if it has none."
    /// The next step after a batch stops early: what stands, and how to plan the rest.
    static let batchRest = "Completed steps are in the receipt and were not undone. Plan the rest from the capture in this reply; do not resend the batch."
}

/// Keep native cleanup and quarantine evidence when a read fails before an action.
struct AgentModeNativeFailure: Error, Sendable {
    let response: SelectedHIDResponse
}

/// Internal broker metadata; compact output alone exposes this bounded preview.
struct AgentModeScrollPreview: Codable, Sendable {
    let rows: [String]
    let hasMore: Bool
    var truncatedFields: [CLIOutputValue]? = nil
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
    var totalRows: Int? = nil
    var nextRowOffset: Int? = nil
    var redundantTextRefs: [String]? = nil
    var unavailableReferences: [String: String]? = nil
    /// Bounded read-only previews; complete exact arrays use guarded read-ref chunks.
    var customActions: [String: [String]]? = nil
    var truncatedCustomActionRefs: [String]? = nil
    var scrollPreview: AgentModeScrollPreview? = nil
}

struct AgentModeActionReceipt: Codable, Sendable {
    let kind: AgentModeRequest.Kind
    let outcome: String
    let enqueuedEventCount: Int
    let cleanup: String
    let replayed: Bool
    let quarantine: SelectedHIDQuarantine?
    var slider: SelectedSliderResult? = nil
    var sliderValue: SelectedSliderValueResult? = nil
    /// True when a refusal before any input was recovered inside this call: the screen was read
    /// again and the same target was acted on from that newer table. Absent otherwise.
    var retried: Bool? = nil
}

struct AgentModeCacheState: Codable, Sendable {
    let status: String
    let reason: String?
    let requiresRefresh: Bool
}

/// Scalar evidence from an existing failed AX read. It does not authorize a new owner.
struct AgentModeObservationEvidence: Codable, Sendable {
    struct Attempt: Codable, Sendable {
        let index: Int
        let startUptime: Double
        let endUptime: Double
        let rootPID: Int32
        let outcome: FBSimulatorAXAcquisitionOutcome
    }
    let expectedPID: Int32?
    let observedPID: Int32?
    let outcome: FBSimulatorAXAcquisitionOutcome
    let attempts: [Attempt]

    init?(_ response: SelectedHIDResponse?) {
        guard let ax = response?.ax, let acquisition = ax.acquisition,
              acquisition.outcome != .ready else { return nil }
        expectedPID = ax.expectedPID
        outcome = acquisition.outcome
        observedPID = acquisition.attempts.last.flatMap { $0.rootPID > 0 ? $0.rootPID : nil }
        // Native policy permits at most eight attempts. Do not copy AX roots.
        attempts = acquisition.attempts.suffix(8).map {
            Attempt(index: $0.index, startUptime: $0.startUptime, endUptime: $0.endUptime,
                    rootPID: $0.rootPID, outcome: $0.outcome)
        }
    }

    func captureInstruction(udid: String) -> String? {
        guard outcome == .processChanged, let observedPID, observedPID != expectedPID else { return nil }
        return "The frontmost application changed during the AX read. Run describe-ui --agent --udid \(udid) for a fresh snapshot. Old references were not retargeted. Do not replay completed input."
    }
}

struct AgentModeResult: Codable, Sendable {
    struct Data: Codable, Sendable {
        let capture: AgentModeCapture?
        let action: AgentModeActionReceipt?
        let batch: AgentBatchReceipt?
        let cache: AgentModeCacheState
        let context: SelectedHIDContext?
        let quarantine: SelectedHIDQuarantine?
        let observation: AgentModeObservationEvidence?
        let detail: AgentModeTextDetail?
    }
    let schema: String
    let schemaVersion: String
    let didError: Bool
    let error: AgentModeFailure?
    let data: Data
    let nextSteps: [String]

    init(error: AgentModeFailure? = nil, capture: AgentModeCapture? = nil,
         action: AgentModeActionReceipt? = nil, batch: AgentBatchReceipt? = nil, cache: AgentModeCacheState,
         context: SelectedHIDContext? = nil, quarantine: SelectedHIDQuarantine? = nil,
         observation: AgentModeObservationEvidence? = nil, detail: AgentModeTextDetail? = nil,
         nextSteps: [String] = []) {
        schema = "axe.output.agent-result"
        schemaVersion = "1"
        didError = error != nil
        self.error = error
        data = Data(capture: capture, action: AgentModePublicErrorProjection.action(action),
                    batch: AgentModePublicErrorProjection.batch(batch), cache: cache,
                    context: capture?.context ?? context,
                    quarantine: AgentModePublicErrorProjection.quarantine(quarantine),
                    observation: observation, detail: detail)
        self.nextSteps = nextSteps
    }
}

/// Optional agent evidence. Nil preserves the existing selected command route.
struct AgentModeAdmission: Codable, Sendable {
    let context: SelectedHIDContext
    let expectedPID: Int32
    let screenHash: String
    let nativeFingerprint: String
    /// The admission comparison; `nativeFingerprint` identifies the exact native read.
    let visibleFingerprint: String
    let target: AgentModeTarget?
    var selectorKind: SelectedAXRequest.SelectorKind? = nil
    var selectorValue: String? = nil
    var nativeTarget: SelectedNativeTarget? = nil

    func validateContext(_ observation: FBSimulatorHIDSessionObservation) throws {
        guard context == SelectedHIDContext(observation) else {
            throw AgentModeFailure("contextChanged", "The simulator restarted, rotated or changed its display after this snapshot, so nothing was sent. \(AgentModeFailure.actFromCapture)")
        }
    }

    func validateScreen(_ roots: [FBSimulatorAXNode],
                        nativeIdentityMetadata: FBSimulatorAXNativeIdentityMetadata? = nil) throws {
        let snapshot = try AgentModeSnapshot(roots: roots, nativeIdentityMetadata: nativeIdentityMetadata, context: context)
        try validateScreen(snapshot)
    }

    func validateScreen(_ snapshot: AgentModeSnapshot) throws {
        guard snapshot.visibleFingerprint == visibleFingerprint else {
            throw AgentModeFailure("screenChanged", "The screen changed after this snapshot was taken, so nothing was sent. Use the snapshot ID and refs from the capture in this reply, or run describe-ui if there is none, then act again.")
        }
        if let nativeTarget, nativeTarget.nativeIdentity != nil {
            let node = try snapshot.match(target: nativeTarget)
            try target?.validate(node)
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
    let nativeIdentity: FBSimulatorAXNativeIdentity?
    private let nativeRole: String?
    private let nativeSubrole: String?
    private let nativeRoleDescription: String?
    private let nativeFocused: Bool?
    private let nativeEnabled: Bool?
    private let nativeHidden: Bool?

    init(_ node: FBSimulatorAXNode, nativeTarget: SelectedNativeTarget? = nil) throws {
        guard let frame = node.frame else { throw AgentModeFailure("missingFrame", "The selected target has no native frame.") }
        if let identity = nativeTarget?.nativeIdentity {
            try nativeTarget?.validate()
            guard node.nativeIdentity == identity, node.pid == identity.pid, node.type == nativeTarget?.elementType else {
                throw AgentModeFailure("targetChanged", "Your target changed after this snapshot was taken, so nothing was sent. \(AgentModeFailure.actFromCapture)")
            }
            nativeIdentity = identity
            nativeRole = node.role; nativeSubrole = node.subrole; nativeRoleDescription = node.roleDescription
            nativeFocused = node.focused; nativeEnabled = node.enabled; nativeHidden = node.hidden
        } else {
            nativeIdentity = nil
            nativeRole = nil; nativeSubrole = nil; nativeRoleDescription = nil
            nativeFocused = nil; nativeEnabled = nil; nativeHidden = nil
        }
        type = node.type; identifier = node.identifier; label = node.label; value = node.value; pid = node.pid
        self.frame = AgentFrame(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
    }

    func validateNativeIdentity(_ node: FBSimulatorAXNode) throws {
        guard let nativeIdentity else { return }
        guard nativeIdentity == node.nativeIdentity, type == node.type, pid == node.pid,
              identifier == node.identifier, label == node.label,
              nativeRole == node.role, nativeSubrole == node.subrole,
              nativeRoleDescription == node.roleDescription, nativeFocused == node.focused,
              nativeEnabled == node.enabled, nativeHidden == node.hidden else {
            throw AgentModeFailure("targetChanged", "Your target changed after this snapshot was taken, so nothing was sent. \(AgentModeFailure.actFromCapture)")
        }
    }

    func validate(_ node: FBSimulatorAXNode, allowingValueChange: Bool = false) throws {
        let fresh = try AgentModeTarget(node)
        try validateNativeIdentity(node)
        guard type == fresh.type, identifier == fresh.identifier, label == fresh.label, pid == fresh.pid,
              frame == fresh.frame, allowingValueChange || value == fresh.value else {
            throw AgentModeFailure("targetChanged", "Your target changed or moved after this snapshot was taken, so nothing was sent. \(AgentModeFailure.actFromCapture)")
        }
    }

    /// The same control at a new position: everything `validate` binds except the frame.
    /// A changed value is a changed state, not a moved control.
    /// Focus may move to or from it: the expected effect of an earlier focus step.
    func validateMoved(_ node: FBSimulatorAXNode) throws {
        let fresh = try AgentModeTarget(node)
        if let nativeIdentity {
            guard nativeIdentity == node.nativeIdentity, nativeRole == node.role, nativeSubrole == node.subrole,
                  nativeRoleDescription == node.roleDescription else {
                throw AgentModeFailure("targetChanged", "A later batch target was replaced after a focus step, so the remaining steps were not sent. \(AgentModeFailure.batchRest)")
            }
        }
        guard type == fresh.type, identifier == fresh.identifier, label == fresh.label, pid == fresh.pid,
              value == fresh.value else {
            throw AgentModeFailure("targetChanged", "A later batch target changed after a focus step, so the remaining steps were not sent. \(AgentModeFailure.batchRest)")
        }
    }
}
