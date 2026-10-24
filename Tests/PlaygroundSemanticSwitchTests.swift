import Foundation
import Testing

@Suite("Playground Semantic Switch E2E", .serialized, .enabled(if: isE2EEnabled))
struct PlaygroundSemanticSwitchTests {
    @Test("Semantic switch activation reports and causes a real state change")
    func switchValueChange() async throws { try await verifySemanticSwitch(position: .outer0, tabletop: false) }
}

@Suite("Playground Duo Semantic Switch E2E", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundDuoSemanticSwitchTests {
    @Test("The open inner landscape switch changes through native activation")
    func innerSwitchValueChange() async throws { try await verifySemanticSwitch(position: .inner90, tabletop: false) }
    @Test("The tabletop inner landscape switch changes through native activation")
    func tabletopSwitchValueChange() async throws { try await verifySemanticSwitch(position: .inner90, tabletop: true) }
}

private func verifySemanticSwitch(position: DuoControlsPosition, tabletop: Bool) async throws {
    let session = try await PlaygroundAgentFeatureSession.open(caseName: "semantic-" + position.rawValue + (tabletop ? "-tabletop" : ""), position: position)
    if tabletop {
        let device = try DuoPlaygroundSession()
        let current = try await device.catalogue()
        _ = try await device.setPose(.tabletop, boot: current.bootIdentity)
    }
    try await session.show("feature.showText")
    let before = try session.document.read()
    try #require(!before.switchOn)
    let result = try await session.command(["tap", "--semantic-press", "--id", "feature.switch",
        "--expected-pid", String(session.pid)] + session.selectedFlags)
    try #require(result.exitCode == 0)
    let value = try SemanticSwitchReceipt.decode(result.output)
    try #require(value.outcome == "switchValueChangedObserved" && value.enqueuedEventCount == 0 && value.cleanup == "notNeeded")
    try #require(value.ax.kind == "semanticPress" && value.ax.expectedPID == session.pid)
    let press = value.ax.press
    try #require(press.outcome == "switchValueChangedObserved" && press.delivery == "nativeReplyAccepted"
        && press.stateBefore == false && press.stateAfter == true && press.sendCount == 1 && press.callbackCount == 1)
    try #require(press.reply.nativeResponsePresent && press.reply.error == "0" && press.reply.value)
    let after = try await session.document.waitFor("actual switch value and one callback") {
        $0.switchOn && $0.count("switchChanged") == before.count("switchChanged") + 1 && $0.activeWindowTouches == 0
    }
    try #require(after.text == before.text && after.slider == before.slider && after.count("tap") == before.count("tap"))
    // Native AXPress can generate a guest contact. Zero AXe HID events is not a claim of zero guest touches.
    let oldIDs = Set(before.windowTouchTrace.map(\.contactID))
    let added = after.windowTouchTrace.filter { !oldIDs.contains($0.contactID) }
    for rows in Dictionary(grouping: added, by: \.contactID).values {
        try #require(rows.first?.phase == "windowTouchBegan" && rows.last?.phase == "windowTouchEnded")
    }
}

private struct SemanticSwitchReceipt: Decodable {
    struct AX: Decodable {
        struct Press: Decodable {
            struct Reply: Decodable { let nativeResponsePresent: Bool; let error: String; let value: Bool }
            let outcome: String
            let delivery: String
            let stateBefore: Bool
            let stateAfter: Bool
            let sendCount: Int
            let callbackCount: Int
            let reply: Reply
        }
        let kind: String
        let expectedPID: Int32
        let press: Press
    }
    let outcome: String
    let enqueuedEventCount: Int
    let cleanup: String
    let ax: AX
    static func decode(_ output: String) throws -> Self {
        for line in output.split(separator: "\n") where line.first == "{" {
            if let value = try? JSONDecoder().decode(Self.self, from: Data(line.utf8)) { return value }
        }
        throw TestError.invalidJSON("No semantic switch receipt: \(output)")
    }
}

@Suite("Playground Duo Interior Slider E2E", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundDuoInteriorSliderTests {
    @Test("An inner slider reaches an interior value and releases input in both recorded rotations")
    func innerSliderValue() async throws {
        for position in [DuoControlsPosition.inner90, .inner180] {
            try await verifySlider(position: position)
        }
    }

    private func verifySlider(position: DuoControlsPosition) async throws {
        let session = try await PlaygroundAgentFeatureSession.open(caseName: "inner-slider-interior-" + position.rawValue, position: position)
        let before = try session.document.read()
        try #require(abs(before.slider - 50) <= 0.07)
        let result = try await session.command(["slider", "--id", "feature.slider", "--element-type", "Slider",
            "--expected-pid", String(session.pid), "--value", "63.25"] + session.selectedFlags)
        try #require(result.exitCode == 0)
        let receipt = try session.rawReceipt(result.output)
        try #require(receipt.outcome == "reached" && receipt.cleanup == "notNeeded" && receipt.error == nil
            && receipt.quarantine == nil && receipt.context == session.initialContext)
        let percentage = try PlaygroundAgentSliderEnvelope.decode(result.output)
        try #require(percentage.ax?.kind == "sliderPercentage")
        let value = try #require(percentage.ax?.sliderValue)
        try value.requireReached(target: 63.25, initial: before.slider, events: receipt.enqueuedEventCount)
        let after = try await session.document.waitFor("inner slider at 63.25 percent with release") {
            abs($0.slider - 63.25) <= 0.07 && $0.activeWindowTouches == 0
        }
        let contacts = try session.contacts(after: before, in: after, count: 1)
        let rows = try #require(contacts.first)
        try #require(rows.count >= 3 && rows.count <= receipt.enqueuedEventCount)
        let state = try await session.core.state()
        let raw = try #require(try session.core.element("feature.slider", in: state).value)
        let percent = try #require(session.core.sliderPercent(raw))
        try #require(abs(percent - 63.25) <= 0.07 && after.count("sliderChanged") > before.count("sliderChanged"))
    }
}
