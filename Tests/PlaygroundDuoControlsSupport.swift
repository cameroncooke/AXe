import Foundation
import Testing

enum DuoControlsPosition: String, CaseIterable {
    case outer0, outer90, outer270, inner0, inner90, inner180, inner270
    var pose: DuoPlaygroundPose { rawValue.hasPrefix("outer") ? .closed : .open }
    var rotation: Int {
        switch self {
        case .outer0, .inner0: return 0
        case .outer90, .inner90: return 90
        case .inner180: return 180
        case .outer270, .inner270: return 270
        }
    }
}

struct PlaygroundControlsDocument: PlaygroundObservedDocument {
    let fixtureVersion: Int
    let traceScope: String
    let pid: Int32
    let generation: UUID
    let sequence: Int
    let counts: [String: Int]
    let advancedSliders: [String: Double]
    let waitTargetVisible: Bool
    let waitDuplicateVisible: Bool
    let targetAppearedUptime: Double
    let scheduleGeneration: Int
    let text: String
    let textFocused: Bool
    let keyboardVisible: Bool
    let slider: Double
    let switchOn: Bool
    let listOffsetY: Double
    let pageOffsetY: Double
    let canvasOffsetX: Double
    let canvasOffsetY: Double
    let panX: Double
    let panY: Double
    let pinchScale: Double
    let rotationRadians: Double
    let activeWindowTouches: Int
    let windowTraceDropped: Int
    let recognizerTraceDropped: Int
    let windowTouchTrace: [PlaygroundControlsContact]
    let recognizerTrace: [PlaygroundControlsRecognizer]
    let geometry: [String: PlaygroundControlsRect]
    let touchX: Double
    let touchY: Double

    func count(_ name: String) -> Int { counts[name, default: 0] }
    func requireClear() throws {
        try #require(fixtureVersion == 6 && traceScope == "duo-controls-page")
        try #require(windowTraceDropped == 0 && recognizerTraceDropped == 0 && activeWindowTouches == 0)
    }
}

struct PlaygroundControlsContact: Decodable, Equatable {
    let contactID: Int
    let phase: String
    let x: Double
    let y: Double
    let timestamp: Double
    let activeTouches: Int
    let hitView: String
}

struct PlaygroundControlsRecognizer: Decodable, Equatable {
    let name: String
    let state: Int
    let touches: Int
    let timestamp: Double
    let x: Double
    let y: Double
}
struct PlaygroundControlsRect: Decodable, Equatable { let x: Double; let y: Double; let width: Double; let height: Double }

struct PlaygroundControlsReceipt: Decodable {
    let outcome: String
    let enqueuedEventCount: Int
    let cleanup: String
    let token: UUID?
    let error: String?
    let context: DuoContext?
    let quarantine: DuoCLIResponse.Quarantine?

    func requireCompleted() throws {
        try #require(error == nil && quarantine == nil && cleanup != "uncertain")
        try #require(["enqueuedAndDrained", "retained", "moved", "endedAndDrained", "closed"].contains(outcome))
    }
}

struct PlaygroundControlsSession {
    let app: AgentPlaygroundSession
    let pid: Int32
    let documents: PlaygroundDocumentReader<PlaygroundControlsDocument>
    let catalogue: DuoCatalogue
    let artifacts: URL

    init() async throws {
        let app = try AgentPlaygroundSession()
        let pid = try await app.open("duo-controls", readyID: "feature.tap")
        self.app = app
        self.pid = pid
        documents = try await PlaygroundDocumentReader(udid: app.udid, pid: pid, fileName: "state.json")
        catalogue = try await DuoPlaygroundSession().catalogue()
        let directory = ProcessInfo.processInfo.environment["AXE_E2E_ARTIFACT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        artifacts = directory.appendingPathComponent("controls-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        try documents.read().requireClear()
        try Data(contentsOf: documents.url).write(to: artifacts.appendingPathComponent("initial-state.json"))
    }

    func selection() -> [String] {
        let identity = catalogue.activePanel.identity
        return ["--input-mode", "selected", "--screen-id", String(identity.displayID), "--screen-uuid", identity.uniqueID.uuidString]
    }

    func selected(_ arguments: [String], allowFailure: Bool = false) async throws -> PlaygroundControlsReceipt {
        let output = try await app.run(arguments + selection(), allowFailure: true)
        let name = UUID().uuidString
        let executable = try TestHelpers.getAxePath()
        let invocation = [executable] + arguments + selection() + ["--udid", app.udid]
        try JSONEncoder().encode(invocation).write(to: artifacts.appendingPathComponent(name + "-argv.json"))
        try Data(output.output.utf8).write(to: artifacts.appendingPathComponent(name + "-receipt.txt"))
        try Data(contentsOf: documents.url).write(to: artifacts.appendingPathComponent(name + "-state.json"))
        let line = output.output.split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
        let receipt = try JSONDecoder().decode(PlaygroundControlsReceipt.self, from: Data(line.utf8))
        if !allowFailure {
            try #require(output.exitCode == 0, "Selected command failed: \(output.output)")
            try receipt.requireCompleted()
            let context = try #require(receipt.context)
            try context.requireMatch(catalogue)
        }
        return receipt
    }

    func show(_ identifier: String) async throws {
        _ = try await app.run(["tap", "--id", identifier, "--element-type", "Button"])
        _ = try await documents.waitFor("toolbar release") { $0.activeWindowTouches == 0 }
    }

    func preserveState(_ name: String) throws {
        try Data(contentsOf: documents.url).write(to: artifacts.appendingPathComponent(name + ".json"))
    }

    func frame(_ identifier: String) async throws -> UIElement.Frame {
        let output = try await app.run(["describe-ui"])
        let roots = try UIStateParser.parseDescribeUIRoots(output.output)
        let element = try #require(UIStateParser.findElement(in: roots, withIdentifier: identifier))
        let frame = try #require(element.frame)
        let finite = [frame.x, frame.y, frame.width, frame.height].allSatisfy(\.isFinite)
        try #require(finite)
        try #require(frame.width > 0 && frame.height > 0)
        return frame
    }

    private func dismissAccentPopupIfPresent() async throws {
        let name = "accent-popup-" + UUID().uuidString
        let beforeTree = try await app.run(["describe-ui"], allowFailure: true)
        try Data(beforeTree.output.utf8).write(to: artifacts.appendingPathComponent(name + "-before-tree.txt"))
        try #require(beforeTree.exitCode == 0, "Could not read the current accent popup state.")
        let roots = try UIStateParser.parseDescribeUIRoots(beforeTree.output)
        guard let popup = UIStateParser.findElement(in: roots, withIdentifier: "PopoverDismissRegion") else { return }
        try #require(popup.type == "Group" && popup.label == "dismiss popup", "Unexpected popup identity.")
        let before = try documents.read()
        try before.requireClear()
        try #require(before.textFocused)
        try preserveState(name + "-before-escape")
        let arguments = ["key", "41"]
        let executable = try TestHelpers.getAxePath()
        try JSONEncoder().encode([executable] + arguments + ["--udid", app.udid])
            .write(to: artifacts.appendingPathComponent(name + "-escape-argv.json"))
        let escape = try await app.run(arguments, allowFailure: true)
        try Data(escape.output.utf8).write(to: artifacts.appendingPathComponent(name + "-escape-output.txt"))
        try JSONEncoder().encode(escape.exitCode).write(to: artifacts.appendingPathComponent(name + "-escape-exit-code.json"))
        try preserveState(name + "-after-escape")
        try #require(escape.exitCode == 0, "Accent popup Escape command failed; input is not replayed.")
        let afterTree = try await app.run(["describe-ui"], allowFailure: true)
        try Data(afterTree.output.utf8).write(to: artifacts.appendingPathComponent(name + "-after-tree.txt"))
        try #require(afterTree.exitCode == 0, "Could not verify accent popup dismissal.")
        let afterRoots = try UIStateParser.parseDescribeUIRoots(afterTree.output)
        try #require(UIStateParser.findElement(in: afterRoots, withIdentifier: "PopoverDismissRegion") == nil,
            "Escape did not dismiss the accent popup; input is not replayed.")
        let dismiss = try #require(UIStateParser.findElement(in: afterRoots, withIdentifier: "feature.dismissKeyboard"))
        let field = try #require(UIStateParser.findElement(in: afterRoots, withIdentifier: "feature.text"))
        try #require(dismiss.type == "Button" && field.type == "TextField", "The normal app controls are not exposed.")
        let after = try documents.read()
        try after.requireClear()
        try #require(after.pid == before.pid && after.generation == before.generation)
        try #require(after.text == before.text && after.textFocused == before.textFocused && after.counts == before.counts)
        try #require(after.windowTouchTrace == before.windowTouchTrace && after.recognizerTrace == before.recognizerTrace)
        try preserveState(name + "-verified-after-escape")
    }

    func freshTap() async throws {
        if try documents.read().textFocused {
            try await dismissAccentPopupIfPresent()
            try await show("feature.dismissKeyboard")
            _ = try await documents.waitFor("keyboard dismissal before fresh physical tap") {
                !$0.textFocused && $0.activeWindowTouches == 0
            }
        }
        try await show("feature.showPad")
        let current = try await DuoPlaygroundSession().catalogue(boot: catalogue.bootIdentity)
        let before = try documents.read()
        let frame = try await self.frame("feature.tap")
        let point = (frame.x + frame.width / 2, frame.y + frame.height / 2)
        let panel = current.activePanel.identity
        let arguments = ["tap", "--id", "feature.tap", "--element-type", "Button", "--tap-style", "physical",
            "--expected-pid", String(pid), "--input-mode", "selected", "--screen-id", String(panel.displayID), "--screen-uuid", panel.uniqueID.uuidString]
        let output = try await app.run(arguments)
        try Data(output.output.utf8).write(to: artifacts.appendingPathComponent("fresh-tap-" + UUID().uuidString + ".txt"))
        let receipt = try controlsReceipt(output.output)
        try #require(receipt.outcome == "enqueuedAndDrained" && receipt.enqueuedEventCount == 2 && receipt.cleanup == "notNeeded" && receipt.quarantine == nil)
        let context = try #require(receipt.context)
        try context.requireMatch(current)
        let after = try await documents.waitFor("fresh real physical tap callback") {
            $0.count("tap") == before.count("tap") + 1 && $0.activeWindowTouches == 0
        }
        try requireContact(after, since: before, start: point, end: point)
        try #require(after.text == before.text && after.slider == before.slider && after.switchOn == before.switchOn)
    }

    func requireContact(_ after: PlaygroundControlsDocument, since before: PlaygroundControlsDocument,
                        start: (Double, Double), end: (Double, Double), contacts expected: Int = 1) throws {
        let groups = try controlsContactGroups(after, before: before, expected: expected)
        for rows in groups {
            let first = try #require(rows.first)
            let last = try #require(rows.last)
            try controlsNear(first, point: start)
            try controlsNear(last, point: end)
            for row in rows { try controlsOnLine(row, start: start, end: end) }
            if start != end { try #require(rows.contains { $0.phase == "windowTouchMoved" }) }
        }
        if expected == 2 {
            let firstEnd = try #require(groups[0].last)
            let secondStart = try #require(groups[1].first)
            try #require(firstEnd.timestamp < secondStart.timestamp, "Double-tap contacts must be separate.")
        }
    }
}


func controlsContactGroups(_ after: PlaygroundControlsDocument, before: PlaygroundControlsDocument,
                           expected: Int) throws -> [[PlaygroundControlsContact]] {
    try after.requireClear()
    try #require(before.activeWindowTouches == 0)
    try #require(after.windowTouchTrace.count >= before.windowTouchTrace.count)
    try #require(Array(after.windowTouchTrace.prefix(before.windowTouchTrace.count)) == before.windowTouchTrace)
    let events = Array(after.windowTouchTrace.dropFirst(before.windowTouchTrace.count))
    let previousIDs = Set(before.windowTouchTrace.map(\.contactID))
    let groups = Dictionary(grouping: events, by: \.contactID)
    try #require(groups.count == expected)
    var active = Set<Int>()
    var previousTime = before.windowTouchTrace.last?.timestamp ?? 0
    for event in events {
        let finite = [event.x, event.y, event.timestamp].allSatisfy(\.isFinite)
        try #require(finite)
        try #require(event.timestamp >= previousTime && event.contactID > 0 && !previousIDs.contains(event.contactID))
        previousTime = event.timestamp
        switch event.phase {
        case "windowTouchBegan":
            let inserted = active.insert(event.contactID).inserted
            try #require(inserted)
        case "windowTouchMoved": try #require(active.contains(event.contactID))
        case "windowTouchEnded":
            let removed = active.remove(event.contactID)
            try #require(removed != nil)
        default: throw TestError.unexpectedState("A complete gesture has a cancelled or unknown contact phase.")
        }
        try #require(event.activeTouches == active.count)
    }
    try #require(active.isEmpty)
    for phase in ["windowTouchBegan", "windowTouchMoved", "windowTouchEnded", "windowTouchCancelled"] {
        try #require(after.count(phase) - before.count(phase) == events.filter { $0.phase == phase }.count)
    }
    for rows in groups.values {
        try #require(rows.first?.phase == "windowTouchBegan" && rows.last?.phase == "windowTouchEnded")
        try #require(rows.filter { $0.phase == "windowTouchBegan" }.count == 1)
        try #require(rows.filter { $0.phase == "windowTouchEnded" }.count == 1)
    }
    return groups.values.sorted {
        ($0.first?.timestamp ?? 0, $0.first?.x ?? 0) < ($1.first?.timestamp ?? 0, $1.first?.x ?? 0)
    }
}

func controlsNear(_ event: PlaygroundControlsContact, point: (Double, Double)) throws {
    try #require(abs(event.x - point.0) <= 0.5 && abs(event.y - point.1) <= 0.5)
}

func controlsOnLine(_ event: PlaygroundControlsContact, start: (Double, Double), end: (Double, Double)) throws {
    let dx = end.0 - start.0, dy = end.1 - start.1
    let length = hypot(dx, dy)
    if length == 0 { try controlsNear(event, point: start); return }
    let distance = abs((event.x - start.0) * dy - (event.y - start.1) * dx) / length
    let projection = ((event.x - start.0) * dx + (event.y - start.1) * dy) / length
    try #require(distance <= 0.5 && projection >= -0.5 && projection <= length + 0.5)
}

func controlsRecognizer(_ after: PlaygroundControlsDocument, before: PlaygroundControlsDocument,
                        name: String, discrete: Bool = false, padTapAfterHold: Bool = false) throws {
    try #require(!padTapAfterHold || name == "longPress")
    try #require(Array(after.recognizerTrace.prefix(before.recognizerTrace.count)) == before.recognizerTrace)
    let records = Array(after.recognizerTrace.dropFirst(before.recognizerTrace.count))
    let contacts = Array(after.windowTouchTrace.dropFirst(before.windowTouchTrace.count))
    try #require(contacts.allSatisfy { $0.hitView == "feature.pad" })
    let relevant = records.filter { $0.name == name }
    try #require(!relevant.isEmpty && relevant.first?.state == (discrete ? 3 : 1))
    try #require(relevant.last?.state == 3 && relevant.filter { $0.state == 3 }.count == 1)
    let expectedNames: Set<String> = padTapAfterHold ? [name, "padTap"] : [name]
    if padTapAfterHold {
        // This normal pad permits the tap and hold recognizers to run together.
        let taps = records.filter { $0.name == "padTap" }
        try #require(taps.count == 1)
        let tap = try #require(taps.first)
        let holdEnd = try #require(relevant.last)
        try #require(tap.state == 3 && tap.timestamp >= holdEnd.timestamp)
        try #require(after.count("padTap") == before.count("padTap") + 1)
    }
    var last = before.recognizerTrace.last?.timestamp ?? 0
    for record in records {
        let finite = [record.timestamp, record.x, record.y].allSatisfy(\.isFinite)
        try #require(finite)
        try #require(record.timestamp >= last && record.touches >= 0 && [1, 2, 3].contains(record.state))
        try #require(expectedNames.contains(record.name))
        last = record.timestamp
    }
    let callbackNames = ["tap", "padTap", "doubleTap", "longPress", "pan", "pinch", "rotation", "twoFingerTap", "twoFingerHold", "sliderChanged", "switchChanged", "textChanged", "returnKey"]
    for key in callbackNames where !expectedNames.contains(key) { try #require(after.count(key) == before.count(key)) }
    try #require(after.geometry == before.geometry)
}


func controlsScrollUnchanged(_ after: PlaygroundControlsDocument, before: PlaygroundControlsDocument) throws {
    try #require(after.text == before.text && after.textFocused == before.textFocused)
    try #require(after.slider == before.slider && after.switchOn == before.switchOn && after.advancedSliders == before.advancedSliders)
    try #require(after.panX == before.panX && after.panY == before.panY && after.pinchScale == before.pinchScale && after.rotationRadians == before.rotationRadians)
    try #require(after.touchX == before.touchX && after.touchY == before.touchY && after.recognizerTrace == before.recognizerTrace)
    for key in Set(after.counts.keys).union(before.counts.keys) where !key.hasPrefix("windowTouch") {
        try #require(after.count(key) == before.count(key))
    }
}
