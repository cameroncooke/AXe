import AXeCore
import Foundation
import FBSimulatorControl

/// Taps on and typing into hosted web controls (`w` refs). Each action reads the screen again,
/// finds the chosen control on that read, and sends input through a guard that reads the element
/// at the control's point again before the first event. The screen after the action is returned
/// as a new capture, with web rows, as for app refs.
///
/// Web elements report `AXFocused` as true whether or not they hold focus, so typing and keys
/// always tap the field first (`type --focus`, `key`, `key-combo`, `key-sequence`), near its right
/// end so the caret follows any existing text, and take the app's software keyboard appearing as
/// the sign the tap focused it.
extension AgentModeController {
    /// The keyboard is read at most this many times after the focus tap, this far apart.
    static let webFocusReads = 6
    static let webFocusInterval = Duration.milliseconds(150)

    typealias WebTarget = (node: FBSimulatorAXNode, point: SelectedAXPoint, record: Record)

    func performWebReserved(_ request: SelectedHIDRequest) async -> SelectedHIDResponse {
        var action: AgentModeActionReceipt?
        var refusalContext: SelectedHIDContext?
        var refusalPID: Int32?
        var observedScreen = false
        do {
            try request.validate()
            guard let mode = request.agent, let ref = mode.ref else {
                throw AgentModeFailure("missingRequest", "The agent request is missing.")
            }
            guard mode.kind != .typeText else {
                throw AgentModeFailure("unsupportedReference", "Web fields do not report keyboard focus, so AXe types into a web field only after tapping it. Use type --focus with its ref. Nothing was sent.")
            }
            let original = try requireRecordIdentity(mode)
            try requireRequestedDisplay(request, matches: original.context)
            refusalContext = original.context
            refusalPID = original.expectedPID
            guard let web = original.snapshot.web else {
                throw AgentModeFailure("referenceMissing", "That ref is not in this snapshot, so nothing was sent. Capture with describe-ui --agent --web to list web controls.")
            }
            let keys = [.keyPress, .keyCombo, .keySequence].contains(mode.kind)
            let typing = mode.kind == .focusAndType || keys
            let chosen = try web.node(ref: ref, requiredAction: typing ? .typeText : .tap)
            observedScreen = true
            var current = try await readWebControl(chosen, original: original, typing: typing)
            let keyboardBefore = Self.keyboardVisible(current.record)
            let tapped = await sendWebInput(request, kind: .webTap, current: current, keyEvents: nil)
            let tapReceipt = receipt(.tap, tapped, retried: false)
            action = tapReceipt
            guard tapped.error == nil, tapped.cleanup != "uncertain" else {
                return await refusal(request, tapped.agent?.error ?? AgentModePublicErrorProjection.nativeFailure(tapped),
                    native: tapped, action: tapReceipt, context: current.record.context, pid: current.record.expectedPID,
                    allowsRetry: false)
            }
            let text = mode.text
            guard typing, let events = try mode.keyEvents ?? text.map({
                try KeyboardPrimitives.from(SelectedKeyboardRequest.textEvent($0, layout: mode.layout))
            }) else {
                return await publishReplacement(request, mode: mode, result: tapped, action: tapReceipt,
                    context: current.record.context, pid: current.record.expectedPID)
            }
            let focused = try await waitForWebFocus(chosen: current, keyboardBefore: keyboardBefore)
            current = focused.target
            let keysOnly = await sendWebInput(request, kind: .webType, current: current, keyEvents: events,
                covered: focused.covered)
            // The focus tap is input too: the reply counts both phases.
            let typed = Self.afterFocusTap(keysOnly, tapped: tapped)
            let typeReceipt = receipt(mode.kind, typed, retried: false)
            action = typeReceipt
            guard typed.error == nil, typed.cleanup != "uncertain" else {
                let reason = keysOnly.agent?.error ?? AgentModePublicErrorProjection.nativeFailure(keysOnly)
                return await refusal(request, keysOnly.enqueuedEventCount == 0 ? Self.stoppedAfterFocusTap(reason) : reason,
                    native: typed, action: typeReceipt, context: current.record.context, pid: current.record.expectedPID,
                    allowsRetry: false)
            }
            guard let text, !keys else {
                return await publishReplacement(request, mode: mode, result: typed, action: typeReceipt,
                    context: current.record.context, pid: current.record.expectedPID)
            }
            return await publishWebTyping(request, mode: mode, result: typed, action: typeReceipt,
                field: current.node, text: text, context: current.record.context, pid: current.record.expectedPID)
        } catch let error as AgentModeFailure where error.code == "snapshotMissing"
            && request.agent?.snapshotID != nil && record != nil && request.agent?.snapshotID != record?.id {
            // A stale caller cannot erase another caller's newer reference table.
            return failure(request, error, action: action)
        } catch {
            let nativeFailure = error as? AgentModeNativeFailure
            if nativeFailure != nil || observedScreen || (error as? AgentModeFailure)?.code == "snapshotExpired" {
                record = nil
            }
            let reason = error as? AgentModeFailure
                ?? AgentModeFailure("observationFailed", "The simulator observation failed.")
            if nativeFailure == nil, action == nil {
                return await refusal(request, reason, native: nil, action: action,
                    context: refusalContext, pid: refusalPID, allowsRetry: false)
            }
            return failure(request, reason, native: nativeFailure?.response, action: action)
        }
    }

    /// The chosen control on a fresh read of the snapshot's display, stored as the current table.
    private func readWebControl(_ chosen: FBSimulatorAXNode, original: Record, typing: Bool) async throws -> WebTarget {
        let found = try await findWebControl(chosen, original: original, typing: typing)
        guard let target = found.target else {
            throw AgentModeFailure("targetMissing", "That web control is no longer on screen or something covers it, so nothing was sent. \(AgentModeFailure.actFromCapture)")
        }
        return target
    }

    private func findWebControl(_ chosen: FBSimulatorAXNode, original: Record, typing: Bool) async throws
        -> (target: WebTarget?, record: Record) {
        let fresh = try await readWebTable(display: try Self.display(of: original.context), pid: original.expectedPID)
        guard fresh.context == original.context else {
            throw AgentModeFailure("contextChanged", "The app or display changed after this snapshot was taken, so nothing was sent. \(AgentModeFailure.actFromCapture)")
        }
        guard let match = fresh.snapshot.web?.match(chosen, original: original.snapshot.web),
              let point = typing ? AgentWebControls.typingPoint(match.node, context: fresh.context,
                    others: fresh.snapshot.web?.nodes ?? [])
                : AgentWebControls.tapPoint(match.node, context: fresh.context) else { return (nil, fresh) }
        return ((match.node, point, fresh), fresh)
    }

    private func readWebTable(display: ActivePanelIdentity, pid: Int32) async throws -> Record {
        let observed = try await observe(display: display, pid: pid)
        guard let context = observed.context, let roots = observed.ax?.roots, let observedPID = observed.ax?.expectedPID else {
            throw AgentModeFailure("missingObservation", "The native observation has no selected context or hierarchy.")
        }
        let snapshot = try PhaseTimer.measureSync("agent.snapshotBuild") {
            try AgentModeSnapshot(roots: roots, nativeIdentityMetadata: observed.ax?.nativeIdentityMetadata,
                context: context, web: Self.webControls(observed))
        }
        return store(snapshot, context: context, pid: observedPID)
    }

    static func keyboardVisible(_ record: Record) -> Bool {
        if record.snapshot.web?.keyboardVisible == true { return true }
        let context = record.context
        let size = CGSize(width: context.logicalWidth, height: context.logicalHeight)
        return AgentModeKeyboardDetector.observe(record.snapshot.keyboardButtons,
            logicalWidth: context.logicalWidth, logicalHeight: context.logicalHeight,
            numericKeyCount: AgentModeKeyboardDetector.numericKeyCount(in: record.snapshot,
                expectedPID: record.expectedPID, logicalSize: size)).state == .likelyVisible
    }

    /// After the focus tap the keyboard appears, and the page can move the field to clear it, so
    /// each read finds the field again. A keyboard already up before the tap (moving from another
    /// field) gives no new evidence; one read after a pause then stands for it. When the keyboard
    /// now covers the field (a web view in the lower half of an app screen), the field cannot be
    /// read at its point; typing then goes ahead on the keyboard's evidence alone (`covered`), but
    /// only when the web read worked and the field's last frame reaches under the keyboard.
    private func waitForWebFocus(chosen tapped: WebTarget, keyboardBefore: Bool) async throws
        -> (target: WebTarget, covered: Bool) {
        var keyboardSeen = false
        for _ in 0..<Self.webFocusReads {
            try await PhaseTimer.measure("agent.webFocusPause") { try await Task.sleep(for: Self.webFocusInterval) }
            let found = try await findWebControl(tapped.node, original: tapped.record, typing: true)
            let keyboard = Self.keyboardVisible(found.record)
            guard keyboardBefore || keyboard else { continue }
            keyboardSeen = keyboardSeen || keyboard
            if let target = found.target { return (target, false) }
            if keyboard, Self.keyboardCovers(tapped.node, record: found.record) {
                return ((tapped.node, tapped.point, found.record), true)
            }
        }
        guard keyboardSeen else {
            throw AgentModeFailure("targetChanged", "The keyboard did not appear after tapping the web field, so nothing was typed. The field may not accept text. \(AgentModeFailure.actFromCapture)")
        }
        throw AgentModeFailure("targetChanged", "The web field was tapped, but it could not be found again, so nothing was typed. \(AgentModeFailure.actFromCapture)")
    }

    /// The web read worked and the field's frame reaches below the top of the keyboard.
    static func keyboardCovers(_ field: FBSimulatorAXNode, record: Record) -> Bool {
        guard let web = record.snapshot.web, web.failure == nil, let frame = field.frame else { return false }
        let context = record.context
        let native = AgentModeKeyboardDetector.occlusion(in: record.snapshot, expectedPID: record.expectedPID,
            logicalSize: CGSize(width: context.logicalWidth, height: context.logicalHeight))?.frame.minY
        guard let top = [native, web.keyboardTop].compactMap({ $0 }).min() else { return false }
        return frame.maxY > top
    }

    /// The type phase's response, counting the focus tap's events: after a delivered tap, a
    /// refused key phase is no longer "nothing sent".
    static func afterFocusTap(_ typed: SelectedHIDResponse, tapped: SelectedHIDResponse) -> SelectedHIDResponse {
        guard tapped.enqueuedEventCount > 0 else { return typed }
        let refusedBeforeKeys = typed.outcome == "failedBeforeInput" || typed.outcome == "rejectedBeforeInput"
        var combined = SelectedHIDResponse(version: typed.version, requestID: typed.requestID, brokerID: typed.brokerID,
            outcome: refusedBeforeKeys ? "failedNoReplay" : typed.outcome, token: typed.token,
            enqueuedEventCount: tapped.enqueuedEventCount + typed.enqueuedEventCount,
            cleanup: typed.cleanup == "notNeeded" ? tapped.cleanup : typed.cleanup,
            error: typed.error, context: typed.context ?? tapped.context)
        combined.errorCode = typed.errorCode
        combined.ax = typed.ax
        combined.quarantine = typed.quarantine ?? tapped.quarantine
        combined.agent = typed.agent
        combined.timing = typed.timing
        return combined
    }

    /// A key phase refusal after the focus tap went through: the tap is not undone.
    static func stoppedAfterFocusTap(_ reason: AgentModeFailure) -> AgentModeFailure {
        let detail = reason.message.replacingOccurrences(of: ", so nothing was sent.", with: ".")
            .replacingOccurrences(of: " Nothing was sent.", with: "")
        return AgentModeFailure(reason.code, "The web field was tapped, but no key was typed: \(detail)")
    }

    /// The screen after typing, checked against the text when the field shows its value.
    private func publishWebTyping(_ request: SelectedHIDRequest, mode: AgentModeRequest, result: SelectedHIDResponse,
                                  action: AgentModeActionReceipt, field: FBSimulatorAXNode, text: String,
                                  context: SelectedHIDContext, pid: Int32) async -> SelectedHIDResponse {
        let stored: Record
        do {
            stored = try await PhaseTimer.measure("agent.refresh") {
                try await readWebTable(display: try Self.display(of: context), pid: pid)
            }
        } catch {
            return await publishReplacement(request, mode: mode, result: result, action: action, context: context, pid: pid)
        }
        var steps: [String] = []
        if !AgentWebControls.hidesValue(field), let after = stored.snapshot.web?.match(field)?.node,
           AgentModeSnapshot.text(after.value)?.contains(text) != true {
            steps.append("The keys were sent, but the field does not show the text. Check the field in a screenshot before going on; do not resend the text blindly.")
        }
        let capture = stored.snapshot.capture(id: stored.id, sequence: stored.sequence, udid: simulatorUDID,
            request: mode, applicationPID: stored.expectedPID, context: stored.context,
            unchanged: false, expiresIn: Self.timeToLive)
        return success(request, native: result, capture: capture, action: action,
            cache: AgentModeCacheState(status: "refreshed", reason: "inputCompleted", requiresRefresh: false),
            nextSteps: steps)
    }

    private func sendWebInput(_ outer: SelectedHIDRequest, kind: SelectedAXRequest.Kind, current: WebTarget,
                              keyEvents: [SelectedKeyboardPrimitive]?, covered: Bool = false) async -> SelectedHIDResponse {
        let context = current.record.context
        do {
            guard let uuid = UUID(uuidString: context.screenUUID) else { throw AgentModeFailure.missingContext }
            var ax = SelectedAXRequest(kind: kind, expectedPID: current.record.expectedPID, endpoint: nil,
                selectorKind: nil, selectorValue: nil, preDelay: 0, postDelay: 0, point: current.point)
            ax.webTarget = current.node
            ax.keyEvents = keyEvents
            ax.webFieldCovered = covered ? true : nil
            let native = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: outer.requestID,
                screenID: context.screenID, screenUUID: uuid, operation: .complete, token: nil, payload: .ax(ax),
                agentAdmission: AgentModeAdmission(context: context, expectedPID: current.record.expectedPID,
                    visibleFingerprint: current.record.snapshot.visibleFingerprint, target: nil))
            try native.validate()
            // Invalidate before input, including partial or uncertain native delivery.
            record = nil
            return await PhaseTimer.measure("agent.input") { await owner.perform(native) }
        } catch {
            var refused = SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: outer.requestID,
                brokerID: owner.brokerID, outcome: "rejectedBeforeInput", token: nil, enqueuedEventCount: 0,
                cleanup: "notNeeded", error: error.localizedDescription, context: nil)
            if let failure = error as? AgentModeFailure {
                refused.agent = AgentModeResult(error: failure,
                    cache: AgentModeCacheState(status: "invalidated", reason: failure.code, requiresRefresh: true))
            }
            return refused
        }
    }
}
