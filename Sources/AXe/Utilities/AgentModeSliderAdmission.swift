import Foundation
import FBSimulatorControl

/// The native slider worker invokes these checks before returning a sample or adjusting its owned handle.
struct AgentModeSliderAdmission: FBSimulatorSliderAdmissionGuard {
    let admission: AgentModeAdmission
    private let target: AgentModeTarget

    init(_ admission: AgentModeAdmission) throws {
        guard let target = admission.target, target.type == "Slider", target.pid == admission.expectedPID else {
            throw AgentModeFailure("unsupportedSliderReference", "Slider admission requires the current native Slider target in the expected process.")
        }
        self.admission = admission
        self.target = target
    }

    func validateScreen(_ roots: [FBSimulatorAXNode], observation: FBSimulatorHIDSessionObservation,
                        allowingValueChange: Bool) throws {
        try admission.validateContext(observation)
        if !allowingValueChange {
            try admission.validateScreen(roots)
            return
        }
        guard let kind = admission.selectorKind, let value = admission.selectorValue else {
            throw AgentModeFailure("unsupportedSliderReference", "The slider admission has no native selector.")
        }
        let snapshot = try AgentModeSnapshot(roots: roots)
        let node = try snapshot.sliderNode(kind: kind, value: value)
        try target.validate(node, allowingValueChange: true)
    }

    func validateTarget(_ capabilities: FBSimulatorSliderCapabilities, allowingValueChange: Bool) throws {
        try admission.validateContext(capabilities.observation.sessionObservation())
        let node = capabilities.node
        guard node.type == "Slider", node.pid == admission.expectedPID,
              node.enabled == true, node.hidden == false else {
            throw AgentModeFailure("sliderNotReady", "The native Slider is no longer visible and enabled in the expected process.")
        }
        try target.validate(node, allowingValueChange: allowingValueChange)
        _ = try capabilities.requireDomain()
    }
}
