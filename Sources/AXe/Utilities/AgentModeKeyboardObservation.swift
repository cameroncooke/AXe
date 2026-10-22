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
    }

    let state: State
    let source: String
    let scope: String
    let signals: Signals

    init(signals: Signals) {
        self.signals = signals
        state = signals.idChromeCount >= 2 || signals.globeSeen
            || signals.letterKeyCount >= 10 || signals.chromeKeyCount >= 3 ? .likelyVisible : .unknown
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

    static func observe(_ buttons: [Button], logicalWidth: Double, logicalHeight: Double) -> AgentModeKeyboardObservation {
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
            globeSeen: globeSeen, letterKeyCount: letters.count, chromeKeyCount: labels.count))
    }
}
