import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Owned single reference taps", .serialized)
@MainActor
struct AgentReferenceTapAdmissionTests {
    @Test("The owned tap request carries the table's target, display and style without a pre-description")
    func requestShape() throws {
        let fixture = try Fixture()
        let admission = try fixture.admission(ref: "e2")
        let request = try admission.request(requestID: UUID())
        #expect(request.ax?.kind == .tap && request.ax?.expectedPID == 1234)
        #expect(request.ax?.nativeTarget == .semantic(kind: .label, value: "5", elementType: "Button"))
        #expect(request.ax?.elementType == "Button" && request.ax?.selectorKind == nil)
        #expect(request.screenID == fixture.context.screenID)
        #expect(request.screenUUID == UUID(uuidString: fixture.context.screenUUID))
        #expect(request.agentAdmission == nil && request.agent == nil && request.keyboard == nil)
        #expect(!admission.requiresNativeIdentity)
    }

    @Test("Only a visible, enabled tap-capable reference can open an owned tap")
    func unsupportedReferenceRejects() throws {
        let fixture = try Fixture()
        for ref in ["e3", "e999"] {
            #expect(throws: (any Error).self) { try fixture.admission(ref: ref) }
        }
    }

    @Test("An identical owned tree binds the fresh target; any other tree change rejects before input")
    func ownedTreeMustMatchTheTable() throws {
        let fixture = try Fixture()
        let admission = try fixture.admission(ref: "e2")
        let same = try fixture.roots(fixture.controls)
        let accepted = try admission.validateOwnedSnapshot(roots: same, context: fixture.context,
            pid: 1234, nativeTarget: same[0].children[0])
        #expect(accepted.nativeFingerprint == fixture.snapshot.nativeFingerprint)
        #expect(accepted.selectorKind == .label && accepted.selectorValue == "5")
        try accepted.target?.validate(same[0].children[0])
        var variants: [[Fixture.Node]] = []
        var nodes = fixture.controls; nodes[2].label = "Motion"; variants.append(nodes)
        nodes = fixture.controls; nodes[2].value = "0"; variants.append(nodes)
        nodes = fixture.controls; nodes[0].frame.x += 1; variants.append(nodes)
        nodes = fixture.controls; nodes.append(.init(type: "Button", label: "Overlay")); variants.append(nodes)
        for changed in variants {
            let roots = try fixture.roots(changed)
            #expect(throws: (any Error).self) {
                try admission.validateOwnedSnapshot(roots: roots, context: fixture.context,
                    pid: 1234, nativeTarget: roots[0].children[0])
            }
        }
        #expect(throws: (any Error).self) {
            try admission.validateOwnedSnapshot(roots: same, context: fixture.context,
                pid: 1234, nativeTarget: same[0].children[2])
        }
        for context in [try Fixture.context(boot: "other"), try Fixture.context(rotation: 90)] {
            #expect(throws: (any Error).self) { try admission.validateContext(context, pid: 1234) }
            #expect(throws: (any Error).self) {
                try admission.validateOwnedSnapshot(roots: same, context: context,
                    pid: 1234, nativeTarget: same[0].children[0])
            }
        }
        #expect(throws: (any Error).self) { try admission.validateContext(fixture.context, pid: 4321) }
    }

    @Test("A reference tap runs one owned operation, then publishes its replacement from the same display")
    func controllerUsesOwnedTap() async throws {
        let harness = try Harness()
        let (snapshot, ref) = try await harness.describe()
        let response = await harness.controller.perform(harness.tap(snapshot: snapshot, ref: ref))
        let result = try #require(response.agent)
        #expect(!result.didError)
        #expect(result.data.action?.outcome == "enqueuedAndDrained" && result.data.action?.enqueuedEventCount == 2)
        #expect(result.data.cache.status == "refreshed" && !result.data.cache.requiresRefresh)
        #expect(result.data.capture?.snapshotID != nil && result.data.capture?.snapshotID != snapshot)
        #expect(harness.state.kinds == [.describe, .tap, .describe])
        #expect(harness.state.ownedTaps == 1)
        // The initial description measured the panel; the tap and its replacement reused the table's display.
        #expect(harness.state.discoveries == 1)
        #expect(!harness.owner.isBusy)
    }

    @Test("An explicit display option must name the table's display")
    func explicitDisplayMustMatch() async throws {
        let harness = try Harness()
        let (snapshot, ref) = try await harness.describe()
        var request = harness.tap(snapshot: snapshot, ref: ref)
        request = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: request.requestID,
            screenID: 2, screenUUID: UUID(), operation: .complete, token: nil, primitives: [], agent: request.agent)
        let response = await harness.controller.perform(request)
        #expect(response.agent?.error?.code == "inactiveDisplay")
        #expect(harness.state.kinds == [.describe] && harness.state.discoveries == 1)
    }

    @Test("A changed screen with an unchanged target is refused before input, then retried on the new table")
    func changedScreenRetriesUnchangedTarget() async throws {
        let harness = try Harness()
        let (snapshot, ref) = try await harness.describe()
        var changed = harness.fixture.controls
        changed[2].value = "0"
        harness.state.ownedRoots = try harness.fixture.roots(changed)
        harness.state.describeRoots = harness.state.ownedRoots
        let response = await harness.controller.perform(harness.tap(snapshot: snapshot, ref: ref))
        let result = try #require(response.agent)
        #expect(!result.didError)
        #expect(result.data.action?.outcome == "enqueuedAndDrained" && result.data.action?.enqueuedEventCount == 2)
        #expect(result.data.cache.status == "refreshed" && !result.data.cache.requiresRefresh)
        #expect(result.data.capture?.snapshotID != nil && result.data.capture?.snapshotID != snapshot)
        // The first owned tap refuses before input; one read replaces the table; the tap runs on it.
        #expect(harness.state.kinds == [.describe, .tap, .describe, .tap, .describe])
        #expect(harness.state.ownedTaps == 2 && harness.state.discoveries == 1)
    }

    @Test("A ticking ordinary label neither refuses a ref tap nor lets a read return its old text")
    func tickingTextAdmitsInput() async throws {
        let harness = try Harness()
        let (snapshot, ref) = try await harness.describe()
        var ticked = harness.fixture.controls
        ticked[1].label = "8"
        harness.state.ownedRoots = try harness.fixture.roots(ticked)
        harness.state.describeRoots = harness.state.ownedRoots
        let read = try #require(await harness.controller.perform(harness.read(snapshot: snapshot, ref: "e3")).agent)
        #expect(read.didError && read.error?.code == "screenChanged" && read.data.detail == nil)

        let (current, currentRef) = try await harness.describe()
        ticked[1].label = "9"
        harness.state.ownedRoots = try harness.fixture.roots(ticked)
        harness.state.describeRoots = harness.state.ownedRoots
        harness.state.kinds = []
        let result = try #require(await harness.controller.perform(harness.tap(snapshot: current, ref: currentRef)).agent)
        #expect(!result.didError && result.data.action?.retried == nil)
        #expect(harness.state.kinds == [.tap, .describe] && harness.state.ownedTaps == 1)
    }

    @Test("A changed target stops before input and returns the current screen as a new table")
    func changedTargetReturnsNewTable() async throws {
        let harness = try Harness()
        let (snapshot, ref) = try await harness.describe()
        var changed = harness.fixture.controls
        changed[0].label = "7"
        harness.state.ownedRoots = try harness.fixture.roots(changed)
        harness.state.describeRoots = harness.state.ownedRoots
        let response = await harness.controller.perform(harness.tap(snapshot: snapshot, ref: ref))
        let result = try #require(response.agent)
        #expect(result.didError && result.error?.code == "screenChanged")
        #expect(result.data.action?.outcome == "failedBeforeInput" && result.data.action?.enqueuedEventCount == 0)
        let capture = try #require(result.data.capture)
        #expect(capture.snapshotID != snapshot && capture.targets.contains { $0.contains("|tap|button|7|") })
        #expect(result.data.cache.status == "refreshed" && !result.data.cache.requiresRefresh)
        #expect(harness.state.kinds == [.describe, .tap, .describe] && harness.state.ownedTaps == 1)
        // The refused table is replaced; its ID no longer admits input.
        let retry = await harness.controller.perform(harness.tap(snapshot: snapshot, ref: ref))
        #expect(retry.agent?.error?.code == "snapshotMissing")
        #expect(harness.state.kinds == [.describe, .tap, .describe])
    }

    @Test("A ref that offers no tap is refused before input with the current screen, and is not retried",
          arguments: ["e3", "e999"])
    func unsupportedReferenceReturnsCurrentScreen(ref: String) async throws {
        let harness = try Harness()
        let (snapshot, _) = try await harness.describe()
        // The screen moved on since the agent's capture, as when a dismissed sheet reveals a pushed card.
        var changed = harness.fixture.controls
        changed.append(.init(type: "Button", label: "Edit", frame: .init(y: 300)))
        harness.state.ownedRoots = try harness.fixture.roots(changed)
        harness.state.describeRoots = harness.state.ownedRoots
        let response = await harness.controller.perform(harness.tap(snapshot: snapshot, ref: ref))
        let result = try #require(response.agent)
        #expect(result.didError && result.error?.code == "unsupportedReference")
        #expect(result.data.action == nil || result.data.action?.enqueuedEventCount == 0)
        let capture = try #require(result.data.capture, "The refusal must carry the current screen")
        #expect(capture.snapshotID != snapshot && capture.targets.contains { $0.contains("|tap|button|Edit|") })
        #expect(result.data.cache.status == "refreshed" && !result.data.cache.requiresRefresh)
        // No owned tap, and exactly one refresh read: the agent's own choice is not retried.
        #expect(harness.state.ownedTaps == 0)
        #expect(harness.state.kinds == [.describe, .describe])
    }

    @Test("A reference read follows an unchanged control on a changed screen and refuses a changed one")
    func readFollowsUnchangedControl() async throws {
        let harness = try Harness()
        let (snapshot, ref) = try await harness.describe()
        var elsewhere = harness.fixture.controls
        elsewhere[2].value = "0"
        harness.state.describeRoots = try harness.fixture.roots(elsewhere)
        // Another row changed: the read is of the same control on the current screen, and the
        // cache state still reports the snapshot as stale for input.
        let read = try #require(await harness.controller.perform(harness.read(snapshot: snapshot, ref: ref)).agent)
        #expect(!read.didError && read.data.detail?.text == "5" && read.data.detail?.ref == ref)
        #expect(read.data.cache.status == "invalidated" && read.data.cache.requiresRefresh)

        var changed = elsewhere
        changed[0].label = "7"
        harness.state.describeRoots = try harness.fixture.roots(changed)
        let refused = try #require(await harness.controller.perform(harness.read(snapshot: snapshot, ref: ref)).agent)
        #expect(refused.didError && refused.error?.code == "screenChanged" && refused.data.detail == nil)
        #expect(harness.state.ownedTaps == 0)
    }

    @Test("A target that moved and changed its value is not retried")
    func movedTargetWithChangedValueReturnsNewTable() async throws {
        let harness = try Harness()
        let (snapshot, ref) = try await harness.describe()
        var changed = harness.fixture.controls
        changed[0].frame.x += 40
        changed[0].value = "1"
        harness.state.ownedRoots = try harness.fixture.roots(changed)
        harness.state.describeRoots = harness.state.ownedRoots
        let response = await harness.controller.perform(harness.tap(snapshot: snapshot, ref: ref))
        let result = try #require(response.agent)
        #expect(result.didError && result.error?.code == "screenChanged")
        #expect(result.data.capture != nil && result.data.cache.status == "refreshed")
        // One refused owned tap and one refresh read; the moved control is not tapped again.
        #expect(harness.state.ownedTaps == 1)
    }

    @Test("A changed screen whose same-label target is a different native object is not retried")
    func replacedObjectIsNotRetried() async throws {
        var controls = Fixture.defaultControls
        controls[0].nativeIdentity = FBSimulatorAXNativeIdentity(pid: 1234, objectID: 1)
        let harness = try Harness(controls: controls)
        let (snapshot, ref) = try await harness.describe()
        // Another alert replaced the first: an equal button at the same frame, but another object.
        var replaced = controls
        replaced[0].nativeIdentity = FBSimulatorAXNativeIdentity(pid: 1234, objectID: 2)
        replaced.append(.init(type: "Button", label: "Overlay", frame: .init(y: 300)))
        harness.state.ownedRoots = try harness.fixture.roots(replaced)
        harness.state.describeRoots = harness.state.ownedRoots
        let result = try #require(await harness.controller.perform(harness.tap(snapshot: snapshot, ref: ref)).agent)
        #expect(result.didError && result.error?.code == "screenChanged")
        #expect(result.data.capture != nil && !result.data.cache.requiresRefresh)
        #expect(harness.state.ownedTaps == 1)

        let batch = try Harness(controls: controls)
        let (batchSnapshot, batchRef) = try await batch.describe()
        batch.state.ownedRoots = try batch.fixture.roots(replaced)
        batch.state.describeRoots = batch.state.ownedRoots
        let stopped = try #require(await batch.controller.performBatch(
            try batch.batch(snapshot: batchSnapshot, refs: [batchRef])).agent)
        #expect(stopped.didError && stopped.error?.code == "batchLayoutChanged")
        #expect(stopped.data.batch?.completedSteps == 0 && stopped.data.capture != nil)
        #expect(batch.state.ownedTaps == 1)
    }

    @Test("A covered target is refused once with the current screen, for a ref and a selector")
    func coveredTargetIsNotRetried() async throws {
        let harness = try Harness()
        let (snapshot, ref) = try await harness.describe()
        harness.state.tapFailure = .targetRejected
        let result = try #require(await harness.controller.perform(harness.tap(snapshot: snapshot, ref: ref)).agent)
        #expect(result.didError && result.error?.code == "targetCovered")
        #expect(result.data.action?.outcome == "failedBeforeInput" && result.data.action?.enqueuedEventCount == 0)
        #expect(result.data.capture != nil && !result.data.cache.requiresRefresh)
        #expect(harness.state.kinds == [.describe, .tap, .describe] && harness.state.ownedTaps == 1)

        let selector = try Harness()
        selector.state.tapFailure = .targetRejected
        let refused = try #require(await selector.controller.perform(selector.tap(label: "5")).agent)
        #expect(refused.didError && refused.error?.code == "targetCovered" && refused.data.capture != nil)
        #expect(selector.state.kinds == [.describe, .tap, .describe] && selector.state.ownedTaps == 1)
    }

    @Test("Native refusals before input have distinct codes, return the screen and are not retried", arguments: [
        (SelectedAXFailure.ownershipRejected, "busy"), (.acquisitionFailed, "observationFailed"),
        (.setupFailed, "displayChanged"), (.waitTimedOut, "waitTimedOut"),
    ])
    func nativeRefusalsHaveDistinctCodes(_ failure: SelectedAXFailure, code: String) async throws {
        let harness = try Harness()
        let (snapshot, ref) = try await harness.describe()
        harness.state.tapFailure = failure
        let result = try #require(await harness.controller.perform(harness.tap(snapshot: snapshot, ref: ref)).agent)
        #expect(result.didError && result.error?.code == code)
        #expect(result.data.capture != nil && harness.state.ownedTaps == 1)
    }

    @Test("A typed path or frame guard refusal before input returns the current screen")
    func typedGuardRefusalReturnsCurrentScreen() async throws {
        let harness = try Harness()
        let (snapshot, ref) = try await harness.describe()
        harness.state.tapPolicyFailure = AgentModeFailure("opaqueFrameTapRejected", "Another control is at the point.")
        let result = try #require(await harness.controller.perform(harness.tap(snapshot: snapshot, ref: ref)).agent)
        #expect(result.didError && result.error?.code == "opaqueFrameTapRejected")
        let capture = try #require(result.data.capture, "The refusal must carry the current screen")
        #expect(capture.snapshotID != snapshot && !result.data.cache.requiresRefresh)
        #expect(harness.state.kinds == [.describe, .tap, .describe] && harness.state.ownedTaps == 1)
    }

    @Test("A focus tap refused before input is retried only by the focus-and-type loop")
    func refusedFocusTapIsNotRetriedTwice() async throws {
        var controls = Fixture.defaultControls
        controls.append(.init(type: "TextField", label: "Field", value: "", frame: .init(y: 200, width: 200),
            identifier: "field", role: "AXTextField", focused: false))
        let harness = try Harness(controls: controls)
        var describe = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
            screenID: nil, screenUUID: nil, operation: .complete, token: nil, primitives: [])
        describe.agent = AgentModeRequest(kind: .describe)
        let capture = try #require(await harness.controller.perform(describe).agent?.data.capture)
        let row = try #require(capture.targets.first { $0.contains("|text-field|Field|") })
        harness.state.tapFailure = .targetRejected
        var request = describe
        request.agent = AgentModeRequest(kind: .focusAndType, snapshotID: capture.snapshotID,
            ref: String(row.prefix { $0 != "|" }), text: "Hi")
        let result = try #require(await harness.controller.perform(request).agent)
        #expect(result.didError && result.error?.code == "targetCovered")
        #expect(result.data.capture != nil)
        // One focus tap. Its refusal is not retried as a plain tap that would skip the focus plan.
        #expect(harness.state.ownedTaps == 1)
    }

    @Test("Paging a snapshot whose screen changed is refused with the new snapshot's first page")
    func stalePageIsRefused() async throws {
        let harness = try Harness()
        let (snapshot, _) = try await harness.describe()
        var changed = harness.fixture.controls
        changed.append(.init(type: "Button", label: "Edit", frame: .init(y: 300)))
        harness.state.describeRoots = try harness.fixture.roots(changed)
        var page = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
            screenID: nil, screenUUID: nil, operation: .complete, token: nil, primitives: [])
        page.agent = AgentModeRequest(kind: .describe, snapshotID: snapshot, rowOffset: 2)
        let result = try #require(await harness.controller.perform(page).agent)
        #expect(result.didError && result.error?.code == "screenChanged")
        let capture = try #require(result.data.capture)
        #expect(capture.snapshotID != snapshot && capture.rowOffset == 0)
        #expect(capture.targets.contains { $0.contains("|tap|button|Edit|") })
        #expect(result.data.cache.status == "refreshed" && !result.data.cache.requiresRefresh)
        // The replacement is the current table: it pages and admits input.
        page.agent = AgentModeRequest(kind: .describe, snapshotID: capture.snapshotID, rowOffset: 1)
        let next = try #require(await harness.controller.perform(page).agent)
        #expect(!next.didError && next.data.capture?.snapshotID == capture.snapshotID)
    }

    @Test("A batch stopped by a step that sent nothing returns the current screen, without resending input")
    func stoppedBatchReturnsCurrentScreen() async throws {
        let harness = try Harness()
        let (snapshot, ref) = try await harness.describe()
        var changed = harness.fixture.controls
        changed.append(.init(type: "Button", label: "Overlay", frame: .init(y: 300)))
        let changedRoots = try harness.fixture.roots(changed)
        harness.state.afterTap = {
            // Step one changes the layout; step two's owned read sees it before any input.
            harness.state.ownedRoots = changedRoots
            harness.state.describeRoots = changedRoots
            harness.state.afterTap = nil
        }
        let response = await harness.controller.performBatch(try harness.batch(snapshot: snapshot, refs: [ref, ref]))
        let result = try #require(response.agent)
        #expect(result.didError && result.error?.code == "batchLayoutChanged")
        let batch = try #require(result.data.batch)
        #expect(batch.completedSteps == 1 && batch.stoppedAt == 2)
        #expect(batch.steps.last?.receipt?.outcome == "failedBeforeInput" && batch.steps.last?.receipt?.enqueuedEventCount == 0)
        let capture = try #require(result.data.capture)
        #expect(capture.snapshotID != snapshot && capture.targets.contains { $0.contains("|tap|button|Overlay|") })
        #expect(result.data.cache.status == "refreshed" && !result.data.cache.requiresRefresh)
        // Two owned taps (one delivered, one refused) and one refresh read; nothing is tapped again.
        #expect(harness.state.ownedTaps == 2)
        #expect(harness.state.kinds == [.describe, .tap, .tap, .describe])
        // The new table admits the agent's next action.
        let next = try #require(capture.targets.first { $0.contains("|tap|button|Overlay|") })
        let tap = await harness.controller.perform(harness.tap(snapshot: capture.snapshotID,
            ref: String(next.prefix { $0 != "|" })))
        #expect(tap.agent?.error?.code != "snapshotMissing")
    }

    @Test("A failed replacement read discovers the panel once and repeats the failure when it is unchanged")
    func replacementFallbackSamePanel() async throws {
        let harness = try Harness()
        let (snapshot, ref) = try await harness.describe()
        harness.state.failNextDescribes = 1
        let response = await harness.controller.perform(harness.tap(snapshot: snapshot, ref: ref))
        let result = try #require(response.agent)
        #expect(!result.didError && result.data.action?.outcome == "enqueuedAndDrained")
        #expect(result.data.capture == nil)
        #expect(result.data.cache.status == "invalidated" && result.data.cache.reason == "postActionRefreshFailed")
        #expect(harness.state.kinds == [.describe, .tap, .describe])
        #expect(harness.state.discoveries == 2)
    }

    @Test("A failed replacement read follows a replaced active panel with one more read")
    func replacementFallbackNewPanel() async throws {
        let harness = try Harness()
        let (snapshot, ref) = try await harness.describe()
        let replacement = try Fixture.context(screen: 2, uuid: "6B1D1A1E-3F8C-4B6E-9C1E-2D5B8A7F0C11")
        harness.state.failNextDescribes = 1
        harness.state.activePanel = ActivePanelIdentity(displayID: 2, uniqueID: UUID(uuidString: replacement.screenUUID)!)
        harness.state.describeContext = replacement
        let response = await harness.controller.perform(harness.tap(snapshot: snapshot, ref: ref))
        let result = try #require(response.agent)
        #expect(!result.didError && result.data.cache.status == "refreshed")
        #expect(result.data.capture?.context.screenID == 2)
        #expect(harness.state.kinds == [.describe, .tap, .describe, .describe])
        #expect(harness.state.discoveries == 2)
    }

    /// A fake owner that answers descriptions from fixture trees and runs owned taps through
    /// the supplied admission, as the native operation does.
    @MainActor
    private final class Harness {
        final class State {
            var kinds: [SelectedAXRequest.Kind] = []
            var ownedTaps = 0
            var discoveries = 0
            var failNextDescribes = 0
            var ownedRoots: [FBSimulatorAXNode] = []
            var describeRoots: [FBSimulatorAXNode] = []
            var describeContext: SelectedHIDContext
            var activePanel: ActivePanelIdentity
            /// Runs after each owned tap that delivered input, to change the screen between steps.
            var afterTap: (() throws -> Void)?
            /// A native refusal before input that every owned tap returns, without a policy code.
            var tapFailure: SelectedAXFailure?
            /// A typed admission refusal before input that every owned tap returns.
            var tapPolicyFailure: AgentModeFailure?
            init(context: SelectedHIDContext) {
                describeContext = context
                activePanel = ActivePanelIdentity(displayID: context.screenID, uniqueID: UUID(uuidString: context.screenUUID)!)
            }
        }
        let fixture: Fixture
        let state: State
        let owner: SelectedHIDOwner
        let controller: AgentModeController

        init(controls: [Fixture.Node] = Fixture.defaultControls) throws {
            let fixture = try Fixture(controls: controls)
            self.fixture = fixture
            let state = State(context: fixture.context)
            state.ownedRoots = try fixture.roots(fixture.controls)
            state.describeRoots = state.ownedRoots
            self.state = state
            let acquisition = try JSONDecoder().decode(SelectedAXAcquisition.self, from: Data("""
            {"outcome":"ready","attempts":[{"index":1,"startUptime":0,"endUptime":1,"rootPID":1234,"outcome":"ready"}],"phases":[]}
            """.utf8))
            let dependencies = SelectedAXDependencies(execute: { request, _, broker, _, batchTap in
                guard let ax = request.ax else {
                    Issue.record("Only AX requests are expected")
                    return Self.failed(request, broker: broker, error: "unexpected", agent: nil)
                }
                state.kinds.append(ax.kind)
                switch ax.kind {
                case .describe:
                    #expect(batchTap == nil)
                    if state.failNextDescribes > 0 {
                        state.failNextDescribes -= 1
                        return Self.failed(request, broker: broker, error: "Context read failed", agent: nil)
                    }
                    var result = SelectedAXResult(kind: .describe, expectedPID: 1234)
                    result.acquisition = acquisition
                    result.roots = state.describeRoots
                    return SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: request.requestID,
                        brokerID: broker, outcome: "ready", token: nil, enqueuedEventCount: 0,
                        cleanup: "notNeeded", error: nil, context: state.describeContext, ax: result)
                case .tap:
                    state.ownedTaps += 1
                    if let failure = state.tapFailure {
                        return Self.failed(request, broker: broker, error: "covered", agent: nil, failure: failure)
                    }
                    if let policy = state.tapPolicyFailure {
                        return Self.failed(request, broker: broker, error: policy.message,
                            agent: AgentModeResult(error: policy,
                                cache: AgentModeCacheState(status: "invalidated", reason: policy.code, requiresRefresh: true),
                                context: fixture.context))
                    }
                    #expect(request.agentAdmission == nil)
                    do {
                        let supplied = try #require(batchTap)
                        let target = try #require(state.ownedRoots.first?.children.first)
                        _ = try supplied.validateOwnedSnapshot(roots: state.ownedRoots, nativeIdentityMetadata: nil,
                            context: fixture.context, pid: 1234, nativeTarget: target)
                        try state.afterTap?()
                        return SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: request.requestID,
                            brokerID: broker, outcome: "enqueuedAndDrained", token: nil, enqueuedEventCount: 2,
                            cleanup: "notNeeded", error: nil, context: fixture.context)
                    } catch {
                        let policy = error as? AgentModeFailure
                        return Self.failed(request, broker: broker, error: String(describing: error),
                            agent: policy.map { AgentModeResult(error: $0,
                                cache: AgentModeCacheState(status: "invalidated", reason: $0.code, requiresRefresh: true),
                                context: fixture.context) })
                    }
                default:
                    Issue.record("Unexpected AX kind \(ax.kind)")
                    return Self.failed(request, broker: broker, error: "unexpected", agent: nil)
                }
            }, persist: { _, _, _ in Issue.record("No quarantine expected") }, now: { 0 })
            owner = SelectedHIDOwner(simulatorUDID: UUID().uuidString, logger: AxeLogger(), dependencies: dependencies)
            controller = AgentModeController(simulatorUDID: UUID().uuidString, logger: AxeLogger(), owner: owner,
                discoverDisplay: { _ in
                    state.discoveries += 1
                    return state.activePanel
                })
        }

        func describe() async throws -> (UUID, String) {
            var request = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
                screenID: nil, screenUUID: nil, operation: .complete, token: nil, primitives: [])
            request.agent = AgentModeRequest(kind: .describe)
            let response = await controller.perform(request)
            let capture = try #require(response.agent?.data.capture)
            let row = try #require(capture.targets.first { $0.contains("|tap|button|5|") })
            return (capture.snapshotID, String(row.prefix { $0 != "|" }))
        }

        func batch(snapshot: UUID, refs: [String]) throws -> SelectedHIDRequest {
            var request = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
                screenID: nil, screenUUID: nil, operation: .complete, token: nil, primitives: [])
            let steps = refs.map { #"{"action":"tap","ref":"\#($0)"}"# }.joined(separator: ",")
            request.agentBatch = try JSONDecoder().decode(AgentBatchRequest.self, from: Data(
                #"{"snapshotID":"\#(snapshot.uuidString)","steps":[\#(steps)]}"#.utf8))
            return request
        }

        func read(snapshot: UUID, ref: String) -> SelectedHIDRequest {
            var request = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
                screenID: nil, screenUUID: nil, operation: .complete, token: nil, primitives: [])
            request.agent = AgentModeRequest(kind: .read, snapshotID: snapshot, readReference: ref,
                textQuery: AgentModeTextQuery(field: .label, offset: 0, limit: 64))
            return request
        }

        func tap(label: String) -> SelectedHIDRequest {
            var request = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
                screenID: nil, screenUUID: nil, operation: .complete, token: nil, primitives: [])
            request.agent = AgentModeRequest(kind: .tap, selectorKind: .label, selectorValue: label)
            return request
        }

        func tap(snapshot: UUID, ref: String) -> SelectedHIDRequest {
            var request = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
                screenID: nil, screenUUID: nil, operation: .complete, token: nil, primitives: [])
            request.agent = AgentModeRequest(kind: .tap, snapshotID: snapshot, ref: ref)
            return request
        }

        private static func failed(_ request: SelectedHIDRequest, broker: UUID, error: String,
                                   agent: AgentModeResult?, failure: SelectedAXFailure = .setupFailed) -> SelectedHIDResponse {
            var ax = request.ax.map { SelectedAXResult(kind: $0.kind, expectedPID: $0.expectedPID) }
            ax?.failure = failure
            var response = SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: request.requestID,
                brokerID: broker, outcome: "failedBeforeInput", token: nil, enqueuedEventCount: 0,
                cleanup: "notNeeded", error: error, context: nil, ax: ax)
            response.agent = agent
            return response
        }
    }

    private struct Fixture {
        let context: SelectedHIDContext
        let snapshot: AgentModeSnapshot
        static let defaultControls = [Node(type: "Button", label: "5"),
            Node(type: "StaticText", label: "0", frame: .init(x: 200)),
            Node(type: "Switch", label: "Animations", value: "1", frame: .init(y: 100))]
        let controls: [Node]

        init(controls: [Node] = Self.defaultControls) throws {
            let context = try Self.context()
            self.context = context
            self.controls = controls
            snapshot = try AgentModeSnapshot(roots: Self.roots(controls), context: context)
        }

        func admission(ref: String) throws -> AgentReferenceTapAdmission {
            try AgentReferenceTapAdmission(published: snapshot, context: context, pid: 1234,
                mode: AgentModeRequest(kind: .tap, snapshotID: UUID(), ref: ref))
        }

        func roots(_ controls: [Node], appPID: Int32 = 1234) throws -> [FBSimulatorAXNode] {
            try Self.roots(controls, appPID: appPID)
        }

        static func roots(_ controls: [Node], appPID: Int32 = 1234) throws -> [FBSimulatorAXNode] {
            let root = Node(type: "Application", label: "Example",
                frame: .init(width: 390, height: 844), children: controls, pid: appPID)
            return try JSONDecoder().decode([FBSimulatorAXNode].self, from: JSONEncoder().encode([root]))
        }

        static func context(boot: String = "boot", screen: Int = 1, rotation: Int = 0,
                            uuid: String = "DF1FB281-4CCC-4A62-88D3-635D18FAD832",
                            pose: String = "open") throws -> SelectedHIDContext {
            try JSONDecoder().decode(SelectedHIDContext.self, from: Data("""
            {"bootIdentity":"\(boot)","screenID":\(screen),"screenUUID":"\(uuid)",
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
            var nativeIdentity: FBSimulatorAXNativeIdentity? = nil
            var identifier: String? = nil
            var role: String? = nil
            var focused: Bool? = nil
            private enum CodingKeys: String, CodingKey {
                case type, label = "AXLabel", value = "AXValue", frame, children, pid, enabled, hidden, nativeIdentity,
                     identifier = "AXUniqueId", role, focused
            }
        }
    }
}
