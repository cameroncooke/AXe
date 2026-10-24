import Foundation
import Testing

@Suite("Playground Duo Held Modifier E2E", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundDuoHeldModifierTests {
    @Test("Folding releases the held A and Shift keys, then lowercase input works")
    func heldModifierDuringFold() async throws { try await verify(mode: "fold") }

    @Test("Rotating releases the held A and Shift keys, then lowercase input works")
    func heldModifierDuringRotation() async throws { try await verify(mode: "rotate") }

    private func verify(mode: String) async throws {
        try await preparePlaygroundChangingScreen(pose: .open, rotation: 90) {
            let controls = try await PlaygroundControlsSession()
            try await controls.show("feature.showText")
            _ = try await controls.app.run(["tap", "--id", "feature.text", "--element-type", "TextField"])
            _ = try await controls.documents.waitFor("real focused field") { $0.textFocused && $0.activeWindowTouches == 0 }
            let environment = ProcessInfo.processInfo.environment
            let probe = try #require(environment["AXE_DUO_HELD_MODIFIER_PROBE_PATH"])
            let stateOperator = try #require(environment["AXE_DUO_STATE_CHANGE_PATH"])
            try #require(FileManager.default.isExecutableFile(atPath: probe))
            try #require(FileManager.default.isExecutableFile(atPath: stateOperator))
            let cli = try TestHelpers.getAxePath()
            let helper = URL(fileURLWithPath: cli).deletingLastPathComponent().appendingPathComponent("cadisplay-context").path
            let catalogue = controls.catalogue
            let pair = catalogue.activePanel.identity
            let markerURL = controls.artifacts.appendingPathComponent("modifier-down.json")
            let arguments = ["FBSIMULATORCONTROL_LOG_HID_DETAILS=1", probe, controls.app.udid,
                catalogue.bootIdentity, String(pair.displayID), pair.uniqueID.uuidString,
                helper, "shift-a", markerURL.path]
            try JSONEncoder().encode(arguments).write(to: controls.artifacts.appendingPathComponent("modifier-argv.json"))
            let input = try PlaygroundTestProcess(executable: "/usr/bin/env", arguments: arguments,
                directory: controls.artifacts, name: "modifier")
            let external = try PlaygroundTestProcess(executable: stateOperator, arguments: [mode,
                catalogue.bootIdentity, String(pair.displayID), pair.uniqueID.uuidString, "0",
                controls.artifacts.appendingPathComponent("external-marker.json").path, controls.app.udid, helper],
                directory: controls.artifacts, name: "external")
            do {
                try input.start()
                let marker = try await waitForHeldModifier(input: input, markerURL: markerURL, controls: controls)
                try #require(marker.source == "publicLibrarySessionStatus" && marker.button == "shift-a")
                try #require(marker.normalDownSentCount == 2 && marker.state == "executing")
                try #require(marker.normalSendCompleted && !marker.wholeGestureDrainCompleted)
                try #require(marker.boot == catalogue.bootIdentity && marker.screenID == pair.displayID)
                try #require(UUID(uuidString: marker.device) == UUID(uuidString: controls.app.udid))
                try #require(UUID(uuidString: marker.screenUUID) == pair.uniqueID)
                try controls.preserveState("real-uppercase-before-change")
                try #require(input.isRunning)
                try external.start()
                try await external.wait(timeout: 20)
                let externalOutput = try external.diagnostics()
                try #require(external.exitCode == 0, "External change failed: \(externalOutput)")
                let changed = try JSONDecoder().decode(PlaygroundExternalLayoutReceipt.self, from: Data(try external.output().utf8))
                try #require(changed.mode == mode && changed.startedUptime > marker.capturedUptime)
                try await input.wait(timeout: 15)
                let output = try input.diagnostics()
                try #require(input.exitCode == 1, "Held modifier did not stop: \(output)")
                let receipt = try JSONDecoder().decode(PlaygroundNativeHoldReceipt.self, from: Data(try input.output().utf8))
                try #require(receipt.downMarkerWritten && receipt.outcome == "failedNoReplay")
                try #require(receipt.normalEventCount == 2 && receipt.phase == "delay" && receipt.normalDrainCompleted == false)
                try #require(receipt.interruption?.contains("staleContext") == true && receipt.cleanup == "releaseEnqueuedAndDrained")
                let runtimeDirectory = URL(fileURLWithPath: cli).deletingLastPathComponent().standardized.path + "/"
                try #require(receipt.frameworkPath.hasPrefix(runtimeDirectory))
                let cleanup = try #require(receipt.cleanupEvidence)
                try cleanup.requireOwnedReleases(["Keyboard Code=4 up", "Keyboard Code=225 up"],
                    messageType: "IndigoKeyboardButtonEvent", catalogue: catalogue,
                    udid: controls.app.udid, changedAt: changed.startedUptime)
                let released = try controls.documents.read()
                try #require(!released.text.isEmpty && released.text.allSatisfy { $0 == "A" })
                try #require(released.count("textChanged") == released.text.count)
                try released.requireClear()
                for _ in 0..<4 {
                    try await Task.sleep(nanoseconds: 250_000_000)
                    let stable = try controls.documents.read()
                    try #require(stable.text == released.text && stable.count("textChanged") == released.count("textChanged"))
                }
                let after = try await DuoPlaygroundSession().catalogue(boot: catalogue.bootIdentity)
                if mode == "fold" { try #require(after.activePanel.identity != pair) }
                else {
                    let rotation = try after.activePanel.rotationDegrees()
                    try #require(after.activePanel.identity == pair && rotation != 90)
                }
                try await controls.freshTap()
                try await controls.show("feature.showText")
                _ = try await controls.app.run(["tap", "--id", "feature.text", "--element-type", "TextField"])
                _ = try await controls.documents.waitFor("fresh field focus") { $0.textFocused && $0.activeWindowTouches == 0 }
                _ = try await controls.app.run(["type", "a"])
                let lower = try await controls.documents.waitFor("lowercase proves Shift is released") {
                    $0.text == released.text + "a" && $0.count("textChanged") == released.count("textChanged") + 1
                }
                try lower.requireClear()
                try controls.preserveState("fresh-lowercase-after-release")
            } catch {
                await external.finish()
                await input.finish()
                throw error
            }
            await external.finish()
            await input.finish()
        }
    }

    private func waitForHeldModifier(input: PlaygroundTestProcess, markerURL: URL,
                                     controls: PlaygroundControlsSession) async throws -> PlaygroundNativeDownMarker {
        let deadline = ProcessInfo.processInfo.systemUptime + 9
        while ProcessInfo.processInfo.systemUptime < deadline {
            try #require(input.isRunning, "The held modifier ended before actual app input.")
            if FileManager.default.fileExists(atPath: markerURL.path) {
                let marker = try JSONDecoder().decode(PlaygroundNativeDownMarker.self, from: Data(contentsOf: markerURL))
                let state = try controls.documents.read()
                if !state.text.isEmpty {
                    try #require(state.text.allSatisfy { $0 == "A" })
                    try #require(state.count("textChanged") == state.text.count)
                    try #require(input.isRunning)
                    return marker
                }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw TestError.unexpectedState("No real uppercase app edit and held-DOWN marker; no external change was sent.")
    }
}
