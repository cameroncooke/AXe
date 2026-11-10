import Foundation
import Testing

/// The matrix runs these on ordinary iPhone and iPad, with the same current CLI payload.
@Suite("Playground Ordinary Device Regression E2E", .serialized, .enabled(if: isE2EEnabled && !isDuoPlaygroundE2EEnabled))
struct PlaygroundOrdinaryRegressionTests {
    @Test("Raw and selected physical taps change one real Button", arguments: [false, true])
    func tap(selected: Bool) async throws {
        let session = try await PlaygroundAgentFeatureSession.open()
        let before = try session.document.read()
        let flags = selected ? session.selectedFlags + ["--expected-pid", String(session.pid)] : []
        let result = try await session.command(["tap", "--id", "feature.tap", "--tap-style", "physical"] + flags)
        try #require(result.exitCode == 0)
        try await session.requireButtonTap(after: before)
    }

    @Test("Raw and selected swipes deliver the measured path", arguments: [false, true])
    func swipe(selected: Bool) async throws {
        let session = try await PlaygroundAgentFeatureSession.open()
        let before = try session.document.read()
        let state = try await session.core.state()
        let frame = try session.core.frame(of: session.core.element("feature.pad", in: state))
        let x = frame.x + frame.width / 2, y = frame.y + frame.height / 2
        let args = ["swipe", "--start-x", String(x - 40), "--start-y", String(y),
            "--end-x", String(x + 40), "--end-y", String(y), "--duration", "0.4", "--delta", "10"]
        let result = try await session.command(args + (selected ? session.selectedFlags : []))
        try #require(result.exitCode == 0)
        let after = try await session.document.waitFor("one completed ordinary-device pan") {
            $0.count("pan") == before.count("pan") + 1 && $0.activeWindowTouches == 0
        }
        let contacts = Array(after.windowTouchTrace.dropFirst(before.windowTouchTrace.count))
        let first = try #require(contacts.first), last = try #require(contacts.last)
        try #require(Set(contacts.map(\.contactID)).count == 1 && first.phase == "windowTouchBegan" && last.phase == "windowTouchEnded")
        try #require(abs(first.x - (x - 40)) <= 0.5 && abs(first.y - y) <= 0.5)
        try #require(abs(last.x - (x + 40)) <= 0.5 && abs(last.y - y) <= 0.5)
        try #require(after.slider == before.slider && after.switchOn == before.switchOn && after.text == before.text)
    }

    @Test("Selected pinch releases both fingers")
    func pinch() async throws {
        let session = try await PlaygroundAgentFeatureSession.open()
        let before = try session.document.read()
        let state = try await session.core.state()
        let frame = try session.core.frame(of: session.core.element("feature.pad", in: state))
        let center = session.core.point(in: frame, x: 0.5, y: 0.5)
        let result = try await session.command(["gesture", "pinch", "-x", String(center.x), "-y", String(center.y),
            "--radius", "24", "--scale", "1.5", "--duration", "0.5"] + session.selectedFlags)
        try #require(result.exitCode == 0)
        let after = try await session.document.waitFor("completed ordinary-device pinch") {
            $0.count("pinch") == before.count("pinch") + 1 && $0.activeWindowTouches == 0 && $0.pinchScale > 1.2
        }
        let contacts = Array(after.windowTouchTrace.dropFirst(before.windowTouchTrace.count))
        let ids = Set(contacts.map(\.contactID))
        try #require(ids.count == 2)
        for id in ids {
            let events = contacts.filter { $0.contactID == id }
            try #require(events.first?.phase == "windowTouchBegan" && events.last?.phase == "windowTouchEnded")
        }
    }

    @Test("Raw and selected typing and Return reach the actual field", arguments: [false, true])
    func typeAndReturn(selected: Bool) async throws {
        let session = try await PlaygroundAgentFeatureSession.open()
        let selectedTap = selected ? session.selectedFlags + ["--expected-pid", String(session.pid)] : []
        _ = try await session.command(["tap", "--id", "feature.text", "--tap-style", "physical"] + selectedTap)
        _ = try await session.document.waitFor("ordinary-device field focus") { $0.textFocused && $0.activeWindowTouches == 0 }
        // Selected typing refuses a field that is still scrolling above the rising keyboard.
        let focused = try await session.waitForSettledKeyboard()
        let keyboardFlags = selected ? session.selectedFlags + ["--expected-pid", String(session.pid), "--focus-id", "feature.text"] : []
        let text = "A!q7"
        let result = try await session.command(["type", text] + keyboardFlags)
        try #require(result.exitCode == 0)
        let typed = try await session.document.waitFor("exact ordinary-device text") {
            $0.text == text && $0.count("textChanged") == focused.count("textChanged") + text.count
        }
        try #require(typed.windowTouchTrace.count == focused.windowTouchTrace.count)
        _ = try await session.command(["key", "40"] + keyboardFlags)
        let returned = try await session.document.waitFor("Return ended editing") {
            !$0.textFocused && $0.count("returnKey") == typed.count("returnKey") + 1 && $0.activeWindowTouches == 0
        }
        try #require(returned.text == text && returned.windowTouchTrace.count == typed.windowTouchTrace.count)
    }

    @Test("Selected discovery, direct app accessibility and PNG work on ordinary devices")
    func selectedDiscoveryAndCapture() async throws {
        let session = try await PlaygroundAgentFeatureSession.open()
        let described = try await session.command(["describe-ui", "--expected-pid", String(session.pid)] + session.selectedFlags)
        let receipt = try JSONDecoder().decode(DuoCLIResponse.self, from: Data(described.output.utf8))
        try receipt.requireSuccess("ready")
        try #require(receipt.enqueuedEventCount == 0 && receipt.cleanup == "notNeeded")
        let roots = try #require(receipt.ax?.roots)
        try #require(UIStateParser.findElement(in: roots, withIdentifier: "feature.tap") != nil)
        let context = try #require(receipt.context)
        let discovery = try await session.command(["displays", "--verbose"])
        let catalogue = try JSONDecoder().decode(DuoCatalogue.self, from: Data(discovery.output.utf8))
        try context.requireMatch(catalogue)
        let metadata = try JSONDecoder().decode(OrdinaryDiscoveryMetadata.self, from: Data(discovery.output.utf8))
        try #require(catalogue.requestedSimulatorUDID == UUID(uuidString: session.agent.udid) && !catalogue.bootIdentity.isEmpty)
        // AXe reads the guest CoreDevice display-info action in process; it has no devicectl JSON schema.
        try #require(metadata.sourceCommandType == "com.apple.coredevice.action.displayinfo"
            && metadata.sourceJSONVersion == 0 && !metadata.sourceVersion.isEmpty)
        try #require(catalogue.panels.count == 1)
        let panel = try #require(catalogue.panels.first)
        try #require(panel == catalogue.activePanel && panel.identity.displayID == 1)
        try #require(metadata.panels == [metadata.activePanel])
        try #require(metadata.activePanel.boundsOriginX == 0 && metadata.activePanel.boundsOriginY == 0)
        let finiteGeometry = [panel.nativePixelWidth, panel.nativePixelHeight, panel.boundsWidth, panel.boundsHeight]
            .allSatisfy { $0.isFinite && $0 > 0 && $0 <= 65_536 }
        try #require(finiteGeometry && panel.pointScale > 0 && panel.pointScale <= 16)
        try #require(panel.boundsWidth == panel.nativePixelWidth && panel.boundsHeight == panel.nativePixelHeight)
        // The measured rigid schema omits active. Do not invent an active flag from primary.
        switch metadata.selectionBasis {
        case "verifiedSingleIntegratedPanel":
            try #require(panel.active == nil)
        case "explicitActiveFlag":
            try #require(panel.active == true)
        default:
            throw TestError.unexpectedState("Unsupported ordinary display selection basis: \(metadata.selectionBasis)")
        }
        let rotation = try panel.rotationDegrees()
        let swapped = rotation == 90 || rotation == 270
        let logicalWidth = (swapped ? panel.nativePixelHeight : panel.nativePixelWidth) / Double(panel.pointScale)
        let logicalHeight = (swapped ? panel.nativePixelWidth : panel.nativePixelHeight) / Double(panel.pointScale)
        try #require(context.logicalWidth == logicalWidth && context.logicalHeight == logicalHeight)
        let pid = try await DuoPlaygroundSession().launch(screen: "media-pattern")
        _ = try await session.core.waitFor("ordinary capture markers") { session.core.value("media-pattern-phase", in: $0) == "0" }
        let base = try #require(ProcessInfo.processInfo.environment["AXE_E2E_ARTIFACT_DIR"])
        let output = URL(fileURLWithPath: base).appendingPathComponent("ordinary-selected-" + UUID().uuidString + ".png")
        // Screenshot takes the screen pair but not the selected-input --verbose flag.
        let flags = ["--screen-id", String(session.initialContext.screenID),
            "--screen-uuid", session.initialContext.screenUUID.uuidString,
            "--expected-boot", catalogue.bootIdentity]
        _ = try await session.command(["screenshot", "--output", output.path] + flags)
        let geometry = try PlaygroundMediaAssertions.image(Data(contentsOf: output), type: "public.png")
        try #require(geometry.width > 100 && geometry.height > 100 && pid > 0)
    }
}

private struct OrdinaryDiscoveryMetadata: Decodable {
    let selectionBasis: String
    let sourceCommandType: String
    let sourceJSONVersion: Int
    let sourceVersion: String
    let activePanel: BoundsOrigin
    let panels: [BoundsOrigin]

    struct BoundsOrigin: Decodable, Equatable {
        let boundsOriginX: Double
        let boundsOriginY: Double
    }
}
