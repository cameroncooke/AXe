import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Initial physical Button execution binding")
struct AgentPhysicalButtonBindingTests {
    @Test("Unique label and native ID references keep semantic meaning but gain fresh execution authority")
    func uniqueButtonsUseFreshNativeExecution() throws {
        for id in [String?.none, .some("save")] {
            let fixture = try Fixture([node(id: id, label: "Action", key: 101)])
            let original = try fixture.snapshot.target(ref: "e2")
            #expect(original.nativeIdentity == nil)
            let execution = try fixture.bind(original)
            #expect(execution.nativeIdentity?.objectID == 101)
            #expect(try fixture.snapshot.target(ref: "e2") == original)
        }
    }

    @Test("Repeated labels retain the already captured object authority")
    func repeatedLabelsKeepTheirExistingBinding() throws {
        let fixture = try Fixture([node(label: "Repeated", key: 101),
            node(label: "Repeated", key: 102, frame: frame(x: 180))])
        let original = try fixture.snapshot.target(ref: "e2")
        #expect(original.nativeIdentity?.objectID == 101)
        #expect(try fixture.bind(original) == original)
    }

    @Test("A semantic reference can resolve a replacement object before one new execution is bound")
    func stableSemanticReferenceDoesNotBecomeAnInstanceReference() throws {
        let before = try Fixture([node(id: "save", label: "Action", key: 101)])
        let after = try Fixture([node(id: "save", label: "Action", key: 102)])
        let original = try before.snapshot.target(ref: "e2")
        #expect(before.snapshot.protectedTargetsMatch(after.snapshot))
        let execution = try after.bind(original)
        #expect(execution.nativeIdentity?.objectID == 102)
        #expect(try after.snapshot.target(ref: "e2") == original)
    }

    @Test("Absent or globally incomplete native evidence preserves the existing semantic route")
    func missingNativeEvidenceIsNotAnErrorDrivenFallback() throws {
        for fixture in [try Fixture([node(id: "save", label: "Action", key: nil)]),
                        try Fixture([node(id: "save", label: "Action", key: 101)], complete: false)] {
            let original = try fixture.snapshot.target(ref: "e2")
            #expect(try fixture.bind(original) == original)
            #expect(original.semanticID == "save")
        }
    }

    @Test("Present duplicate and wrong-owner keys stop binding before any input")
    func presentInvalidAuthorityCannotSilentlyUseSemantics() throws {
        let duplicate = try Fixture([node(id: "save", label: "Action", key: 101),
            node(id: "other", label: "Other", key: 101, frame: frame(x: 180))])
        #expect(throws: (any Error).self) { _ = try duplicate.bind(duplicate.snapshot.target(ref: "e2")) }
        let foreign = try Fixture([node(id: "save", label: "Action", key: 101, keyPID: 9000)])
        #expect(throws: (any Error).self) { _ = try foreign.bind(foreign.snapshot.target(ref: "e2")) }
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(FBSimulatorAXNode.self, from: Data(#"{"nativeIdentity":{"pid":1234,"objectID":"0"}}"#.utf8))
        }
    }

    @Test("An opaque reference cannot acquire a replacement object's authority")
    func capturedOpaqueIdentityStillRefusesReplacement() throws {
        let before = try Fixture([node(key: 101)]), after = try Fixture([node(key: 102)])
        let original = try before.snapshot.target(ref: "e2")
        #expect(original.nativeIdentity?.objectID == 101)
        #expect(throws: (any Error).self) { _ = try after.bind(original) }
    }

    @Test("Qualified nested permission Buttons retain their existing chain route")
    func nestedButtonChainStaysSemantic() throws {
        let leaf = node(id: "permission.save", label: "Save", key: 102)
        let fixture = try Fixture([node(id: "permission.save", label: "Save", key: 101, children: [leaf])])
        let original = try fixture.snapshot.target(ref: "e3")
        #expect(original.semanticID == "permission.save")
        #expect(try fixture.bind(original, index: 2) == original)
    }

    @Test("New execution authority still uses the existing covered-control refusal")
    func coveredNamedButtonDoesNotGainAnOverlayBypass() throws {
        let fixture = try Fixture([node(id: "save", label: "Action", key: 101),
            node(id: "cover", label: "Cover", key: 102)])
        let execution = try fixture.bind(fixture.snapshot.target(ref: "e2"))
        let request = SelectedAXRequest(kind: .tap, expectedPID: 1234, endpoint: nil,
            selectorKind: nil, selectorValue: nil, preDelay: 0, postDelay: 0,
            tapStyle: .physical, nativeTarget: execution)
        let guardOwner = try #require(try SelectedOpaqueFrameTapAdmission.make(for: request))
        #expect(throws: (any Error).self) {
            try guardOwner.validate(roots: fixture.roots, nativeIdentityMetadata: .init(complete: true),
                target: fixture.snapshot.nodes[1], point: CGPoint(x: 70, y: 122), observation: fixture.observation)
        }
    }

    @Test("The bound target keeps exact frame, owner and pose checks")
    func boundExecutionRejectsLaterChanges() throws {
        let fixture = try Fixture([node(id: "save", label: "Action", key: 101)])
        let execution = try fixture.bind(fixture.snapshot.target(ref: "e2"))
        let target = try AgentModeTarget(fixture.snapshot.nodes[1], nativeTarget: execution)
        let moved = try Fixture([node(id: "save", label: "Action", key: 101, frame: frame(x: 21))])
        #expect(throws: (any Error).self) { try target.validate(moved.snapshot.nodes[1]) }
        let replacement = try Fixture([node(id: "save", label: "Action", key: 102)])
        #expect(throws: (any Error).self) { try target.validate(replacement.snapshot.nodes[1]) }
        let admission = AgentModeAdmission(context: fixture.context, expectedPID: 1234,
            visibleFingerprint: fixture.snapshot.visibleFingerprint,
            target: target, nativeTarget: execution)
        let changed = try FBSimulatorHIDSessionObservation(simulatorUDID: fixture.observation.simulatorUDID,
            bootIdentity: "other-boot", screenID: 1, screenUniqueID: fixture.context.screenUUID, axDisplayID: 1,
            displayContext: fixture.observation.displayContext, poseRevision: "closed")
        #expect(throws: (any Error).self) { try admission.validateContext(changed) }
    }

    private struct Fixture {
        let roots: [FBSimulatorAXNode]
        let snapshot: AgentModeSnapshot
        let observation: FBSimulatorHIDSessionObservation
        var context: SelectedHIDContext { SelectedHIDContext(observation) }
        init(_ children: [AXNodeFixture], complete: Bool = true) throws {
            observation = try FBSimulatorHIDSessionObservation(simulatorUDID: "00000000-0000-0000-0000-000000000001",
                bootIdentity: "boot", screenID: 1, screenUniqueID: "DFEBAD86-C7D4-45CA-BB20-2F2D73B355B0", axDisplayID: 1,
                displayContext: FBSimulatorHIDDisplayContext(hidTarget: 1,
                    nativePixelSize: CGSize(width: 1170, height: 2400), scale: 3, rotation: .rot0), poseRevision: "rigid")
            let root = node(type: "Application", label: "Example", key: 1,
                frame: frame(x: 0, y: 0, width: 390, height: 800), children: children)
            roots = try AXNodeFixture.decode([root])
            snapshot = try AgentModeSnapshot(roots: roots, nativeIdentityMetadata: .init(complete: complete),
                context: SelectedHIDContext(observation))
        }
        func bind(_ reference: SelectedNativeTarget, index: Int = 1) throws -> SelectedNativeTarget {
            try snapshot.physicalButtonExecutionTarget(reference: reference, node: snapshot.nodes[index], context: context)
        }
    }
}

private func frame(x: Double = 20, y: Double = 100, width: Double = 100, height: Double = 44) -> AXNodeFixture.Frame {
    .init(x: x, y: y, width: width, height: height)
}

private func node(type: String = "Button", id: String? = nil, label: String? = nil, key: UInt64? = nil,
                  keyPID: Int32 = 1234, frame: AXNodeFixture.Frame = frame(),
                  children: [AXNodeFixture] = []) -> AXNodeFixture {
    AXNodeFixture(type: type, identifier: id, label: label, role: "AX" + type, frame: frame, pid: 1234,
        focused: false, enabled: true, hidden: false,
        nativeIdentity: key.map { FBSimulatorAXNativeIdentity(pid: keyPID, objectID: $0) }, children: children)
}
