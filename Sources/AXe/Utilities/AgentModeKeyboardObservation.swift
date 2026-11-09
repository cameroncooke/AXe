// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 LY Corporation
//
// Adapted from lycorp-jp/sim-use, commit c02295edfd2f442249b869096dda3dc7bfcd308d,
// Sources/iOSSimBackend/A11y/SoftKeyboardDetector.swift.
// AXe changes: likelyVisible/unknown state, distinct counts, inherited-hidden filtering,
// current logical display bounds, and reuse of the existing agent snapshot.
// Licence and upstream NOTICE: Resources/licenses/sim-use/.

import Foundation
import FBSimulatorControl

/// Keyboard-like key evidence from one selected application's existing AX tree.
/// Missing signals do not prove that the OS keyboard is hidden.
struct AgentModeKeyboardObservation: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case likelyVisible, unknown }

    struct Signals: Codable, Equatable, Sendable {
        let idChromeCount: Int
        let globeSeen: Bool
        let letterKeyCount: Int
        let chromeKeyCount: Int
        let numericKeyCount: Int?

        init(idChromeCount: Int, globeSeen: Bool, letterKeyCount: Int, chromeKeyCount: Int,
             numericKeyCount: Int? = nil) {
            self.idChromeCount = idChromeCount; self.globeSeen = globeSeen
            self.letterKeyCount = letterKeyCount; self.chromeKeyCount = chromeKeyCount
            self.numericKeyCount = numericKeyCount
        }
    }

    let state: State
    let source: String
    let scope: String
    let signals: Signals

    init(signals: Signals) {
        self.signals = signals
        state = signals.idChromeCount >= 2 || signals.globeSeen
            || signals.letterKeyCount >= 10 || signals.chromeKeyCount >= 3
            || signals.numericKeyCount == 10 ? .likelyVisible : .unknown
        source = "accessibility-key-signals"
        scope = "selected-application"
    }
}

enum AgentModeKeyboardDetector {
    /// Captured during the same bounded walk as the native snapshot fingerprint.
    struct Button: Sendable {
        let identifier: String?
        let label: String?
        let frame: CGRect

        init?(_ node: FBSimulatorAXNode, inheritedHidden: Bool) {
            guard node.type == "Button", !inheritedHidden, let frame = node.frame,
                  [frame.origin.x, frame.origin.y, frame.width, frame.height, frame.maxX, frame.maxY].allSatisfy(\.isFinite),
                  frame.width > 0, frame.height > 0 else { return nil }
            identifier = node.identifier?.trimmingCharacters(in: .whitespacesAndNewlines)
            label = node.label?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.frame = frame
        }
    }

    private static let chromeIdentifiers: Set<String> = [
        "shift", "delete", "return", "Search", "more", "emoji", "dictation", "space",
    ]
    private static let globeLabels: Set<String> = [
        "Next Keyboard", "次のキーボード", "下一个键盘", "下一個鍵盤", "다음 키보드",
    ]
    private static let chromeLabels: Set<String> = [
        "shift", "delete", "return", "space", "numbers", "more", "Emoji", "Dictation", "Next Keyboard",
        "下一个键盘", "听写", "换行", "空格", "改行", "スペース", "次のキーボード", "다음 키보드", "받아쓰기",
    ]

    struct Occlusion {
        let frame: CGRect
        let path: String
    }

    /// Exact current bounds and path of a shared keyboard-signal ancestor.
    static func occlusion(in snapshot: AgentModeSnapshot, expectedPID: Int32,
                          logicalSize: CGSize) -> Occlusion? {
        guard expectedPID > 0, snapshot.nativeIdentityMetadata?.complete == true,
              logicalSize.width.isFinite, logicalSize.height.isFinite,
              logicalSize.width > 0, logicalSize.height > 0 else { return nil }
        let display = CGRect(origin: .zero, size: logicalSize)
        if let numeric = numericEvidence(in: snapshot, expectedPID: expectedPID, display: display) {
            return numericOcclusion(in: snapshot, evidence: numeric, expectedPID: expectedPID, display: display)
        }
        var signals: [(path: String, button: Button)] = []
        for index in snapshot.nodes.indices {
            let node = snapshot.nodes[index], element = snapshot.elements[index]
            guard node.pid == expectedPID, node.enabled == true, node.hidden == false,
                  element.state.visible, element.state.enabled,
                  let rect = node.frame, rect.isUsableAgentFrame, rect.intersects(display),
                  let button = Button(node, inheritedHidden: false), isKeyboardSignal(button) else { continue }
            signals.append((element.path, button))
        }
        guard observe(signals.map(\.button), logicalWidth: logicalSize.width,
                logicalHeight: logicalSize.height).state == .likelyVisible,
              var path = signals.first?.path else { return nil }
        while let separator = path.lastIndex(of: ".") {
            path = String(path[..<separator])
            guard signals.allSatisfy({ $0.path.hasPrefix(path + ".") }) else { continue }
            guard let index = snapshot.elements.firstIndex(where: { $0.path == path }) else { return nil }
            let node = snapshot.nodes[index], element = snapshot.elements[index]
            guard node.type == "Group" else { continue }
            guard node.pid == expectedPID, node.enabled == true, node.hidden == false,
                  element.state.visible, element.state.enabled,
                  let identity = node.nativeIdentity, identity.pid == expectedPID, identity.objectID > 0,
                  snapshot.nodes.filter({ $0.nativeIdentity == identity }).count == 1,
                  let frame = node.frame, frame.isUsableAgentFrame, display.contains(frame),
                  signals.allSatisfy({ frame.contains($0.button.frame.intersection(display)) }) else { return nil }
            return Occlusion(frame: frame, path: path)
        }
        return nil
    }

    /// Numeric labels alone can be an app dialpad. Require the observed OS keyplane and focused editor.
    static func numericKeyCount(in snapshot: AgentModeSnapshot, expectedPID: Int32,
                                logicalSize: CGSize) -> Int? {
        guard logicalSize.width.isFinite, logicalSize.height.isFinite,
              logicalSize.width > 0, logicalSize.height > 0 else { return nil }
        let display = CGRect(origin: .zero, size: logicalSize)
        return numericEvidence(in: snapshot, expectedPID: expectedPID, display: display).map { _ in 10 }
    }

    private struct NumericEvidence {
        let markerPath: String
        let markerFrame: CGRect
    }

    private static func numericEvidence(in snapshot: AgentModeSnapshot, expectedPID: Int32,
                                        display: CGRect) -> NumericEvidence? {
        guard expectedPID > 0, snapshot.nativeIdentityMetadata?.complete == true else { return nil }
        let focused = snapshot.nodes.indices.filter { index in
            let node = snapshot.nodes[index], element = snapshot.elements[index]
            return node.type == "TextField" && node.pid == expectedPID && node.focused == true
                && node.enabled == true && node.hidden == false
                && element.state.visible && element.state.enabled && element.actions.contains(.typeText)
        }
        guard focused.count == 1 else { return nil }
        var matches: [NumericEvidence] = []
        for index in snapshot.nodes.indices {
            let node = snapshot.nodes[index], element = snapshot.elements[index]
            guard node.identifier == "UIKeyboardLayoutStar Preview",
                  let frame = ownedGroupFrame(index, snapshot: snapshot, expectedPID: expectedPID),
                  display.contains(frame) else { continue }
            let prefix = element.path + "."
            var digits: [UInt32] = []
            var deleteCount = 0
            for child in snapshot.nodes.indices where snapshot.elements[child].path.hasPrefix(prefix) {
                let key = snapshot.nodes[child], state = snapshot.elements[child].state
                guard key.type == "Button", key.pid == expectedPID, key.enabled == true, key.hidden == false,
                      state.visible, state.enabled, let bounds = key.frame, bounds.isUsableAgentFrame,
                      display.contains(bounds), frame.contains(bounds) else { continue }
                let label = key.label?.trimmingCharacters(in: .whitespacesAndNewlines)
                if label?.unicodeScalars.count == 1, let digit = label?.unicodeScalars.first,
                   (48...57).contains(digit.value) { digits.append(digit.value) }
                if key.identifier == "delete" || label?.lowercased() == "delete" { deleteCount += 1 }
            }
            guard digits.count == 10, Set(digits).count == 10, deleteCount == 1 else { continue }
            matches.append(NumericEvidence(markerPath: element.path, markerFrame: frame))
        }
        return matches.count == 1 ? matches.first : nil
    }

    private static func numericOcclusion(in snapshot: AgentModeSnapshot, evidence: NumericEvidence,
                                         expectedPID: Int32, display: CGRect) -> Occlusion? {
        var path = evidence.markerPath
        while let separator = path.lastIndex(of: ".") {
            path = String(path[..<separator])
            guard let index = snapshot.elements.firstIndex(where: { $0.path == path }),
                  let frame = ownedGroupFrame(index, snapshot: snapshot, expectedPID: expectedPID),
                  display.contains(frame), frame.contains(evidence.markerFrame), frame.minY > display.minY,
                  abs(frame.minX - display.minX) <= 0.5, abs(frame.maxX - display.maxX) <= 0.5,
                  abs(frame.maxY - display.maxY) <= 0.5 else { continue }
            // A form or full application ancestor must not become keyboard authority.
            let prefix = path + ".", markerPrefix = evidence.markerPath + "."
            let outside = snapshot.nodes.indices.filter {
                let current = snapshot.elements[$0].path
                return current.hasPrefix(prefix) && current != evidence.markerPath && !current.hasPrefix(markerPrefix)
            }
            let hasAppControl = outside.contains { current in
                let node = snapshot.nodes[current], element = snapshot.elements[current]
                guard element.state.visible, element.state.enabled, node.enabled == true, node.hidden == false else { return false }
                if node.type == "Button" {
                    guard node.pid == expectedPID, let button = Button(node, inheritedHidden: false) else { return true }
                    return !isKeyboardSignal(button)
                }
                return ["TextField", "TextView", "Slider", "Switch", "CheckBox", "Cell"].contains(node.type ?? "")
            }
            guard !hasAppControl else { return nil }
            return Occlusion(frame: frame, path: path)
        }
        return nil
    }

    private static func ownedGroupFrame(_ index: Int, snapshot: AgentModeSnapshot, expectedPID: Int32) -> CGRect? {
        let node = snapshot.nodes[index], element = snapshot.elements[index]
        guard node.type == "Group", node.pid == expectedPID, node.enabled == true, node.hidden == false,
              element.state.visible, element.state.enabled,
              let identity = node.nativeIdentity, identity.pid == expectedPID, identity.objectID > 0,
              snapshot.nodes.filter({ $0.nativeIdentity == identity }).count == 1,
              let frame = node.frame, frame.isUsableAgentFrame else { return nil }
        return frame
    }

    private static func isKeyboardSignal(_ button: Button) -> Bool {
        if let identifier = button.identifier, chromeIdentifiers.contains(identifier) { return true }
        guard let label = button.label else { return false }
        if globeLabels.contains(label) || chromeLabels.contains(label) { return true }
        guard label.unicodeScalars.count == 1, let scalar = label.unicodeScalars.first else { return false }
        return (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }

    static func observe(_ buttons: [Button], logicalWidth: Double, logicalHeight: Double,
                        numericKeyCount: Int? = nil) -> AgentModeKeyboardObservation {
        var identifiers: Set<String> = []
        var labels: Set<String> = []
        var letters: Set<UInt32> = []
        var globeSeen = false
        if logicalWidth.isFinite, logicalHeight.isFinite, logicalWidth > 0, logicalHeight > 0 {
            let display = CGRect(x: 0, y: 0, width: logicalWidth, height: logicalHeight)
            for button in buttons where button.frame.intersects(display) {
                if let identifier = button.identifier, chromeIdentifiers.contains(identifier) {
                    identifiers.insert(identifier)
                }
                guard let label = button.label else { continue }
                if globeLabels.contains(label) { globeSeen = true }
                if chromeLabels.contains(label) { labels.insert(label) }
                if label.unicodeScalars.count == 1, let scalar = label.unicodeScalars.first {
                    let value = scalar.value
                    if (65...90).contains(value) { letters.insert(value + 32) }
                    else if (97...122).contains(value) { letters.insert(value) }
                }
            }
        }
        return AgentModeKeyboardObservation(signals: .init(idChromeCount: identifiers.count,
            globeSeen: globeSeen, letterKeyCount: letters.count, chromeKeyCount: labels.count,
            numericKeyCount: numericKeyCount))
    }
}
