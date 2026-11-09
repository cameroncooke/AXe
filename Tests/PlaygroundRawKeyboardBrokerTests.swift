import Foundation
import Testing
@testable import AXe

@Suite("Ordinary raw keyboard input ownership", .serialized,
       .enabled(if: isE2EEnabled && !isDuoPlaygroundE2EEnabled))
struct PlaygroundRawKeyboardBrokerTests {
    @Test("A held raw touch refuses a key, then UP permits one Backspace")
    func retainedTouchBlocksKeyboardUntilRelease() async throws {
        let session = try await PlaygroundAgentFeatureSession.open(caseName: "raw-keyboard-ownership")
        try await session.focusField()
        _ = try await session.rawCommand(["type", "lockproof"])
        let initial = try await session.document.waitFor("focused exact keyboard seed") {
            $0.text == "lockproof" && $0.textFocused && $0.activeWindowTouches == 0
        }
        let state = try await session.core.state()
        let button = try session.core.frame(of: session.core.element("feature.tap", in: state))
        try #require(button.width > 0 && button.height > 0)
        let point = (x: button.x + button.width / 2, y: button.y + button.height / 2)
        let coordinates = ["-x", String(point.x), "-y", String(point.y)]
        var downAttempted = false
        var upAttempted = false
        do {
            downAttempted = true
            _ = try await session.rawCommand(["touch", "--down"] + coordinates)
            let held = try await session.document.waitFor("one actual raw button touch") {
                $0.activeWindowTouches == 1 && $0.windowTouchTrace.count > initial.windowTouchTrace.count
            }
            let oldIDs = Set(initial.windowTouchTrace.map(\.contactID))
            let added = held.windowTouchTrace.filter { !oldIDs.contains($0.contactID) }
            try #require(added.count == 1 && added[0].phase == "windowTouchBegan"
                && added[0].hitView == "feature.tap")
            try #require(hypot(added[0].x - point.x, added[0].y - point.y) <= 2)
            try #require(held.text == "lockproof" && held.textFocused
                && held.count("tap") == initial.count("tap"))

            // A held raw touch must prevent keyboard input through the shared owner.
            // Require its exact busy receipt; a generic transport error cannot pass.
            let refused = try await session.command(["key", "42"], allowFailure: true)
            let expectedError = "Error: Another AXe command is using the simulator. Try again when it finishes."
            try #require(refused.exitCode == 1
                && refused.output.trimmingCharacters(in: .whitespacesAndNewlines) == expectedError,
                "Raw key did not return the shared-owner busy refusal: \(refused.output)")
            try #require(try session.document.read().inputState == held.inputState,
                "The refused key changed app input or its held contact.")

            upAttempted = true
            _ = try await session.rawCommand(["touch", "--up"] + coordinates)
            try await session.requireButtonTap(after: initial)
            let released = try session.document.read()
            let contacts = try session.contacts(after: initial, in: released, count: 1)
            let contact = try #require(contacts.first)
            try #require(contact.first?.contactID == added[0].contactID
                && contact.last?.contactID == added[0].contactID)
            try #require(released.text == "lockproof" && released.textFocused
                && released.activeWindowTouches == 0)

            // Send once, after the actual release. Do not retry an uncertain keyboard command.
            _ = try await session.rawCommand(["key", "42"])
            let edited = try await session.document.waitFor("one Backspace after raw UP") {
                $0.text == "lockproo" && $0.count("textChanged") == released.count("textChanged") + 1
            }
            try #require(edited.textFocused && edited.activeWindowTouches == 0)
            try #require(edited.inputState.windowTouchTrace == released.inputState.windowTouchTrace)
            try #require(edited.count("tap") == released.count("tap")
                && edited.slider == released.slider && edited.switchOn == released.switchOn)
        } catch {
            let primary = error
            if downAttempted {
                await cleanup(session, initial: initial, coordinates: coordinates,
                    point: point, upAttempted: upAttempted)
            }
            throw primary
        }
    }

    /// Cleanup cannot supply acceptance or repeat DOWN, key input or an attempted UP.
    private func cleanup(_ session: PlaygroundAgentFeatureSession, initial: PlaygroundControlsDocument,
                         coordinates: [String], point: (x: Double, y: Double), upAttempted: Bool) async {
        do {
            if !upAttempted {
                let current = try session.document.read()
                if current.activeWindowTouches != 0 {
                    let oldIDs = Set(initial.windowTouchTrace.map(\.contactID))
                    let added = current.windowTouchTrace.filter { !oldIDs.contains($0.contactID) }
                    try #require(current.activeWindowTouches == 1 && added.count == 1
                        && added[0].phase == "windowTouchBegan" && added[0].hitView == "feature.tap"
                        && hypot(added[0].x - point.x, added[0].y - point.y) <= 2,
                        "Cannot identify the test's possible contact; no cleanup input was sent.")
                    _ = try await session.rawCommand(["touch", "--up"] + coordinates)
                }
            }
            _ = try await session.document.waitFor("release after the one owned UP attempt") {
                $0.activeWindowTouches == 0
            }
        } catch {
            Issue.record("Owned touch cleanup did not prove release; no input was repeated: \(error)")
        }
    }
}
