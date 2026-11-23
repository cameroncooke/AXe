import Foundation

/// When an agent `type` may publish its replacement screen. AXe hands every key to the simulator in
/// about 0.2 s, but iOS works through them at about 5.7 ms a character (iPhone 17, iOS 27.3), so a read
/// right after a long `type` shows the field partway: 256 characters were complete 1.4 s later. The
/// replacement is read again until the focused field ends with the typed text, or holds the same value
/// on two reads in a row (autocorrect, a formatter or a secure field can make it differ), or a limit
/// that grows with the text runs out. A few words are complete on the first read.
enum AgentTypedTextSettle {
    static let textTypes: Set<String> = ["TextField", "TextView", "SecureTextField"]
    static let interval: Duration = .milliseconds(50)

    /// The value of the application's focused text field, or nil when none has focus.
    static func focusedValue(in snapshot: AgentModeSnapshot, pid: Int32) -> String? {
        guard let node = snapshot.nodes.first(where: {
            $0.focused == true && $0.pid == pid && textTypes.contains($0.type ?? "")
        }) else { return nil }
        return AgentModeSnapshot.text(node.value) ?? ""
    }

    /// Nothing to wait for without a focused field; done when it ends with the text, or stopped changing.
    static func isSettled(typed: String, previous: String??, current: String?) -> Bool {
        guard let current else { return true }
        if current.hasSuffix(typed) { return true }
        guard let previous else { return false }
        return previous == current
    }

    /// One second plus 15 ms a character: about two and a half times the rate iOS 27.3 was measured at.
    static func timeLimit(for typed: String) -> Double {
        1 + 0.015 * Double(typed.count)
    }
}
