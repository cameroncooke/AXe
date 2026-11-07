import Foundation
import FBSimulatorControl

/// Keyboard input targets native focus, not a cached point. An owned edit can resize
/// the same field (for example when its clear button appears) before the next key.
enum SelectedKeyboardEditingTargetPolicy {
    static func validateCurrentField(_ field: FBSimulatorAXNode, expectedPID: Int32,
                                     focusID: String, logicalSize: CGSize) throws {
        try validateCurrentField(field, expectedPID: expectedPID,
            fieldTarget: .semantic(kind: .id, value: focusID, elementType: "TextField"), logicalSize: logicalSize)
    }

    static func validateCurrentField(_ field: FBSimulatorAXNode, expectedPID: Int32,
                                     fieldTarget: SelectedNativeTarget, logicalSize: CGSize) throws {
        try SelectedKeyboardFocusPolicy.validate(field, expectedPID: expectedPID, fieldTarget: fieldTarget)
        guard logicalSize.width.isFinite, logicalSize.height.isFinite,
              logicalSize.width > 0, logicalSize.height > 0, let frame = field.frame,
              [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height].allSatisfy(\.isFinite),
              frame.size.width > 0, frame.size.height > 0,
              CGRect(origin: .zero, size: logicalSize).contains(frame) else {
            throw AgentModeFailure("targetChanged", "The focused field is off screen or has no size, so nothing was sent. Scroll it into view, then act again from the capture in this reply.")
        }
    }

    static func validate(_ field: FBSimulatorAXNode, against original: AgentModeTarget,
                         expectedPID: Int32, focusID: String, logicalSize: CGSize,
                         editingStarted: Bool) throws {
        try validate(field, against: original, expectedPID: expectedPID,
            fieldTarget: .semantic(kind: .id, value: focusID, elementType: "TextField"),
            logicalSize: logicalSize, editingStarted: editingStarted)
    }

    static func validate(_ field: FBSimulatorAXNode, against original: AgentModeTarget,
                         expectedPID: Int32, fieldTarget: SelectedNativeTarget, logicalSize: CGSize,
                         editingStarted: Bool) throws {
        try validateCurrentField(field, expectedPID: expectedPID, fieldTarget: fieldTarget, logicalSize: logicalSize)
        guard editingStarted else {
            // Before the first owned key, retain the complete snapshot target contract.
            try original.validate(field)
            return
        }
        let identityMatches: Bool
        switch fieldTarget {
        case let .semantic(kind, value, _):
            identityMatches = kind == .id && original.identifier == value &&
                (original.label ?? original.identifier) == (field.label ?? field.identifier)
        case let .nativeObject(identity, _):
            try original.validateNativeIdentity(field)
            identityMatches = original.nativeIdentity == identity && field.nativeIdentity == identity &&
                original.identifier == field.identifier && original.label == field.label
        }
        guard identityMatches, original.type == "TextField", original.pid == expectedPID,
              original.type == field.type, original.identifier == field.identifier,
              original.pid == field.pid else {
            throw AgentModeFailure("targetChanged", "The focused field changed while typing, so typing stopped. Check the event count in the action receipt and the field's value in the capture before typing the rest; do not resend text already typed.")
        }
        // An absent native label uses the exact native ID for identity. Empty strings,
        // case changes and distinct materialized labels are not aliases.
        // Values already change during owned typing. The exact current frame is read
        // from the unique focused field before every DOWN; it supplies no coordinates.
    }
}
