import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

enum OwnedBatchTapTreeCase: CaseIterable, Sendable {
    case valid, changedLayout, overlay, wrongApp, changedContext, wrongTarget
}

@Suite("Owned reference batch taps", .serialized)
@MainActor
struct AgentBatchTapAdmissionTests {
    @Test("The owned tree permits result text and values to change, then binds the fresh target value")
    func freshOwnedTree() throws {
        let fixture = try Fixture()
        let admission = AgentBatchTapAdmission(plan: try fixture.plan(), index: 1)
        var changed = fixture.controls
        changed[1].label = "8"
        changed[1].frame.width = 30
        changed[2].value = "0"
        let roots = try fixture.roots(changed)
        let target = roots[0].children[2]
        let accepted = try admission.validateOwnedSnapshot(roots: roots, context: fixture.context,
            pid: 1234, nativeTarget: target)
        #expect(accepted.target?.value == .string("0"))
        try accepted.target?.validate(target)
        let oldTarget = try fixture.roots(fixture.controls)[0].children[2]
        #expect(throws: (any Error).self) { try accepted.target?.validate(oldTarget) }
        let request = try admission.request(requestID: UUID())
        #expect(request.ax?.kind == .tap && request.ax?.selectorValue == "Animations")
        #expect(request.agentAdmission == nil && request.agent == nil && request.keyboard == nil)
    }

    @Test("Old plan layout, overlays and wrong app trees cannot authorize input")
    func changedOwnedTreesReject() throws {
        let fixture = try Fixture()
        let admission = AgentBatchTapAdmission(plan: try fixture.plan(), index: 0)
        var variants: [[Fixture.Node]] = []
        var nodes = fixture.controls; nodes[0].frame.x += 1; variants.append(nodes)
        nodes = fixture.controls; nodes[0].label = "Different"; variants.append(nodes)
        nodes = fixture.controls; nodes[0].hidden = true; variants.append(nodes)
        nodes = fixture.controls; nodes[0].enabled = false; variants.append(nodes)
        nodes = fixture.controls; nodes.append(.init(type: "Button", label: "Overlay")); variants.append(nodes)
        nodes = fixture.controls; nodes[0].pid = 4321; variants.append(nodes)
        for changed in variants {
            let roots = try fixture.roots(changed)
            #expect(throws: (any Error).self) {
                try admission.validateOwnedSnapshot(roots: roots, context: fixture.context,
                    pid: 1234, nativeTarget: roots[0].children[0])
            }
        }
        let wrongApp = try fixture.roots(fixture.controls, appPID: 4321)
        #expect(throws: (any Error).self) {
            try admission.validateOwnedSnapshot(roots: wrongApp, context: fixture.context,
                pid: 1234, nativeTarget: wrongApp[0].children[0])
        }
    }

    @Test("PID and full context remain bound before and after owned acquisition")
    func contextAndPIDReject() throws {
        let fixture = try Fixture()
        let admission = AgentBatchTapAdmission(plan: try fixture.plan(), index: 0)
        let roots = try fixture.roots(fixture.controls)
        for context in [try Fixture.context(boot: "other"), try Fixture.context(screen: 2),
                        try Fixture.context(rotation: 90), try Fixture.context(pose: "closed")] {
            #expect(throws: (any Error).self) { try admission.validateContext(context, pid: 1234) }
            #expect(throws: (any Error).self) {
                try admission.validateOwnedSnapshot(roots: roots, context: context,
                    pid: 1234, nativeTarget: roots[0].children[0])
            }
        }
        #expect(throws: (any Error).self) { try admission.validateContext(fixture.context, pid: 4321) }
        #expect(throws: (any Error).self) {
            try admission.validateOwnedSnapshot(roots: roots, context: fixture.context,
                pid: 4321, nativeTarget: roots[0].children[0])
        }
    }

    @Test("The operation's selected target must equal the target resolved from its owned tree")
    func wrongNativeTargetRejects() throws {
        let fixture = try Fixture()
        let admission = AgentBatchTapAdmission(plan: try fixture.plan(), index: 0)
        let roots = try fixture.roots(fixture.controls)
        #expect(throws: (any Error).self) {
            try admission.validateOwnedSnapshot(roots: roots, context: fixture.context,
                pid: 1234, nativeTarget: roots[0].children[2])
        }
    }

    @Test("The normal owner keeps rejected owned evidence before input and releases its lease",
          arguments: OwnedBatchTapTreeCase.allCases)
    func ownerUsesOwnedAdmission(_ variant: OwnedBatchTapTreeCase) async throws {
        let fixture = try Fixture()
        let admission = AgentBatchTapAdmission(plan: try fixture.plan(), index: 0)
        var nodes = fixture.controls
        if variant == .changedLayout { nodes[0].frame.x += 1 }
        if variant == .overlay { nodes.append(.init(type: "Button", label: "Overlay")) }
        let roots = try fixture.roots(nodes, appPID: variant == .wrongApp ? 4321 : 1234)
        let context = variant == .changedContext ? try Fixture.context(boot: "other") : fixture.context
        let target = roots[0].children[variant == .wrongTarget ? 2 : 0]
        let state = State()
        let udid = UUID().uuidString
        let dependencies = SelectedAXDependencies(execute: { request, _, broker, _, batchTap in
            state.calls += 1
            do {
                let supplied = try #require(batchTap)
                _ = try supplied.validateOwnedSnapshot(roots: roots, context: context,
                    pid: 1234, nativeTarget: target)
                state.inputs += 2
                return Self.response(request, broker: broker, count: 2, error: nil)
            } catch { return Self.response(request, broker: broker, count: 0, error: String(describing: error)) }
        }, persist: { _, _, _ in Issue.record("No quarantine expected") }, now: { 0 })
        let owner = SelectedHIDOwner(simulatorUDID: udid, logger: AxeLogger(), dependencies: dependencies)
        let result = await owner.perform(try admission.request(requestID: UUID()), batchTap: admission)
        let expectedCount = variant == .valid ? 2 : 0
        #expect((result.error == nil) == (variant == .valid))
        #expect(result.enqueuedEventCount == expectedCount)
        #expect(state.calls == 1 && state.inputs == expectedCount && !owner.isBusy)
        let lease = try HIDInputLease.acquire(simulatorUDID: udid)
        withExtendedLifetime(lease) {}
    }

    @Test("An invalid later ref or stale table fails before any owned input can be submitted")
    func invalidLaterReferenceHasNoInput() async throws {
        let fixture = try Fixture()
        let state = State()
        let dependencies = SelectedAXDependencies(execute: { request, _, broker, _, _ in
            state.calls += 1
            state.inputs += 2
            return Self.response(request, broker: broker, count: 2, error: nil)
        }, persist: { _, _, _ in Issue.record("No quarantine expected") }, now: { 0 })
        let owner = SelectedHIDOwner(simulatorUDID: UUID().uuidString, logger: AxeLogger(), dependencies: dependencies)
        for (ref, table) in [("e999", fixture.table), ("e4", UUID())] {
            do {
                let plan = try fixture.plan(laterRef: ref, publishedTable: table)
                let admission = AgentBatchTapAdmission(plan: plan, index: 0)
                _ = await owner.perform(try admission.request(requestID: UUID()), batchTap: admission)
                Issue.record("Invalid plan reached input")
            } catch {}
        }
        #expect(state.calls == 0 && state.inputs == 0 && !owner.isBusy)
    }

    private static func response(_ request: SelectedHIDRequest, broker: UUID, count: Int,
                                 error: String?) -> SelectedHIDResponse {
        SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: request.requestID,
            brokerID: broker, outcome: error == nil ? "enqueuedAndDrained" : "failedBeforeInput",
            token: nil, enqueuedEventCount: count, cleanup: "notNeeded", error: error, context: nil)
    }

    private final class State {
        var calls = 0
        var inputs = 0
    }

    private struct Fixture {
        let table = UUID()
        let context: SelectedHIDContext
        let controls = [Node(type: "Button", label: "5"),
            Node(type: "StaticText", label: "0", frame: .init(x: 200)),
            Node(type: "Switch", label: "Animations", value: "1", frame: .init(y: 100))]

        init() throws { context = try Self.context() }

        func plan(laterRef: String = "e4", publishedTable: UUID? = nil) throws -> AgentBatchReferencePlan {
            let steps = try JSONDecoder().decode([AgentBatchStep].self, from: Data("""
            [{"action":"tap","ref":"e2"},{"action":"tap","ref":"\(laterRef)"}]
            """.utf8))
            let request = AgentBatchRequest(expectedPID: nil, snapshotID: table,
                steps: steps)
            let snapshot = try AgentModeSnapshot(roots: roots(controls), context: context)
            return try AgentBatchReferencePlan(request: request, snapshotID: publishedTable ?? table,
                snapshot: snapshot, context: context, pid: 1234)
        }

        func roots(_ controls: [Node], appPID: Int32 = 1234) throws -> [FBSimulatorAXNode] {
            let root = Node(type: "Application", label: "Example",
                frame: .init(width: 390, height: 844), children: controls, pid: appPID)
            return try JSONDecoder().decode([FBSimulatorAXNode].self, from: JSONEncoder().encode([root]))
        }

        static func context(boot: String = "boot", screen: Int = 1, rotation: Int = 0,
                            pose: String = "open") throws -> SelectedHIDContext {
            try JSONDecoder().decode(SelectedHIDContext.self, from: Data("""
            {"bootIdentity":"\(boot)","screenID":\(screen),"screenUUID":"DF1FB281-4CCC-4A62-88D3-635D18FAD832",
            "logicalWidth":390,"logicalHeight":844,"rotationDegrees":\(rotation),
            "nativePixelWidth":1170,"nativePixelHeight":2532,"scale":3,"poseRevision":"\(pose)"}
            """.utf8))
        }

        struct Node: Encodable {
            struct Frame: Encodable {
                var x = 0.0
                var y = 0.0
                var width = 80.0
                var height = 44.0
            }
            let type: String
            var label: String
            var value: String? = nil
            var frame = Frame()
            var children: [Node] = []
            var pid: Int32 = 1234
            var enabled = true
            var hidden = false
            private enum CodingKeys: String, CodingKey {
                case type, label = "AXLabel", value = "AXValue", frame, children, pid, enabled, hidden
            }
        }
    }
}
