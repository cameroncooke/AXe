import AXeCore
import Foundation
import FBSimulatorControl

extension AgentModeController {
    func nativeRequest(_ outer: SelectedHIDRequest, mode: AgentModeRequest, pid: Int32, context: SelectedHIDContext,
                               snapshot: AgentModeSnapshot, cached: Record?,
                               binding: AgentBatchReferencePlan.ResolvedTarget? = nil) throws -> SelectedHIDRequest {
        guard pid > 0, let uuid = UUID(uuidString: context.screenUUID) else {
            throw AgentModeFailure.missingContext
        }
        var plannedPrimitives: [SelectedHIDPrimitive] = []
        var plannedPath: SelectedHIDPath?
        var plannedPinch: SelectedHIDPinch?
        var plannedAX: SelectedAXRequest?
        var plannedKeyboard: SelectedKeyboardRequest?
        var node: FBSimulatorAXNode?
        var chosenTarget: SelectedNativeTarget?
        if let binding {
            let current = try snapshot.match(target: binding.nativeTarget)
            try AgentModeTarget(binding.node, nativeTarget: binding.nativeTarget).validate(current)
            node = current
            chosenTarget = binding.nativeTarget
        } else if let ref = mode.ref, let cached {
            let original: FBSimulatorAXNode
            if mode.kind == .drag {
                original = try cached.snapshot.dragNode(ref: ref)
            } else if mode.kind == .pinch {
                original = try cached.snapshot.pinchNode(ref: ref)
            } else if mode.kind == .sliderEndpoint || mode.kind == .sliderPercentage {
                original = try cached.snapshot.sliderNode(ref: ref)
            } else {
                let action: RuntimeElementAction
                switch mode.kind {
                case .typeText, .keyPress, .keyCombo, .keySequence: action = .typeText
                case .swipe: action = .swipeWithin
                case .hold: action = .longPress
                default: action = .tap
                }
                original = try cached.snapshot.node(ref: ref, requiredAction: action)
            }
            let chosen = try cached.snapshot.target(ref: ref)
            let freshTarget = try snapshot.match(target: chosen)
            try AgentModeTarget(original, nativeTarget: chosen).validate(freshTarget)
            node = freshTarget
            if mode.kind == .tap, mode.tapStyle == nil || mode.tapStyle == .physical,
               freshTarget.type == "Button" {
                chosenTarget = try snapshot.physicalButtonExecutionTarget(reference: chosen,
                    node: freshTarget, context: context)
            } else { chosenTarget = chosen }
        } else if let kind = mode.selectorKind, let value = mode.selectorValue {
            switch mode.kind {
            case .typeText, .keyPress, .keyCombo, .keySequence:
                let ref = try snapshot.reference(id: value, action: .typeText)
                node = try snapshot.node(ref: ref, requiredAction: .typeText)
            default:
                node = try snapshot.match(kind: kind, value: value, type: mode.elementType)
            }
        } else if let selector = mode.tapSelector {
            node = try snapshot.match(selector, type: mode.elementType, context: context)
        }
        if let node, chosenTarget == nil {
            let selector = try snapshot.uniqueSelector(for: node)
            chosenTarget = .semantic(kind: selector.kind, value: selector.value, elementType: node.type)
        }
        var admission = AgentModeAdmission(context: context, expectedPID: pid,
            visibleFingerprint: snapshot.visibleFingerprint,
            target: try node.map { try AgentModeTarget($0, nativeTarget: chosenTarget) }, nativeTarget: chosenTarget)
        if case let .semantic(kind, value, _)? = chosenTarget {
            admission.selectorKind = kind
            admission.selectorValue = value
        }
        switch mode.kind {
        case .describe, .read, .focusAndType: throw AgentModeFailure("invalidAction", "A description or reference read is not an input action.")
        case .tap:
            if let node {
                guard let chosenTarget else { throw AgentModeFailure("unsupportedIdentity", "AXe could not resolve the tap target to one control, so nothing was sent. \(AgentModeFailure.actFromCapture)") }
                plannedAX = SelectedAXRequest(kind: .tap, expectedPID: pid,
                    endpoint: nil, selectorKind: nil, selectorValue: nil,
                    preDelay: mode.preDelay, postDelay: mode.postDelay, elementType: node.type, tapStyle: mode.tapStyle,
                    nativeTarget: chosenTarget)
            } else if let point = mode.point {
                let style = try (mode.tapStyle ?? .physical).resolved(for: nil)
                if mode.preDelay > 0 { plannedPrimitives.append(.delay(mode.preDelay)) }
                plannedPrimitives += try style.primitives(x: point.x, y: point.y)
                if mode.postDelay > 0 { plannedPrimitives.append(.delay(mode.postDelay)) }
            } else { throw AgentModeFailure("missingTarget", "The tap target is no longer on screen, so nothing was sent. \(AgentModeFailure.actFromCapture)") }
        case .hold:
            guard let node else {
                throw AgentModeFailure("missingHoldTarget", "The fresh hold target is unavailable.")
            }
            guard let chosenTarget else { throw AgentModeFailure("unsupportedIdentity", "AXe could not resolve the press target to one control, so nothing was sent. \(AgentModeFailure.actFromCapture)") }
            plannedAX = SelectedAXRequest(kind: .hold, expectedPID: pid,
                endpoint: nil, selectorKind: nil, selectorValue: nil,
                preDelay: 0, postDelay: 0, elementType: node.type, holdDuration: mode.duration, nativeTarget: chosenTarget)
        case .doubleTap:
            guard let node, let timing = mode.doubleTapTiming else {
                throw AgentModeFailure("missingDoubleTapTarget", "The fresh double-tap target or timing is unavailable.")
            }
            guard let chosenTarget else { throw AgentModeFailure("unsupportedIdentity", "AXe could not resolve the double-tap target to one control, so nothing was sent. \(AgentModeFailure.actFromCapture)") }
            plannedAX = SelectedAXRequest(kind: .doubleTap, expectedPID: pid,
                endpoint: nil, selectorKind: nil, selectorValue: nil,
                preDelay: mode.preDelay, postDelay: mode.postDelay,
                elementType: node.type, doubleTapTiming: timing, nativeTarget: chosenTarget)
        case .pinch:
            guard let node, let geometry = mode.pinch, let frame = node.frame else {
                throw AgentModeFailure("missingPinchTarget", "The fresh pinch area or geometry is unavailable.")
            }
            let selector = try snapshot.uniqueSelector(for: node)
            _ = try snapshot.pinchNode(kind: selector.kind, value: selector.value, type: node.type)
            plannedPinch = geometry.selected(at: CGPoint(x: frame.midX, y: frame.midY),
                duration: mode.duration, preDelay: mode.preDelay, postDelay: mode.postDelay)
        case .sliderPercentage:
            guard let node, node.type == "Slider", let percentage = mode.sliderPercentage else {
                throw AgentModeFailure("missingSliderTarget", "The fresh slider target or percentage is unavailable.")
            }
            let selector = try snapshot.uniqueSelector(for: node)
            let endpoint = SelectedAXRequest.endpoint(forPercentage: percentage)
            plannedAX = SelectedAXRequest(kind: endpoint == nil ? .sliderPercentage : .sliderEndpoint,
                expectedPID: pid,
                endpoint: endpoint, selectorKind: selector.kind, selectorValue: selector.value,
                preDelay: 0, postDelay: 0, elementType: node.type, percentage: endpoint == nil ? percentage : nil)
        case .sliderEndpoint:
            guard let node, node.type == "Slider", let endpoint = mode.sliderEndpoint else {
                throw AgentModeFailure("missingSliderTarget", "The fresh slider target or endpoint is unavailable.")
            }
            let selector = try snapshot.uniqueSelector(for: node)
            plannedAX = SelectedAXRequest(kind: .sliderEndpoint, expectedPID: pid,
                endpoint: endpoint, selectorKind: selector.kind, selectorValue: selector.value,
                preDelay: 0, postDelay: 0, elementType: node.type)
        case .keyPress, .keyCombo, .keySequence:
            guard let node, let chosenTarget, let events = mode.keyEvents else {
                throw AgentModeFailure("unsupportedKeyTarget", "Keyboard input requires a chosen focused native field.")
            }
            try SelectedKeyboardFocusPolicy.validate(node, expectedPID: pid, fieldTarget: chosenTarget)
            plannedKeyboard = SelectedKeyboardRequest(expectedPID: pid, fieldTarget: chosenTarget, events: events)
        case .typeText:
            guard let node, let chosenTarget, let text = mode.text, !text.isEmpty,
                  text.utf8.count <= SelectedKeyboardRequest.maximumTextBytes else {
                throw AgentModeFailure("unsupportedTextTarget", "Typing requires a chosen focused native field and bounded text.")
            }
            try SelectedKeyboardFocusPolicy.validate(node, expectedPID: pid, fieldTarget: chosenTarget)
            plannedKeyboard = SelectedKeyboardRequest(expectedPID: pid, fieldTarget: chosenTarget,
                events: try SelectedKeyboardRequest.primitives(from: SelectedKeyboardRequest.textEvent(text)))
        case .swipe:
            guard let node, let ref = mode.ref, let cached, let direction = mode.direction,
                  let original = cached.snapshot.elements.first(where: { $0.ref == ref }) else {
                throw AgentModeFailure("missingSwipeTarget", "The swipe target is unavailable.")
            }
            let plan = try AgentModeSwipePlanner.plan(target: node, snapshot: snapshot,
                logicalSize: CGSize(width: context.logicalWidth, height: context.logicalHeight),
                role: original.role, direction: direction, distance: mode.distance, nativeTarget: chosenTarget)
            let points = plan.points
            plannedPath = SelectedHIDPath(kind: .swipe, startX: points.from.x, startY: points.from.y,
                endX: points.to.x, endY: points.to.y, duration: mode.duration, delta: 50,
                preDelay: mode.preDelay, postDelay: mode.postDelay, endsAtRest: true)
        case .drag:
            guard let node, let frame = node.frame, let destination = mode.destination,
                  frame.isUsableAgentFrame else {
                throw AgentModeFailure("missingDragTarget", "The fresh native drag target has no valid frame.")
            }
            let bounds = CGRect(x: 0, y: 0, width: context.logicalWidth, height: context.logicalHeight)
            let start = CGPoint(x: frame.midX, y: frame.midY)
            let end = CGPoint(x: destination.x, y: destination.y)
            guard bounds.contains(start), bounds.contains(end) else {
                throw AgentModeFailure("invalidDragGeometry", "The drag start and destination must be inside the current selected display.")
            }
            plannedPath = SelectedHIDPath(kind: .drag, startX: start.x, startY: start.y,
                endX: end.x, endY: end.y, duration: mode.duration, steps: mode.steps,
                preDelay: mode.preDelay, postDelay: mode.postDelay)
        case .complete:
            guard mode.snapshotID != nil, outer.hinge == nil, outer.rotation == nil,
                  outer.keyboard == nil, outer.ax == nil, outer.home == nil, outer.button == nil,
                  outer.pinch == nil, outer.gesture == nil, outer.path != nil || !outer.primitives.isEmpty else {
                throw AgentModeFailure("unsupportedCompleteAction", "This agent slice supports complete coordinate paths and taps only.")
            }
            plannedPath = outer.path
            plannedPrimitives = outer.primitives
        }
        let request = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: outer.requestID,
            screenID: context.screenID, screenUUID: uuid, operation: .complete, token: nil,
            primitives: plannedPrimitives, path: plannedPath, pinch: plannedPinch, ax: plannedAX,
            keyboard: plannedKeyboard, agentAdmission: admission)
        try request.validate()
        return request
    }
}
