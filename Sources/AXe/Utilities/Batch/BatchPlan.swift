import Foundation
import FBSimulatorControl

enum BatchPrimitive {
    case hidMergeable(FBSimulatorHIDEvent)
    case hidBarrier(FBSimulatorHIDEvent)
    case hostSleep(TimeInterval)
    case physicalTap(point: (x: Double, y: Double), preDelay: Double?, postDelay: Double?)
}

struct BatchPlan {
    let primitives: [BatchPrimitive]
}

