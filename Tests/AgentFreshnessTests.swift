import Testing
@testable import AXeCore

@Suite("Agent decision freshness")
struct AgentFreshnessTests {
    private let add = RuntimeSnapshotElement(
        ref: "e2",
        role: .button,
        label: "Add",
        identifier: "add-plus-button",
        frame: AgentFrame(x: 300, y: 60, width: 44, height: 44),
        actions: [.tap, .longPress, .touch]
    )

    @Test("Accepts decisions when only details outside the compact rows changed")
    func acceptsSameCompactRows() {
        let observed = screen([add])
        let fresh = screen([
            add,
            RuntimeSnapshotElement(ref: "e3", role: .other, frame: AgentFrame(x: 0, y: 0, width: 0, height: 0), actions: []),
        ])

        for operation in [AgentOperation.done, .tap, .pressReturn] {
            let outcome = AgentFreshness.evaluate(decision(operation, element: operation == .tap ? add : nil), observed: observed, fresh: fresh)
            #expect(outcome.reason == .sameCompactRows)
            #expect(outcome.decision != nil)
        }
    }

    @Test("Re-resolves a moved target and executes against the fresh element")
    func resolvesMovedTarget() throws {
        let moved = RuntimeSnapshotElement(
            ref: "e9",
            role: .button,
            label: "Add",
            identifier: "add-plus-button",
            frame: AgentFrame(x: 300, y: 100, width: 44, height: 44),
            actions: [.tap, .longPress, .touch]
        )
        let clock = RuntimeSnapshotElement(ref: "e4", role: .text, label: "18:36", frame: AgentFrame(x: 16, y: 400, width: 60, height: 20), actions: [.longPress, .touch])

        let outcome = AgentFreshness.evaluate(decision(.tap, element: add), observed: screen([add]), fresh: screen([clock, moved]))

        #expect(outcome.reason == .targetResolved)
        let resolved = try #require(outcome.decision?.element)
        #expect(resolved.ref == "e9")
        #expect(resolved.frame.y == 100)
    }

    @Test("Discards decisions whose target or evidence changed")
    func discardsStaleDecisions() {
        let cancel = RuntimeSnapshotElement(ref: "e4", role: .button, label: "Cancel", frame: AgentFrame(x: 16, y: 100, width: 60, height: 44), actions: [.tap])

        #expect(AgentFreshness.evaluate(decision(.tap, element: add), observed: screen([add]), fresh: screen([cancel])).reason == .stale)
        // A sheet presenting over the screen: the target still resolves behind it, but new targets appeared.
        #expect(AgentFreshness.evaluate(decision(.tap, element: add), observed: screen([add]), fresh: screen([add, cancel])).reason == .stale)
        #expect(AgentFreshness.evaluate(decision(.done), observed: screen([add]), fresh: screen([add, cancel])).reason == .stale)
        #expect(AgentFreshness.evaluate(decision(.openApp), observed: screen([add]), fresh: screen([cancel])).reason == .screenIndependent)

        // Mid-transition: identical rows, but targets are still moving.
        let sliding = RuntimeSnapshotElement(ref: "e2", role: .button, label: "Add", identifier: "add-plus-button", frame: AgentFrame(x: 250, y: 60, width: 44, height: 44), actions: [.tap, .longPress, .touch])
        #expect(AgentFreshness.evaluate(decision(.done), observed: screen([add]), fresh: screen([sliding])).reason == .stale)
    }

    @Test("Falls through ambiguous identifiers to a unique label")
    func fallsThroughAmbiguousSelectors() {
        let first = RuntimeSnapshotElement(ref: "e1", role: .cell, label: "Alert, None", identifier: "cell", frame: AgentFrame(x: 0, y: 100, width: 390, height: 44), actions: [.tap])
        let second = RuntimeSnapshotElement(ref: "e2", role: .cell, label: "Repeat, Never", identifier: "cell", frame: AgentFrame(x: 0, y: 150, width: 390, height: 44), actions: [.tap])

        #expect(AgentFreshness.resolve(second, for: .tap, in: [first, second])?.ref == "e2")
        #expect(AgentFreshness.resolve(second, for: .typeText, in: [first, second]) == nil)
    }

    private func screen(_ elements: [RuntimeSnapshotElement]) -> AgentScreenSnapshot {
        let application = RuntimeSnapshotElement(
            ref: "e1",
            role: .application,
            label: "Calendar",
            frame: AgentFrame(x: 0, y: 0, width: 390, height: 844),
            actions: []
        )
        return AgentScreenSnapshot(applicationName: "Calendar", bundleIdentifier: nil, elements: [application] + elements)
    }

    private func decision(_ operation: AgentOperation, element: RuntimeSnapshotElement? = nil) -> AgentDecision {
        AgentDecision(
            operation: operation,
            element: element,
            application: nil,
            text: nil,
            operationConfidence: 1,
            operationProbability: 1,
            targetConfidence: nil,
            targetProbability: nil
        )
    }
}
