import Foundation
import Testing
import FBSimulatorControl
@testable import AXe

/// Web page controls (`w` refs): rows, matching across reads, tap points, the point guard and the
/// wire checks of web input.
@Suite("Agent web controls")
struct AgentWebControlsTests {
    private let appPID: Int32 = 100
    private let webPID: Int32 = 200

    private func context() throws -> SelectedHIDContext {
        try SelectedHIDContext.fixture(width: 402, height: 874, rotation: 0,
            pixelWidth: 1206, pixelHeight: 2622, pose: "static")
    }

    /// A web control as a web read returns it: no children, its native identity, `is_remote` web.
    private func web(_ role: String, label: String?, value: String? = nil, frame: CGRect,
                     objectID: UInt64, pid: Int32? = nil, subrole: String? = nil,
                     type: String? = nil, enabled: Bool = true, tapAnswer: UInt64? = nil) throws -> FBSimulatorAXNode {
        let owner = pid ?? webPID
        var values: [String: Any] = [
            "role": role, "type": type ?? String(role.dropFirst(2)),
            "frame": ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height],
            "pid": owner, "is_remote": "web", "enabled": enabled, "hidden": false, "focused": true,
            "nativeIdentity": ["pid": owner, "objectID": String(objectID)], "children": [],
        ]
        if let label { values["AXLabel"] = label }
        if let value { values["AXValue"] = value }
        if let subrole { values["subrole"] = subrole }
        if let tapAnswer { values["webTapAnswer"] = ["pid": owner, "objectID": String(tapAnswer)] }
        return try JSONDecoder().decode(FBSimulatorAXNode.self, from: JSONSerialization.data(withJSONObject: values))
    }

    private func form() throws -> [FBSimulatorAXNode] {
        [
            try web("AXLink", label: "Read the terms", frame: CGRect(x: 16, y: 120, width: 120, height: 22), objectID: 1),
            try web("AXTextField", label: "Email", frame: CGRect(x: 16, y: 180, width: 300, height: 34), objectID: 2),
            try web("AXTextField", label: "Password", value: "•••", frame: CGRect(x: 16, y: 230, width: 300, height: 34),
                objectID: 3, subrole: "AXSecureTextField"),
            try web("AXCheckBox", label: "I agree", value: "0", frame: CGRect(x: 16, y: 280, width: 20, height: 20), objectID: 4),
            try web("AXButton", label: "Create account", frame: CGRect(x: 16, y: 320, width: 140, height: 30), objectID: 5),
            try web("AXButton", label: "Disabled", frame: CGRect(x: 16, y: 360, width: 140, height: 30), objectID: 6,
                enabled: false),
        ]
    }

    @Test("Web controls become w rows: fields type, the rest tap, disabled ones are left out")
    func rows() throws {
        let controls = AgentWebControls(nodes: try form())
        #expect(controls.rows().map(\.text) == [
            "w1|tap|link|Read the terms||",
            "w2|typeText|text-field|Email||",
            "w3|typeText|text-field|Password|•••|",
            "w4|tap|switch|I agree|0|",
            "w5|tap|button|Create account||",
        ])
        #expect(try controls.node(ref: "w2", requiredAction: .typeText).label == "Email")
        #expect(throws: AgentModeFailure.self) { try controls.node(ref: "w1", requiredAction: .typeText) }
        #expect(throws: AgentModeFailure.self) { try controls.node(ref: "w9", requiredAction: .tap) }
        #expect(AgentWebControls.hidesValue(try controls.node(ref: "w3", requiredAction: .typeText)))
    }

    @Test("An ARIA option is a tap row named once; other labels keep their commas")
    func optionRows() throws {
        let option = try web("AXStaticText", label: "Ada Lovelace, Ada Lovelace",
            frame: CGRect(x: 16, y: 216, width: 370, height: 45), objectID: 7, type: "StaticText")
        let controls = AgentWebControls(nodes: [option])
        #expect(controls.rows().map(\.text) == ["w1|tap|button|Ada Lovelace||"])
        let pair = try web("AXStaticText", label: "Babbage, Charles, Babbage, Charles",
            frame: CGRect(x: 16, y: 260, width: 370, height: 45), objectID: 8, type: "StaticText")
        #expect(AgentWebControls.label(pair) == "Babbage, Charles")
        let link = try web("AXLink", label: "Paris, Paris", frame: CGRect(x: 16, y: 300, width: 100, height: 20), objectID: 9)
        #expect(AgentWebControls.label(link) == "Paris, Paris")
        let odd = try web("AXStaticText", label: "Red, green, blue",
            frame: CGRect(x: 16, y: 340, width: 370, height: 45), objectID: 10, type: "StaticText")
        #expect(AgentWebControls.label(odd) == "Red, green, blue")
    }

    @Test("A capture lists web rows after the app's own targets and reports the web read")
    func captureRows() throws {
        let context = try context()
        let root = AXNodeFixture(type: "Application", label: "Probe", role: "AXApplication",
            frame: .init(x: 0, y: 0, width: 402, height: 874), pid: appPID, enabled: true, hidden: false,
            children: [AXNodeFixture(type: "Button", identifier: "open", label: "Open", role: "AXButton",
                frame: .init(x: 20, y: 60, width: 100, height: 40), pid: appPID, enabled: true, hidden: false)])
        let snapshot = try AgentModeSnapshot(roots: AXNodeFixture.decode([root]), context: context,
            web: AgentWebControls(nodes: try form()))
        let capture = snapshot.capture(id: UUID(), sequence: 1, udid: "U", request: AgentModeRequest(kind: .describe),
            applicationPID: appPID, context: context, unchanged: false, expiresIn: 60)
        let refs = capture.targets.map { String($0.prefix { $0 != "|" }) }
        #expect(refs.first?.hasPrefix("e") == true)
        #expect(Array(refs.drop { $0.hasPrefix("e") }) == ["w1", "w2", "w3", "w4", "w5"])
        #expect(capture.webContent?.controls == 5)
        // The web rows never change the app's own screen hash or fingerprints.
        let plain = try AgentModeSnapshot(roots: AXNodeFixture.decode([root]), context: context)
        #expect(plain.hash == snapshot.hash && plain.visibleFingerprint == snapshot.visibleFingerprint)
        #expect(plain.capture(id: UUID(), sequence: 1, udid: "U", request: AgentModeRequest(kind: .describe),
            applicationPID: appPID, context: context, unchanged: false, expiresIn: 60).webContent == nil)
    }

    @Test("Web rows come before the keys of an on-screen keyboard, so they stay on the first page")
    func webRowsBeforeKeyboard() throws {
        let context = try context()
        var next: UInt64 = 10
        func node(_ type: String, _ label: String, _ frame: AXNodeFixture.Frame,
                  children: [AXNodeFixture] = []) -> AXNodeFixture {
            next += 1
            return AXNodeFixture(type: type, label: label, role: type == "Button" ? "AXButton" : nil, frame: frame,
                pid: appPID, enabled: true, hidden: false, nativeIdentity: .init(pid: appPID, objectID: next),
                children: children)
        }
        let letters = Array("qwertyuiopasdfghjklzxcvbnm").enumerated().map { index, letter in
            node("Button", String(letter), .init(x: Double(index % 10) * 40 + 2, y: 597 + Double(index / 10) * 54,
                width: 36, height: 46))
        }
        let root = node("Application", "Safari", .init(x: 0, y: 0, width: 402, height: 874), children: [
            node("Button", "Back", .init(x: 20, y: 60, width: 44, height: 44)),
            node("Group", "", .init(x: 0, y: 540, width: 402, height: 334), children: letters),
        ])
        let snapshot = try AgentModeSnapshot(roots: AXNodeFixture.decode([root]),
            nativeIdentityMetadata: .init(complete: true, reason: nil), context: context,
            web: AgentWebControls(nodes: try form()))
        var request = AgentModeRequest(kind: .describe)
        request.rowLimit = 8
        let capture = snapshot.capture(id: UUID(), sequence: 1, udid: "U", request: request,
            applicationPID: appPID, context: context, unchanged: false, expiresIn: 60)
        let labels = capture.targets.map { String($0.split(separator: "|", omittingEmptySubsequences: false)[3]) }
        #expect(labels == ["Back", "Read the terms", "Email", "Password", "I agree", "Create account", "q", "w"])
        #expect(capture.targets[1].hasPrefix("w1|") && capture.targets[6].hasPrefix("e"))
    }

    @Test("A newer read finds the control by identity, or by its one role and label when rebuilt")
    func matching() throws {
        let chosen = try form()[1]
        let same = AgentWebControls(nodes: try form())
        #expect(same.match(chosen)?.ref == "w2")
        let rebuilt = AgentWebControls(nodes: [
            try web("AXTextField", label: "Email", frame: CGRect(x: 16, y: 400, width: 300, height: 34), objectID: 99),
        ])
        #expect(rebuilt.match(chosen)?.ref == "w1")
        let twice = AgentWebControls(nodes: [
            try web("AXTextField", label: "Email", frame: CGRect(x: 16, y: 180, width: 300, height: 34), objectID: 98),
            try web("AXTextField", label: "Email", frame: CGRect(x: 16, y: 400, width: 300, height: 34), objectID: 99),
        ])
        #expect(twice.match(chosen) == nil)
        #expect(AgentWebControls(nodes: []).match(chosen) == nil)
    }

    @Test("A control is tapped at the centre of its part on screen; a field near its right end")
    func points() throws {
        let context = try context()
        let field = try web("AXTextField", label: "Email", frame: CGRect(x: 16, y: 180, width: 300, height: 34), objectID: 2)
        let centre = try #require(AgentWebControls.tapPoint(field, context: context))
        #expect(centre.x == 166 && centre.y == 197)
        let typing = try #require(AgentWebControls.typingPoint(field, context: context))
        #expect(typing.x == 308 && typing.y == 197)
        // Partly below the display: the visible part's centre.
        let clipped = try web("AXButton", label: "Go", frame: CGRect(x: 0, y: 854, width: 100, height: 40), objectID: 7)
        let point = try #require(AgentWebControls.tapPoint(clipped, context: context))
        #expect(point.y == 864)
        let offscreen = try web("AXButton", label: "Far", frame: CGRect(x: 0, y: 900, width: 100, height: 40), objectID: 8)
        #expect(AgentWebControls.tapPoint(offscreen, context: context) == nil)
    }

    @Test("The typing tap stays left of a control drawn over the field's right end, never past its centre")
    func typingPointAvoidsOverlays() throws {
        let context = try context()
        let field = try web("AXTextField", label: "Search", frame: CGRect(x: 16, y: 180, width: 300, height: 34), objectID: 2)
        let clear = try web("AXButton", label: "Clear", frame: CGRect(x: 288, y: 185, width: 24, height: 24), objectID: 3)
        let below = try web("AXButton", label: "Search", frame: CGRect(x: 276, y: 230, width: 40, height: 30), objectID: 4)
        let typing = try #require(AgentWebControls.typingPoint(field, context: context, others: [field, clear, below]))
        #expect(typing.x == 280 && typing.y == 197)
        // A control over most of the field leaves the centre.
        let wide = try web("AXButton", label: "Overlay", frame: CGRect(x: 100, y: 180, width: 216, height: 34), objectID: 5)
        #expect(AgentWebControls.typingPoint(field, context: context, others: [wide])?.x == 166)
    }

    @Test("Keyboard keys from any process count; other buttons do not")
    func keyboard() throws {
        let keys = [
            try web("AXButton", label: "Q", frame: CGRect(x: 0, y: 600, width: 30, height: 40), objectID: 1, pid: 300, type: "Button"),
            try web("AXButton", label: "space", frame: CGRect(x: 100, y: 760, width: 180, height: 40), objectID: 2, pid: 300, type: "Button"),
        ]
        #expect(AgentWebControls(nodes: [], keyboard: keys).keyboardVisible)
        let other = [try web("AXButton", label: "Create account", frame: CGRect(x: 0, y: 600, width: 30, height: 40),
            objectID: 3, type: "Button")]
        #expect(!AgentWebControls(nodes: [], keyboard: other).keyboardVisible)
        #expect(AgentWebControls.keyboardProbePoints(CGSize(width: 402, height: 874)).count == 9)
        #expect(AgentWebControls.keyboardProbePoints(CGSize(width: 402, height: 200)).isEmpty)
    }

    @Test("The point guard admits the control, its own text, or the same control under a new object ID or as a button")
    func pointGuard() throws {
        let target = try web("AXLink", label: "Start again", frame: CGRect(x: 16, y: 210, width: 83, height: 23), objectID: 10)
        try SelectedWebTargetPolicy.validate(target, target: target, exact: true)
        let renamed = try web("AXLink", label: "Start again", frame: CGRect(x: 16, y: 210, width: 83, height: 23), objectID: 11)
        try SelectedWebTargetPolicy.validate(renamed, target: target, exact: true)
        // WebKit can answer a point read on a link with a button for the same element.
        let asButton = try web("AXButton", label: "Start again", frame: CGRect(x: 16, y: 210, width: 83, height: 23),
            objectID: 15, type: "Button")
        try SelectedWebTargetPolicy.validate(asButton, target: target, exact: false)
        let asField = try web("AXTextField", label: "Start again", frame: CGRect(x: 16, y: 210, width: 83, height: 23),
            objectID: 16, type: "TextField")
        #expect(throws: AgentModeFailure.self) { try SelectedWebTargetPolicy.validate(asField, target: target, exact: false) }
        let text = try web("AXStaticText", label: "Start again", frame: CGRect(x: 18, y: 212, width: 70, height: 19), objectID: 12)
        try SelectedWebTargetPolicy.validate(text, target: target, exact: false)
        #expect(throws: AgentModeFailure.self) { try SelectedWebTargetPolicy.validate(text, target: target, exact: true) }
        let other = try web("AXButton", label: "Cancel", frame: CGRect(x: 20, y: 212, width: 40, height: 19), objectID: 13)
        #expect(throws: AgentModeFailure.self) { try SelectedWebTargetPolicy.validate(other, target: target, exact: false) }
        let app = try web("AXButton", label: "Start again", frame: CGRect(x: 16, y: 210, width: 83, height: 23),
            objectID: 14, pid: appPID)
        #expect(throws: AgentModeFailure.self) { try SelectedWebTargetPolicy.validate(app, target: target, exact: false) }
        let disabled = try web("AXLink", label: "Start again", frame: CGRect(x: 16, y: 210, width: 83, height: 23),
            objectID: 10, enabled: false)
        #expect(throws: AgentModeFailure.self) { try SelectedWebTargetPolicy.validate(disabled, target: target, exact: false) }
    }

    @Test("A tap accepts the container the web read found at the control's point, and nothing else")
    func tapAnswer() throws {
        let link = try web("AXLink", label: "Story", frame: CGRect(x: 209, y: 310, width: 174, height: 101),
            objectID: 40, tapAnswer: 39)
        let heading = try web("AXHeading", label: "Story", frame: CGRect(x: 209, y: 310, width: 177, height: 101), objectID: 39)
        try SelectedWebTargetPolicy.validate(heading, target: link, exact: false)
        #expect(throws: AgentModeFailure.self) { try SelectedWebTargetPolicy.validate(heading, target: link, exact: true) }
        let other = try web("AXHeading", label: "Story", frame: CGRect(x: 209, y: 310, width: 177, height: 101), objectID: 38)
        #expect(throws: AgentModeFailure.self) { try SelectedWebTargetPolicy.validate(other, target: link, exact: false) }
        let plain = try web("AXLink", label: "Story", frame: CGRect(x: 209, y: 310, width: 174, height: 101), objectID: 41)
        #expect(throws: AgentModeFailure.self) { try SelectedWebTargetPolicy.validate(heading, target: plain, exact: false) }
    }

    @Test("While typing, the field proved before the first key is followed by identity, not label")
    func typingFollowsIdentity() throws {
        let anchor = try web("AXTextField", label: "Search", frame: CGRect(x: 16, y: 100, width: 300, height: 34), objectID: 30)
        let relabelled = try web("AXTextField", label: "", value: "cats", frame: CGRect(x: 16, y: 100, width: 300, height: 34), objectID: 30)
        #expect(SelectedWebTargetPolicy.sameElement(relabelled, anchor))
        let other = try web("AXTextField", label: "Search", frame: CGRect(x: 16, y: 100, width: 300, height: 34), objectID: 31)
        #expect(!SelectedWebTargetPolicy.sameElement(other, anchor))
        let disabled = try web("AXTextField", label: "Search", frame: CGRect(x: 16, y: 100, width: 300, height: 34),
            objectID: 30, enabled: false)
        #expect(!SelectedWebTargetPolicy.sameElement(disabled, anchor))
    }

    @Test("Web key input has the native allowance plus its waits and a point read per key")
    func keyAllowance() {
        let events: [SelectedKeyboardPrimitive] = [.down(42), .delay(0.1), .up(42), .delay(0.25), .down(4), .up(4)]
        #expect(abs(SelectedWebInputGuard.allowance(events) - (8 + 0.35 + 2 * 0.15)) < 1e-9)
        #expect(SelectedWebInputGuard.allowance([]) == 8)
        // 100 Backspaces at the default 0.1 s delay: 9.9 s of waits alone, past a flat 8 s.
        let clear = (0..<100).flatMap { index -> [SelectedKeyboardPrimitive] in
            [.down(42), .up(42)] + (index < 99 ? [.delay(0.1)] : [])
        }
        #expect(SelectedWebInputGuard.allowance(clear) > 9.9 + 100 * 0.1)
    }

    @Test("A rebuilt control is matched by label only when that label named one control before")
    func ambiguousLabel() throws {
        let rows = AgentWebControls(nodes: [
            try web("AXButton", label: "Delete", frame: CGRect(x: 300, y: 200, width: 60, height: 30), objectID: 1),
            try web("AXButton", label: "Delete", frame: CGRect(x: 300, y: 400, width: 60, height: 30), objectID: 2),
        ])
        let rebuilt = AgentWebControls(nodes: [
            try web("AXButton", label: "Delete", frame: CGRect(x: 300, y: 260, width: 60, height: 30), objectID: 9),
        ])
        #expect(rebuilt.match(rows.nodes[0], original: rows) == nil)
        let single = AgentWebControls(nodes: [rows.nodes[0]])
        #expect(rebuilt.match(rows.nodes[0], original: single)?.ref == "w1")
    }

    @Test("Letter buttons in the page's own process are not a keyboard")
    func pageLetterButtons() throws {
        let page = try form()
        let tiles = [
            try web("AXButton", label: "Q", frame: CGRect(x: 0, y: 620, width: 30, height: 40), objectID: 40, type: "Button"),
            try web("AXButton", label: "W", frame: CGRect(x: 40, y: 620, width: 30, height: 40), objectID: 41, type: "Button"),
        ]
        #expect(!AgentWebControls(nodes: page, keyboard: tiles).keyboardVisible)
        let keys = [
            try web("AXButton", label: "Q", frame: CGRect(x: 0, y: 600, width: 30, height: 40), objectID: 42, pid: 300, type: "Button"),
            try web("AXButton", label: "space", frame: CGRect(x: 100, y: 760, width: 180, height: 40), objectID: 43, pid: 300, type: "Button"),
        ]
        let controls = AgentWebControls(nodes: page, keyboard: keys)
        #expect(controls.keyboardVisible && controls.keyboardTop == 600)
    }

    @Test("Typing goes ahead on keyboard evidence alone only when the web read worked and the keyboard covers the field")
    @MainActor
    func coveredField() throws {
        let context = try context()
        let keys = [
            try web("AXButton", label: "Q", frame: CGRect(x: 0, y: 600, width: 30, height: 40), objectID: 42, pid: 300, type: "Button"),
            try web("AXButton", label: "space", frame: CGRect(x: 100, y: 760, width: 180, height: 40), objectID: 43, pid: 300, type: "Button"),
        ]
        let root = AXNodeFixture(type: "Application", label: "Probe", role: "AXApplication",
            frame: .init(x: 0, y: 0, width: 402, height: 874), pid: appPID, enabled: true, hidden: false)
        func record(_ web: AgentWebControls) throws -> AgentModeController.Record {
            AgentModeController.Record(id: UUID(), sequence: 1, capturedAt: 0, expectedPID: appPID, context: context,
                snapshot: try AgentModeSnapshot(roots: AXNodeFixture.decode([root]), context: context, web: web))
        }
        let low = try web("AXTextField", label: "Note", frame: CGRect(x: 16, y: 640, width: 300, height: 34), objectID: 50)
        let high = try web("AXTextField", label: "Email", frame: CGRect(x: 16, y: 180, width: 300, height: 34), objectID: 51)
        let read = try record(AgentWebControls(nodes: try form(), keyboard: keys))
        #expect(AgentModeController.keyboardCovers(low, record: read))
        #expect(!AgentModeController.keyboardCovers(high, record: read))
        let failed = try record(AgentWebControls(nodes: [], failure: "readFailed", keyboard: keys))
        #expect(!AgentModeController.keyboardCovers(low, record: failed))
    }

    @Test("After a delivered focus tap, a refused key phase still reports the tap")
    @MainActor
    func focusTapCounted() {
        func response(_ outcome: String, _ count: Int, _ cleanup: String) -> SelectedHIDResponse {
            SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: UUID(), brokerID: UUID(),
                outcome: outcome, token: nil, enqueuedEventCount: count, cleanup: cleanup, error: nil, context: nil)
        }
        let tapped = response("completed", 2, "released")
        let combined = AgentModeController.afterFocusTap(response("failedBeforeInput", 0, "notNeeded"), tapped: tapped)
        #expect(combined.outcome == "failedNoReplay" && combined.enqueuedEventCount == 2 && combined.cleanup == "released")
        let typed = AgentModeController.afterFocusTap(response("completed", 6, "released"), tapped: tapped)
        #expect(typed.outcome == "completed" && typed.enqueuedEventCount == 8)
        let stopped = AgentModeController.stoppedAfterFocusTap(AgentModeFailure("targetCovered",
            "Something else now covers that web control, so nothing was sent. \(AgentModeFailure.actFromCapture)"))
        #expect(stopped.code == "targetCovered")
        #expect(stopped.message.hasPrefix("The web field was tapped, but no key was typed") && !stopped.message.contains("nothing was sent"))
    }

    @Test("Web input carries the app's PID, one point and a web control from another process")
    func webInputValidation() throws {
        let target = try form()[1]
        var tap = SelectedAXRequest(kind: .webTap, expectedPID: appPID, endpoint: nil, selectorKind: nil,
            selectorValue: nil, preDelay: 0, postDelay: 0, point: SelectedAXPoint(x: 166, y: 197))
        tap.webTarget = target
        try tap.validate()
        var noPoint = tap
        noPoint.point = nil
        #expect(throws: (any Error).self) { try noPoint.validate() }
        var samePID = tap
        samePID.webTarget = try web("AXButton", label: "Own", frame: CGRect(x: 0, y: 0, width: 10, height: 10),
            objectID: 1, pid: appPID)
        #expect(throws: (any Error).self) { try samePID.validate() }
        var keys = tap
        keys.keyEvents = [.down(4), .up(4)]
        #expect(throws: (any Error).self) { try keys.validate() }
        var typing = tap
        typing = SelectedAXRequest(kind: .webType, expectedPID: appPID, endpoint: nil, selectorKind: nil,
            selectorValue: nil, preDelay: 0, postDelay: 0, point: SelectedAXPoint(x: 308, y: 197))
        typing.webTarget = target
        #expect(throws: (any Error).self) { try typing.validate() }
        typing.keyEvents = [.down(4), .up(4)]
        try typing.validate()
        typing.webFieldCovered = true
        try typing.validate()
        tap.webFieldCovered = true
        #expect(throws: (any Error).self) { try tap.validate() }
        var describe = SelectedAXRequest(kind: .describe, expectedPID: nil, endpoint: nil, selectorKind: nil,
            selectorValue: nil, preDelay: 0, postDelay: 0)
        describe.includeWebContent = true
        try describe.validate()
        var point = SelectedAXRequest(kind: .describePoint, expectedPID: nil, endpoint: nil, selectorKind: nil,
            selectorValue: nil, preDelay: 0, postDelay: 0, point: SelectedAXPoint(x: 1, y: 1))
        point.includeWebContent = true
        #expect(throws: (any Error).self) { try point.validate() }
    }

    @Test("w refs are refs for tap, type and keys only; --web is a capture option")
    func requestValidation() throws {
        let snapshot = UUID()
        try AgentModeRequest(kind: .tap, snapshotID: snapshot, ref: "w3").validate()
        try AgentModeRequest(kind: .focusAndType, snapshotID: snapshot, ref: "w3", text: "Ada").validate()
        try AgentModeRequest(kind: .keyPress, snapshotID: snapshot, ref: "w3", keyEvents: [.down(42), .up(42)]).validate()
        try AgentModeRequest(kind: .keySequence, snapshotID: snapshot, ref: "w3",
            keyEvents: [.down(42), .up(42), .down(42), .up(42)]).validate()
        try AgentModeRequest(kind: .keyCombo, snapshotID: snapshot, ref: "w3",
            keyEvents: [.down(227), .down(4), .up(4), .up(227)]).validate()
        #expect(throws: AgentModeFailure.self) {
            try AgentModeRequest(kind: .swipe, snapshotID: snapshot, ref: "w3", direction: .up).validate()
        }
        #expect(throws: AgentModeFailure.self) { try AgentModeRequest(kind: .tap, snapshotID: snapshot, ref: "w0").validate() }
        #expect(throws: AgentModeFailure.self) { try AgentModeRequest(kind: .tap, snapshotID: snapshot, ref: "x3").validate() }
        try AgentModeRequest(kind: .describe, includeWebContent: true).validate()
        #expect(throws: AgentModeFailure.self) {
            try AgentModeRequest(kind: .tap, snapshotID: snapshot, ref: "e3", includeWebContent: true).validate()
        }
        #expect(AgentModeOptions.isReference("w12"))
        #expect(AgentModeOptions.isReference("e12"))
        #expect(!AgentModeOptions.isReference("w"))
        #expect(!AgentModeOptions.isReference("w01"))
    }

    @Test("Actions keep reading web content on a snapshot that read it")
    func inheritedWebReads() throws {
        let context = try context()
        let root = try AXNodeFixture(type: "Application", label: "Probe", role: "AXApplication",
            frame: .init(x: 0, y: 0, width: 402, height: 874), pid: appPID, enabled: true, hidden: false).decoded()
        let id = UUID()
        let webRecord = AgentModeController.Record(id: id, sequence: 1, capturedAt: 0, expectedPID: appPID, context: context,
            snapshot: try AgentModeSnapshot(roots: [root], context: context, web: AgentWebControls(nodes: [])))
        let plainRecord = AgentModeController.Record(id: id, sequence: 1, capturedAt: 0, expectedPID: appPID, context: context,
            snapshot: try AgentModeSnapshot(roots: [root], context: context))
        let tap = AgentModeRequest(kind: .tap, snapshotID: id, ref: "e2")
        #expect(AgentModeController.readsWebContent(tap, snapshotID: id, record: webRecord))
        #expect(!AgentModeController.readsWebContent(tap, snapshotID: id, record: plainRecord))
        #expect(!AgentModeController.readsWebContent(tap, snapshotID: UUID(), record: webRecord))
        #expect(AgentModeController.readsWebContent(AgentModeRequest(kind: .describe, includeWebContent: true),
            snapshotID: nil, record: nil))
        #expect(!AgentModeController.readsWebContent(AgentModeRequest(kind: .describe), snapshotID: nil, record: webRecord))
        #expect(AgentModeController.readsWebContent(AgentModeRequest(kind: .tap, snapshotID: id, ref: "w1"),
            snapshotID: id, record: plainRecord))
    }
}
