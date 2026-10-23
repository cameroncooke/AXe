import Foundation

/// Scalar physical value evidence; it does not expose raw native handles or app data.
struct SelectedSliderValueResult: Codable, Sendable {
    let phase = "physicalOwnedValue"
    let outcome: String
    let reason: String?
    let delivery: String
    let requestedPercent: Double
    let initialValue: Double?
    let finalValue: Double?
    let nativeTarget: Double?
    let domainMinimum: Double?
    let domainMaximum: Double?
    let tolerance: Double?
    let moves: Int
    let pickupReadPhases: Int
    let elapsedSeconds: Double
    let nativeReadDiagnostic: SliderValueNativeReadDiagnostic?
    let replayed = false
}

struct SelectedSliderValueExecution {
    let receipt: SelectedSliderValueResult
    let outcome: String
    let error: String?
    let enqueuedEventCount: Int
    let cleanup: String
}

/// The broker keeps this owner beside its common lease. Uncertainty is sticky.
@MainActor
final class SelectedSliderValueOwner {
    private var retainedOperation: SelectedSliderValueOperation?

    func run(_ operation: SelectedSliderValueOperation, percent: Double) async -> SelectedSliderValueExecution {
        if retainedOperation != nil {
            let receipt = SelectedSliderValueResult(outcome: "failed",
                reason: "Slider input owner requires external recovery. Do not repeat input.",
                delivery: "uncertain", requestedPercent: percent, initialValue: nil, finalValue: nil,
                nativeTarget: nil, domainMinimum: nil, domainMaximum: nil, tolerance: nil,
                moves: 0, pickupReadPhases: 0, elapsedSeconds: 0, nativeReadDiagnostic: nil)
            return SelectedSliderValueExecution(receipt: receipt, outcome: "rejectedBeforeInput",
                error: receipt.reason, enqueuedEventCount: 0, cleanup: "uncertain")
        }
        retainedOperation = operation
        let result = await operation.run(percent: percent)
        if result.cleanup != "uncertain" { retainedOperation = nil }
        return result
    }

    /// A general broker clear cannot discard an uncertain read child or input owner.
    func clear() {
        guard retainedOperation?.requiresExternalRecovery != true else { return }
        retainedOperation = nil
    }
}
