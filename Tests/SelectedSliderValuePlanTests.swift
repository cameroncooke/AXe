import Foundation
import Testing
@testable import AXe

@Suite("Selected slider path planning")
struct SelectedSliderValuePlanTests {
    // These scalar samples are from the failed 100 -> 63.25 outer-panel command.
    // This checks the correction math; physical target/release checks remain in the existing UI case.
    private let target = 63.25
    private let tolerance = 0.07
    private func nativePixel(_ x: Double) -> Double {
        (x * 3).rounded(.toNearestOrAwayFromZero) / 3
    }

    @Test func firstIntervalKeepsThumbTakeUpMargin() {
        let previousX = 339.6666666666667
        let currentX = 278.3333333333333
        let value = 84.6307373046875
        let slope = (value - 100) / (currentX - previousX)
        let proposed = SliderValuePathPlan.correctionGain(iteration: 1) * (target - value) / slope
        let next = nativePixel(currentX + max(proposed, currentX - previousX))
        #expect(abs(next - 235.66666666666666) < 0.000001)
        #expect(next < currentX && next > 207)
    }

    @Test func recordedCleanIntervalReachesTargetOnThirdPath() {
        let previousX = 278.3333333333333
        let currentX = 235.66666666666666
        let previousValue = 84.6307373046875
        let value = 71.85629272460938
        let slope = (value - previousValue) / (currentX - previousX)
        let proposed = SliderValuePathPlan.correctionGain(iteration: 2) * (target - value) / slope
        let next = nativePixel(currentX + max(proposed, currentX - previousX))
        let predicted = value + (next - currentX) * slope
        #expect(next == 207)
        #expect(next < currentX && abs(next - currentX) <= abs(currentX - previousX))
        #expect(abs(predicted - target) <= tolerance)
        #expect(predicted >= target - tolerance)
    }

    @Test func pathAdmissionIncludesPacingSettleAndRelease() {
        // The failure admitted a fourth path with only 287 ms before the release reserve.
        // A path needs 275 ms of pacing, the 400 ms settle and the 1.5 s release reserve.
        #expect(!SliderValuePathPlan.canBegin(remainingSeconds: 1.5 + 0.287, releaseReserveSeconds: 1.5))
        #expect(!SliderValuePathPlan.canBegin(remainingSeconds: 2.175, releaseReserveSeconds: 1.5))
        #expect(SliderValuePathPlan.canBegin(remainingSeconds: 2.176, releaseReserveSeconds: 1.5))
        #expect(!SliderValuePathPlan.canBegin(remainingSeconds: .infinity, releaseReserveSeconds: 1.5))
        #expect(!SliderValuePathPlan.canBegin(remainingSeconds: .nan, releaseReserveSeconds: 1.5))
    }
}
