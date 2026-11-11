import Foundation
import Testing

@Suite("Playground Duo Selected Discovery", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundDuoSelectedTargetTests {
    @Test("Selected point, label and exact value resolve the current app", arguments: [DuoControlsPosition.outer0, .inner90])
    func targets(position: DuoControlsPosition) async throws {
        try await withDuoPlaygroundScreen(pose: position.pose, rotation: position.rotation) {
            let app = try await PlaygroundControlsSession()
            let treeOutput = try await app.app.run(["describe-ui", "--expected-pid", String(app.pid)] + app.selection(), allowFailure: true)
            try Data(treeOutput.output.utf8).write(to: app.artifacts.appendingPathComponent("point-full-tree.txt"))
            try #require(treeOutput.exitCode == 0, "Selected full-tree read failed: \(treeOutput.output)")
            let tree = try JSONDecoder().decode(ControlsPointReceipt.self, from: Data(treeOutput.output.utf8))
            let treeIsReady = tree.outcome == "ready" && tree.error == nil && tree.enqueuedEventCount == 0 && tree.cleanup == "notNeeded"
            try #require(treeIsReady)
            try #require(tree.ax.expectedPID == app.pid && tree.ax.kind == "describe")
            let treeContext = try #require(tree.context)
            try treeContext.requireMatch(app.catalogue)
            let treeAcquisition = try #require(tree.ax.acquisition)
            try #require(treeAcquisition.outcome == .ready && treeAcquisition.attempts.last?.rootPID == app.pid)
            let treeRoots = try #require(tree.ax.roots)
            let foundButton = UIStateParser.findElement(in: treeRoots, withIdentifier: "feature.tap")
            let button = try #require(foundButton)
            try #require(button.type == "Button" && button.enabled == true)
            let frame = try #require(button.frame)
            let frameIsFinite = [frame.x, frame.y, frame.width, frame.height].allSatisfy(\.isFinite)
            try #require(frameIsFinite)
            try #require(frame.width > 0 && frame.height > 0)
            let foundLabel = UIStateParser.findElement(in: button) { node in
                node.type == "StaticText" && node.label == "Tap counter"
            }
            let label = try #require(foundLabel)
            try #require(label.enabled == true)
            let labelFrame = try #require(label.frame)
            let pointX = frame.x + frame.width / 2
            let pointY = frame.y + frame.height / 2
            let point = "\(pointX),\(pointY)"
            let output = try await app.app.run(["describe-ui", "--point", point, "--expected-pid", String(app.pid)] + app.selection(), allowFailure: true)
            try Data(output.output.utf8).write(to: app.artifacts.appendingPathComponent("point-receipt.txt"))
            try #require(output.exitCode == 0, "Selected point read failed: \(output.output)")
            let response = try JSONDecoder().decode(ControlsPointReceipt.self, from: Data(output.output.utf8))
            let pointIsReady = response.outcome == "ready" && response.error == nil && response.enqueuedEventCount == 0 && response.cleanup == "notNeeded"
            try #require(pointIsReady)
            let context = try #require(response.context)
            try context.requireMatch(app.catalogue)
            try #require(response.ax.expectedPID == app.pid && response.ax.kind == "describePoint")
            let acquisition = try #require(response.ax.acquisition)
            try #require(acquisition.outcome == .ready && acquisition.attempts.last?.rootPID == app.pid)
            let roots = try #require(response.ax.roots)
            try #require(roots.count == 1)
            let hit = try #require(roots.first)
            // The runtime's hit test picks the element: iOS 27.2 returns the label inside the
            // button, iOS 27.3 the button itself. Either is the current app's element at the point.
            let hitIsLabel = hit.type == label.type && hit.label == label.label && hit.children?.isEmpty == true
            let hitIsButton = hit.type == button.type && hit.identifier == "feature.tap"
            try #require((hitIsLabel || hitIsButton) && hit.enabled == true)
            let hitFrame = try #require(hit.frame)
            let hitFrameIsFinite = [hitFrame.x, hitFrame.y, hitFrame.width, hitFrame.height].allSatisfy(\.isFinite)
            try #require(hitFrameIsFinite)
            try #require(hitFrame.width > 0 && hitFrame.height > 0)
            let containsPoint = pointX >= hitFrame.x && pointX < hitFrame.x + hitFrame.width
                && pointY >= hitFrame.y && pointY < hitFrame.y + hitFrame.height
            let expectedFrame = hitIsLabel ? labelFrame : frame
            let matchesFrame = hitFrame.x == expectedFrame.x && hitFrame.y == expectedFrame.y
                && hitFrame.width == expectedFrame.width && hitFrame.height == expectedFrame.height
            try #require(containsPoint && matchesFrame)
            _ = try await app.selected(["tap", "--label", "Text entry", "--element-type", "TextField", "--expected-pid", String(app.pid)])
            _ = try await app.documents.waitFor("label selector focused the real field") { $0.textFocused }
            _ = try await app.app.run(["type", "AXe selected value"])
            _ = try await app.documents.waitFor("exact text readback") { $0.text == "AXe selected value" }
            try await app.show("feature.dismissKeyboard")
            // The touch ends before the field gives up focus. Read the state only once it has,
            // or the next comparison sees the focus change as an effect of its own command.
            _ = try await app.documents.waitFor("the keyboard to be dismissed") { !$0.textFocused && $0.activeWindowTouches == 0 }
            for batch in [false, true] {
                let before = try app.documents.read()
                let arguments = ["tap", "--value", "AXe selected value", "--element-type", "TextField", "--expected-pid", String(app.pid)]
                if batch {
                    let output = try await app.app.run(["batch", "--step", arguments.map(controlsQuote).joined(separator: " ")] + app.selection())
                    let receipt = try controlsBatchReceipts(output.output).only()
                    try #require(receipt.status == "completed")
                } else { _ = try await app.selected(arguments) }
                let focused = try await app.documents.waitFor("exact-value selector focused the unchanged text") { $0.textFocused && $0.activeWindowTouches == 0 }
                try #require(focused.text == before.text && focused.count("textChanged") == before.count("textChanged"))
                try await app.show("feature.dismissKeyboard")
                // The touch ends before the field gives up focus. Read the state only once it has,
                // or the next comparison sees the focus change as an effect of its own command.
                _ = try await app.documents.waitFor("the keyboard to be dismissed") { !$0.textFocused && $0.activeWindowTouches == 0 }
            }
            for selector in [["--value", "AXe absent value", "--element-type", "TextField"], ["--id", "feature.text", "--element-type", "Button"]] {
                let before = try app.documents.read()
                let failure = try await app.selected(["tap"] + selector + ["--expected-pid", String(app.pid)], allowFailure: true)
                try #require(failure.error != nil && failure.outcome == "failedBeforeInput" && failure.enqueuedEventCount == 0 && failure.cleanup == "notNeeded")
                let after = try app.documents.read()
                try #require(after.text == before.text && after.textFocused == before.textFocused && after.windowTouchTrace.count == before.windowTouchTrace.count)
            }
            try await app.freshTap()
        }
    }
}

private struct ControlsPointReceipt: Decodable {
    let outcome: String
    let error: String?
    let enqueuedEventCount: Int
    let cleanup: String
    let context: DuoContext?
    let ax: AX
    struct AX: Decodable {
        let kind: String
        let expectedPID: Int32
        let roots: [UIElement]?
        let acquisition: DuoCLIResponse.Acquisition?
    }
}

enum PlaygroundSliderPosition: String, CaseIterable {
    case outer0, outer90, outer270, inner0, inner90, tabletop90
    var pose: DuoPlaygroundPose { self == .tabletop90 ? .tabletop : rawValue.hasPrefix("outer") ? .closed : .open }
    var rotation: Int {
        switch self { case .outer0, .inner0: return 0; case .outer270: return 270; case .outer90, .inner90, .tabletop90: return 90 }
    }
}

@Suite("Playground Duo Selected Slider Identity", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundDuoSelectedSliderTests {
    @Test("Native endpoints and exact identity preserve other sliders", arguments: PlaygroundSliderPosition.allCases)
    func exactIdentity(position: PlaygroundSliderPosition) async throws {
        try await withDuoPlaygroundScreen(pose: position.pose, rotation: position.rotation) {
            let app = try await PlaygroundControlsSession()
            try await app.show("feature.showTargets")
            for batch in [false, true] {
                for (endpoint, expected) in [("maximum", 100.0), ("minimum", 0.0), ("minimum", 0.0)] {
                    let before = try app.documents.read()
                    let arguments = ["slider", "--id", "feature.nativeSlider", "--endpoint", endpoint, "--element-type", "Slider", "--expected-pid", String(app.pid)]
                    let receipt: PlaygroundControlsReceipt
                    if batch {
                        let output = try await app.app.run(["batch", "--step", arguments.map(controlsQuote).joined(separator: " ")] + app.selection())
                        let step = try controlsBatchReceipts(output.output).only()
                        try #require(step.status == "completed")
                        receipt = try #require(step.response)
                    } else { receipt = try await app.selected(arguments, allowFailure: true) }
                    try #require(receipt.error == nil && receipt.enqueuedEventCount == 0 && receipt.cleanup == "notNeeded" && receipt.quarantine == nil)
                    let already = before.advancedSliders["exact"] == expected
                    try #require(receipt.outcome == (already ? "alreadyAtEndpoint" : "endpointObserved"))
                    let after = try await app.documents.waitFor("native endpoint \(expected)") { $0.advancedSliders["exact"] == expected && $0.activeWindowTouches == 0 }
                    for (key, value) in before.advancedSliders where key != "exact" { try #require(after.advancedSliders[key] == value) }
                    if already { try #require(after.count("slider.exact") == before.count("slider.exact")) }
                    try after.requireClear()
                }
            }
            // Both positive labels use their exact native identity; the second is a selected batch.
            for batch in [false, true] {
                let endpoint = batch ? "minimum" : "maximum"
                let expected = batch ? 0.0 : 100.0
                let arguments = ["slider", "--label", "Exact native slider", "--endpoint", endpoint, "--element-type", "Slider", "--expected-pid", String(app.pid)]
                let receipt: PlaygroundControlsReceipt
                if batch {
                    let output = try await app.app.run(batchArguments([arguments.map(controlsQuote).joined(separator: " ")]) + app.selection())
                    let row = try controlsBatchReceipts(output.output).only()
                    try #require(row.status == "completed")
                    receipt = try #require(row.response)
                } else { receipt = try await app.selected(arguments, allowFailure: true) }
                try #require(receipt.outcome == "endpointObserved" && receipt.error == nil && receipt.enqueuedEventCount == 0 && receipt.cleanup == "notNeeded")
                _ = try await app.documents.waitFor("exact native label reached \(expected)") { $0.advancedSliders["exact"] == expected }
            }
            for batch in [false, true] {
                for selector in [["--id", "feature.duplicateSlider"], ["--label", "Duplicate slider label"], ["--label", "Exact native"],
                                 ["--id", "feature.nativeSlider", "--element-type", "Button"], ["--id", "feature.tap"]] {
                    let before = try app.documents.read()
                    let arguments = ["slider"] + selector + ["--endpoint", "maximum", "--expected-pid", String(app.pid)]
                    let failure: PlaygroundControlsReceipt
                    if batch {
                        let output = try await app.app.run(batchArguments([arguments.map(controlsQuote).joined(separator: " "),
                            "tap --id feature.tap --expected-pid \(app.pid)"]) + app.selection(), allowFailure: true)
                        let rows = try controlsBatchReceipts(output.output)
                        try #require(output.exitCode != 0 && rows.count == 1 && rows[0].status == "failedResponse")
                        failure = try #require(rows[0].response)
                    } else { failure = try await app.selected(arguments, allowFailure: true) }
                    try #require(failure.error != nil && failure.enqueuedEventCount == 0 && failure.cleanup == "notNeeded" && failure.quarantine == nil)
                    let after = try app.documents.read()
                    try #require(after.advancedSliders == before.advancedSliders && after.counts == before.counts && after.windowTouchTrace.count == before.windowTouchTrace.count)
                    try after.requireClear()
                }
            }
            try app.preserveState("slider-identity-final")
        }
    }
}
