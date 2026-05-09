import ArgumentParser
import Foundation

enum TapStyle: String, CaseIterable, ExpressibleByArgument {
    case automatic
    case simulator
    case physical
}

struct TapResolution {
    let point: (x: Double, y: Double)
    let isSwitchLikeControl: Bool
}

enum TapTiming {
    static let defaultHoldDuration: TimeInterval = 0.1
}
