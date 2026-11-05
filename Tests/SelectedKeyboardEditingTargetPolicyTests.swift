import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Focused keyboard editing target")
struct SelectedKeyboardEditingTargetPolicyTests {
    private let logicalSize = CGSize(width: 402, height: 874)

    @Test("Typing can resize the same focused field while coordinate target checks remain exact")
    func ownedEditingUsesTheCurrentField() throws {
        let empty = try Field().node()
        var edited = Field()
        edited.AXValue = "L"
        edited.frame.width = 283.66666666666663
        let current = try edited.node()
        let original = try AgentModeTarget(empty)
        #expect(throws: (any Error).self) { try validate(current, original: original, started: false) }
        try validate(current, original: original, started: true)
        #expect(throws: (any Error).self) { try original.validate(current, allowingValueChange: true) }
    }

    @Test("An owned edit can materialize or remove a label equal to its exact ID")
    func sameIdentifierLabelFallbackSurvivesOwnedEditing() throws {
        for initiallyMaterialized in [false, true] {
            var initial = Field()
            initial.AXLabel = initiallyMaterialized ? initial.AXUniqueId : nil
            var edited = initial
            edited.AXLabel = initiallyMaterialized ? nil : edited.AXUniqueId
            edited.AXValue = "M"
            let original = try AgentModeTarget(initial.node())
            try validate(edited.node(), original: original, started: true)
        }
    }

    @Test("Label fallback does not change the strict check before the first owned key")
    func beforeFirstKeyNativeLabelMustStillMatchExactly() throws {
        var initial = Field()
        initial.AXLabel = nil
        var materialized = initial
        materialized.AXLabel = materialized.AXUniqueId
        let original = try AgentModeTarget(initial.node())
        #expect(throws: (any Error).self) {
            try validate(materialized.node(), original: original, started: false)
        }
    }

    @Test("Owned editing does not alias empty, trimmed, case-changed or distinct labels")
    func labelFallbackKeepsExactIdentity() throws {
        let initial = Field()
        let original = try AgentModeTarget(initial.node())
        for label in ["", " " + initial.AXUniqueId, initial.AXUniqueId + " ",
                      initial.AXUniqueId.uppercased(), "Different field"] {
            var changed = initial
            changed.AXLabel = label
            changed.AXValue = "M"
            #expect(throws: (any Error).self) {
                try validate(changed.node(), original: original, started: true)
            }
        }
        var explicit = Field()
        explicit.AXLabel = "Stable label"
        var removed = explicit
        removed.AXLabel = nil
        #expect(throws: (any Error).self) {
            try validate(removed.node(), original: AgentModeTarget(explicit.node()), started: true)
        }
    }

    @Test("The first owned key still requires the original value and frame")
    func firstKeyIsStrict() throws {
        let original = try AgentModeTarget(Field().node())
        try validate(Field().node(), original: original, started: false)
        var valueOnly = Field(); valueOnly.AXValue = "L"
        var frameOnly = Field(); frameOnly.frame.x += 1
        for field in [valueOnly, frameOnly] {
            #expect(throws: (any Error).self) { try validate(field.node(), original: original, started: false) }
        }
    }

    @Test("Owned editing cannot transfer to a different native identity or invalid focus state")
    func identityAndStateRemainStrict() throws {
        let original = try AgentModeTarget(Field().node())
        var variants: [Field] = []
        var field = Field(); field.AXUniqueId = "other"; variants.append(field)
        field = Field(); field.type = "TextArea"; variants.append(field)
        field = Field(); field.AXLabel = "Changed"; variants.append(field)
        field = Field(); field.pid = 999; variants.append(field)
        field = Field(); field.focused = false; variants.append(field)
        field = Field(); field.focused = nil; variants.append(field)
        field = Field(); field.hidden = true; variants.append(field)
        field = Field(); field.hidden = nil; variants.append(field)
        field = Field(); field.enabled = false; variants.append(field)
        field = Field(); field.enabled = nil; variants.append(field)
        for invalid in variants {
            #expect(throws: (any Error).self) { try validate(invalid.node(), original: original, started: true) }
        }
    }

    @Test("The fresh editing frame must remain positive and inside the selected display")
    func currentFrameMustStayOnTheDisplay() throws {
        let original = try AgentModeTarget(Field().node())
        var variants: [Field] = []
        var field = Field(); field.frame.width = 0; variants.append(field)
        field = Field(); field.frame.width = -1; variants.append(field)
        field = Field(); field.frame.height = -1; variants.append(field)
        field = Field(); field.frame.x = -1; variants.append(field)
        field = Field(); field.frame.y = 900; variants.append(field)
        field = Field(); field.frame.width = 403; variants.append(field)
        for invalid in variants {
            #expect(throws: (any Error).self) { try validate(invalid.node(), original: original, started: true) }
        }
    }

    @Test("Keyboard editing does not bypass the existing boot, display, rotation or hinge admission")
    func deviceContextRemainsBound() throws {
        let initial = try observation()
        let target = try AgentModeTarget(Field().node())
        let admission = AgentModeAdmission(context: SelectedHIDContext(initial), expectedPID: 2934,
            screenHash: "test", nativeFingerprint: "test", target: target)
        try admission.validateContext(initial)
        for changed in [try observation(boot: "changed"), try observation(screen: 2),
                        try observation(rotation: .rot90), try observation(pose: "folded")] {
            #expect(throws: (any Error).self) { try admission.validateContext(changed) }
        }
    }

    private func validate(_ field: FBSimulatorAXNode, original: AgentModeTarget, started: Bool) throws {
        try SelectedKeyboardEditingTargetPolicy.validate(field, against: original, expectedPID: 2934,
            focusID: "weather.locationsSheet", logicalSize: logicalSize, editingStarted: started)
    }

    private func observation(boot: String = "test-boot", screen: UInt32 = 1,
                             rotation: FBSimulatorHIDDisplayRotation = .rot0,
                             pose: String = "rigid") throws -> FBSimulatorHIDSessionObservation {
        try FBSimulatorHIDSessionObservation(simulatorUDID: "00000000-0000-0000-0000-000000000001",
            bootIdentity: boot, screenID: screen, screenUniqueID: "5D3C4CC2-87E2-4A57-AB7B-565B1B4F14F9", axDisplayID: screen,
            displayContext: FBSimulatorHIDDisplayContext(hidTarget: UInt64(screen),
                nativePixelSize: CGSize(width: 1206, height: 2622), scale: 3, rotation: rotation), poseRevision: pose)
    }

    private struct Field: Encodable {
        struct Frame: Encodable {
            var x = 60.33333333333333
            var y = 132.0
            var width = 309.66666666666663
            var height = 19.666666666666657
        }
        var type = "TextField"
        var AXUniqueId = "weather.locationsSheet"
        var AXLabel: String? = nil
        var AXValue = "Search for a city, airport, or country"
        var frame = Frame()
        var pid: Int32 = 2934
        var focused: Bool? = true
        var enabled: Bool? = true
        var hidden: Bool? = false
        func node() throws -> FBSimulatorAXNode {
            try JSONDecoder().decode(FBSimulatorAXNode.self, from: JSONEncoder().encode(self))
        }
    }
}
