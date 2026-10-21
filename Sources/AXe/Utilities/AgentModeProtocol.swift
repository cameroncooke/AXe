import AXeCore
import Foundation
import FBSimulatorControl

struct AgentModeRequest: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case describe, tap, typeText, swipe, complete }
    let kind: Kind
    var expectedPID: Int32? = nil
    var snapshotID: UUID? = nil
    var ref: String? = nil
    var sinceScreenHash: String? = nil
    var point: SelectedAXPoint? = nil
    var selectorKind: SelectedAXRequest.SelectorKind? = nil
    var selectorValue: String? = nil
    var elementType: String? = nil
    var text: String? = nil
    var direction: RuntimeSwipeDirection? = nil
    var distance: Double = 1
    var duration: Double = 1
    var preDelay: Double = 0
    var postDelay: Double = 0
    var tapStyle: SelectedTapStyle? = nil
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
        if let ref {
            guard snapshotID != nil, ref.utf8.count <= 32, ref.first == "e",
                  let number = Int(ref.dropFirst()), number > 0 else {
                throw AgentModeFailure("invalidReference", "A reference requires its immutable --snapshot-id and an eN name.")
            }
        }
        guard [point != nil, ref != nil, selectorValue != nil].filter({ $0 }).count <= 1 else {
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
        if snapshotID != nil, sinceScreenHash != nil {
            throw AgentModeFailure("mixedSnapshotQuery", "Snapshot paging cannot be combined with since-screen-hash.")
        }
        if kind == .describe {
            guard ref == nil, point == nil, selectorValue == nil, text == nil, direction == nil else {
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
            guard ref != nil || selectorValue != nil || point != nil else {
                throw AgentModeFailure("missingTarget", "Agent tap requires a reference, selector, or point.")
            }
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
