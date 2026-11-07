import AXeCore
import Foundation
import FBSimulatorControl

/// A tap target whose activation point lies under the keyboard the app shows. A physical touch
/// there lands on a key, whatever the keyboard's position or layout, so the native hit check
/// refuses it on every attempt; the keyboard does not move by itself, so retrying cannot help.
/// The keyboard frame is the measured native keyboard group, not an assumed bottom band.
struct AgentKeyboardCover: Sendable {
    let keyboard: CGRect
    let target: RuntimeSnapshotElement
    /// The innermost scroll area that holds the target and is not part of the keyboard.
    let scrollArea: RuntimeSnapshotElement?

    static func find(ref: String, in snapshot: AgentModeSnapshot, pid: Int32,
                     context: SelectedHIDContext) -> AgentKeyboardCover? {
        let size = CGSize(width: context.logicalWidth, height: context.logicalHeight)
        guard let keyboard = AgentModeKeyboardDetector.occlusion(in: snapshot, expectedPID: pid, logicalSize: size),
              let target = snapshot.elements.first(where: { $0.ref == ref }) else { return nil }
        func insideKeyboard(_ element: RuntimeSnapshotElement) -> Bool {
            element.path == keyboard.path || element.path.hasPrefix(keyboard.path + ".")
        }
        guard !insideKeyboard(target), keyboard.frame.contains(activationPoint(target)) else { return nil }
        let area = snapshot.elements
            .filter { $0.actions.contains(.swipeWithin) && target.path.hasPrefix($0.path + ".") && !insideKeyboard($0) }
            .max { $0.path.split(separator: ".").count < $1.path.split(separator: ".").count }
        return AgentKeyboardCover(keyboard: keyboard.frame, target: target, scrollArea: area)
    }

    /// The refusal: the reason, that nothing was sent, and the fix, naming the scroll area to swipe.
    /// The scroll-area ref belongs to the table this cover was found on.
    var failure: AgentModeFailure {
        let name: String
        if let label = target.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            name = "\"\(label)\""
        } else {
            name = "The target"
        }
        let scroll = scrollArea.map { "Swipe ref \($0.ref) up (--distance 0.5) until it clears the keyboard" }
            ?? "Scroll its form until it clears the keyboard"
        return AgentModeFailure("keyboardCovered",
            "\(name) is under the keyboard, so a tap there would press a key; nothing was sent. \(scroll), or dismiss the keyboard with an app control, then tap again. Do not use the form's Cancel, Close or Done to hide it.")
    }

    static func activationPoint(_ element: RuntimeSnapshotElement) -> CGPoint {
        if let point = element.activationPointOverride { return CGPoint(x: point.x, y: point.y) }
        return CGPoint(x: element.frame.x + element.frame.width / 2, y: element.frame.y + element.frame.height / 2)
    }
}
