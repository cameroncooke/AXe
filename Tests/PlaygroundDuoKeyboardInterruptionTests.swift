import Foundation
import Testing

/// Public raw keyboard input, real field readback, layout change, then fresh raw input.
@Suite("Playground Duo Keyboard Interruption E2E", .serialized, .enabled(if: isDuoPlaygroundE2EEnabled))
struct PlaygroundDuoKeyboardInterruptionTests {
    @Test("Folding releases a held no-flag letter and fresh typing works")
    func heldLetterDuringFold() async throws { try await verify(.fold) }

    @Test("Rotating releases a held no-flag letter and fresh typing works")
    func heldLetterDuringRotation() async throws { try await verify(.rotate) }

    @Test("Folding stops a no-flag key sequence before the second key")
    func keySequenceDuringFold() async throws { try await verify(.fold, sequence: true) }

    @Test("Rotating stops a no-flag key sequence before the second key")
    func keySequenceDuringRotation() async throws { try await verify(.rotate, sequence: true) }

    private func verify(_ change: KeyboardLayoutChange, sequence: Bool = false) async throws {
        try await KeyboardInterruptionSession(change: change, sequence: sequence).run()
    }
}

private enum KeyboardLayoutChange: String { case fold, rotate }

private struct KeyboardInterruptionSession {
    let change: KeyboardLayoutChange
    let sequence: Bool
    let udid: String
    let cli: String
    let stateOperator: String
    let directory: URL

    init(change: KeyboardLayoutChange, sequence: Bool) throws {
        self.change = change
        self.sequence = sequence
        udid = try TestHelpers.requireSimulatorUDID()
        cli = try TestHelpers.getAxePath()
        let environment = ProcessInfo.processInfo.environment
        stateOperator = try #require(environment["AXE_DUO_STATE_CHANGE_PATH"], "Run the matrix to build the state operator.")
        try #require(FileManager.default.isExecutableFile(atPath: stateOperator))
        let artifacts = try #require(environment["AXE_E2E_ARTIFACT_DIR"], "Set the matrix artifact directory.")
        directory = URL(fileURLWithPath: artifacts).appendingPathComponent((sequence ? "key-sequence-" : "held-letter-") + change.rawValue)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    func run() async throws {
        let device = try DuoPlaygroundSession()
        let app = try AgentPlaygroundSession()
        let preparation = DuoStateReadWait.Preparation(phase: "before-input", artifacts: directory)
        let initial = try await DuoStateReadWait.$preparation.withValue(preparation) { try await device.catalogue() }
        _ = try await DuoStateReadWait.$preparation.withValue(preparation) { try await device.setPose(.open, boot: initial.bootIdentity) }
        // Make the normal page visible before asking its scene to change orientation.
        let pid = try await app.open("text-input", readyID: "text-input-field")
        var before = try await DuoStateReadWait.$preparation.withValue(preparation) { try await device.catalogue(boot: initial.bootIdentity) }
        for _ in 0..<4 {
            if try before.activePanel.rotationDegrees() == 90 { break }
            before = try await DuoStateReadWait.$preparation.withValue(preparation) { try await device.rotateRight(catalogue: before) }
        }
        try #require(try before.activePanel.rotationDegrees() == 90)
        _ = try await app.run(["tap", "--id", "text-input-field", "--element-type", "TextField"])
        _ = try await app.waitFor("focused normal text field") {
            UIStateParser.findElement(in: $0, withIdentifier: "typing-active-indicator") != nil
        }
        let prefix = "AXe held"
        _ = try await app.run(["type", prefix])
        try await app.waitForValue("text-input-field", equals: prefix)
        let arguments = sequence
            ? ["key-sequence", "--keycodes", "4,5", "--delay", "5", "--udid", udid]
            : ["key", "4", "--duration", "6", "--udid", udid]
        try save(arguments, name: "held-key-argv")
        let input = try PlaygroundTestProcess(executable: cli, arguments: arguments, directory: directory, name: "held-key")
        let panel = before.activePanel.identity
        let rotationPlan: DuoRotationPlan?
        if change == .rotate {
            let context = try await DuoStateReadWait.$preparation.withValue(preparation) {
                try await device.nativeContext(catalogue: before, pid: pid, artifacts: directory, name: "rotation-before-input")
            }
            rotationPlan = try DuoRotationPlan(catalogue: before, context: context)
        } else { rotationPlan = nil }
        let requestedDegrees = rotationPlan.map { Double($0.target) } ?? 0
        let foldControl: DuoHeldLayoutControl? = try DuoHeldLayoutControl(boot: before.bootIdentity,
            udid: udid, degrees: requestedDegrees, artifacts: directory, rotation: rotationPlan)
        let operatorArguments = [change == .fold ? "fold-write-held" : "rotate-write-held", before.bootIdentity, String(panel.displayID), panel.uniqueID.uuidString,
            String(requestedDegrees), directory.appendingPathComponent("state-change-marker.json").path, udid,
            URL(fileURLWithPath: cli).deletingLastPathComponent().appendingPathComponent("cadisplay-context").path]
            + (foldControl?.arguments ?? [])
        try save(operatorArguments, name: "external-change-argv")
        let external = try PlaygroundTestProcess(executable: stateOperator, arguments: operatorArguments,
            directory: directory, name: "external-change")
        do {
            try input.start()
            let observed = try await waitForLetter(app: app, prefix: prefix, input: input)
            try save(observed, name: "text-before-change")
            try #require(input.isRunning, "The held key ended before the layout change.")
            try external.start()
            var changeReceipt: KeyboardExternalStateReceipt?
            var rotationConfirmation: DuoRotationConfirmation?
            if let foldControl {
                try await foldControl.waitForReady(external)
                try await input.wait(timeout: foldControl.remaining())
            } else {
                try await external.wait(timeout: 20)
                let operatorDiagnostics = try external.diagnostics()
                try #require(external.exitCode == 0, "The layout change failed: \(operatorDiagnostics)")
                changeReceipt = try JSONDecoder().decode(KeyboardExternalStateReceipt.self, from: Data(try external.output().utf8))
                try await input.wait(timeout: 15)
            }
            let diagnostics = try input.diagnostics()
            try #require(input.exitCode == 1, "The held key did not stop: \(diagnostics)")
            // The native interruption must confirm release. Outer close can need no further release.
            let nativeFailure = "Error: Duo input stopped: interrupted(reason: "
                + "FBSimulatorControl.FBSimulatorHIDInterruption.staleContext, cleanup: "
                + "FBSimulatorControl.FBSimulatorHIDCleanupOutcome.releaseEnqueuedAndDrained); "
            var allowedErrors = [
                nativeFailure + "cleanup=releaseEnqueuedAndDrained. Input was not replayed.",
                nativeFailure + "cleanup=notNeeded. Input was not replayed.",
            ]
            if sequence {
                let idleFailure = "Error: Duo input stopped: interrupted(reason: "
                    + "FBSimulatorControl.FBSimulatorHIDInterruption.staleContext, cleanup: "
                    + "FBSimulatorControl.FBSimulatorHIDCleanupOutcome.notNeeded); "
                allowedErrors += [idleFailure + "cleanup=notNeeded. Input was not replayed."]
            }
            let errors = diagnostics.split(separator: "\n").map(String.init).filter { $0.hasPrefix("Error:") }
            try #require(errors.count == 1 && allowedErrors.contains(errors[0]),
                "Raw key input lacks confirmed native release and no-replay evidence: \(diagnostics)")
            try save(errors, name: "confirmed-native-release-error")
            if let foldControl {
                rotationConfirmation = try await foldControl.confirmTargetAndRelease(external, device: device, pid: pid)
                let operatorDiagnostics = try external.diagnostics()
                try #require(external.exitCode == 0, "The layout change failed: \(operatorDiagnostics)")
                changeReceipt = try JSONDecoder().decode(KeyboardExternalStateReceipt.self, from: Data(try external.output().utf8))
            }
            let changed = try #require(changeReceipt)
            if let foldControl {
                try foldControl.requireCompleted(changed.connectionHold,
                    started: changed.startedUptime, finished: changed.finishedUptime)
            }
            let released = try await text(app: app, name: "after-owned-release")
            try requireOnlyLettersAdded(released, prefix: prefix)
            for index in 0..<4 {
                try await Task.sleep(nanoseconds: 250_000_000)
                let settled = try await text(app: app, name: "settled-release-\(index)")
                try #require(settled == released, "Text changed after the confirmed key release.")
            }
            let recovery = try DuoStateReadWait(phase: "after-writer-close", artifacts: directory)
            let after = try await DuoStateReadWait.$current.withValue(recovery) { () async throws -> DuoCatalogue in
            if change == .fold {
                let write = try #require(changed.write)
                try await device.requireExternalFold(write, boot: before.bootIdentity, degrees: 0,
                    after: changed.finishedUptime, artifacts: directory)
            }
            if let rotationPlan {
                let write = try #require(changed.write)
                rotationConfirmation = try await device.requireExternalRotation(write, plan: rotationPlan, pid: pid,
                    after: changed.finishedUptime, artifacts: directory, artifactPrefix: "post-close-rotation")
                return try #require(rotationConfirmation).catalogue
            }
            return try await device.stableCatalogue(boot: before.bootIdentity, expectedScreenID: 1)
            }
            try requireLayoutChange(changed, before: before, after: after, rotation: rotationConfirmation)
            // Read the new tree before a new tap. No old coordinates or action replay are used.
            let fresh = try await text(app: app, name: "fresh-field-before-tap")
            try #require(fresh == released)
            _ = try await app.run(["tap", "--id", "text-input-field", "--element-type", "TextField"])
            _ = try await app.waitFor("refocused normal text field") {
                UIStateParser.findElement(in: $0, withIdentifier: "typing-active-indicator") != nil
            }
            _ = try await app.run(["key-combo", "--modifiers", "227", "--key", "4"])
            _ = try await app.run(["key", "42"])
            try await app.waitForValue("text-input-field", equals: "empty")
            let replacement = "fresh after " + change.rawValue
            _ = try await app.run(["type", replacement])
            try await app.waitForValue("text-input-field", equals: replacement)
            try await app.waitForValue("character-count", equals: String(replacement.count))
            let finalText = try await text(app: app, name: "fresh-exact-text")
            try #require(finalText == replacement)
            let final = try await device.catalogue(boot: before.bootIdentity)
            try #require(final.activePanel == after.activePanel, "Fresh keyboard input changed the measured display.")
            try save(["change": change.rawValue, "appPID": String(pid), "cleanup": sequence ? "between-keys-no-owned-contact" : "releaseEnqueuedAndDrained",
                "freshText": finalText, "osPressedKeyInventory": "UNVERIFIED", "inputReplayed": "false"], name: "result")
            print("Duo raw key interruption passed: \(change.rawValue), owned release confirmed, fresh text=\(finalText). OS key inventory is unverified.")
        } catch {
            do { try foldControl?.abort() }
            catch { Issue.record("Cannot publish held fold abort: \(error)") }
            await external.finish()
            await input.finish()
            throw error
        }
        await external.finish()
        await input.finish()
    }

    private func waitForLetter(app: AgentPlaygroundSession, prefix: String, input: PlaygroundTestProcess) async throws -> String {
        let deadline = ProcessInfo.processInfo.systemUptime + 9
        var attempt = 0
        repeat {
            try #require(input.isRunning, "Held key ended before its real letter effect.")
            let value = try await text(app: app, name: "held-key-read-\(attempt)")
            try #require(input.isRunning, "Held key ended before the external change could start.")
            if value != prefix {
                try requireOnlyLettersAdded(value, prefix: prefix)
                return value
            }
            attempt += 1
            try await Task.sleep(nanoseconds: 30_000_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw TestError.unexpectedState("No real letter effect was observed before the layout change.")
    }

    private func text(app: AgentPlaygroundSession, name: String) async throws -> String {
        let output = try await app.run(["describe-ui"])
        try output.output.write(to: directory.appendingPathComponent(name + ".stdout"), atomically: false, encoding: .utf8)
        let roots = try UIStateParser.parseDescribeUIRoots(output.output)
        let field = try #require(UIStateParser.findElement(in: roots, withIdentifier: "text-input-field"))
        try #require(field.type == "TextField" && field.enabled == true)
        let value = try #require(field.value)
        let count = try #require(UIStateParser.findElement(in: roots, withIdentifier: "character-count")?.value)
        try #require(count == String(value.count), "Field text and the visible character count differ.")
        return value
    }

    private func requireOnlyLettersAdded(_ value: String, prefix: String) throws {
        try #require(value.hasPrefix(prefix))
        let suffix = value.dropFirst(prefix.count)
        try #require(!suffix.isEmpty && suffix.allSatisfy { $0 == "a" }, "The held key did not add only letter a characters.")
    }

    private func requireLayoutChange(_ value: KeyboardExternalStateReceipt, before: DuoCatalogue, after: DuoCatalogue,
                                     rotation: DuoRotationConfirmation?) throws {
        try #require(value.mode == (change == .fold ? "fold-write-held" : "rotate-write-held")
            && value.finishedUptime >= value.startedUptime)
        if change == .fold {
            try #require(value.write != nil && value.hinge == nil && value.rotation == nil)
            try #require(after.activePanel.identity != before.activePanel.identity, "Folding did not change the active screen.")
        } else {
            let rotation = try #require(rotation)
            try #require(value.rotation == nil && value.write?.source == "orientation-picker-control")
            try #require(value.write?.vendorEventCount == 1 && rotation.matchingObservationCount == 2
                && rotation.before.rotationDegrees != rotation.after.rotationDegrees)
            let finalRotation = try after.activePanel.rotationDegrees()
            try #require(after.activePanel.identity == before.activePanel.identity
                && finalRotation == rotation.after.rotationDegrees)
        }
    }

    private func save<Value: Encodable>(_ value: Value, name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: directory.appendingPathComponent(name + ".json"), options: .withoutOverwriting)
    }
}

private struct KeyboardExternalStateReceipt: Decodable {
    let mode: String
    let startedUptime: TimeInterval
    let finishedUptime: TimeInterval
    let write: DuoExternalLayoutWrite?
    let connectionHold: DuoExternalConnectionHold?
    let hinge: Hinge?
    let rotation: DuoCLIResponse.RotationReceipt?

    struct Hinge: Decodable {
        let outcome: String
        let requestedDegrees: Double
        let wasAlreadyWithinTolerance: Bool
        let matchingSamples: [DuoCLIResponse.HingeSample]
    }
}
