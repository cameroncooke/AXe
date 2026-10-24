import Foundation
import Testing

/// These run serially because every case owns the foreground app and device layout.
@Suite("Playground Duo Core E2E", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundDuoCoreTests {
    @Test("Find and tap on outer portrait")
    func outerPortraitFindAndTap() async throws {
        try await withScreen(.outerPortrait) { try await PlaygroundCoreTests().findAndTap() }
    }

    @Test("Find and tap on inner landscape")
    func innerLandscapeFindAndTap() async throws {
        try await withScreen(.innerLandscape) { try await PlaygroundCoreTests().findAndTap() }
    }

    @Test("Type text on outer portrait")
    func outerPortraitTypeText() async throws {
        try await withScreen(.outerPortrait) { try await PlaygroundCoreTests().typeText() }
    }

    @Test("Type text on inner landscape")
    func innerLandscapeTypeText() async throws {
        try await withScreen(.innerLandscape) { try await PlaygroundCoreTests().typeText() }
    }

    @Test("Scroll and select a new row on outer portrait")
    func outerPortraitScrollList() async throws {
        try await withScreen(.outerPortrait) { try await PlaygroundCoreTests().scrollList() }
    }

    @Test("Scroll and select a new row on inner landscape")
    func innerLandscapeScrollList() async throws {
        try await withScreen(.innerLandscape) { try await PlaygroundCoreTests().scrollList() }
    }

    @Test("Swipe with coordinate readback on outer portrait")
    func outerPortraitSwipe() async throws {
        try await withScreen(.outerPortrait) { try await PlaygroundCoreTests().swipe() }
    }

    @Test("Swipe with coordinate readback on inner landscape")
    func innerLandscapeSwipe() async throws {
        try await withScreen(.innerLandscape) { try await PlaygroundCoreTests().swipe() }
    }

    @Test("Drag with movement and release on outer portrait")
    func outerPortraitDrag() async throws {
        try await withScreen(.outerPortrait) { try await PlaygroundCoreTests().drag() }
    }

    @Test("Drag with movement and release on inner landscape")
    func innerLandscapeDrag() async throws {
        try await withScreen(.innerLandscape) { try await PlaygroundCoreTests().drag() }
    }

    @Test("Change a SwiftUI switch both ways on outer portrait")
    func outerPortraitSwiftUISwitch() async throws {
        try await withScreen(.outerPortrait) { try await PlaygroundCoreTests().swiftUISwitchState() }
    }

    @Test("Change a SwiftUI switch both ways on inner landscape")
    func innerLandscapeSwiftUISwitch() async throws {
        try await withScreen(.innerLandscape) { try await PlaygroundCoreTests().swiftUISwitchState() }
    }

    @Test("Change a UIKit switch both ways on outer portrait")
    func outerPortraitUIKitSwitch() async throws {
        try await withScreen(.outerPortrait) { try await PlaygroundCoreTests().uiKitSwitchState() }
    }

    @Test("Change a UIKit switch both ways on inner landscape")
    func innerLandscapeUIKitSwitch() async throws {
        try await withScreen(.innerLandscape) { try await PlaygroundCoreTests().uiKitSwitchState() }
    }

    @Test("Set slider to 75% and 40% on outer portrait")
    func outerPortraitSlider() async throws {
        try await withScreen(.outerPortrait) { try await PlaygroundCoreTests().slider() }
    }

    @Test("Set slider to 75% and 40% on inner landscape")
    func innerLandscapeSlider() async throws {
        try await withScreen(.innerLandscape) { try await PlaygroundCoreTests().slider() }
    }

    @Test("Edit text with keys and modifiers on outer portrait")
    func outerPortraitKeyboard() async throws {
        try await withScreen(.outerPortrait) { try await PlaygroundKeyboardTests().editTextWithKeys() }
    }

    @Test("Edit text with keys and modifiers on inner landscape")
    func innerLandscapeKeyboard() async throws {
        try await withScreen(.innerLandscape) { try await PlaygroundKeyboardTests().editTextWithKeys() }
    }

    private func withScreen(_ screen: DuoCoreScreen, check: () async throws -> Void) async throws {
        let app = try DuoPlaygroundSession()
        let original = try await app.catalogue()
        var current = try await app.setPose(screen.pose, boot: original.bootIdentity)
        let identity = current.activePanel.identity
        for _ in 0..<4 {
            if try current.activePanel.rotationDegrees() == screen.rotation { break }
            current = try await app.rotateRight(catalogue: current)
        }
        try #require(current.activePanel.identity == identity)
        try #require(try current.activePanel.rotationDegrees() == screen.rotation)
        print("Core screen prepared: \(screen.rawValue), boot=\(current.bootIdentity), panel=\(identity.displayID)")
        print("Core catalogue before \(screen.rawValue): \(String(reflecting: current))")
        do {
            try await check()
        } catch {
            let originalFailure = error
            do {
                let observed = try await app.catalogue()
                print("Core catalogue after failed \(screen.rawValue): \(String(reflecting: observed))")
            } catch {
                print("Core catalogue read after failed \(screen.rawValue) also failed: \(error)")
            }
            throw originalFailure
        }
        let after = try await app.catalogue(boot: original.bootIdentity)
        print("Core catalogue after \(screen.rawValue): \(String(reflecting: after))")
        try #require(after.activePanel == current.activePanel, "The core check changed its measured display or geometry.")
    }
}

private enum DuoCoreScreen: String {
    case outerPortrait, innerLandscape

    var pose: DuoPlaygroundPose { self == .outerPortrait ? .closed : .open }
    var rotation: Int { self == .outerPortrait ? 0 : 90 }
}
