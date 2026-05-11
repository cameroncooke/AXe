import Foundation
import Testing
@testable import AXe

@Suite("Accessibility Target Resolver Tests")
struct AccessibilityTargetResolverTests {
    @Test("Selector tap point uses contained switch activation frame")
    func selectorTapPointUsesContainedSwitchActivationFrame() throws {
        let roots = try decodeElements(
            """
            [
              {
                "type": "Cell",
                "frame": { "x": 0, "y": 100, "width": 390, "height": 60 },
                "AXLabel": "Weather Alerts",
                "children": [
                  {
                    "type": "Switch",
                    "frame": { "x": 300, "y": 110, "width": 50, "height": 30 },
                    "AXLabel": "Weather Alerts",
                    "AXUniqueId": "weather-alerts-switch"
                  }
                ]
              }
            ]
            """
        )

        let point = try AccessibilityTargetResolver.resolveTapPoint(roots: roots, query: .label("Weather Alerts"))

        #expect(point.x == 325)
        #expect(point.y == 125)
    }

    @Test("Matched row uses contained switch with different label")
    func matchedRowUsesContainedSwitchWithDifferentLabel() throws {
        let roots = try decodeElements(
            """
            [
              {
                "type": "Cell",
                "frame": { "x": 0, "y": 100, "width": 390, "height": 60 },
                "AXLabel": "Weather Alerts",
                "children": [
                  {
                    "type": "Switch",
                    "frame": { "x": 300, "y": 110, "width": 50, "height": 30 },
                    "AXLabel": "Off"
                  }
                ]
              }
            ]
            """
        )

        let point = try AccessibilityTargetResolver.resolveTapPoint(roots: roots, query: .label("Weather Alerts"))

        #expect(point.x == 325)
        #expect(point.y == 125)
    }

    @Test("Matched label uses sibling switch in nearest container")
    func matchedLabelUsesSiblingSwitchInNearestContainer() throws {
        let roots = try decodeElements(
            """
            [
              {
                "type": "Cell",
                "frame": { "x": 0, "y": 100, "width": 390, "height": 60 },
                "children": [
                  {
                    "type": "StaticText",
                    "frame": { "x": 16, "y": 120, "width": 140, "height": 20 },
                    "AXLabel": "Weather Alerts"
                  },
                  {
                    "type": "CheckBox",
                    "role_description": "switch",
                    "subrole": "AXSwitch",
                    "frame": { "x": 300, "y": 110, "width": 50, "height": 30 },
                    "AXValue": "0"
                  }
                ]
              }
            ]
            """
        )

        let resolution = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .label("Weather Alerts"))

        #expect(resolution.point.x == 325)
        #expect(resolution.point.y == 125)
        #expect(resolution.isSwitchLikeControl)
    }

    @Test("Matched label ignores nested sibling switch descendants")
    func matchedLabelIgnoresNestedSiblingSwitchDescendants() throws {
        let roots = try decodeElements(
            """
            [
              {
                "type": "Cell",
                "frame": { "x": 0, "y": 100, "width": 390, "height": 100 },
                "children": [
                  {
                    "type": "StaticText",
                    "frame": { "x": 16, "y": 120, "width": 140, "height": 20 },
                    "AXLabel": "Weather Alerts"
                  },
                  {
                    "type": "Cell",
                    "frame": { "x": 220, "y": 110, "width": 150, "height": 60 },
                    "children": [
                      {
                        "type": "Switch",
                        "frame": { "x": 300, "y": 125, "width": 50, "height": 30 },
                        "AXLabel": "Unrelated Nested Switch"
                      }
                    ]
                  }
                ]
              }
            ]
            """
        )

        let resolution = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .label("Weather Alerts"))

        #expect(resolution.point.x == 86)
        #expect(resolution.point.y == 130)
        #expect(!resolution.isSwitchLikeControl)
    }

    @Test("Wide switch-like rows use trailing activation point")
    func wideSwitchLikeRowsUseTrailingActivationPoint() throws {
        let roots = try decodeElements(
            """
            [
              {
                "type": "CheckBox",
                "role_description": "switch",
                "subrole": "AXSwitch",
                "frame": { "x": 16, "y": 180, "width": 370, "height": 28 },
                "AXLabel": "SwiftUI Weather Alerts",
                "AXValue": "0"
              }
            ]
            """
        )

        let point = try AccessibilityTargetResolver.resolveTapPoint(roots: roots, query: .label("SwiftUI Weather Alerts"))

        #expect(point.x == 355)
        #expect(point.y == 194)
    }

    @Test("Identifier matching accepts AXIdentifier when AXUniqueId is missing")
    func identifierMatchingAcceptsAXIdentifier() throws {
        let roots = try decodeElements(
            """
            [
              {
                "type": "Switch",
                "frame": { "x": 10, "y": 20, "width": 40, "height": 20 },
                "AXLabel": "Weather Alerts",
                "AXIdentifier": "weather-alerts-switch"
              }
            ]
            """
        )

        let point = try AccessibilityTargetResolver.resolveTapPoint(roots: roots, query: .id("weather-alerts-switch"))

        #expect(point.x == 30)
        #expect(point.y == 30)
    }

    @Test("Duplicate AXIdentifier does not identify a different ancestor")
    func duplicateAXIdentifierDoesNotIdentifyDifferentAncestor() throws {
        let roots = try decodeElements(
            """
            [
              {
                "type": "Cell",
                "frame": { "x": 0, "y": 100, "width": 390, "height": 60 },
                "children": [
                  {
                    "type": "StaticText",
                    "frame": { "x": 16, "y": 120, "width": 140, "height": 20 },
                    "AXLabel": "Unrelated Label",
                    "AXIdentifier": "shared-label-id"
                  },
                  {
                    "type": "Switch",
                    "frame": { "x": 300, "y": 110, "width": 50, "height": 30 },
                    "AXLabel": "Unrelated Switch"
                  }
                ]
              },
              {
                "type": "Cell",
                "frame": { "x": 0, "y": 200, "width": 390, "height": 60 },
                "children": [
                  {
                    "type": "StaticText",
                    "frame": { "x": 16, "y": 220, "width": 140, "height": 20 },
                    "AXLabel": "Weather Alerts",
                    "AXIdentifier": "shared-label-id"
                  },
                  {
                    "type": "Switch",
                    "frame": { "x": 100, "y": 210, "width": 50, "height": 30 },
                    "AXLabel": "Weather Alerts Switch"
                  }
                ]
              }
            ]
            """
        )

        let resolution = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .label("Weather Alerts"))

        #expect(resolution.point.x == 125)
        #expect(resolution.point.y == 225)
        #expect(resolution.isSwitchLikeControl)
    }

    @Test("Elements with same type and frame but different roles are distinct")
    func elementsWithSameTypeAndFrameButDifferentRolesAreDistinct() throws {
        let roots = try decodeElements(
            """
            [
              {
                "type": "Cell",
                "frame": { "x": 0, "y": 100, "width": 390, "height": 60 },
                "children": [
                  {
                    "type": "StaticText",
                    "frame": { "x": 16, "y": 120, "width": 140, "height": 20 },
                    "AXValue": "1"
                  },
                  {
                    "type": "CheckBox",
                    "role_description": "switch",
                    "subrole": "AXSwitch",
                    "frame": { "x": 300, "y": 110, "width": 50, "height": 30 },
                    "AXValue": "0"
                  }
                ]
              }
            ]
            """
        )

        let resolution = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .value("1"))

        #expect(resolution.point.x == 86)
        #expect(resolution.point.y == 130)
        #expect(!resolution.isSwitchLikeControl)
    }

    @Test("Resolved element preserves slider frame and AXValue")
    func resolvedElementPreservesSliderFrameAndAXValue() throws {
        let roots = try decodeElements(
            """
            [
              {
                "type": "Slider",
                "role": "AXSlider",
                "frame": { "x": 40, "y": 200, "width": 300, "height": 40 },
                "AXLabel": "Volume",
                "AXUniqueId": "volume-slider",
                "AXValue": "0.25"
              }
            ]
            """
        )

        let match = try AccessibilityTargetResolver.resolveElement(roots: roots, query: .label("Volume"), elementType: "Slider")

        #expect(match.selectorDescription == "--label 'Volume'")
        #expect(match.element.isSliderLikeControl)
        #expect(match.element.frame?.x == 40)
        #expect(match.element.normalizedValue == "0.25")
    }

    private func decodeElements(_ json: String) throws -> [AccessibilityElement] {
        let data = try #require(json.data(using: .utf8))
        return try JSONDecoder().decode([AccessibilityElement].self, from: data)
    }
}
