import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Public agent tap default style")
struct AgentTapDefaultStyleTests {
    enum Target: CaseIterable, Sendable {
        case reference, selector, coordinates
        var arguments: [String] {
            switch self {
            case .reference: return ["--ref", "e2"]
            case .selector: return ["--label", "Action", "--element-type", "Button"]
            case .coordinates: return ["-x", "20", "-y", "30"]
            }
        }
    }
    enum Style: CaseIterable, Equatable, Sendable {
        case omitted, physical, automatic, simulator
        var arguments: [String] {
            switch self {
            case .omitted: return []
            case .physical: return ["--tap-style", "physical"]
            case .automatic: return ["--tap-style", "automatic"]
            case .simulator: return ["--tap-style", "simulator"]
            }
        }
        var expected: SelectedTapStyle {
            switch self {
            case .omitted, .physical: return .physical
            case .automatic: return .automatic
            case .simulator: return .simulator
            }
        }
    }

    @Test("Omission is physical; each explicit style remains exact", arguments: Target.allCases, Style.allCases)
    func publicRequestUsesDocumentedStyle(target: Target, style: Style) throws {
        let table = "00000000-0000-0000-0000-000000000002"
        let command = try Tap.parse(["--agent", "--udid", "00000000-0000-0000-0000-000000000001",
            "--snapshot-id", table] + target.arguments + style.arguments)
        try command.validate()
        let outer = try command.agentRequest()
        let request = try #require(outer.agent)
        #expect(outer.version == SelectedHIDRequest.version && request.kind == .tap)
        #expect(request.tapStyle == style.expected && request.snapshotID == UUID(uuidString: table))
        switch target {
        case .reference: #expect(request.ref == "e2" && request.point == nil && request.selectorKind == nil)
        case .selector: #expect(request.selectorKind == .label && request.selectorValue == "Action" && request.elementType == "Button")
        case .coordinates: #expect(request.point?.x == 20 && request.point?.y == 30 && request.ref == nil)
        }
        // This is the actual adapter result, not a hand-built native request.
        let ax = SelectedAXRequest(kind: .tap, expectedPID: 1234, endpoint: nil,
            selectorKind: nil, selectorValue: nil, preDelay: 0, postDelay: 0,
            tapStyle: request.tapStyle,
            nativeTarget: .nativeObject(identity: .init(pid: 1234, objectID: 101), elementType: "Button"))
        #expect((try SelectedOpaqueFrameTapAdmission.make(for: ax) != nil) == (style.expected == .physical))
    }

    @Test("Legacy parsing keeps omission and explicit styles unchanged", arguments: Style.allCases)
    func legacyDefaultsStaySeparate(style: Style) throws {
        let command = try Tap.parse(["--udid", "00000000-0000-0000-0000-000000000001",
            "-x", "20", "-y", "30"] + style.arguments)
        try command.validate()
        #expect(!command.agentMode.enabled && command.selectedInput.mode == .legacy)
        #expect(command.tapStyle?.rawValue == (style == .omitted ? nil : style.expected.rawValue))
    }
}
