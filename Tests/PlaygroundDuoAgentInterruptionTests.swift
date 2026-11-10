import Foundation
import Testing

enum PlaygroundAgentInterruptedAction: String, CaseIterable, Sendable {
    case referenceHoldFold, referenceDragFold, referencePinchFold, referencePinchRotate
    case referenceSwipeFold, coordinateSwipeRotate, typeOpening, typeRotate, batchFold, independentPairFold
    case referenceSliderFold, referenceSliderRotate
    static var selectedNonSliderCases: [Self] {
        let baseline = allCases.filter { !$0.slider }
        guard let raw = ProcessInfo.processInfo.environment["AXE_E2E_DUO_INTERRUPTED_ACTIONS"] else { return baseline }
        let names = raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard !names.isEmpty, Set(names).count == names.count,
              names.allSatisfy({ name in baseline.contains { $0.rawValue == name } }) else {
            fatalError("AXE_E2E_DUO_INTERRUPTED_ACTIONS must select unique existing non-slider cases.")
        }
        return baseline.filter { names.contains($0.rawValue) }
    }
    var rotating: Bool { [.referencePinchRotate, .coordinateSwipeRotate, .typeRotate, .referenceSliderRotate].contains(self) }
    var typing: Bool { self == .typeOpening || self == .typeRotate }
    var slider: Bool { self == .referenceSliderFold || self == .referenceSliderRotate }
    var contacts: Int { typing || self == .batchFold ? 0 : self == .referencePinchFold || self == .referencePinchRotate || self == .independentPairFold ? 2 : 1 }
    var position: DuoControlsPosition {
        if self == .typeOpening { return .outer0 }
        if self == .coordinateSwipeRotate { return .outer90 }
        if self == .independentPairFold || self == .referenceHoldFold || self == .referenceDragFold { return .inner270 }
        if self == .referenceSwipeFold { return .inner180 }
        return .inner90
    }
    var kind: String {
        switch self {
        case .referenceHoldFold: "hold"
        case .referenceDragFold: "drag"
        case .referencePinchFold, .referencePinchRotate: "pinch"
        case .referenceSwipeFold: "swipe"
        case .coordinateSwipeRotate: "complete"
        case .typeOpening, .typeRotate: "typeText"
        case .batchFold: "tap"
        case .independentPairFold: "independentPair"
        case .referenceSliderFold, .referenceSliderRotate: "sliderPercentage"
        }
    }
}

@Suite("Playground Duo Agent Layout Changes E2E", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundDuoAgentInterruptionTests {
    @Test("Changed layout stops old input, releases contacts and permits fresh input", arguments: PlaygroundAgentInterruptedAction.selectedNonSliderCases)
    func inputDuringLayoutChange(_ action: PlaygroundAgentInterruptedAction) async throws {
        try await AgentLayoutInterruption(action: action).run()
    }

    @Test("Fold stops a moving reference slider, releases its contact and permits fresh input")
    func referenceSliderFold() async throws {
        try await AgentLayoutInterruption(action: .referenceSliderFold).run()
    }

    @Test("Rotate stops a moving reference slider, releases its contact and permits fresh input")
    func referenceSliderRotate() async throws {
        try await AgentLayoutInterruption(action: .referenceSliderRotate).run()
    }
}

private struct AgentLayoutInterruption {
    let action: PlaygroundAgentInterruptedAction
    private let payload = String(repeating: "A", count: 200)
    private let sliderTarget = 63.25

    func run() async throws {
        let preparation = DuoStateReadWait.Preparation(phase: "before-input-" + action.rawValue)
        let session = try await DuoStateReadWait.$preparation.withValue(preparation) {
            try await PlaygroundAgentFeatureSession.open(caseName: "agent-layout-" + action.rawValue, position: action.position)
        }
        if action.typing { try await session.focusField() }
        else { try await session.show(action == .referenceSwipeFold || action == .referenceDragFold ? "feature.showList" : "feature.showPad") }
        let catalogue = try await DuoStateReadWait.$preparation.withValue(preparation) {
            try await DuoPlaygroundSession().catalogue()
        }
        let capture = try await session.capture()
        let state = try await session.core.state()
        let target = action.typing ? "feature.text" : action.slider ? "feature.slider" : action == .referenceSwipeFold || action == .referenceDragFold ? "feature.list" : action == .referenceHoldFold || action == .batchFold ? "feature.tap" : "feature.pad"
        let frame = try session.core.frame(of: session.core.element(target, in: state))
        let arguments = try inputArguments(session, capture: capture, frame: frame, target: target)
        let before = try session.document.read()
        // The full view keeps the receipt's kind and replayed fields that the compact reply omits.
        let input = try PlaygroundTestProcess(executable: TestHelpers.getAxePath(),
            arguments: canonicalAgentArguments(arguments + ["--udid", session.agent.udid]),
            directory: session.artifacts, name: "interrupted-input")
        let externalPath = try #require(ProcessInfo.processInfo.environment["AXE_DUO_STATE_CHANGE_PATH"])
        let identity = catalogue.activePanel.identity
        let rotationPlan = try action.rotating ? DuoRotationPlan(catalogue: catalogue, context: session.initialContext) : nil
        let requestedDegrees = rotationPlan.map { Double($0.target) } ?? (action == .typeOpening ? 180 : 0)
        let foldControl: DuoHeldLayoutControl? = try DuoHeldLayoutControl(boot: catalogue.bootIdentity,
            udid: session.agent.udid, degrees: requestedDegrees, artifacts: session.artifacts, rotation: rotationPlan)
        let external = try PlaygroundTestProcess(executable: externalPath,
            arguments: [action.rotating ? "rotate-write-held" : "fold-write-held", catalogue.bootIdentity, String(identity.displayID), identity.uniqueID.uuidString,
                String(requestedDegrees), session.artifacts.appendingPathComponent("layout-change-marker.json").path,
                session.agent.udid] + (foldControl?.arguments ?? []),
            directory: session.artifacts, name: "external-layout-change")
        do {
            try input.start()
            let held = try await session.document.waitFor("real input before the external change", timeout: 15) { value in
                try #require(input.isRunning, "Input ended before the layout-change witness.")
                if action.typing { return !value.text.isEmpty && value.text.count < payload.count }
                if action == .batchFold { return value.count("tap") > before.count("tap") && value.count("tap") < before.count("tap") + 8 }
                let groups = newContacts(value, since: before)
                guard value.activeWindowTouches == action.contacts && groups.count == action.contacts else { return false }
                if action == .referenceHoldFold { return true }
                if action.slider {
                    return value.count("sliderChanged") > before.count("sliderChanged")
                        && abs(value.slider - before.slider) > 0.07
                        && abs(value.slider - sliderTarget) > 0.07
                }
                if action == .referenceDragFold || action == .referenceSwipeFold {
                    guard value.listOffsetY > before.listOffsetY + 2
                        && abs(value.pageOffsetY - before.pageOffsetY) < 1 else { return false }
                }
                if action == .coordinateSwipeRotate {
                    guard abs(value.panX - before.panX) > 2 && abs(value.pageOffsetY - before.pageOffsetY) < 1 else { return false }
                }
                return groups.allSatisfy { rows in
                    guard let first = rows.first else { return false }
                    return rows.contains { $0.phase == "windowTouchMoved" && hypot($0.x - first.x, $0.y - first.y) > 2 }
                }
            }
            try Data(contentsOf: session.document.url).write(to: session.artifacts.appendingPathComponent("input-before-layout-change.json"))
            try #require(input.isRunning)
            try external.start()
            var changeReceipt: AgentExternalLayoutReceipt?
            var rotationConfirmation: DuoRotationConfirmation?
            if let foldControl {
                try await foldControl.waitForReady(external)
                try await input.wait(timeout: foldControl.remaining())
            } else {
                try await external.wait(timeout: 20)
                let changeDiagnostics = try external.diagnostics()
                try #require(external.exitCode == 0, "External change failed: \(changeDiagnostics)")
                changeReceipt = try JSONDecoder().decode(AgentExternalLayoutReceipt.self, from: Data(try external.output().utf8))
                try await input.wait(timeout: 20)
            }
            try #require(input.exitCode != 0, "Input ran to normal completion across the layout change.")
            let output = try input.output()
            if action == .independentPairFold {
                let receipt = try session.rawReceipt(output)
                try #require(receipt.outcome == "failedNoReplay" && receipt.cleanup == "releaseEnqueuedAndDrained"
                    && receipt.enqueuedEventCount > 0 && receipt.quarantine == nil && receipt.error?.contains("staleContext") == true)
            } else if action == .batchFold { try requireInterruptedBatch(output, session: session) }
            else {
                let result = try session.decodeAgent(output)
                // Interrupted AX input reports inputIncomplete; other interrupted input keeps the generic code.
                try #require(result.didError && ["inputIncomplete", "nativeActionFailed"].contains(result.error?.code)
                    && result.data.cache.requiresRefresh)
                let receipt = try #require(result.data.action)
                try #require(receipt.kind == action.kind && receipt.outcome == "failedNoReplay" && receipt.enqueuedEventCount > 0 && !receipt.replayed)
                try #require(receipt.cleanup == "releaseEnqueuedAndDrained" || (action.typing && receipt.cleanup == "notNeeded"))
                if action == .referenceHoldFold { try #require(receipt.enqueuedEventCount == 1) }
                if action.typing { try #require(receipt.enqueuedEventCount < payload.count * 4) }
                if action.slider {
                    let slider = try #require(try PlaygroundAgentSliderEnvelope.decode(output).data?.action?.sliderValue)
                    try #require(slider.phase == "physicalOwnedValue" && slider.outcome == "failed"
                        && slider.delivery == "sent" && slider.requestedPercent == sliderTarget && !slider.replayed)
                }
            }
            let released: PlaygroundControlsDocument
            if let foldControl {
                released = try await session.document.waitFor("all original contacts released",
                    timeout: foldControl.remaining()) { $0.activeWindowTouches == 0 }
            } else {
                released = try await session.document.waitFor("all original contacts released") { $0.activeWindowTouches == 0 }
            }
            try released.requireClear()
            if action.contacts > 0 { try requireOriginalContactsReleased(before: before, held: held, released: released, frame: frame) }
            if action.typing {
                try #require(!released.text.isEmpty && released.text.count < payload.count && payload.hasPrefix(released.text))
            }
            if let foldControl {
                rotationConfirmation = try await foldControl.confirmTargetAndRelease(external, device: DuoPlaygroundSession(), pid: session.pid)
                let changeDiagnostics = try external.diagnostics()
                try #require(external.exitCode == 0, "External change failed: \(changeDiagnostics)")
                changeReceipt = try JSONDecoder().decode(AgentExternalLayoutReceipt.self, from: Data(try external.output().utf8))
            }
            let changed = try #require(changeReceipt)
            try #require(changed.mode == (action.rotating ? "rotate-write-held" : "fold-write-held")
                && changed.finishedUptime >= changed.startedUptime)
            if let foldControl {
                try foldControl.requireCompleted(changed.connectionHold,
                    started: changed.startedUptime, finished: changed.finishedUptime)
            }
            try await Task.sleep(nanoseconds: 500_000_000)
            let settled = try session.document.read()
            try #require(settled.inputState == released.inputState, "Old input continued after release.")
            let recovery = try DuoStateReadWait(phase: "after-writer-close", artifacts: session.artifacts)
            let afterLayout = try await DuoStateReadWait.$current.withValue(recovery) { () async throws -> DuoCatalogue in
            if let rotationPlan {
                let write = try #require(changed.write)
                rotationConfirmation = try await DuoPlaygroundSession().requireExternalRotation(write,
                    plan: rotationPlan, pid: session.pid, after: changed.finishedUptime,
                    artifacts: session.artifacts, artifactPrefix: "post-close-rotation")
                return try #require(rotationConfirmation).catalogue
            } else {
                let expectedDegrees = action == .typeOpening ? 180.0 : 0.0
                let write = try #require(changed.write)
                try #require(changed.hinge == nil && changed.rotation == nil)
                try await DuoPlaygroundSession().requireExternalFold(write, boot: catalogue.bootIdentity,
                    degrees: expectedDegrees, after: changed.finishedUptime, artifacts: session.artifacts)
                let expectedScreenID: UInt32 = action == .typeOpening ? 3 : 1
                return try await DuoPlaygroundSession().stableCatalogue(
                    boot: catalogue.bootIdentity, expectedScreenID: expectedScreenID)
            }
            }
            if action.rotating {
                let rotation = try #require(rotationConfirmation)
                try #require(changed.rotation == nil && changed.write?.source == "orientation-picker-control"
                    && changed.write?.vendorEventCount == 1 && rotation.matchingObservationCount == 2
                    && rotation.before.rotationDegrees != rotation.after.rotationDegrees)
                try #require(afterLayout.activePanel.identity == catalogue.activePanel.identity
                    && (try afterLayout.activePanel.rotationDegrees()) == rotation.after.rotationDegrees)
            } else {
                try #require(afterLayout.activePanel.identity != catalogue.activePanel.identity)
            }
            try capture.requireUnexpired("before stale-reference refusal")
            let old = try await session.command(["tap"] + (try session.contextArguments(capture, identifier: target)), allowFailure: true)
            let oldResult = try session.decodeAgent(old.output)
            try #require(old.exitCode != 0 && oldResult.didError && oldResult.data.action == nil)
            try #require(["snapshotMissing", "contextChanged", "screenChanged"].contains(oldResult.error?.code ?? ""))
            let afterOld = try session.document.read()
            try #require(afterOld.inputState == settled.inputState)
            if action.typing {
                let panel = afterLayout.activePanel.identity
                let selection = ["--input-mode", "selected", "--screen-id", String(panel.displayID),
                    "--screen-uuid", panel.uniqueID.uuidString, "--verbose"]
                let beforePopup = try await typingPopupTree(session, selection: selection, catalogue: afterLayout)
                if let popup = UIStateParser.findElement(in: beforePopup.roots, withIdentifier: "PopoverDismissRegion") {
                    try #require(popup.type == "Group" && popup.label == "dismiss popup")
                    let beforeEscape = try session.document.read()
                    try requireTypingCleanupState(beforeEscape, unchangedFrom: afterOld)
                    try #require(beforeEscape.textFocused)
                    let escape = try await session.command(["key", "41", "--expected-pid", String(session.pid),
                        "--focus-id", "feature.text"] + selection)
                    let escapeReceipt = try session.rawReceipt(escape.output)
                    try #require(escape.exitCode == 0 && escapeReceipt.outcome == "enqueuedAndDrained"
                        && escapeReceipt.enqueuedEventCount == 2 && escapeReceipt.cleanup == "notNeeded"
                        && escapeReceipt.error == nil && escapeReceipt.quarantine == nil
                        && escapeReceipt.context == beforePopup.context)
                    let line = try #require(escape.output.split(separator: "\n").first { $0.first == "{" })
                    let focused = try JSONDecoder().decode(AgentTypingEscapeReceipt.self, from: Data(line.utf8)).keyboard
                    try #require(focused.expectedPID == session.pid && focused.focusID == "feature.text"
                        && focused.validatedKeyDownCount == 1)
                    for field in [focused.initialTarget, focused.lastValidatedTarget] {
                        try #require(field.type == "TextField" && field.pid == session.pid && field.AXUniqueId == "feature.text"
                            && field.focused == true && field.enabled == true && field.hidden == false)
                    }
                    try requireTypingCleanupState(session.document.read(), unchangedFrom: afterOld)
                    let afterPopup = try await typingPopupTree(session, selection: selection, catalogue: afterLayout)
                    try #require(afterPopup.context == beforePopup.context)
                    try #require(UIStateParser.findElement(in: afterPopup.roots, withIdentifier: "PopoverDismissRegion") == nil,
                        "Escape did not dismiss the typing popup; input is not replayed.")
                }
                try requireTypingCleanupState(session.document.read(), unchangedFrom: afterOld)
            }
            try await session.show("feature.showPad")
            let fresh = try await session.capture()
            try #require(fresh.capture.snapshotID != capture.capture.snapshotID)
            let beforeTap = try session.document.read()
            let tapped = try await session.command(["tap"] + (try session.contextArguments(fresh, identifier: "feature.tap")))
            try session.requireHIDSuccess(tapped, kind: "tap", events: 2)
            try await session.requireButtonTap(after: beforeTap)
            if action.typing {
                if !(try session.document.read()).textFocused { try await session.focusField() }
                else { try await session.show("feature.showText") }
                let field = try await session.capture()
                let beforeProbe = try session.document.read()
                let typed = try await session.command(["type", "q7"] + (try session.contextArguments(field, identifier: "feature.text")))
                try session.requireHIDSuccess(typed, kind: "typeText", events: 4)
                _ = try await session.document.waitFor("lowercase input after the interrupted Shift sequence") { $0.text == beforeProbe.text + "q7" }
            }
            try capture.requireUnexpired("after layout interruption and fresh recovery")
            await external.finish()
            await input.finish()
        } catch {
            do { try foldControl?.abort() }
            catch { Issue.record("Cannot publish held fold abort: \(error)") }
            await external.finish(); await input.finish(); throw error
        }
    }

    private func typingPopupTree(_ session: PlaygroundAgentFeatureSession, selection: [String],
                                 catalogue: DuoCatalogue) async throws -> (roots: [UIElement], context: DuoContext) {
        let tree = try await session.command(["describe-ui", "--expected-pid", String(session.pid)] + selection)
        let line = try #require(tree.output.split(separator: "\n").first { $0.first == "{" })
        let receipt = try JSONDecoder().decode(DuoCLIResponse.self, from: Data(line.utf8))
        try receipt.requireSuccess("ready")
        try #require(tree.exitCode == 0 && receipt.enqueuedEventCount == 0 && receipt.cleanup == "notNeeded"
            && receipt.ax?.kind == "describe" && receipt.ax?.expectedPID == session.pid)
        let context = try #require(receipt.context)
        try context.requireMatch(catalogue)
        return (try #require(receipt.ax?.roots), context)
    }

    private func requireTypingCleanupState(_ value: PlaygroundControlsDocument,
                                           unchangedFrom before: PlaygroundControlsDocument) throws {
        try value.requireClear()
        try #require(value.pid == before.pid && value.generation == before.generation
            && value.text == before.text && value.count("textChanged") == before.count("textChanged"))
        try #require(value.windowTouchTrace == before.windowTouchTrace && value.recognizerTrace == before.recognizerTrace
            && value.windowTraceDropped == before.windowTraceDropped
            && value.recognizerTraceDropped == before.recognizerTraceDropped)
    }

    private func inputArguments(_ session: PlaygroundAgentFeatureSession, capture: AgentPlaygroundTimedCapture,
                                frame: UIElement.Frame, target: String) throws -> [String] {
        let cx = frame.x + frame.width / 2
        let cy = frame.y + frame.height / 2
        let context = try session.contextArguments(capture, identifier: target)
        switch action {
        case .referenceHoldFold: return ["touch", "--down", "--up", "--delay", "8"] + context
        case .referenceDragFold: return ["drag", "--end-x", String(cx), "--end-y", String(cy - min(100, frame.height / 3)), "--duration", "8", "--steps", "120"] + context
        case .referencePinchFold, .referencePinchRotate:
            return ["gesture", "pinch", "--radius", "20", "--scale", "1.8", "--duration", "8", "--delta", "0.5"] + context
        case .referenceSwipeFold: return ["swipe", "--direction", "up", "--distance", "0.8", "--duration", "8"] + context
        case .referenceSliderFold, .referenceSliderRotate:
            return ["slider", "--value", String(sliderTarget)] + context
        case .coordinateSwipeRotate:
            return ["swipe", "--agent", "--expected-pid", String(session.pid), "--snapshot-id", capture.capture.snapshotID.uuidString,
                "--start-x", String(cx - frame.width / 4), "--start-y", String(cy),
                "--end-x", String(cx + frame.width / 4), "--end-y", String(cy), "--duration", "8", "--delta", "1"]
        case .typeOpening, .typeRotate: return ["type", payload] + context
        case .batchFold:
            let file = session.artifacts.appendingPathComponent("eight-button-steps.json")
            let step = ["action": "tap", "id": "feature.tap"]
            try JSONEncoder().encode(["steps": Array(repeating: step, count: 8)]).write(to: file)
            return ["batch", "--agent", "--file", file.path, "--expected-pid", String(session.pid)]
        case .independentPairFold:
            return ["gesture", "two-finger-swipe", "-x", String(cx - 50), "-y", String(cy - 15),
                "--x2", String(cx + 45), "--y2", String(cy + 15), "--end-x", String(cx - 30), "--end-y", String(cy + 15),
                "--end-x2", String(cx + 65), "--end-y2", String(cy - 15), "--duration", "8", "--delta", "0.25"] + session.selectedFlags
        }
    }
    private func newContacts(_ value: PlaygroundControlsDocument, since before: PlaygroundControlsDocument) -> [[PlaygroundControlsContact]] {
        let old = Set(before.windowTouchTrace.map(\.contactID))
        return Dictionary(grouping: value.windowTouchTrace.filter { !old.contains($0.contactID) }, by: \.contactID).values.sorted { ($0.first?.x ?? 0) < ($1.first?.x ?? 0) }
    }
    private func requireOriginalContactsReleased(before: PlaygroundControlsDocument, held: PlaygroundControlsDocument,
                                                  released: PlaygroundControlsDocument, frame: UIElement.Frame) throws {
        let original = newContacts(held, since: before)
        let terminal = newContacts(released, since: before)
        try #require(original.count == action.contacts && terminal.count == action.contacts)
        for (index, rows) in terminal.enumerated() {
            let first = try #require(rows.first)
            let last = try #require(rows.last)
            try #require(first.contactID == original[index].first?.contactID && first.phase == "windowTouchBegan")
            try #require(["windowTouchEnded", "windowTouchCancelled"].contains(last.phase))
            try #require(rows.filter { $0.phase == "windowTouchBegan" }.count == 1)
            try #require(rows.dropFirst().dropLast().allSatisfy { $0.phase == "windowTouchMoved" })
            let ordered = zip(rows, rows.dropFirst()).allSatisfy { $0.0.timestamp <= $0.1.timestamp }
            try #require(ordered)
            try #require(rows.filter { ["windowTouchEnded", "windowTouchCancelled"].contains($0.phase) }.count == 1)
            let ends = plannedEnds(frame)
            if index < ends.count {
                try #require(rows.filter { $0.phase == "windowTouchMoved" }.allSatisfy {
                    hypot($0.x - ends[index].x, $0.y - ends[index].y) > 3
                }, "The interrupted contact reached its old final point.")
            }
            try #require(rows.count >= original[index].count)
            for (saved, current) in zip(original[index], rows) {
                try #require(PlaygroundComparableContact(saved) == PlaygroundComparableContact(current))
            }
        }
    }
    private func plannedEnds(_ frame: UIElement.Frame) -> [(x: Double, y: Double)] {
        let cx = frame.x + frame.width / 2
        let cy = frame.y + frame.height / 2
        switch action {
        case .referenceDragFold: return [(cx, cy - min(100, frame.height / 3))]
        case .referencePinchFold, .referencePinchRotate: return [(cx - 36, cy), (cx + 36, cy)]
        case .coordinateSwipeRotate: return [(cx + frame.width / 4, cy)]
        case .independentPairFold: return [(cx - 30, cy + 15), (cx + 65, cy - 15)]
        default: return []
        }
    }
    private func requireInterruptedBatch(_ output: String, session: PlaygroundAgentFeatureSession) throws {
        let result = try session.decodeAgent(output)
        try #require(result.didError && result.data.cache.requiresRefresh)
        let batch = try AgentInterruptedBatchEnvelope.decode(output).data.batch
        try #require(batch.totalSteps == 8 && batch.completedSteps > 0 && batch.completedSteps < 8
            && batch.stoppedAt != nil && !batch.replayed && !batch.rolledBack)
        let actual = try session.document.read()
        try #require(actual.count("tap") == batch.completedSteps && actual.activeWindowTouches == 0)
    }
}

private struct AgentExternalLayoutReceipt: Decodable {
    struct Hinge: Decodable { let outcome: String; let requestedDegrees: Double; let wasAlreadyWithinTolerance: Bool }
    let mode: String
    let startedUptime: Double
    let finishedUptime: Double
    let write: DuoExternalLayoutWrite?
    let connectionHold: DuoExternalConnectionHold?
    let hinge: Hinge?
    let rotation: DuoCLIResponse.RotationReceipt?
}
private struct AgentInterruptedBatchEnvelope: Decodable {
    struct Payload: Decodable { let batch: Batch }
    struct Batch: Decodable {
        let totalSteps: Int
        let completedSteps: Int
        let stoppedAt: Int?
        let replayed: Bool
        let rolledBack: Bool
    }
    let data: Payload
    static func decode(_ output: String) throws -> Self {
        for line in output.split(separator: "\n") where line.first == "{" {
            if let value = try? JSONDecoder().decode(Self.self, from: Data(line.utf8)) { return value }
        }
        throw TestError.invalidJSON("No interrupted batch receipt: \(output)")
    }
}

private struct AgentTypingEscapeReceipt: Decodable {
    struct Keyboard: Decodable {
        let expectedPID: Int32
        let focusID: String
        let validatedKeyDownCount: Int
        let initialTarget: Field
        let lastValidatedTarget: Field
    }
    struct Field: Decodable {
        let type: String?
        let pid: Int32?
        let AXUniqueId: String?
        let focused: Bool?
        let enabled: Bool?
        let hidden: Bool?
    }
    let keyboard: Keyboard
}
