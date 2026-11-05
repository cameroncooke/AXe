import Foundation
import Testing
@testable import AXeCore

@Suite("rs/1 Runtime Snapshot")
struct RuntimeSnapshotTests {
    private let viewport = AgentFrame(x: 0, y: 0, width: 390, height: 844)

    @Test("Derives roles, actions and viewport visibility")
    func derivesRolesAndActions() throws {
        let elements = RuntimeSnapshotBuilder.elements(from: [
            RuntimeSnapshotNode(type: "Application", label: "Calendar", frame: viewport, children: [
                RuntimeSnapshotNode(type: "Button", label: "Add", frame: frame(y: 60)),
                RuntimeSnapshotNode(type: "TextField", label: "Title", frame: frame(y: 120)),
                RuntimeSnapshotNode(type: "StaticText", label: "  Sunday\n16 August ", frame: frame(y: 180)),
                RuntimeSnapshotNode(type: "Button", label: "Offscreen", frame: frame(y: 900)),
                RuntimeSnapshotNode(type: "Button", label: "Disabled", frame: frame(y: 240), enabled: false),
                RuntimeSnapshotNode(role: "AXSwitch", label: "All-day", frame: AgentFrame(x: 16, y: 300, width: 358, height: 44)),
                RuntimeSnapshotNode(type: "Other", label: "Card", frame: frame(y: 360), customActions: ["Delete"]),
            ]),
        ])

        #expect(elements.map(\.ref) == ["e1", "e2", "e3", "e4", "e5", "e6", "e7", "e8"])
        #expect(elements[0].role == .application)
        // The labelled off-screen button overflows the viewport, so the application becomes scrollable.
        #expect(elements[0].actions == [.swipeWithin])
        #expect(elements[0].swipeFrame == viewport)
        #expect(elements[1].actions == [.tap, .longPress, .touch])
        #expect(elements[2].role == .textField)
        #expect(elements[2].actions == [.tap, .typeText, .longPress, .touch])
        #expect(elements[3].role == .text)
        #expect(elements[3].label == "  Sunday\n16 August ")
        #expect(elements[4].state.visible == false)
        #expect(elements[4].actions.isEmpty)
        #expect(elements[5].actions.isEmpty)
        #expect(elements[6].role == .switch)
        #expect(elements[6].activationPoint == AgentPoint(x: 322, y: 322))
        #expect(elements[7].actions.contains(.tap))
    }

    @Test("Moves bottom-clipped activation points inside the element")
    func adjustsBottomClippedActivationPoint() {
        let elements = RuntimeSnapshotBuilder.elements(from: [
            RuntimeSnapshotNode(type: "Application", frame: viewport, children: [
                RuntimeSnapshotNode(type: "Button", label: "Today", frame: AgentFrame(x: 33, y: 800, width: 69, height: 44)),
            ]),
        ])

        #expect(elements[1].activationPoint == AgentPoint(x: 68, y: 808))
    }

    @Test("Infers scroll areas from overflowing descendants")
    func infersScrollAreas() {
        let elements = RuntimeSnapshotBuilder.elements(from: [
            RuntimeSnapshotNode(type: "Application", frame: viewport, children: [
                RuntimeSnapshotNode(type: "Group", frame: AgentFrame(x: 0, y: 100, width: 390, height: 600), children: [
                    RuntimeSnapshotNode(type: "StaticText", label: "Late event", frame: frame(y: 780)),
                ]),
            ]),
        ])

        #expect(elements[1].actions.contains(.swipeWithin))
        #expect(!elements[0].actions.contains(.swipeWithin))
        #expect(RuntimeSnapshotCompactor.scrollAreas(in: elements).map(\.text) == ["e2|swipe|other|||"])

        // Display text can be padded or multiline without changing the sheet boundary.
        for marker in ["Sheet Grabber", " \nSheet  Grabber\t "] {
            let sheet = RuntimeSnapshotBuilder.elements(from: [
                RuntimeSnapshotNode(type: "Application", frame: viewport, children: [
                    RuntimeSnapshotNode(type: "Button", label: marker, frame: frame(y: 60)),
                    RuntimeSnapshotNode(type: "StaticText", label: "Behind the sheet", frame: frame(y: 900)),
                ]),
            ])
            #expect(!sheet[0].actions.contains(.swipeWithin))
            #expect(sheet[1].label == marker)
            #expect(!RuntimeSnapshotCompactor.targets(in: sheet).contains { $0.element.ref == "e2" })
        }
    }

    @Test("Projects compact rows in rs/1 display priority order")
    func projectsCompactRows() {
        let buttons = (1...70).map {
            RuntimeSnapshotNode(type: "Button", label: "Day \($0)", frame: frame(y: 100))
        }
        let elements = RuntimeSnapshotBuilder.elements(from: [
            RuntimeSnapshotNode(type: "Application", frame: viewport, children: [
                RuntimeSnapshotNode(type: "Button", label: "Close", frame: frame(y: 60)),
                RuntimeSnapshotNode(type: "Button", label: "Cameron Birthday, from 17:00", frame: frame(y: 60)),
                RuntimeSnapshotNode(type: "TextField", label: "Title", value: "a|b", frame: frame(y: 60)),
            ] + buttons),
        ])

        let targets = RuntimeSnapshotCompactor.targets(in: elements).map(\.text)
        #expect(targets.count == RuntimeSnapshotProtocol.targetLimit)
        #expect(targets[0] == "e3|tap|button|Cameron Birthday, from 17:00||")
        #expect(targets[1] == "e4|typeText|text-field|Title|a/b|")
        #expect(targets[2] == "e5|tap|button|Day 1||")
        #expect(!targets.contains("e2|tap|button|Close||"))
    }

    @Test("Screen hash ignores traversal order but detects content changes")
    func screenHashIgnoresOrder() {
        func hash(_ labels: [String]) -> String {
            RuntimeSnapshotBuilder.screenHash(of: RuntimeSnapshotBuilder.elements(from: [
                RuntimeSnapshotNode(type: "Application", frame: viewport, children: labels.map {
                    RuntimeSnapshotNode(type: "Button", label: $0, frame: frame(y: 100))
                }),
            ]))
        }

        #expect(hash(["Passwords", "Shortcuts"]) == hash(["Shortcuts", "Passwords"]))
        #expect(hash(["Passwords", "Shortcuts"]) != hash(["Passwords", "Contacts"]))
    }

    @Test("An explicit oriented display keeps right-side controls without exposing offscreen controls")
    func orientedDisplayOverridesPortraitRootBounds() {
        let roots = [RuntimeSnapshotNode(type: "Application",
            frame: AgentFrame(x: 0, y: 0, width: 669, height: 951), children: [
                RuntimeSnapshotNode(type: "Button", label: "Waits", identifier: "feature.showWaits",
                    frame: AgentFrame(x: 719, y: 184, width: 80, height: 32)),
                RuntimeSnapshotNode(type: "CheckBox", label: "Switch control", identifier: "feature.switch",
                    frame: AgentFrame(x: 782, y: 478, width: 63, height: 28)),
                RuntimeSnapshotNode(type: "Button", label: "Outside right",
                    frame: AgentFrame(x: 970, y: 184, width: 80, height: 32)),
                RuntimeSnapshotNode(type: "Button", label: "Below display",
                    frame: AgentFrame(x: 100, y: 700, width: 80, height: 32)),
            ])]
        let legacy = RuntimeSnapshotBuilder.elements(from: roots)
        #expect(!legacy[1].state.visible && !legacy[2].state.visible)

        let selected = RuntimeSnapshotBuilder.elements(from: roots,
            viewport: AgentFrame(x: 0, y: 0, width: 951, height: 669))
        #expect(selected[1].state.visible && selected[1].actions.contains(.tap))
        #expect(selected[2].state.visible && selected[2].actions.contains(.tap))
        #expect(selected[1].frame == legacy[1].frame)
        #expect(selected[2].frame == legacy[2].frame)
        #expect(!selected[3].state.visible && selected[3].actions.isEmpty)
        #expect(!selected[4].state.visible && selected[4].actions.isEmpty)
    }

    @Test("Computes rs/1 swipe points within a frame")
    func computesSwipePoints() throws {
        let area = RuntimeSnapshotElement(ref: "e1", role: .application, frame: viewport, actions: [.swipeWithin])

        let up = try #require(area.swipePoints(direction: .up))
        #expect(up.from == AgentPoint(x: 195, y: 717))
        #expect(up.to == AgentPoint(x: 195, y: 127))

        let down = try #require(area.swipePoints(direction: .down))
        #expect(down.from == up.to)
        #expect(down.to == up.from)
    }

    @Test("Display labels and field values keep exact whitespace", arguments: [
        " leading", "trailing ", " repeated  spaces ", "line one\nline two\t\r", "left|right\\literal",
    ])
    func exactDisplayWhitespace(_ raw: String) throws {
        let elements = RuntimeSnapshotBuilder.elements(from: [
            RuntimeSnapshotNode(type: "TextField", label: raw, value: raw, identifier: "field", frame: frame(y: 60)),
            RuntimeSnapshotNode(type: "StaticText", label: raw, frame: frame(y: 120)),
        ])
        #expect(elements[0].label == raw && elements[0].value == raw)
        #expect(elements[1].label == raw)
        let decoded = try JSONDecoder().decode([RuntimeSnapshotElement].self, from: JSONEncoder().encode(elements))
        #expect(decoded == elements)
        let row = RuntimeSnapshotCompactor.row(elements[0], action: "typeText").text
        let cells = row.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        #expect(cells.count == 6)
        let displayed = raw.replacingOccurrences(of: "|", with: "/")
        #expect(cells[3] == displayed && cells[4] == displayed)
    }

    @Test("Whitespace-only content changes alter the screen hash", arguments: ["a ", "a  ", " a", "a\n", "a\t"])
    func exactWhitespaceChangesHash(_ changed: String) {
        func elements(_ text: String) -> [RuntimeSnapshotElement] {
            RuntimeSnapshotBuilder.elements(from: [RuntimeSnapshotNode(type: "TextField", label: "Title",
                value: text, identifier: "field", frame: frame(y: 60))])
        }
        #expect(RuntimeSnapshotBuilder.normalizedText(changed) == "a")
        #expect(RuntimeSnapshotBuilder.screenHash(of: elements("a")) != RuntimeSnapshotBuilder.screenHash(of: elements(changed)))
    }

    @Test("Visible labelled images remain exact observations without new tap authority")
    func labelledImagesAreObservations() {
        let elements = RuntimeSnapshotBuilder.elements(from: [
            RuntimeSnapshotNode(type: "Image", label: "  Upload|status\n ", value: "queued  2",
                identifier: "upload.icon", frame: frame(y: 60)),
            RuntimeSnapshotNode(type: "Image", label: "Disabled icon", frame: frame(y: 120), enabled: false),
            RuntimeSnapshotNode(type: "Image", label: " \t\n", frame: frame(y: 180)),
        ])
        let rows = RuntimeSnapshotCompactor.text(in: elements)
        #expect(rows.map(\.text) == [
            "e1|text|image|  Upload/status\n |queued  2|upload.icon",
            "e2|text|image|Disabled icon||",
        ])
        #expect(elements[0].label == "  Upload|status\n " && elements[0].value == "queued  2")
        #expect(elements[0].role == .image)
        #expect(!elements[0].actions.contains(.tap) && !elements[0].actions.contains(.typeText))
        #expect(elements[1].actions.isEmpty)
        #expect(RuntimeSnapshotCompactor.targets(in: elements).isEmpty)
    }

    @Test("Image observations use existing visibility, ordering and page limits")
    func imageObservationsUseExistingPaging() {
        let elements = RuntimeSnapshotBuilder.elements(from: [
            RuntimeSnapshotNode(type: "Application", frame: viewport, children: [
                RuntimeSnapshotNode(type: "StaticText", label: "Later text", frame: frame(y: 120)),
                RuntimeSnapshotNode(type: "Image", label: "First icon", frame: frame(y: 60)),
                RuntimeSnapshotNode(type: "Image", value: "Value only", frame: frame(y: 90)),
                RuntimeSnapshotNode(type: "Image", label: "Outside", frame: frame(y: 900)),
                RuntimeSnapshotNode(type: "Image", label: "Zero frame", frame: AgentFrame(x: 0, y: 0, width: 0, height: 0)),
            ]),
        ])
        let all = RuntimeSnapshotCompactor.text(in: elements)
        #expect(all.map(\.element.ref) == ["e3", "e4", "e2"])
        #expect(all.map(\.text) == ["e3|text|image|First icon||", "e4|text|image||Value only|",
            "e2|text|text|Later text||"])
        #expect(RuntimeSnapshotCompactor.text(in: elements, limit: 2) == Array(all.prefix(2)))
        #expect(RuntimeSnapshotCompactor.text(in: elements, offset: 2, limit: 2) == Array(all.suffix(1)))
        #expect(RuntimeSnapshotCompactor.text(in: elements, limit: 0).isEmpty)
        #expect(RuntimeSnapshotCompactor.text(in: elements, offset: 3).isEmpty)
    }

    private func frame(y: Double) -> AgentFrame {
        AgentFrame(x: 16, y: y, width: 200, height: 44)
    }
}
