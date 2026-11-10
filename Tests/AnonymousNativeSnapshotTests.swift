import AXeCore
import Foundation
import Testing
import FBSimulatorControl
@testable import AXe

@Suite("Anonymous native snapshot authority")
struct AnonymousNativeSnapshotTests {
    @Test("An anonymous focused field uses one object mode even with a unique label")
    func focusedFieldChoosesOneMode() throws {
        let snapshot = try make([fixture(type: "TextField", label: "Title", focused: true, key: 101)])
        let chosen = try snapshot.target(ref: "e2")
        #expect(chosen.nativeIdentity?.objectID == 101)
        #expect(chosen.semanticID == nil)
        _ = try snapshot.node(ref: "e2", requiredAction: .tap)
        _ = try snapshot.node(ref: "e2", requiredAction: .typeText)
        #expect(try snapshot.match(target: chosen).nativeIdentity == chosen.nativeIdentity)
    }

    @Test("Fresh native resolution recovers the current ordinal after sibling reorder")
    func currentOrdinalComesFromTheFreshTree() throws {
        let a = fixture(key: 101), b = fixture(key: 102)
        let before = try make([a, b]), after = try make([b, a])
        let chosen = try before.target(ref: "e2")
        #expect(before.nativeFingerprint == after.nativeFingerprint)
        #expect(before.hash == after.hash)
        #expect(try after.reference(target: chosen) == "e3")
        #expect(try after.match(target: chosen).nativeIdentity?.objectID == 101)
        #expect(before.protectedTargetsMatch(after))
    }

    @Test("Duplicates count before type, focus, PID, visibility or viewport filtering",
          arguments: ["hidden", "unfocused", "foreign-process", "different-type", "outside"])
    func allOccurrencesCount(variant: String) throws {
        let field = fixture(type: "TextField", focused: true, key: 101)
        var duplicate = field
        switch variant {
        case "hidden": duplicate.hidden = true
        case "unfocused": duplicate.focused = false
        case "foreign-process": duplicate.pid = 9000
        case "different-type": duplicate.type = "StaticText"
        default: duplicate.frame?.y = 900
        }
        let snapshot = try make([field, duplicate])
        #expect(throws: AgentModeFailure.self) { _ = try snapshot.target(ref: "e2") }
        #expect(throws: AgentModeFailure.self) {
            _ = try snapshot.match(target: .nativeObject(identity: .init(pid: 1234, objectID: 101), elementType: "TextField"))
        }
        #expect(snapshot.nodes.count == 3)
    }

    @Test("Optional metadata cannot alter shared semantic hashes or existing ID capabilities")
    func incompleteMetadataKeepsSemanticAuthority() throws {
        let nodes = [fixture(id: "save", key: 101), fixture(type: "TextField", focused: true, key: 102)]
        let complete = try make(nodes), incomplete = try make(nodes, complete: false)
        #expect(complete.hash == incomplete.hash)
        #expect(complete.nativeFingerprint == incomplete.nativeFingerprint)
        #expect(try incomplete.target(ref: "e2").semanticID == "save")
        _ = try incomplete.node(ref: "e2", requiredAction: .tap)
        try complete.validateProtectedReference("e2", in: incomplete)
        #expect(throws: AgentModeFailure.self) { try complete.validateProtectedReference("e3", in: incomplete) }
        #expect(!complete.protectedTargetsMatch(incomplete))
    }

    @Test("A claimed complete sidecar cannot hide a node with missing identity")
    func missingTupleMakesOpaqueEvidenceIncomplete() throws {
        let snapshot = try make([fixture(key: 101), fixture(id: "save", key: nil)])
        #expect(snapshot.nativeIdentityMetadata?.complete == false)
        #expect(try snapshot.target(ref: "e3").semanticID == "save")
        #expect(throws: AgentModeFailure.self) { _ = try snapshot.target(ref: "e2") }
    }

    @Test("A present duplicated native ID does not gain typing through an object key")
    func duplicatedFieldIDsKeepTheirRefusal() throws {
        let snapshot = try make([
            fixture(type: "TextField", id: "duplicate", label: "First", focused: true, key: 101),
            fixture(type: "TextField", id: "duplicate", label: "Second", focused: true, key: 102)])
        #expect(snapshot.elements.allSatisfy { !$0.actions.contains(.typeText) })
        #expect(try snapshot.target(ref: "e2").nativeIdentity == nil)
        #expect(throws: AgentModeFailure.self) { _ = try snapshot.node(ref: "e2", requiredAction: .typeText) }
    }

    @Test("Equal public fields cannot transfer an opaque reference to a replacement object")
    func replacementObjectDoesNotAlias() throws {
        let before = try make([fixture(key: 101)]), after = try make([fixture(key: 102)])
        #expect(before.hash == after.hash)
        #expect(before.nativeFingerprint == after.nativeFingerprint)
        #expect(!before.protectedTargetsMatch(after))
        let chosen = try before.target(ref: "e2")
        #expect(throws: AgentModeFailure.self) { _ = try after.match(target: chosen) }
    }

    @Test("Incidental native metadata does not change an existing semantic reference")
    func semanticReferenceDoesNotBindIncidentalKeys() throws {
        let before = try make([fixture(id: "save", key: 101)])
        let after = try make([fixture(id: "save", key: 102)])
        let chosen = try before.target(ref: "e2")
        #expect(chosen.nativeIdentity == nil)
        #expect(before.protectedTargetsMatch(after))
        #expect(try after.match(target: chosen).identifier == "save")
    }

    @Test("Private wire preserves UInt64 strings while public rows and ID readback omit them")
    func privateIdentityNeverBecomesPublicID() throws {
        let key: UInt64 = 9_007_199_254_740_993
        let snapshot = try make([fixture(key: key)])
        let chosen = try snapshot.target(ref: "e2")
        let privateText = String(decoding: try JSONEncoder().encode(chosen), as: UTF8.self)
        #expect(privateText.contains("\"objectID\":\"9007199254740993\""))
        #expect(try JSONDecoder().decode(SelectedNativeTarget.self, from: Data(privateText.utf8)) == chosen)
        let context = try context()
        let capture = snapshot.capture(id: UUID(), sequence: 1, udid: "fixture", request: .init(kind: .describe),
            applicationPID: 1234, context: context, unchanged: false, expiresIn: 60)
        let publicText = String(decoding: try JSONEncoder().encode(capture), as: UTF8.self)
        #expect(!publicText.contains("nativeIdentity") && !publicText.contains("9007199254740993"))
        let detail = try snapshot.detail(ref: "e2", query: .init(field: .id, offset: 0, limit: 1024))
        #expect(detail.text.isEmpty)
    }

    @Test("Private native target cannot mix selectors, wrong owner or read flags")
    func selectedWireHasOneAuthority() throws {
        let target = SelectedNativeTarget.nativeObject(identity: .init(pid: 1234, objectID: 101), elementType: "Button")
        var request = SelectedAXRequest(kind: .tap, expectedPID: 1234, endpoint: nil,
            selectorKind: nil, selectorValue: nil, preDelay: 0, postDelay: 0, nativeTarget: target)
        try request.validate()
        let mixed = SelectedAXRequest(kind: .tap, expectedPID: 1234, endpoint: nil,
            selectorKind: .id, selectorValue: "save", preDelay: 0, postDelay: 0, nativeTarget: target)
        #expect(throws: (any Error).self) { try mixed.validate() }
        let foreign = SelectedAXRequest(kind: .tap, expectedPID: 9000, endpoint: nil,
            selectorKind: nil, selectorValue: nil, preDelay: 0, postDelay: 0, nativeTarget: target)
        #expect(throws: (any Error).self) { try foreign.validate() }
        request.includeNativeIdentity = true
        #expect(throws: (any Error).self) { try request.validate() }
    }

    @Test("Legacy semantic field details remain readable without input authority")
    func readbackDoesNotRequireASelector() throws {
        let snapshot = try make([fixture(type: "StaticText", label: "Same", key: 101),
                                 fixture(type: "StaticText", label: "Same", key: 102)], complete: false)
        try snapshot.validateProtectedReference("e2", in: snapshot)
        #expect(try snapshot.detail(ref: "e2", query: .init(field: .label, offset: 0, limit: 1024)).text == "Same")
    }

    @Test("Private result sidecar and selected target survive JSON without inferring old-record authority")
    func privateWireRoundTripKeepsExplicitCompleteness() throws {
        let original = try make([fixture(key: 101), fixture(id: "save", key: 102)])
        let chosen = try original.target(ref: "e2")
        var result = SelectedAXResult(kind: .describe)
        result.expectedPID = 1234
        result.roots = [try #require(original.nodes.first)]
        result.nativeIdentityMetadata = original.nativeIdentityMetadata
        let bytes = try JSONEncoder().encode(result)
        let recovered = try JSONDecoder().decode(SelectedAXResult.self, from: bytes)
        let fresh = try AgentModeSnapshot(roots: #require(recovered.roots),
            nativeIdentityMetadata: recovered.nativeIdentityMetadata, context: context())
        let recoveredTarget = try JSONDecoder().decode(SelectedNativeTarget.self,
            from: JSONEncoder().encode(chosen))
        #expect(recovered.nativeIdentityMetadata?.complete == true)
        #expect(try fresh.target(ref: "e2") == recoveredTarget)
        let node = try original.match(target: chosen)
        let signature = try AgentModeTarget(node, nativeTarget: chosen)
        let recoveredSignature = try JSONDecoder().decode(AgentModeTarget.self,
            from: JSONEncoder().encode(signature))
        try recoveredSignature.validate(fresh.match(target: recoveredTarget))
        result.nativeIdentityMetadata = nil
        let legacy = try JSONDecoder().decode(SelectedAXResult.self, from: JSONEncoder().encode(result))
        let withoutSidecar = try AgentModeSnapshot(roots: #require(legacy.roots), context: context())
        #expect(throws: AgentModeFailure.self) { _ = try withoutSidecar.match(target: recoveredTarget) }
        #expect(try withoutSidecar.target(ref: "e3").semanticID == "save")
    }

    @Test("Canonical unavailable reasons contain only eligible references on the current page")
    func canonicalReasonsArePagedAndOmittedWhenEmpty() throws {
        let snapshot = try make([fixture(key: 101), fixture(id: "save", key: 102)], complete: false)
        let first = snapshot.capture(id: UUID(), sequence: 1, udid: "fixture",
            request: .init(kind: .describe, rowOffset: 0, rowLimit: 1),
            applicationPID: 1234, context: try context(), unchanged: false, expiresIn: 60)
        #expect(first.unavailableReferences == ["e2": "nativeIdentityIncomplete"])
        let second = snapshot.capture(id: UUID(), sequence: 1, udid: "fixture",
            request: .init(kind: .describe, rowOffset: 1, rowLimit: 1),
            applicationPID: 1234, context: try context(), unchanged: false, expiresIn: 60)
        #expect(second.unavailableReferences == nil)
        #expect(!String(decoding: try JSONEncoder().encode(second), as: UTF8.self).contains("unavailableReferences"))
    }

    @Test("Compact JSON and text keep only current input-ref reason codes without native identities")
    func adaptiveReasonsStayBoundedAndReadable() throws {
        let source = output(targets: ["e2|unavailable|button|||", "e4|tap|button|Save||save"],
            text: ["e3|text|text|Ready||"], reasons: ["e2": "nativeIdentityIncomplete",
                "e3": "nativeIdentityIncomplete", "e4": "nativeObject:9007199254740993", "e99": "nativeIdentityIncomplete"])
        for view in [AgentOutputView.reading, .navigation] {
            let projected = try AgentOutputProjection.project(source, view: view)
            let reasons = try #require(projected["data"]?["capture"]?["unavailableReferences"])
            #expect(reasons["e2"]?.stringValue == "nativeIdentityIncomplete")
            #expect(reasons["e3"] == nil && reasons["e4"] == nil && reasons["e99"] == nil)
            let text = CLIOutputText.render(projected)
            #expect(text.contains("unavailableReferences:") && text.contains("e2: nativeIdentityIncomplete"))
            #expect(!text.contains("9007199254740993") && !text.contains("nativeObject"))
        }
        let noReason = try AgentOutputProjection.project(output(targets: ["e4|tap|button|Save||save"],
            reasons: ["e99": "nativeIdentityIncomplete"]), view: .reading)
        #expect(noReason["data"]?["capture"]?["unavailableReferences"] == nil)
    }

    @Test("The output byte budget also bounds reason metadata to rows actually emitted")
    func adaptiveBudgetFiltersReasonMap() throws {
        let labels = String(repeating: "界", count: 200)
        let targets = (2...65).map { "e\($0)|unavailable|button|\(labels)||" }
        let reasons = Dictionary(uniqueKeysWithValues: (2...65).map { ("e\($0)", "nativeIdentityIncomplete") })
        let projected = try AgentOutputProjection.project(output(targets: targets, reasons: reasons), view: .reading)
        let capture = try #require(projected["data"]?["capture"])
        let rows = try #require(capture["rows"]?.arrayValue).compactMap(\.stringValue)
        #expect(rows.count < targets.count)
        let shown = Set(rows.map { String($0.prefix { $0 != "|" }) })
        guard case let .object(map)? = capture["unavailableReferences"] else {
            Issue.record("Expected reasons for emitted unavailable rows.")
            return
        }
        #expect(Set(map.keys) == shown)
        #expect(map.values.allSatisfy { $0.stringValue == "nativeIdentityIncomplete" })
    }

    @Test("Legacy read requests omit new optional private keys and decode without them")
    func legacyPrivateReadShapeStaysCompatible() throws {
        let request = SelectedAXRequest(kind: .describe, expectedPID: nil, endpoint: nil,
            selectorKind: nil, selectorValue: nil, preDelay: 0, postDelay: 0)
        let text = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        #expect(!text.contains("includeNativeIdentity") && !text.contains("nativeTarget"))
        let old = try JSONDecoder().decode(SelectedAXRequest.self,
            from: Data(#"{"kind":"describe","preDelay":0,"postDelay":0}"#.utf8))
        try old.validate()
        #expect(old.includeNativeIdentity == nil && old.nativeTarget == nil)
    }

    @Test("An opaque Group does not gain inferred scrolling while an existing semantic Group keeps it")
    func opaqueIdentityDoesNotInventGroupScrolling() throws {
        let text = fixture(type: "StaticText", label: "Line", key: 202,
            frame: frame(x: 20, y: 500, width: 100, height: 44))
        var group = fixture(type: "Group", key: 201, children: [text],
            frame: frame(x: 10, y: 100, width: 300, height: 300))
        let anonymous = try make([group])
        #expect(anonymous.semanticElements[1].actions.contains(.swipeWithin))
        #expect(throws: AgentModeFailure.self) { _ = try anonymous.node(ref: "e2", requiredAction: .swipeWithin) }
        group.identifier = "form"
        let semantic = try make([group])
        #expect(try semantic.target(ref: "e2").semanticID == "form")
        _ = try semantic.node(ref: "e2", requiredAction: .swipeWithin)
    }

    @Test("Path admission retains complete identity evidence and refuses missing or changed objects")
    func pathAdmissionRetainsIdentityMetadata() throws {
        let before = try make([fixture(type: "ScrollArea", key: 101)])
        let chosen = try before.target(ref: "e2")
        #expect(chosen.nativeIdentity?.objectID == 101)
        let admission = AgentModeAdmission(context: try context(), expectedPID: 1234,
            visibleFingerprint: before.visibleFingerprint,
            target: try AgentModeTarget(before.match(target: chosen), nativeTarget: chosen), nativeTarget: chosen)
        try admission.validateScreen(before)
        let incomplete = try make([fixture(type: "ScrollArea", key: 101)], complete: false)
        let absent = try AgentModeSnapshot(roots: [before.nodes[0]], context: context())
        let replaced = try make([fixture(type: "ScrollArea", key: 102)])
        for fresh in [incomplete, absent, replaced] {
            #expect(before.nativeFingerprint == fresh.nativeFingerprint)
            #expect(throws: AgentModeFailure.self) { try admission.validateScreen(fresh) }
        }
        let semantic = try make([fixture(type: "ScrollArea", id: "area", key: 101)], complete: false)
        let semanticTarget = try semantic.target(ref: "e2")
        let legacy = AgentModeAdmission(context: try context(), expectedPID: 1234,
            visibleFingerprint: semantic.visibleFingerprint,
            target: try AgentModeTarget(semantic.match(target: semanticTarget), nativeTarget: semanticTarget),
            nativeTarget: semanticTarget)
        try legacy.validateScreen(semantic)
    }

    @MainActor
    @Test("Unchanged-cache reuse also requires the same protected native objects")
    func unchangedCacheBindsProtectedObjects() throws {
        let before = try make([fixture(key: 101)])
        let unchanged = try make([fixture(key: 101)])
        #expect(AgentModeController.canReuseSnapshot(before, with: unchanged))
        let replaced = try make([fixture(key: 102)])
        let incomplete = try make([fixture(key: 101)], complete: false)
        let absent = try AgentModeSnapshot(roots: [before.nodes[0]], context: context())
        for fresh in [replaced, incomplete, absent] {
            #expect(before.hash == fresh.hash)
            #expect(before.nativeFingerprint == fresh.nativeFingerprint)
            #expect(!AgentModeController.canReuseSnapshot(before, with: fresh))
        }
        let a = fixture(key: 101), b = fixture(key: 102)
        #expect(try AgentModeController.canReuseSnapshot(make([a, b]), with: make([b, a])))
        let semanticBefore = try make([fixture(id: "save", key: 101)])
        let semanticAfter = try make([fixture(id: "save", key: 102)], complete: false)
        #expect(AgentModeController.canReuseSnapshot(semanticBefore, with: semanticAfter))
    }

    private func output(targets: [String], text: [String] = [], reasons: [String: String]) -> CLIOutputValue {
        .object(["schema": .string("axe.output.agent-result"), "schemaVersion": .string("1"),
            "didError": .bool(false), "nextSteps": .array([]), "data": .object([
                "cache": .object(["status": .string("refreshed"), "requiresRefresh": .bool(false)]),
                "capture": .object(["type": .string("runtime-snapshot"), "snapshotID": .string(UUID().uuidString),
                    "seq": .integer(1), "expiresInSeconds": .integer(60), "applicationPID": .integer(1234),
                    "rowOffset": .integer(0), "rowLimit": .integer(64), "totalRows": .integer(Int64(targets.count + text.count)),
                    "targets": .array(targets.map { .string($0) }), "scroll": .array([]),
                    "text": .array(text.map { .string($0) }),
                    "unavailableReferences": .object(reasons.mapValues { .string($0) })])])])
    }

    private func make(_ children: [AXNodeFixture], complete: Bool = true) throws -> AgentModeSnapshot {
        let root = fixture(type: "Application", id: "application", label: "Application", key: 1,
                        children: children, frame: frame(x: 0, y: 0, width: 390, height: 800))
        return try AgentModeSnapshot(roots: AXNodeFixture.decode([root]),
            nativeIdentityMetadata: .init(complete: complete, reason: complete ? nil : "nilChildren"), context: context())
    }

    private func context() throws -> SelectedHIDContext {
        try .fixture(boot: "fixture-boot", screenID: 1, width: 390, height: 800, rotation: 0,
            pixelWidth: 1170, pixelHeight: 2400, pose: "rigid")
    }
}

private func frame(x: Double = 10, y: Double = 100, width: Double = 100, height: Double = 44) -> AXNodeFixture.Frame {
    .init(x: x, y: y, width: width, height: height)
}

/// The native identity keeps owner 1234 even when a test later changes the node's `pid`.
private func fixture(type: String = "Button", id: String? = nil, label: String? = nil, focused: Bool = false,
                     key: UInt64? = nil, children: [AXNodeFixture] = [],
                     frame: AXNodeFixture.Frame = frame()) -> AXNodeFixture {
    AXNodeFixture(type: type, identifier: id, label: label, frame: frame, pid: 1234, focused: focused,
        enabled: true, hidden: false, nativeIdentity: key.map { FBSimulatorAXNativeIdentity(pid: 1234, objectID: $0) },
        children: children)
}
