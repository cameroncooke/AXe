import Foundation
import CoreGraphics

struct DuoControlsState: Encodable {
    let fixtureVersion = 6
    let traceScope = "duo-controls-page"
    let generation: UUID
    let pid: Int32
    let sequence: Int
    let event: String
    let counts: [String: Int]
    let advancedSliders: [String: Float]
    let waitTargetVisible: Bool
    let waitDuplicateVisible: Bool
    let targetAppearedUptime: TimeInterval
    let scheduleGeneration: Int
    let slider: Float
    let switchOn: Bool
    let text: String
    let textFocused: Bool
    let keyboardVisible: Bool
    let listOffsetY: Double
    let pageOffsetY: Double
    let canvasOffsetX: Double
    let canvasOffsetY: Double
    let pinchScale: Double
    let rotationRadians: Double
    let panX: Double
    let panY: Double
    let touchX: Double
    let touchY: Double
    let width: Double
    let height: Double
    let interfaceOrientation: Int
    let windowTraceLimit = 4096
    let windowTraceDropped: Int
    let activeWindowTouches: Int
    let windowFirstX: Double
    let windowFirstY: Double
    let windowLastX: Double
    let windowLastY: Double
    let windowTouchTrace: [DuoControlsContact]
    let recognizerTraceDropped: Int
    let recognizerTrace: [DuoControlsRecognizerEvent]
    let frames: [DuoControlsFrame]
    let geometry: [String: DuoControlsRect]
}

struct DuoControlsContact: Codable {
    let contactID: Int
    let phase: String
    let x: Double
    let y: Double
    let timestamp: TimeInterval
    let activeTouches: Int
    let hitView: String
}

struct DuoControlsRecognizerEvent: Codable {
    let name: String
    let state: Int
    let touches: Int
    let timestamp: TimeInterval
    let x: Double
    let y: Double
}

struct DuoControlsFrame: Codable {
    let className: String
    let id: String
    let frame: String
    let bounds: String
    let hidden: Bool
    let alpha: Double
    let inWindow: Bool
    let subviewCount: Int
    let ambiguous: Bool

    enum CodingKeys: String, CodingKey {
        case className = "class"
        case id, frame, bounds, hidden, alpha, inWindow, subviewCount, ambiguous
    }
}

struct DuoControlsRect: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = Double(rect.minX)
        y = Double(rect.minY)
        width = Double(rect.width)
        height = Double(rect.height)
    }
}
