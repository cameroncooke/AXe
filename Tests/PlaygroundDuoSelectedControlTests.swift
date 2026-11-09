import Foundation
import Testing

enum PlaygroundSwitchPosition: String, CaseIterable {
    case outer0, inner90, inner180, tabletop180, outer90
    var pose: DuoPlaygroundPose { self == .tabletop180 ? .tabletop : rawValue.hasPrefix("outer") ? .closed : .open }
    var rotation: Int {
        switch self { case .outer0: return 0; case .inner90, .outer90: return 90; case .inner180, .tabletop180: return 180 }
    }
}

@Suite("Playground Duo Selected Switch", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundDuoSelectedSwitchTests {
    @Test("Selected switch uses current native identity once", arguments: PlaygroundSwitchPosition.allCases, ["omitted", "physical", "automatic"])
    func nativeSwitch(position: PlaygroundSwitchPosition, style: String) async throws {
        try await withDuoPlaygroundScreen(pose: position.pose, rotation: position.rotation) {
            let app = try await PlaygroundControlsSession()
            if position == .outer90 { try await app.show("feature.showText") }
            let before = try app.documents.read()
            let nativeType = try await controlsElement(app, id: "feature.switch").type
            try #require(["Switch", "CheckBox"].contains(nativeType))
            var arguments = ["tap", "--id", "feature.switch", "--expected-pid", String(app.pid), "--element-type", nativeType]
            if style != "omitted" { arguments += ["--tap-style", style] }
            let receipt = try await app.selected(arguments)
            try #require(receipt.enqueuedEventCount > 0)
            let after = try await app.documents.waitFor("exactly one real switch callback") {
                $0.switchOn && $0.count("switchChanged") == before.count("switchChanged") + 1 && $0.activeWindowTouches == 0
            }
            try #require(after.text == before.text && after.slider == before.slider && after.count("tap") == before.count("tap"))
            try after.requireClear()
            try app.preserveState("switch-final")
        }
    }

    @Test("Selected coordinate centre changes the real switch once", arguments: PlaygroundSwitchPosition.allCases)
    func coordinateSwitch(position: PlaygroundSwitchPosition) async throws {
        try await withDuoPlaygroundScreen(pose: position.pose, rotation: position.rotation) {
            let app = try await PlaygroundControlsSession()
            if position == .outer90 { try await app.show("feature.showText") }
            let frame = try await app.frame("feature.switch")
            let point = (frame.x + frame.width / 2, frame.y + frame.height / 2)
            let before = try app.documents.read()
            _ = try await app.selected(["tap", "-x", String(point.0), "-y", String(point.1)])
            let after = try await app.documents.waitFor("one coordinate switch callback and release") {
                $0.switchOn && $0.count("switchChanged") == before.count("switchChanged") + 1 && $0.activeWindowTouches == 0
            }
            try app.requireContact(after, since: before, start: point, end: point)
        }
    }

    @Test("Inactive screen and stale process refuse switch input", arguments: [DuoControlsPosition.outer0, .inner90], [false, true])
    func rejectedSwitch(position: DuoControlsPosition, stalePID: Bool) async throws {
        try await withDuoPlaygroundScreen(pose: position.pose, rotation: position.rotation) {
            let app = try await PlaygroundControlsSession()
            if position == .outer90 { try await app.show("feature.showText") }
            let before = try app.documents.read()
            let inactive = try #require(app.catalogue.panels.first { $0.identity != app.catalogue.activePanel.identity })
            let panel = stalePID ? app.catalogue.activePanel : inactive
            let nativeType = try await controlsElement(app, id: "feature.switch").type
            let output = try await app.app.run(["tap", "--id", "feature.switch", "--element-type", nativeType, "--tap-style", "physical",
                "--expected-pid", String(stalePID ? app.pid + 1 : app.pid), "--input-mode", "selected",
                "--screen-id", String(panel.identity.displayID), "--screen-uuid", panel.identity.uniqueID.uuidString, "--verbose"], allowFailure: true)
            try #require(output.exitCode != 0)
            let result = try controlsReceipt(output.output)
            try #require(result.error != nil && result.outcome == "failedBeforeInput" && result.enqueuedEventCount == 0 && result.cleanup == "notNeeded" && result.quarantine == nil)
            let after = try app.documents.read()
            try #require(after.switchOn == before.switchOn && after.count("switchChanged") == before.count("switchChanged"))
            try #require(after.windowTouchTrace.count == before.windowTouchTrace.count)
            try after.requireClear()
            try await app.freshTap()
        }
    }
}

@Suite("Playground Duo Tap Styles", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundDuoTapStyleTests {
    @Test("Each selected tap style supports exact ID and coordinates standalone and in one-step batch",
        arguments: [DuoControlsPosition.outer0, .inner90], ["physical", "simulator", "automatic"])
    func style(position: DuoControlsPosition, style: String) async throws {
        try await withDuoPlaygroundScreen(pose: position.pose, rotation: position.rotation) {
            let app = try await PlaygroundControlsSession()
            for batch in [false, true] {
                for coordinate in [false, true] {
                    let before = try app.documents.read()
                    let frame = try await app.frame("feature.tap")
                    let target = coordinate ? ["-x", String(frame.x + frame.width / 2), "-y", String(frame.y + frame.height / 2)]
                        : ["--id", "feature.tap", "--element-type", "Button", "--expected-pid", String(app.pid)]
                    let arguments = ["tap"] + target + ["--tap-style", style]
                    let receipt: PlaygroundControlsReceipt
                    if batch {
                        let output = try await app.app.run(["batch", "--step", arguments.map(controlsQuote).joined(separator: " ")] + app.selection())
                        let step = try controlsBatchReceipts(output.output).only()
                        try #require(step.status == "completed" && step.index == 1 && step.totalSteps == 1)
                        receipt = try #require(step.response)
                    } else { receipt = try await app.selected(arguments) }
                    try receipt.requireCompleted()
                    let after = try await app.documents.waitFor("one actual Button callback for style \(style)") {
                        $0.count("tap") == before.count("tap") + 1 && $0.activeWindowTouches == 0
                    }
                    try #require(after.text == before.text && after.slider == before.slider && after.switchOn == before.switchOn)
                    try after.requireClear()
                }
            }
            try app.preserveState("tap-styles-final")
        }
    }
}

func controlsQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
func controlsReceipt(_ output: String) throws -> PlaygroundControlsReceipt {
    let line = try #require(output.split(separator: "\n").first { $0.first == "{" })
    return try JSONDecoder().decode(PlaygroundControlsReceipt.self, from: Data(line.utf8))
}
struct PlaygroundControlsBatchReceipt: Decodable {
    let index: Int
    let totalSteps: Int
    let status: String
    let response: PlaygroundControlsReceipt?
    let requestID: UUID?
    let error: String?
    let hostWait: PlaygroundControlsHostWait?
}
struct PlaygroundControlsHostWait: Decodable { let requestedSeconds: Double; let elapsedSeconds: Double; let outcome: String }
func controlsBatchReceipts(_ output: String) throws -> [PlaygroundControlsBatchReceipt] {
    try output.split(separator: "\n").filter { $0.first == "{" }.map {
        try JSONDecoder().decode(PlaygroundControlsBatchReceipt.self, from: Data($0.utf8))
    }
}
extension Array where Element == PlaygroundControlsBatchReceipt {
    func only() throws -> PlaygroundControlsBatchReceipt { try #require(count == 1); return self[0] }
}

func controlsElement(_ app: PlaygroundControlsSession, id: String) async throws -> UIElement {
    let raw = try await app.app.run(["describe-ui"])
    let roots = try UIStateParser.parseDescribeUIRoots(raw.output)
    return try #require(UIStateParser.findElement(in: roots, withIdentifier: id))
}
