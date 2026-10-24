import Foundation
import Testing

@Suite("Playground Duo Hardware E2E", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundDuoHardwareTests {
    @Test("Selected Siri default and timed presses complete and release", arguments: [false, true])
    func selectedSiri(timed: Bool) async throws {
        try await hardwareScreen {
            let check = try await HardwareAcceptanceSession()
            var arguments = ["button", "siri", "--expected-boot", check.controls.catalogue.bootIdentity]
            if timed { arguments += ["--duration", "0.2"] }
            let receipt = try await check.selected(arguments)
            try receipt.requireComplete(kind: "siri", events: 2, controls: check.controls)
            try await check.returnToSameApp()
            try await check.controls.freshTap()
        }
    }

    @Test("A wrong boot rejects selected Siri before any hardware input")
    func wrongBootSiri() async throws {
        try await hardwareScreen {
            let check = try await HardwareAcceptanceSession()
            let before = try check.controls.documents.read()
            let receipt = try await check.selected(["button", "siri", "--expected-boot", "wrong-boot"], allowFailure: true)
            try #require(receipt.outcome == "failedBeforeInput" && receipt.enqueuedEventCount == 0)
            try #require(receipt.cleanup == "notNeeded" && receipt.quarantine == nil && receipt.error != nil)
            let after = try check.controls.documents.read()
            try #require(before.counts == after.counts && before.text == after.text
                && before.slider == after.slider && before.switchOn == after.switchOn)
            try after.requireClear()
            try await check.controls.freshTap()
        }
    }

    @Test("Selected Lock shows the clock and changes the backlight state")
    func selectedLock() async throws {
        try await hardwareScreen {
            let check = try await HardwareAcceptanceSession()
            _ = try await check.waitForBacklight("activeOn")
            let receipt = try await check.selected(["button", "lock",
                "--expected-boot", check.controls.catalogue.bootIdentity])
            try receipt.requireComplete(kind: "lock", events: 2, controls: check.controls)
            _ = try await check.waitForBacklight("inactiveOn")
            _ = try await check.waitForClock()
            try await check.returnToSameApp()
            try await check.controls.freshTap()
        }
    }

    @Test("Selected side-button wakes the display and exposes the open control")
    func selectedWake() async throws {
        try await hardwareScreen {
            let check = try await HardwareAcceptanceSession()
            let lock = try await check.selected(["button", "side-button", "--duration", "0.2",
                "--expected-boot", check.controls.catalogue.bootIdentity])
            try lock.requireComplete(kind: "side-button", events: 2, controls: check.controls)
            _ = try await check.waitForBacklight("inactiveOn")
            _ = try await check.waitForClock()
            let wake = try await check.selected(["button", "side-button", "--duration", "0.2",
                "--expected-boot", check.controls.catalogue.bootIdentity])
            try wake.requireComplete(kind: "side-button", events: 2, controls: check.controls)
            _ = try await check.waitForBacklight("activeOn")
            _ = try await check.waitForClock()
            try await check.returnToSameApp()
            try await check.controls.freshTap()
        }
    }

    @Test("Apple Pay sends four released hardware events; payment UI is excluded", arguments: [false, true])
    func applePayDelivery(batch: Bool) async throws {
        try await hardwareScreen {
            let check = try await HardwareAcceptanceSession()
            let receipt: HardwareAcceptanceReceipt
            if batch {
                let output = try await check.command(["batch", "--step", "button apple-pay --duration 0.2 --expected-boot "
                    + check.controls.catalogue.bootIdentity] + check.controls.selection())
                let line = output.output.split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
                let step = try JSONDecoder().decode(HardwareBatchReceipt.self, from: Data(line.utf8))
                try #require(step.index == 1 && step.totalSteps == 1 && step.command == "button" && step.status == "completed")
                receipt = try #require(step.response)
            } else {
                receipt = try await check.selected(["button", "apple-pay", "--expected-boot", check.controls.catalogue.bootIdentity])
            }
            try receipt.requireComplete(kind: "apple-pay", events: 4, controls: check.controls)
            try await check.returnToSameApp()
            try await check.controls.freshTap()
        }
    }

    @Test("Legacy Siri exposes the Siri window and enabled Listen button")
    func legacySiriActivation() async throws { try await siriActivation(selected: false) }

    @Test("Selected Siri exposes the Siri window and enabled Listen button")
    func selectedSiriActivation() async throws { try await siriActivation(selected: true) }

    private func siriActivation(selected: Bool) async throws {
        try await hardwareScreen {
            let check = try await HardwareAcceptanceSession()
            let before = try await check.globalTree()
            try #require(UIStateParser.findElement(in: before, matching: check.isSiriControl) == nil)
            try #require(UIStateParser.findElement(in: before, withIdentifier: "siri-interface-window") == nil)
            if selected {
                let response = try await check.selected(["button", "siri", "--duration", "0.2",
                    "--expected-boot", check.controls.catalogue.bootIdentity])
                try response.requireComplete(kind: "siri", events: 2, controls: check.controls)
            } else {
                _ = try await check.command(["button", "siri", "--input-mode", "legacy", "--duration", "0.2"])
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            var found = false
            repeat {
                let roots = try await check.globalTree()
                let listen = UIStateParser.findElement(in: roots, matching: check.isSiriControl)
                let window = UIStateParser.findElement(in: roots, withIdentifier: "siri-interface-window")
                if listen != nil && window?.enabled == true { found = true; break }
                try await Task.sleep(nanoseconds: 100_000_000)
            } while ProcessInfo.processInfo.systemUptime < deadline
            try #require(found, "The accepted Siri input did not expose its real window and enabled Listen button.")
            try await check.returnToSameApp()
            try await check.controls.freshTap()
        }
    }

    private func hardwareScreen(check: () async throws -> Void) async throws {
        try await preparePlaygroundChangingScreen(pose: .closed, rotation: 0, check: check)
    }
}

struct HardwareAcceptanceSession {
    let controls: PlaygroundControlsSession
    init() async throws { controls = try await PlaygroundControlsSession() }
    init(controls: PlaygroundControlsSession) { self.controls = controls }

    func command(_ arguments: [String], allowFailure: Bool = false) async throws -> CommandOutput {
        let result = try await controls.app.run(arguments, allowFailure: true)
        let name = UUID().uuidString
        let invocation = [try TestHelpers.getAxePath()] + arguments + ["--udid", controls.app.udid]
        try JSONEncoder().encode(invocation).write(to: controls.artifacts.appendingPathComponent(name + "-argv.json"))
        try Data(result.output.utf8).write(to: controls.artifacts.appendingPathComponent(name + "-output.txt"))
        if !allowFailure { try #require(result.exitCode == 0, "Hardware command failed: \(result.output)") }
        else { try #require(result.exitCode == 1) }
        return result
    }

    func selected(_ arguments: [String], allowFailure: Bool = false) async throws -> HardwareAcceptanceReceipt {
        let output = try await command(arguments + controls.selection(), allowFailure: allowFailure)
        let line = output.output.split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
        return try JSONDecoder().decode(HardwareAcceptanceReceipt.self, from: Data(line.utf8))
    }

    func globalTree() async throws -> [UIElement] {
        let result = try await command(["describe-ui"])
        return try UIStateParser.parseDescribeUIRoots(result.output)
    }

    func isSiriControl(_ node: UIElement) -> Bool {
        node.enabled == true && node.type == "Button" && node.identifier == "Listen" && node.label == "Listen"
    }

    func waitForBacklight(_ expected: String) async throws -> HardwarePowerCatalogue {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        repeat {
            let result = try await command(["list-simulators", "--displays"])
            let value = try JSONDecoder().decode(HardwarePowerCatalogue.self, from: Data(result.output.utf8))
            try #require(value.bootIdentity == controls.catalogue.bootIdentity)
            try #require(value.activePanel.identity == controls.catalogue.activePanel.identity)
            if value.activePanel.backlightState == expected { return value }
            try await Task.sleep(nanoseconds: 100_000_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw TestError.unexpectedState("The display backlight did not become " + expected + ".")
    }

    func waitForClock() async throws -> [UIElement] {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        repeat {
            let roots = try await globalTree()
            let cover = UIStateParser.findElement(in: roots, withIdentifier: "SBCoverSheetWindow")
            let date = UIStateParser.findElement(in: roots, withIdentifier: "lockscreen-date-view")
            let prompt = UIStateParser.findElement(in: roots) {
                ["Swipe up to open", "Swipe up to unlock"].contains($0.label ?? "")
            }
            if cover != nil && date != nil && prompt != nil { return roots }
            try await Task.sleep(nanoseconds: 100_000_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw TestError.unexpectedState("No real Swipe up to open control was observed.")
    }

    func returnToSameApp() async throws {
        // These are new explicit UI actions after the hardware receipt, never replay of that request.
        let result = try await command(["list-simulators", "--displays"])
        let power = try JSONDecoder().decode(HardwarePowerCatalogue.self, from: Data(result.output.utf8))
        let freshCatalogue = try await DuoPlaygroundSession().catalogue(boot: controls.catalogue.bootIdentity)
        if power.activePanel.backlightState == "inactiveOn" {
            let pair = freshCatalogue.activePanel.identity
            let output = try await command(["button", "side-button", "--duration", "0.2",
                "--expected-boot", freshCatalogue.bootIdentity, "--input-mode", "selected",
                "--screen-id", String(pair.displayID), "--screen-uuid", pair.uniqueID.uuidString])
            let line = output.output.split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
            let wake = try JSONDecoder().decode(HardwareAcceptanceReceipt.self, from: Data(line.utf8))
            try wake.requireComplete(kind: "side-button", events: 2, controls: controls, catalogue: freshCatalogue)
        }
        let roots = try await globalTree()
        if UIStateParser.findElement(in: roots, matching: { $0.label == "Swipe up to open" }) != nil {
            let root = try #require(roots.first(where: { $0.type == "Application" }))
            let frame = try #require(root.frame)
            let x = frame.x + frame.width / 2
            _ = try await command(["swipe", "--start-x", String(x), "--start-y", String(frame.y + frame.height - 2),
                "--end-x", String(x), "--end-y", String(frame.y + frame.height * 0.25), "--duration", "0.5"])
        } else if UIStateParser.findElement(in: roots, matching: isSiriControl) != nil {
            _ = try await command(["button", "home", "--duration", "0.2"])
        }
        let launch = ["xcrun", "simctl", "launch", controls.app.udid, "com.cameroncooke.AxePlayground"]
        let resumed = try await CommandRunner.run(launch.map(playgroundShellQuote).joined(separator: " "), timeout: 30)
        let expected = "com.cameroncooke.AxePlayground: " + String(controls.pid)
        try #require(resumed.output.trimmingCharacters(in: .whitespacesAndNewlines) == expected,
            "Hardware return changed the app process: \(resumed.output)")
        _ = try await controls.frame("feature.tap")
        try controls.documents.read().requireClear()
    }
}

struct HardwarePowerCatalogue: Decodable {
    let bootIdentity: String
    let activePanel: Panel
    struct Panel: Decodable {
        let identity: DuoPanelIdentity
        let backlightState: String?
    }
}

private struct HardwareBatchReceipt: Decodable {
    let index: Int
    let totalSteps: Int
    let command: String?
    let status: String
    let response: HardwareAcceptanceReceipt?
}

struct HardwareAcceptanceReceipt: Decodable {
    let outcome: String
    let enqueuedEventCount: Int
    let cleanup: String
    let error: String?
    let quarantine: DuoCLIResponse.Quarantine?
    let context: DuoContext?
    let button: Button?
    struct Button: Decodable { let kind: String; let execution: Execution }
    struct Execution: Decodable {
        let schemaVersion: Int
        let simulatorUDID: String
        let boundContext: DuoContext
        let phase: String
        let plannedPrimitiveCount: Int
        let sentPrimitiveCount: Int
        let allInputsReleasedBeforeCleanup: Bool
        let drainCompleted: Bool
        let interruption: Interruption?
        let executionCleanup: String
        let startedUptime: Double
        let finishedUptime: Double
        struct Interruption: Decodable { let kind: String }
    }
    func requireComplete(kind: String, events: Int, controls: PlaygroundControlsSession,
                         catalogue: DuoCatalogue? = nil) throws {
        try #require(outcome == "enqueuedAndDrained" && enqueuedEventCount == events)
        try #require(cleanup == "notNeeded" && error == nil && quarantine == nil)
        let context = try #require(context)
        try context.requireMatch(catalogue ?? controls.catalogue)
        let button = try #require(button)
        let execution = button.execution
        try #require(button.kind == kind && execution.schemaVersion == 1)
        try #require(UUID(uuidString: execution.simulatorUDID) == UUID(uuidString: controls.app.udid))
        try #require(execution.boundContext == context && execution.phase == "completed")
        try #require(execution.plannedPrimitiveCount == events && execution.sentPrimitiveCount == events)
        try #require(execution.allInputsReleasedBeforeCleanup && execution.drainCompleted)
        try #require(execution.interruption == nil && execution.executionCleanup == "notNeeded")
        try #require(execution.finishedUptime >= execution.startedUptime)
    }
}
