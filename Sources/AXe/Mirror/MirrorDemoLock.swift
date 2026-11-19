#if AXE_MIRROR
@preconcurrency import FBControlCore
import FBSimulatorControl
import Foundation

/// Keeps a demo's visitor inside the sample app.
///
/// The simulator has no setting that pins it to one app, so the lock is held from outside. Four
/// times a second, while a visitor is connected, the host asks the simulator which app is in front
/// (a look takes about 45 ms). A
/// touch is passed on only while that is the sample app. When it is another app, the visitor's
/// touches are dropped and the sample app is brought back at once. `MirrorDemo.lockStep` holds
/// the rule; this class does the asking and the bringing back.
///
/// The sample app is started with the arguments `--launch-arg demo=1`, which it may use to show
/// only what suits a visitor. AXe's own playground then leaves out every screen with a text
/// field, a web page or a system prompt, because those are how a person gets out of an app.
final class MirrorDemoLock: @unchecked Sendable {
    private let simulator: FBSimulator
    private let app: String
    private let note: (String) -> Void
    private let lock = NSLock()
    private var allows = true
    private var appPID: Int32 = 0
    private var watch: Task<Void, Never>?
    /// The sample app could not be started: it has been removed, or the simulator is not usable.
    var onAppMissing: (() -> Void)?

    init(simulator: FBSimulator, app: String, note: @escaping (String) -> Void) {
        self.simulator = simulator
        self.app = app
        self.note = note
    }

    /// Whether a touch that goes down now is passed on.
    var allowsInput: Bool { lock.withLock { allows } }

    /// Starts the sample app afresh, so that every visitor begins on its first screen and not where
    /// the last one stopped, then watches which app is in front until `visitorLeft()`.
    func visitorArrived() {
        watch?.cancel()
        lock.withLock { allows = false }        // nothing is passed on until the sample app is seen in front
        watch = Task { [weak self] in
            guard let self else { return }
            guard await self.launch(afresh: true) else {
                self.note("demo: the sample app \(self.app) could not be started")
                self.onAppMissing?()
                return
            }
            var reader: FBSimulatorNativeContextReader?
            var observation: FBSimulatorHIDSessionObservation?
            var state = MirrorDemo.LockState()
            var said = ""
            // The app that was just started is not in front for its first moments.
            try? await Task.sleep(nanoseconds: 700_000_000)
            while !Task.isCancelled {
                var inFront: Bool?
                do {
                    if reader == nil || observation == nil {
                        let panel = try await ActivePanelReader.discoverWithMetadata(for: self.simulator).readback.snapshot.activePanel.identity
                        let made = FBSimulatorNativeContextReader(simulator: self.simulator, screenID: panel.displayID, screenUniqueID: panel.uniqueID)
                        observation = try await made.observation()
                        reader = made
                    }
                    if let reader, let observation {
                        let pid = try await FBSimulatorAXSnapshot.frontmostApplicationPID(for: self.simulator, observation: observation,
                                                                                         freshnessProvider: reader, timeoutSeconds: 2)
                        let ours = self.lock.withLock { self.appPID }
                        inFront = ours > 0 ? pid == ours : nil
                    }
                } catch {
                    if Task.isCancelled { break }      // the visitor left while a look was under way
                    // The screen was rotated, or the simulator could not say. Start the next read from nothing.
                    reader = nil
                    observation = nil
                    if said != "unknown" { said = "unknown"; self.note("demo: cannot tell which app is in front (\(error)); input stays open") }
                }
                let step = MirrorDemo.lockStep(inFront: inFront, state: &state)
                self.lock.withLock { self.allows = step.allowsInput }
                if inFront == true, said != "front" {
                    if said == "other" { self.note("demo: the sample app is in front again") }
                    said = "front"
                } else if inFront == false, said != "other" {
                    said = "other"
                    self.note("demo: another app is in front: dropping touches and bringing the sample app back")
                }
                if step.pullBack, await self.launch(afresh: false) == false {
                    self.note("demo: the sample app \(self.app) could not be started")
                    self.onAppMissing?()
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(MirrorDemo.lookEvery * 1_000_000_000))
            }
        }
    }

    func visitorLeft() {
        watch?.cancel()
        watch = nil
        lock.withLock { allows = true }
    }

    /// Starts the sample app, or brings it to the front when it is running, and remembers its
    /// process. False when `simctl` could not start it.
    private func launch(afresh: Bool) async -> Bool {
        let udid = simulator.udid, app = app
        let result: (status: Int32, output: String) = await withCheckedContinuation { done in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["simctl", "launch"] + (afresh ? ["--terminate-running-process"] : []) + [udid, app] + MirrorDemo.launchArguments
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                done.resume(returning: (finished.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
            do { try process.run() } catch { done.resume(returning: (-1, "")) }
        }
        guard result.status == 0 else { return false }
        if let pid = MirrorDemo.processID(inLaunchOutput: result.output) { lock.withLock { appPID = pid } }
        return true
    }
}
#endif
