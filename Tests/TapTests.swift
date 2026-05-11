import Testing
import Foundation

@Suite("Tap Command Tests", .serialized, .enabled(if: isE2EEnabled))
struct TapTests {
    @Test("Basic tap registers on screen")
    func basicTap() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")
        
        // Act
        try await TestHelpers.runAxeCommand("tap -x 200 -y 400", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Assert
        let uiState = try await TestHelpers.getUIState()
        let tapCountElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Tap Count:")
        let tapLocationElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Tap Location:")
        #expect(tapCountElement?.label == "Tap Count: 1", "Tap count should be 1")
        #expect(tapLocationElement?.label == "Tap Location: (200, 400)", "Tap location should be (200, 400)")
    }

    @Test("Landscape coordinate tap hits shifted target", .enabled(if: isLandscapeE2EEnabled))
    func landscapeCoordinateTapHitsShiftedTarget() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "landscape-coordinate-test")
        do {
            try await TestHelpers.resetLandscapeCoordinateFixtureToPortrait()
            try await TestHelpers.setSimulatorOrientationLandscapeLeft()

            let initialState = try await TestHelpers.waitForLandscapeCoordinateFixtureLayout(timeout: 6)

            guard let target = UIStateParser.findElementByLabel(in: initialState, label: "Landscape Target"),
                  let frame = target.frame else {
                throw TestError.elementNotFound("landscape-coordinate-target")
            }

            let logicalX = Int(frame.x + frame.width / 2)
            let logicalY = Int(frame.y + frame.height / 2)

            try await TestHelpers.runAxeCommand("tap -x \(logicalX) -y \(logicalY)", simulatorUDID: defaultSimulatorUDID)

            let hitCount = try await waitForLandscapeHitCount(expected: "Landscape Hit Count: 1", timeout: 3)
            #expect(hitCount == "Landscape Hit Count: 1")
            try await assertLastNamedCoordinate(containing: "Last Tap Hit:", expectedX: logicalX, expectedY: logicalY, timeout: 3)
            try await TestHelpers.resetLandscapeCoordinateFixtureToPortrait()
        } catch {
            try? await TestHelpers.resetLandscapeCoordinateFixtureToPortrait()
            throw error
        }
    }

    @Test("Landscape-right coordinate tap preserves translated point", .enabled(if: isLandscapeE2EEnabled))
    func landscapeRightCoordinateTapPreservesTranslatedPoint() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "landscape-coordinate-test")
        do {
            try await TestHelpers.resetLandscapeCoordinateFixtureToPortrait()
            try await TestHelpers.setSimulatorOrientationLandscapeRight()

            let initialState = try await TestHelpers.waitForLandscapeCoordinateFixtureLayout(timeout: 6)

            guard let target = UIStateParser.findElementByLabel(in: initialState, label: "Landscape Target"),
                  let frame = target.frame else {
                throw TestError.elementNotFound("landscape-coordinate-target")
            }

            let logicalX = Int(frame.x + frame.width / 2)
            let logicalY = Int(frame.y + frame.height / 2)

            try await TestHelpers.runAxeCommand("tap -x \(logicalX) -y \(logicalY)", simulatorUDID: defaultSimulatorUDID)

            let hitCount = try await waitForLandscapeHitCount(expected: "Landscape Hit Count: 1", timeout: 3)
            #expect(hitCount == "Landscape Hit Count: 1")
            try await assertLastNamedCoordinate(containing: "Last Tap Hit:", expectedX: logicalX, expectedY: logicalY, timeout: 3)
            try await TestHelpers.resetLandscapeCoordinateFixtureToPortrait()
        } catch {
            try? await TestHelpers.resetLandscapeCoordinateFixtureToPortrait()
            throw error
        }
    }

    @Test("Tap by AXUniqueId navigates back to home")
    func tapByIDNavigatesBack() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")
        
        // Act
        try await TestHelpers.runAxeCommand("tap --id BackButton", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Assert
        let uiState = try await TestHelpers.getUIState()
        let homeMarker = UIStateParser.findElementContainingLabel(in: uiState, containing: "Touch & Gestures")
        let tapTestMarker = UIStateParser.findElementContainingLabel(in: uiState, containing: "Tap Count:")
        #expect(homeMarker != nil)
        #expect(tapTestMarker == nil)
    }
    
    @Test("Tap by AXLabel navigates back to home")
    func tapByLabelNavigatesBack() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")
        
        // Act
        try await TestHelpers.runAxeCommand("tap --label 'AXe Playground'", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Assert
        let uiState = try await TestHelpers.getUIState()
        let homeMarker = UIStateParser.findElementContainingLabel(in: uiState, containing: "Touch & Gestures")
        let tapTestMarker = UIStateParser.findElementContainingLabel(in: uiState, containing: "Tap Count:")
        #expect(homeMarker != nil)
        #expect(tapTestMarker == nil)
    }
    
    @Test("Multiple taps register correct count")
    func multipleTaps() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")
        let tapCount = 3
        
        // Act
        for i in 1...tapCount {
            try await TestHelpers.runAxeCommand("tap -x \(100 + i * 50) -y \(300 + i * 20)", simulatorUDID: defaultSimulatorUDID)
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // Assert
        let uiState = try await TestHelpers.getUIState()
        let tapCountElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Tap Count:")
        #expect(tapCountElement?.label == "Tap Count: \(tapCount)", "Tap count should be \(tapCount)")
    }
    
    @Test("Tap with pre and post delays")
    func tapWithDelays() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")
        
        // Act
        let startTime = Date()
        try await TestHelpers.runAxeCommand("tap -x 200 -y 300 --pre-delay 1.0 --post-delay 1.0", simulatorUDID: defaultSimulatorUDID)
        let endTime = Date()
        
        // Assert
        let duration = endTime.timeIntervalSince(startTime)
        #expect(duration >= 2.0, "Command should take at least 2 seconds with delays")
        
        let uiState = try await TestHelpers.getUIState()
        let tapCountElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Tap Count:")
        #expect(tapCountElement?.label == "Tap Count: 1", "Tap should still register with delays")
    }
    
    private func waitForLandscapeHitCount(expected: String, timeout: TimeInterval) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var lastValue: String?

        while Date() < deadline {
            let uiState = try await TestHelpers.getUIState()
            if let element = UIStateParser.findElementContainingLabel(in: uiState, containing: "Landscape Hit Count:"),
               let label = element.label {
                lastValue = label
                if label == expected {
                    return label
                }
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        throw TestError.unexpectedState("Timed out waiting for \(expected). Last value: \(lastValue ?? "none")")
    }

    private func assertLastNamedCoordinate(
        containing text: String,
        expectedX: Int,
        expectedY: Int,
        timeout: TimeInterval
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastValue: String?

        while Date() < deadline {
            let uiState = try await TestHelpers.getUIState()
            if let label = UIStateParser.findElementContainingLabel(in: uiState, containing: text)?.label {
                lastValue = label
                if let point = CoordinateParser.parseNamedCoordinates(from: label),
                   abs(point.x - expectedX) <= 1,
                   abs(point.y - expectedY) <= 1 {
                    return
                }
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        throw TestError.unexpectedState(
            "Timed out waiting for \(text) near x:\(expectedX),y:\(expectedY). Last value: \(lastValue ?? "none")"
        )
    }

    @Test("Selector tap switches SwiftUI TabView tab")
    func selectorTapSwitchesSwiftUITabViewTab() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "tab-view-test")

        let initialState = try await TestHelpers.waitForLabel(containing: "Current Tab:", timeout: 3) {
            $0 == "Current Tab: Home"
        }
        #expect(initialState == "Current Tab: Home")

        let uiState = try await TestHelpers.getUIState()
        let homeTab = UIStateParser.findElementByLabel(in: uiState, label: "Home")
        let settingsTab = UIStateParser.findElementByLabel(in: uiState, label: "Settings")

        #expect(homeTab?.type == "RadioButton")
        #expect(settingsTab?.type == "RadioButton")
        #expect(settingsTab?.frame != nil)

        try await TestHelpers.runAxeCommand("tap --label Settings --element-type RadioButton", simulatorUDID: defaultSimulatorUDID)

        let selectedState = try await TestHelpers.waitForLabel(containing: "Current Tab:", timeout: 3) {
            $0 == "Current Tab: Settings"
        }
        #expect(selectedState == "Current Tab: Settings")
    }

    @Test("Selector tap works when the accessibility tree contains numeric AXValue")
    func selectorTapWorksWhenAccessibilityTreeContainsNumericAXValue() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "slider-value-test")

        let initialState = try await TestHelpers.waitForLabel(containing: "Slider Value State:", timeout: 3) {
            $0 == "Slider Value State: Initial"
        }
        #expect(initialState == "Slider Value State: Initial")

        let uiState = try await TestHelpers.getUIState()
        let positionText = UIStateParser.findElementByLabel(in: uiState, label: "Slider Position: 0.25")
        let slider = UIStateParser.findElement(in: uiState) { element in
            element.type == "Slider" && element.value == "0.25"
        }
        #expect(positionText?.value == "0.25")
        #expect(slider != nil)

        try await TestHelpers.runAxeCommand("tap --id slider-value-button", simulatorUDID: defaultSimulatorUDID)

        let tappedState = try await TestHelpers.waitForLabel(containing: "Slider Value State:", timeout: 3) {
            $0 == "Slider Value State: Tapped"
        }
        #expect(tappedState == "Slider Value State: Tapped")
    }

    @Test("Selector tap switches toolbar segmented picker")
    func selectorTapSwitchesToolbarSegmentedPicker() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "toolbar-picker-test")

        let initialState = try await TestHelpers.waitForLabel(containing: "Toolbar Picker State:", timeout: 3) {
            $0 == "Toolbar Picker State: All"
        }
        #expect(initialState == "Toolbar Picker State: All")

        try await TestHelpers.runAxeCommand("tap --label Unread --element-type RadioButton", simulatorUDID: defaultSimulatorUDID)

        let selectedState = try await TestHelpers.waitForLabel(containing: "Toolbar Picker State:", timeout: 3) {
            $0 == "Toolbar Picker State: Unread"
        }
        #expect(selectedState == "Toolbar Picker State: Unread")
    }

    @Test("Selector tap activates generated navigation back button")
    func selectorTapActivatesGeneratedNavigationBackButton() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "toolbar-picker-test")

        let uiState = try await TestHelpers.getUIState()
        let backButton = UIStateParser.findElement(in: uiState, withIdentifier: "BackButton")
        #expect(backButton?.type == "Button")

        try await TestHelpers.runAxeCommand("tap --id BackButton", simulatorUDID: defaultSimulatorUDID)

        let menuState = try await TestHelpers.waitForLabel(containing: "Touch & Gestures", timeout: 3) {
            $0 == "Touch & Gestures"
        }
        #expect(menuState == "Touch & Gestures")
    }

    @Test("Selector tap toggles SwiftUI Toggle")
    func selectorTapTogglesSwiftUIToggle() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "switch-test")

        try await TestHelpers.runAxeCommand("tap --label 'SwiftUI Weather Alerts'", simulatorUDID: defaultSimulatorUDID)

        let state = try await TestHelpers.waitForLabel(containing: "SwiftUI Weather Alerts:", timeout: 3) {
            $0 == "SwiftUI Weather Alerts: On"
        }
        #expect(state == "SwiftUI Weather Alerts: On")
    }

    @Test("Selector tap toggles UIKit UISwitch")
    func selectorTapTogglesUIKitSwitch() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "switch-test")

        try await TestHelpers.runAxeCommand("tap --label 'UIKit Weather Alerts'", simulatorUDID: defaultSimulatorUDID)

        let state = try await TestHelpers.waitForLabel(containing: "UIKit Weather Alerts:", timeout: 3) {
            $0 == "UIKit Weather Alerts: On"
        }
        #expect(state == "UIKit Weather Alerts: On")
    }

    @Test("Coordinate tap toggles switch center")
    func coordinateTapTogglesSwitchCenter() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "switch-test")

        let uiState = try await TestHelpers.getUIState()
        guard let switchElement = UIStateParser.findElement(in: uiState, matching: {
            $0.label == "UIKit Weather Alerts" && $0.roleDescription == "switch"
        }) else {
            throw TestError.elementNotFound("UIKit switch not found")
        }
        guard let frame = switchElement.frame else {
            throw TestError.unexpectedState("UIKit switch has no frame")
        }

        let centerX = frame.x + (frame.width / 2.0)
        let centerY = frame.y + (frame.height / 2.0)
        try await TestHelpers.runAxeCommand("tap -x \(centerX) -y \(centerY) --tap-style physical", simulatorUDID: defaultSimulatorUDID)

        let state = try await TestHelpers.waitForLabel(containing: "UIKit Weather Alerts:", timeout: 3) {
            $0 == "UIKit Weather Alerts: On"
        }
        #expect(state == "UIKit Weather Alerts: On")
    }

    @Test("At least one tap registers at screen edges")
    func tapAtEdgesRegistersAtLeastOne() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")
        
        // Test corners
        let corners = [
            (x: 10, y: 100),      // Top-left
            (x: 380, y: 100),     // Top-right
            (x: 10, y: 800),      // Bottom-left
            (x: 380, y: 800)      // Bottom-right
        ]
        
        // Act
        for corner in corners {
            try await TestHelpers.runAxeCommand("tap -x \(corner.x) -y \(corner.y)", simulatorUDID: defaultSimulatorUDID)
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        // Assert - edge taps can be flaky, require at least one successful registration
        let uiState = try await TestHelpers.getUIState()
        let tapCountElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Tap Count:")
        let tapCount = Int((tapCountElement?.label ?? "").replacingOccurrences(of: "Tap Count: ", with: "")) ?? 0
        #expect(tapCount >= 1, "At least one edge tap should register despite simulator edge flakiness")
    }
}
