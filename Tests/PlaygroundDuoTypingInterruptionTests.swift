import Foundation
import Testing

@Suite("Playground Duo Typing Interruption E2E", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundDuoTypingInterruptionTests {
    @Test("Folding stops a long raw type action and fresh outer typing works")
    func typingDuringFold() async throws {
        try await preparePlaygroundChangingScreen(pose: .open, rotation: 90) {
            let controls = try await PlaygroundControlsSession()
            try await controls.show("feature.showText")
            _ = try await controls.app.run(["tap", "--id", "feature.text", "--element-type", "TextField"])
            _ = try await controls.documents.waitFor("real text focus") { $0.textFocused && $0.activeWindowTouches == 0 }
            let cli = try TestHelpers.getAxePath()
            let stateOperator = try #require(ProcessInfo.processInfo.environment["AXE_DUO_STATE_CHANGE_PATH"])
            let catalogue = controls.catalogue
            let pair = catalogue.activePanel.identity
            let helper = URL(fileURLWithPath: cli).deletingLastPathComponent().appendingPathComponent("cadisplay-context").path
            let text = String(repeating: "a", count: 256)
            let input = try PlaygroundTestProcess(executable: cli,
                arguments: ["type", text, "--udid", controls.app.udid], directory: controls.artifacts, name: "long-type")
            let external = try PlaygroundTestProcess(executable: stateOperator, arguments: ["fold", catalogue.bootIdentity,
                String(pair.displayID), pair.uniqueID.uuidString, "0", controls.artifacts.appendingPathComponent("fold-marker.json").path,
                controls.app.udid, helper], directory: controls.artifacts, name: "external-fold")
            do {
                try input.start()
                let deadline = ProcessInfo.processInfo.systemUptime + 10
                var hasInput = false
                repeat {
                    try #require(input.isRunning, "Typing finished before a real partial edit was observed.")
                    let state = try controls.documents.read()
                    if !state.text.isEmpty {
                        try #require(state.text.count < text.count && state.text.allSatisfy { $0 == "a" })
                        try #require(state.count("textChanged") == state.text.count)
                        hasInput = true
                        break
                    }
                    try await Task.sleep(nanoseconds: 20_000_000)
                } while ProcessInfo.processInfo.systemUptime < deadline
                try #require(hasInput && input.isRunning, "No fold was sent without real ongoing typing.")
                try controls.preserveState("partial-text-before-fold")
                try external.start()
                try await external.wait(timeout: 20)
                let changeOutput = try external.diagnostics()
                try #require(external.exitCode == 0, "Fold failed: \(changeOutput)")
                try await input.wait(timeout: 15)
                let diagnostic = try input.diagnostics()
                try #require(input.exitCode == 1, "Long typing did not stop: \(diagnostic)")
                let base = "Error: Duo input stopped: interrupted(reason: FBSimulatorControl.FBSimulatorHIDInterruption.staleContext, cleanup: FBSimulatorControl.FBSimulatorHIDCleanupOutcome."
                let suffix = ". Input was not replayed."
                let accepted = [
                    base + "releaseEnqueuedAndDrained); cleanup=releaseEnqueuedAndDrained" + suffix,
                    base + "releaseEnqueuedAndDrained); cleanup=notNeeded" + suffix,
                    base + "notNeeded); cleanup=notNeeded" + suffix,
                ]
                let errors = diagnostic.split(separator: "\n").map(String.init).filter { $0.hasPrefix("Error:") }
                try #require(errors.count == 1 && accepted.contains(errors[0]), "Native stop/release is not confirmed: \(diagnostic)")
                let released = try controls.documents.read()
                try #require(!released.text.isEmpty && released.text.count < text.count && released.text.allSatisfy { $0 == "a" })
                try #require(released.count("textChanged") == released.text.count)
                try released.requireClear()
                for _ in 0..<4 {
                    try await Task.sleep(nanoseconds: 250_000_000)
                    let stable = try controls.documents.read()
                    try #require(stable.text == released.text && stable.count("textChanged") == released.count("textChanged"))
                }
                let after = try await DuoPlaygroundSession().catalogue(boot: catalogue.bootIdentity)
                try #require(after.activePanel.identity != pair)
                try await runPlaygroundRefindProof(controls)
                try await controls.show("feature.showText")
                _ = try await controls.app.run(["tap", "--id", "feature.text", "--element-type", "TextField"])
                _ = try await controls.documents.waitFor("fresh outer focus") { $0.textFocused && $0.activeWindowTouches == 0 }
                _ = try await controls.app.run(["key-combo", "--modifiers", "227", "--key", "4"])
                _ = try await controls.app.run(["key", "42"])
                _ = try await controls.documents.waitFor("real text deletion") { $0.text.isEmpty }
                _ = try await controls.app.run(["type", "fresh after fold"])
                let final = try await controls.documents.waitFor("exact new outer text") { $0.text == "fresh after fold" && $0.activeWindowTouches == 0 }
                try final.requireClear()
                try controls.preserveState("fresh-outer-text-after-stopped-type")
            } catch {
                await external.finish()
                await input.finish()
                throw error
            }
            await external.finish()
            await input.finish()
        }
    }
}
