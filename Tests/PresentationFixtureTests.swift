import Testing
import Foundation

@Suite("Presentation Fixture Tests", .serialized, .enabled(if: isE2EEnabled))
struct PresentationFixtureTests {
    @Test("Describe-ui exposes new presentation fixture routes", arguments: [
        (screen: "alert-test", identifier: "alert-test-show-alert", label: "Show Alert"),
        (screen: "sheet-test", identifier: "sheet-test-open-sheet", label: "Open Sheet"),
        (screen: "context-menu-test", identifier: "context-menu-test-target", label: "Long Press Target"),
        (screen: "modal-navigation-test", identifier: "modal-navigation-test-open", label: "Open Modal Flow"),
        (screen: "long-scroll-test", identifier: "long-scroll-test-scroll-view", label: "Long Scroll Row 1")
    ])
    func describeUIExposesPresentationFixtureRoutes(
        fixture: (screen: String, identifier: String, label: String)
    ) async throws {
        try await TestHelpers.launchPlaygroundApp(to: fixture.screen)

        let uiState = try await TestHelpers.getUIState()
        let identifiedElement = UIStateParser.findElement(in: uiState, withIdentifier: fixture.identifier)
        let labeledElement = UIStateParser.findElementByLabel(in: uiState, label: fixture.label)

        #expect(identifiedElement?.frame != nil)
        #expect(labeledElement?.frame != nil)
    }

    @Test("Alert fixture exposes alert controls and applies selected action")
    func alertFixtureExposesAlertControlsAndAction() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "alert-test")

        try await TestHelpers.runAxeCommand("tap --id alert-test-show-alert", simulatorUDID: defaultSimulatorUDID)

        _ = try await waitForElement(timeout: 3) { uiState in
            UIStateParser.findElementByLabel(in: uiState, label: "Delete Draft?")
        }
        let deleteButton = try await waitForElement(timeout: 3) { uiState in
            UIStateParser.findElementByLabel(in: uiState, label: "Delete")
        }
        #expect(deleteButton.type == "Button")

        try await TestHelpers.runAxeCommand("tap --label Delete --element-type Button", simulatorUDID: defaultSimulatorUDID)

        let state = try await TestHelpers.waitForLabel(containing: "Alert State:", timeout: 3) {
            $0 == "Alert State: Deleted"
        }
        #expect(state == "Alert State: Deleted")
    }

    @Test("Sheet fixture exposes sheet content and returns updated state")
    func sheetFixtureExposesSheetContentAndState() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "sheet-test")

        try await TestHelpers.runAxeCommand("tap --id sheet-test-open-sheet", simulatorUDID: defaultSimulatorUDID)

        _ = try await waitForElement(timeout: 3) { uiState in
            UIStateParser.findElementByLabel(in: uiState, label: "Sheet Fixture")
        }
        let actionButton = try await waitForElement(timeout: 3) { uiState in
            UIStateParser.findElementByLabel(in: uiState, label: "Run Sheet Action")
        }
        #expect(actionButton.type == "Button")

        try await TestHelpers.runAxeCommand("tap --label 'Run Sheet Action' --element-type Button", simulatorUDID: defaultSimulatorUDID)
        try await TestHelpers.runAxeCommand("tap --label 'Close Sheet' --element-type Button", simulatorUDID: defaultSimulatorUDID)

        let state = try await TestHelpers.waitForLabel(containing: "Sheet State:", timeout: 3) {
            $0 == "Sheet State: Sheet action tapped"
        }
        #expect(state == "Sheet State: Sheet action tapped")
    }

    @Test("Context menu fixture exposes menu actions after long press")
    func contextMenuFixtureExposesMenuActions() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "context-menu-test")

        let initialState = try await TestHelpers.getUIState()
        let target = try #require(UIStateParser.findElement(in: initialState, withIdentifier: "context-menu-test-target"))
        let frame = try #require(target.frame)
        let centerX = Int(frame.x + frame.width / 2)
        let centerY = Int(frame.y + frame.height / 2)

        try await TestHelpers.runAxeCommand(
            "touch -x \(centerX) -y \(centerY) --down --up --delay 1.0",
            simulatorUDID: defaultSimulatorUDID
        )

        let favoriteAction = try await waitForElement(timeout: 3) { uiState in
            UIStateParser.findElementByLabel(in: uiState, label: "Favorite")
        }
        #expect(favoriteAction.frame != nil)

        try await TestHelpers.runAxeCommand("tap --label Favorite", simulatorUDID: defaultSimulatorUDID)

        let state = try await TestHelpers.waitForLabel(containing: "Context Menu State:", timeout: 3) {
            $0 == "Context Menu State: Favorited"
        }
        #expect(state == "Context Menu State: Favorited")
    }

    @Test("Modal navigation fixture exposes nested route actions")
    func modalNavigationFixtureExposesNestedRouteActions() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "modal-navigation-test")

        try await TestHelpers.runAxeCommand("tap --id modal-navigation-test-open", simulatorUDID: defaultSimulatorUDID)

        _ = try await waitForElement(timeout: 3) { uiState in
            UIStateParser.findElementByLabel(in: uiState, label: "Modal Flow")
        }
        let detailLink = try await waitForElement(timeout: 3) { uiState in
            UIStateParser.findElement(in: uiState, withIdentifier: "modal-navigation-test-detail-link")
        }
        #expect(detailLink.frame != nil)

        try await TestHelpers.runAxeCommand("tap --id modal-navigation-test-detail-link", simulatorUDID: defaultSimulatorUDID)

        _ = try await waitForElement(timeout: 3) { uiState in
            UIStateParser.findElement(in: uiState, withIdentifier: "modal-navigation-test-detail")
        }
        let completeButton = try await waitForElement(timeout: 3) { uiState in
            UIStateParser.findElement(in: uiState, withIdentifier: "modal-navigation-test-complete")
        }
        #expect(completeButton.type == "Button")
    }

    @Test("Long scroll fixture exposes a scroll container and tappable rows")
    func longScrollFixtureExposesScrollContainerAndRows() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "long-scroll-test")

        let uiState = try await TestHelpers.getUIState()
        let scrollView = UIStateParser.findElement(in: uiState, withIdentifier: "long-scroll-test-scroll-view")
        let firstRow = UIStateParser.findElement(in: uiState, withIdentifier: "long-scroll-test-row-1")

        #expect(scrollView?.frame != nil)
        #expect(firstRow?.label == "Long Scroll Row 1")
        #expect(firstRow?.frame != nil)

        try await TestHelpers.runAxeCommand("tap --id long-scroll-test-row-1", simulatorUDID: defaultSimulatorUDID)

        let state = try await TestHelpers.waitForLabel(containing: "Long Scroll Selected:", timeout: 3) {
            $0 == "Long Scroll Selected: Row 1"
        }
        #expect(state == "Long Scroll Selected: Row 1")
    }

    private func waitForElement(
        timeout: TimeInterval,
        matching predicate: (UIElement) -> UIElement?
    ) async throws -> UIElement {
        let deadline = Date().addingTimeInterval(timeout)
        var lastRootType: String?

        while Date() < deadline {
            let uiState = try await TestHelpers.getUIState()
            lastRootType = uiState.type
            if let element = predicate(uiState) {
                return element
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        throw TestError.unexpectedState("Timed out waiting for presentation fixture element. Last root type: \(lastRootType ?? "none")")
    }
}
