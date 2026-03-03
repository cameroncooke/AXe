import Foundation
import FBSimulatorControl

enum BatchPrimitive {
    case hidMergeable(FBSimulatorHIDEvent)
    case hidBarrier(FBSimulatorHIDEvent)
    case hostSleep(TimeInterval)
}

struct BatchPlan {
    let primitives: [BatchPrimitive]
}

