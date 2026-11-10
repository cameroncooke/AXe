import Foundation
import Testing
import FBSimulatorControl
@testable import AXe

@Suite("Opaque physical frame tap admission")
struct SelectedOpaqueFrameTapAdmissionTests {
    private let identity = FBSimulatorAXNativeIdentity(pid: 1234, objectID: 101)
    private let point = CGPoint(x: 70, y: 122)

    @Test("Only one explicit physical native-object tap can install the hook")
    func gateExcludesOtherDeliveries() throws {
        for style in [SelectedTapStyle?.none, .some(.physical)] {
            var request = tap(); request.tapStyle = style
            #expect(try SelectedOpaqueFrameTapAdmission.make(for: request) != nil)
        }
        for style in [SelectedTapStyle.automatic, .simulator] {
            var request = tap(); request.tapStyle = style
            #expect(try SelectedOpaqueFrameTapAdmission.make(for: request) == nil)
        }
        for kind in [SelectedAXRequest.Kind.describe, .describePoint, .hold, .doubleTap,
                     .semanticPress, .sliderEndpoint, .sliderPercentage] {
            #expect(try SelectedOpaqueFrameTapAdmission.make(for: tap(kind: kind)) == nil)
        }
        for kind in [SelectedAXRequest.SelectorKind.id, .label, .value] {
            var semantic = tap()
            semantic.nativeTarget = .semantic(kind: kind, value: "control", elementType: "Button")
            #expect(try SelectedOpaqueFrameTapAdmission.make(for: semantic) == nil)
        }
        var invalid = tap(); invalid.holdDuration = 1
        #expect(throws: (any Error).self) { _ = try SelectedOpaqueFrameTapAdmission.make(for: invalid) }
        invalid = tap(); invalid.doubleTapTiming = .init(hold: 0.1, interval: 0.1)
        #expect(throws: (any Error).self) { _ = try SelectedOpaqueFrameTapAdmission.make(for: invalid) }
        let target = try nodes([node(key: 101)])[0].children[0]
        guard case let .composite(events) = try tap().tapEvent(at: point, target: target) else {
            Issue.record("The physical tap factory did not return its owned touch pair."); return
        }
        var downs = 0, ups = 0
        for event in events {
            switch event {
            case .touch(.down, _, _): downs += 1
            case .touch(.up, _, _): ups += 1
            case .delay: break
            default: Issue.record("The physical single tap contained another input primitive.")
            }
        }
        #expect(downs == 1 && ups == 1)
    }

    @Test("Command adapters keep touch holds, double taps and pinches out of ordinary taps")
    func commandKindsStaySeparate() throws {
        let args = ["--agent", "--udid", "00000000-0000-0000-0000-000000000001",
                    "--snapshot-id", "00000000-0000-0000-0000-000000000002", "--ref", "e2"]
        #expect(try Tap.parse(args + ["--tap-style", "physical"]).agentRequest().agent?.kind == .tap)
        #expect(try Touch.parse(args + ["--down", "--up", "--delay", "0.1"]).agentRequest().agent?.kind == .hold)
        #expect(try Gesture.parse(["double-tap"] + args).agentRequest().agent?.kind == .doubleTap)
        #expect(try Gesture.parse(["pinch"] + args + ["--radius", "15", "--scale", "2"]).agentRequest().agent?.kind == .pinch)
    }

    @Test("A complete fresh tree with one actionable control passes the shared host policy")
    func oneControlPasses() throws {
        let selected = node(key: 101)
        try validate([selected, node(type: "StaticText", label: "Description", key: 102)])
    }

    @Test("Other actionable controls block the point regardless of semantic ID availability")
    func contendersAreNotFilteredByIDs() throws {
        for id in [String?.none, .some("save"), .some("duplicate")] {
            let selected = node(id: id, key: 101)
            let competitor = node(id: id, key: 102)
            #expect(throws: (any Error).self) { try validate([selected, competitor]) }
        }
        #expect(throws: (any Error).self) {
            try validate([node(key: 101), node(type: "TextField", focused: true, key: 102)])
        }
        // IDs are not used to deduplicate or identify the competing native occurrence.
        #expect(throws: (any Error).self) {
            try validate([node(id: "same", key: 101), node(id: "same", key: 102), node(id: "same", key: 103)])
        }
    }

    @Test("Selected-key duplicates count before availability, type, owner and viewport filters",
          arguments: ["hidden", "disabled", "foreign-owner", "other-type", "outside"])
    func allSelectedOccurrencesRemainAmbiguous(_ variant: String) throws {
        var duplicate = node(key: 101)
        switch variant {
        case "hidden": duplicate.hidden = true
        case "disabled": duplicate.enabled = false
        case "foreign-owner": duplicate.pid = 9000
        case "other-type": duplicate.type = "StaticText"
        default: duplicate.frame?.y = 1000
        }
        #expect(throws: (any Error).self) { try validate([node(key: 101), duplicate]) }
    }

    @Test("Hidden, disabled and foreign competing controls still refuse unmapped frame input")
    func unavailableContendersRemainConservative() throws {
        var hidden = node(key: 102); hidden.hidden = true
        var disabled = node(key: 103); disabled.enabled = false
        var foreign = node(key: 104); foreign.pid = 9000
        let parent = node(type: "Group", hidden: true, key: 105, children: [node(key: 106)])
        let normal = try AgentModeSnapshot(roots: nodes([node(key: 101), hidden, disabled, parent]),
            nativeIdentityMetadata: .init(complete: true), context: SelectedHIDContext(observation()))
        // The conservative query does not change normal visibility, state or actions.
        #expect(normal.elements[2].actions.isEmpty && !normal.elements[2].state.visible)
        #expect(normal.elements[3].actions.isEmpty && !normal.elements[3].state.enabled)
        #expect(normal.elements[5].actions.isEmpty && !normal.elements[5].state.visible)
        #expect(AgentModeSnapshot.hasPotentialTapAction(normal.nodes[2]))
        #expect(AgentModeSnapshot.hasPotentialTapAction(normal.nodes[3]))
        #expect(AgentModeSnapshot.hasPotentialTapAction(normal.nodes[5]))
        for contender in [hidden, disabled, foreign, parent] {
            #expect(throws: (any Error).self) { try validate([node(key: 101), contender]) }
        }
        hidden.frame?.y = 200
        disabled.frame?.y = 300
        try validate([node(key: 101), hidden, disabled])
    }

    @Test("Incomplete capture metadata never authorizes the host frame path")
    func incompleteEvidenceRefuses() throws {
        let roots = try nodes([node(key: 101)])
        let hook = try #require(try SelectedOpaqueFrameTapAdmission.make(for: tap()))
        for metadata in [FBSimulatorAXNativeIdentityMetadata?.none, .some(.init(complete: false))] {
            #expect(throws: (any Error).self) {
                try hook.validate(roots: roots, nativeIdentityMetadata: metadata, target: roots[0].children[0],
                    point: point, observation: observation())
            }
        }
        #expect(throws: (any Error).self) { try validate([node(key: 101), node(key: nil)]) }
    }

    @Test("The hook keeps the chosen native key and exact selected signature")
    func changedTargetRefuses() throws {
        let roots = try nodes([node(key: 101)])
        let hook = try #require(try SelectedOpaqueFrameTapAdmission.make(for: tap()))
        let replacement = try nodes([node(key: 102)])[0].children[0]
        #expect(throws: (any Error).self) {
            try hook.validate(roots: roots, nativeIdentityMetadata: .init(complete: true),
                target: replacement, point: point, observation: observation())
        }
        #expect(throws: (any Error).self) { try validate([node(key: 101)], at: CGPoint(x: 1, y: 1)) }
    }

    @Test("Existing semantic nested Button taps retain the strict native path")
    func semanticChainsDoNotInstallTheHook() throws {
        var request = tap()
        request.nativeTarget = .semantic(kind: .id, value: "permission.save", elementType: "Button")
        #expect(try SelectedOpaqueFrameTapAdmission.make(for: request) == nil)
        request.nativeTarget = nil
        #expect(try SelectedOpaqueFrameTapAdmission.make(for: request) == nil)
    }

    private func validate(_ children: [AXNodeFixture], at point: CGPoint? = nil) throws {
        let roots = try nodes(children)
        let hook = try #require(try SelectedOpaqueFrameTapAdmission.make(for: tap()))
        try hook.validate(roots: roots, nativeIdentityMetadata: .init(complete: true),
            target: roots[0].children[0], point: point ?? self.point, observation: observation())
    }

    private func tap(kind: SelectedAXRequest.Kind = .tap) -> SelectedAXRequest {
        SelectedAXRequest(kind: kind, expectedPID: 1234, endpoint: nil,
            selectorKind: nil, selectorValue: nil, preDelay: 0, postDelay: 0,
            nativeTarget: .nativeObject(identity: identity, elementType: "Button"))
    }

    private func nodes(_ children: [AXNodeFixture]) throws -> [FBSimulatorAXNode] {
        let root = node(type: "Application", key: 1, children: children,
            frame: frame(x: 0, y: 0, width: 390, height: 800))
        return try AXNodeFixture.decode([root])
    }

    private func observation() throws -> FBSimulatorHIDSessionObservation {
        try FBSimulatorHIDSessionObservation(simulatorUDID: "00000000-0000-0000-0000-000000000001",
            bootIdentity: "fixture-boot", screenID: 1, screenUniqueID: "DFEBAD86-C7D4-45CA-BB20-2F2D73B355B0", axDisplayID: 1,
            displayContext: FBSimulatorHIDDisplayContext(hidTarget: 1,
                nativePixelSize: CGSize(width: 1170, height: 2400), scale: 3, rotation: .rot0), poseRevision: "rigid")
    }

}

private func frame(x: Double = 20, y: Double = 100, width: Double = 100, height: Double = 44) -> AXNodeFixture.Frame {
    .init(x: x, y: y, width: width, height: height)
}

/// The native identity keeps owner 1234 even when a test later changes the node's `pid`.
private func node(type: String = "Button", id: String? = nil, label: String? = nil, focused: Bool = false,
                  hidden: Bool = false, key: UInt64? = nil, children: [AXNodeFixture] = [],
                  frame: AXNodeFixture.Frame = frame()) -> AXNodeFixture {
    AXNodeFixture(type: type, identifier: id, label: label, frame: frame, pid: 1234, focused: focused,
        enabled: true, hidden: hidden, nativeIdentity: key.map { FBSimulatorAXNativeIdentity(pid: 1234, objectID: $0) },
        children: children)
}
