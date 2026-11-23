import Testing
@testable import AXe

@Suite("Agent typed text settling")
struct AgentTypedTextSettleTests {
    @Test("A field that ends with the typed text is done on the first read")
    func complete() {
        #expect(AgentTypedTextSettle.isSettled(typed: "world", previous: nil, current: "hello world"))
    }

    @Test("A field still filling in is read again until it ends with the text or stops changing")
    func partial() {
        #expect(!AgentTypedTextSettle.isSettled(typed: "hello world", previous: nil, current: "hello w"))
        #expect(!AgentTypedTextSettle.isSettled(typed: "hello world", previous: .some("hello w"), current: "hello wor"))
        // Autocorrect, a formatter or a secure field: the same value twice is what the field holds.
        #expect(AgentTypedTextSettle.isSettled(typed: "teh ", previous: .some("the "), current: "the "))
        #expect(AgentTypedTextSettle.isSettled(typed: "secret", previous: .some("••••••"), current: "••••••"))
    }

    @Test("Without a focused field there is nothing to wait for")
    func noField() {
        #expect(AgentTypedTextSettle.isSettled(typed: "hello\n", previous: nil, current: nil))
    }

    @Test("The wait is bounded by the text's length")
    func limit() {
        #expect(AgentTypedTextSettle.timeLimit(for: "hi") < 1.1)
        #expect(abs(AgentTypedTextSettle.timeLimit(for: String(repeating: "a", count: 1024)) - 16.36) < 0.001)
    }
}

@Suite("Selected keyboard time allowance")
struct SelectedKeyboardAllowanceTests {
    @Test("The allowance grows with the key downs, so the 256-byte maximum fits")
    @MainActor func keyDowns() {
        let events: [SelectedKeyboardPrimitive] = [.down(4), .up(4), .delay(0.1), .down(5), .up(5)]
        #expect(SelectedKeyboardFocusGuard.keyDowns(in: events) == 2)
        #expect(8 + SelectedKeyboardFocusGuard.focusReadAllowance * 256 < 120) // inside the broker's socket read
    }
}


@Suite("Selected keyboard focus reads")
struct SelectedKeyboardFocusReadPlanTests {
    @MainActor private func plan(_ events: [SelectedKeyboardPrimitive], every interval: Int = 16) -> [Int] {
        SelectedKeyboardFocusGuard.checkedKeyDowns(in: events, interval: interval).sorted()
    }
    private func keys(_ codes: [UInt32]) -> [SelectedKeyboardPrimitive] { codes.flatMap { [.down($0), .up($0)] } }

    @Test("Plain text reads before the first key and every 16th")
    @MainActor func text() {
        #expect(plan(keys(Array(repeating: 4, count: 40))) == [0, 16, 32])
        // Shift for capitals adds no read.
        #expect(plan([.down(225), .down(11), .up(11), .up(225)] + keys([4, 4])) == [0])
    }

    @Test("The key after Return, Tab, a shortcut or a delay reads again")
    @MainActor func afterFocusMovingKeys() {
        #expect(plan(keys([40, 4])) == [0, 1])
        #expect(plan(keys([4, 43, 4, 4])) == [0, 2])
        #expect(plan(keys([4]) + [.delay(0.3)] + keys([4])) == [0, 1])
        #expect(plan([.down(227), .down(4), .up(4), .up(227)] + keys([5])) == [0, 1, 2])
    }

    @Test("An interval of one reads before every key")
    @MainActor func everyKey() {
        #expect(plan(keys([4, 4, 4]), every: 1) == [0, 1, 2])
    }
}
