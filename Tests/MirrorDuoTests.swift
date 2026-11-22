import Foundation
import Testing
import FBSimulatorControl
@testable import AXe

/// An iPhone Duo simulator mirrored: which screen is shown, how it is turned and folded, and what a
/// viewer that is itself a Duo asks for.
@Suite("Mirror: iPhone Duo")
struct MirrorDuoTests {
    private let outer = UUID(uuidString: "2CFD9FAC-6E9A-46AB-BC49-279E99034EA9")!
    private let inner = UUID(uuidString: "A22FCAB7-825D-483A-A781-F78BDE0AC706")!

    /// The Duo's display report as measured on iOS 27.2: outer 1398x2034, TV out, inner 2007x2853.
    private func report(innerLit: Bool, rotation: Int) -> [MirrorLitScreen.Row] {
        [MirrorLitScreen.Row(displayID: 1, uniqueID: outer, integrated: true, active: !innerLit, rotation: innerLit ? 0 : rotation, nativeWidth: 1398, nativeHeight: 2034, scale: 3),
         MirrorLitScreen.Row(displayID: 2, uniqueID: UUID(), integrated: false, active: false, rotation: 0, nativeWidth: 0, nativeHeight: 0, scale: 1),
         MirrorLitScreen.Row(displayID: 3, uniqueID: inner, integrated: true, active: innerLit, rotation: innerLit ? rotation : 90, nativeWidth: 2007, nativeHeight: 2853, scale: 3)]
    }

    @Test("The lit screen is the active built-in one, and the smaller of two is the outer")
    func litScreen() throws {
        let open = try #require(MirrorLitScreen.pick(from: report(innerLit: true, rotation: 90)))
        #expect(open.role == "inner" && open.displayID == 3 && open.uniqueID == inner)
        #expect(open.logicalWidth == 951 && open.logicalHeight == 669)
        let closed = try #require(MirrorLitScreen.pick(from: report(innerLit: false, rotation: 0)))
        #expect(closed.role == "outer" && closed.displayID == 1)
        #expect(closed.logicalWidth == 466 && closed.logicalHeight == 678)
    }

    @Test("Open flat, the hinge decides the lit screen over a stale report; closed and in between, the report does")
    func hingeDecides() throws {
        let staleOpen = try #require(MirrorLitScreen.pick(from: report(innerLit: false, rotation: 0), hinge: 180))
        #expect(staleOpen.role == "inner" && staleOpen.displayID == 3)
        // iOS can leave the inner screen lit with the hinge shut, and the outer one is then dark.
        let innerLitShut = try #require(MirrorLitScreen.pick(from: report(innerLit: true, rotation: 90), hinge: 0))
        #expect(innerLitShut.role == "inner" && innerLitShut.displayID == 3)
        let shut = try #require(MirrorLitScreen.pick(from: report(innerLit: false, rotation: 0), hinge: 0))
        #expect(shut.role == "outer" && shut.displayID == 1)
        let halfOpen = try #require(MirrorLitScreen.pick(from: report(innerLit: false, rotation: 0), hinge: 80))
        #expect(halfOpen.role == "outer")
        var noneActive = report(innerLit: true, rotation: 0)
        noneActive[2].active = false
        #expect(MirrorLitScreen.pick(from: noneActive, hinge: 180)?.role == "inner")
        // Shut, with no screen marked active, it is the outer one.
        #expect(MirrorLitScreen.pick(from: noneActive, hinge: 0)?.role == "outer")
    }

    @Test("A simulator with one screen has its main screen, active or not")
    func oneScreen() throws {
        let iPad = MirrorLitScreen.Row(displayID: 1, uniqueID: UUID(), integrated: true, active: nil, rotation: 270, nativeWidth: 1640, nativeHeight: 2360, scale: 2)
        let screen = try #require(MirrorLitScreen.pick(from: [iPad]))
        #expect(screen.role == "main" && screen.logicalWidth == 1180 && screen.logicalHeight == 820)
    }

    @Test("No screen is told while the Duo's report has none marked active")
    func noneActive() {
        var rows = report(innerLit: true, rotation: 0)
        rows[2].active = false
        #expect(MirrorLitScreen.pick(from: rows) == nil)
    }

    @Test("A turn is one way of holding the device: the inner screen is a quarter turn on from it")
    func held() {
        // The inner screen: wide with the device upright, tall with it on its left side.
        #expect(MirrorFold.held(turning: "landscape", role: "inner", rotation: 0) == .portrait)
        #expect(MirrorFold.held(turning: "landscape", role: "inner", rotation: 180) == .portrait)
        #expect(MirrorFold.held(turning: "landscape", role: "inner", rotation: 90) == nil)
        #expect(MirrorFold.held(turning: "portrait", role: "inner", rotation: 90) == .landscapeLeft)
        #expect(MirrorFold.held(turning: "portrait", role: "inner", rotation: 270) == .landscapeLeft)
        // Upside down is tall too, but it is a tent, not a laptop: it is turned upright.
        #expect(MirrorFold.held(turning: "portrait", role: "inner", rotation: 180) == .landscapeLeft)
        #expect(MirrorFold.held(turning: "portrait", role: "inner", rotation: 0) == nil)
        // The outer screen follows the device.
        #expect(MirrorFold.held(turning: "landscape", role: "outer", rotation: 0) == .landscapeRight)
        #expect(MirrorFold.held(turning: "portrait", role: "outer", rotation: 90) == .portrait)
        // A quarter turn: right adds 90 to the picture's rotation and left takes 90 off.
        #expect(MirrorFold.held(turning: "right", role: "inner", rotation: 0) == .portrait)
        #expect(MirrorFold.held(turning: "left", role: "inner", rotation: 0) == .upsideDown)
        #expect(MirrorFold.held(turning: "right", role: "outer", rotation: 0) == .landscapeRight)
        // The outer screen skips upside down.
        #expect(MirrorFold.held(turning: "right", role: "outer", rotation: 90) == .landscapeLeft)
        #expect(MirrorFold.held(turning: "left", role: "outer", rotation: 270) == .landscapeRight)
        #expect(FBSimulatorDuoOrientation.landscapeLeft.innerRotation == 0)
        #expect(FBSimulatorDuoOrientation.portrait.innerRotation == 90)
    }

    @Test("Each posture sets its angle and the way the device is held; a bare angle moves the hinge alone")
    func postures() {
        #expect(MirrorFoldRequest(posture: "closed").hingeDegrees == 0)
        #expect(MirrorFoldRequest(posture: "open").hingeDegrees == 180)
        #expect(MirrorFoldRequest(posture: "book", degrees: 120).hingeDegrees == 120)
        #expect(MirrorFoldRequest(posture: "open", degrees: 200).hingeDegrees == 180)
        #expect(MirrorFoldRequest(posture: "angle", degrees: 60).hingeDegrees == 60)

        // Closed, it is held upright whatever shape was asked for, and turned before it shuts: the
        // outer screen's home screen is upright only.
        #expect(MirrorFold.plan(MirrorFoldRequest(posture: "closed", orientation: "landscape"), outerLit: false)
                == MirrorFold.Plan(hinge: 0, held: .portrait, heldFirst: true))
        // Open flat, it is held for the shape asked for, or left as it is.
        #expect(MirrorFold.plan(MirrorFoldRequest(posture: "open", orientation: "landscape"), outerLit: true) == MirrorFold.Plan(hinge: 180, held: .portrait))
        #expect(MirrorFold.plan(MirrorFoldRequest(posture: "open", orientation: "portrait"), outerLit: true) == MirrorFold.Plan(hinge: 180, held: .landscapeLeft))
        #expect(MirrorFold.plan(MirrorFoldRequest(posture: "open"), outerLit: true) == MirrorFold.Plan(hinge: 180))
        // A book is upright. A laptop is on its left side, by way of a book when the outer screen is lit.
        // Either, from half open short of flat, ends with its inner screen lit.
        #expect(MirrorFold.plan(MirrorFoldRequest(posture: "book", degrees: 100), outerLit: true) == MirrorFold.Plan(hinge: 100, held: .portrait, lightsInner: true))
        #expect(MirrorFold.plan(MirrorFoldRequest(posture: "book", degrees: 90), outerLit: true).lightsInner)
        #expect(!MirrorFold.plan(MirrorFoldRequest(posture: "book", degrees: 80), outerLit: true).lightsInner)
        #expect(MirrorFold.plan(MirrorFoldRequest(posture: "tabletop", degrees: 100), outerLit: true) == MirrorFold.Plan(hinge: 100, held: .landscapeLeft, viaBook: true, lightsInner: true))
        #expect(MirrorFold.plan(MirrorFoldRequest(posture: "tabletop", degrees: 60), outerLit: false) == MirrorFold.Plan(hinge: 60, held: .landscapeLeft))
        #expect(MirrorFold.plan(MirrorFoldRequest(posture: "angle", degrees: 100), outerLit: true) == MirrorFold.Plan(hinge: 100))
        #expect(!MirrorFold.plan(MirrorFoldRequest(posture: "open"), outerLit: true).lightsInner)
    }

    @Test("A Duo is bent short of flat")
    func bent() {
        #expect(MirrorScreenState(role: "inner", width: 669, height: 951, degrees: 100).isBent)
        #expect(!MirrorScreenState(role: "inner", width: 951, height: 669, degrees: 180).isBent)
    }

    @Test("The controls go where they leave the biggest picture")
    func placement() {
        // A portrait iPhone simulator on a portrait iPhone: height is short, so the side is cheaper.
        #expect(MirrorViewerLayout.placement(pane: CGSize(width: 393, height: 774), video: CGSize(width: 402, height: 874)) == .side)
        // A 16:10 picture on a landscape iPad: one bar on top, with the buttons in it, keeps the full
        // width, where bars above and below would cost height and a side bar width.
        #expect(MirrorViewerLayout.placement(pane: CGSize(width: 1180, height: 796), video: CGSize(width: 1600, height: 1000)) == .singleBar)
        // A portrait iPad simulator on a portrait iPad: the side bar, by a few points.
        #expect(MirrorViewerLayout.placement(pane: CGSize(width: 820, height: 1136), video: CGSize(width: 820, height: 1180)) == .side)
        // A landscape simulator on a portrait phone: width is short, so bars above and below.
        #expect(MirrorViewerLayout.placement(pane: CGSize(width: 393, height: 774), video: CGSize(width: 874, height: 402)) == .bars)
    }

    @Test("On an open Duo a picture that loses little on one page takes it")
    func pages() {
        let open = CGSize(width: 951, height: 637)
        #expect(MirrorViewerLayout.usesPages(pane: open, video: CGSize(width: 466, height: 678), sideBySide: true))
        #expect(!MirrorViewerLayout.usesPages(pane: open, video: CGSize(width: 951, height: 669), sideBySide: true))
        let tall = CGSize(width: 669, height: 909)
        #expect(!MirrorViewerLayout.usesPages(pane: tall, video: CGSize(width: 466, height: 678), sideBySide: false))
        #expect(MirrorViewerLayout.usesPages(pane: tall, video: CGSize(width: 951, height: 669), sideBySide: false))
    }
}

/// Whether the simulator on screen is answering, as the host judges it.
@Suite("Mirror: a simulator that stops answering")
struct MirrorResponsivenessTests {
    @Test("Three failed screen reads in a row, and it is not answering; three good ones, and it is again")
    func reads() {
        var health = MirrorResponsiveness()
        let changes = [health.read(ok: false), health.read(ok: false), health.read(ok: false)]
        #expect(changes == [false, false, true])
        #expect(!health.responding && health.reason == "Its screens are not answering.")
        let back = [health.read(ok: true), health.read(ok: true), health.read(ok: true)]
        #expect(back == [false, false, true])
        #expect(health.responding && health.reason == nil)
    }

    @Test("A good read in between starts the count again")
    func interrupted() {
        var health = MirrorResponsiveness()
        _ = health.read(ok: false); _ = health.read(ok: false); _ = health.read(ok: true); _ = health.read(ok: false)
        #expect(health.responding)
    }

    @Test("Refused touches, a process that never starts, or a fold that timed out each say so")
    func otherSignals() {
        var touches = MirrorResponsiveness()
        _ = touches.touch(ok: false, at: 10); _ = touches.touch(ok: false, at: 10.5)
        let touchChanged = touches.touch(ok: false, at: 11)
        #expect(touchChanged && touches.reason == "It is refusing touches.")
        var probe = MirrorResponsiveness()
        _ = probe.probe(ok: false)
        let probeChanged = probe.probe(ok: false)
        #expect(probeChanged && probe.reason == "It is not answering at all.")
        var fold = MirrorResponsiveness()
        let foldChanged = fold.fold(timedOut: true)
        #expect(foldChanged && fold.reason == "Its hinge is not answering.")
    }

    @Test("It is not answering again until the failing signal stops, whatever the reads say")
    func recovery() {
        var health = MirrorResponsiveness()
        _ = health.probe(ok: false); _ = health.probe(ok: false)
        for _ in 0..<5 { _ = health.read(ok: true) }
        #expect(!health.responding)
        let changed = health.probe(ok: true)
        #expect(changed && health.responding)
    }

    @Test("A stuck fold stays against it while its screens still answer, until a fold finishes")
    func stuckFold() {
        var health = MirrorResponsiveness()
        for _ in 0..<5 { _ = health.read(ok: true) }
        _ = health.fold(timedOut: true)
        for _ in 0..<10 { _ = health.read(ok: true) }
        #expect(!health.responding)
        let changed = health.fold(timedOut: false)
        #expect(changed && health.responding)
    }

    @Test("One swipe's worth of refused touches is not a simulator that has stopped answering")
    func oneBadGesture() {
        // Three moves of one swipe, 17 ms apart, all refused: one thing went wrong, once.
        var health = MirrorResponsiveness()
        let changes = [health.touch(ok: false, at: 10.000), health.touch(ok: false, at: 10.017), health.touch(ok: false, at: 10.034)]
        #expect(changes == [false, false, false] && health.responding)
        // Refused again and again over a second is.
        _ = health.touch(ok: false, at: 10.5)
        let changed = health.touch(ok: false, at: 11.0)
        #expect(changed && !health.responding && health.reason == "It is refusing touches.")
    }

    @Test("A simulator that starts a process is answering, whatever a touch or a fold said before")
    func aliveAfterAll() {
        // Refusing touches, with its screens reading well throughout. The card that says so sits over
        // the picture, so the person cannot easily send the touch that would clear it.
        var touches = MirrorResponsiveness()
        for step in 0..<3 { _ = touches.touch(ok: false, at: Double(step)) }
        for _ in 0..<5 { _ = touches.read(ok: true) }
        #expect(!touches.responding)
        let back = touches.probe(ok: true)
        #expect(back && touches.responding && touches.reason == nil)
        // Still refusing them: it says so again.
        for step in 10..<13 { _ = touches.touch(ok: false, at: Double(step)) }
        #expect(!touches.responding)
        // The same for a fold that timed out.
        var fold = MirrorResponsiveness()
        _ = fold.fold(timedOut: true)
        for _ in 0..<5 { _ = fold.read(ok: true) }
        let unfolded = fold.probe(ok: true)
        #expect(unfolded && fold.responding)
        // A simulator that starts nothing stays as it was.
        var frozen = MirrorResponsiveness()
        for step in 0..<3 { _ = frozen.touch(ok: false, at: Double(step)) }
        for _ in 0..<5 { _ = frozen.read(ok: true) }
        _ = frozen.probe(ok: false)
        #expect(!frozen.responding)
    }

    @Test("A touch connection that never opens says so, and opening it clears it")
    func stuckInput() {
        var health = MirrorResponsiveness()
        for _ in 0..<5 { _ = health.read(ok: true) }
        let stuck = health.input(ready: false)
        #expect(stuck && health.reason == "Its touches are not answering.")
        let back = health.input(ready: true)
        #expect(back && health.responding)
    }
}

/// Whether the Mac is busy, as the host judges it from a sample a second.
@Suite("Mirror: a busy Mac")
struct MirrorBusyJudgeTests {
    @Test("Busy after ten seconds of full processors and a long queue; not busy after ten quiet ones")
    func busyAndBack() {
        var judge = MirrorBusyJudge()
        let toBusy = (0..<10).map { _ in judge.sample(cpu: 0.95, loadPerCore: 5.8) }
        #expect(toBusy.filter { $0 }.count == 1 && toBusy.last == true && judge.busy)
        let toIdle = (0..<10).map { _ in judge.sample(cpu: 0.3, loadPerCore: 0.5) }
        #expect(toIdle.last == true && !judge.busy)
    }

    @Test("A moment's spike, or a long queue with the processors free, is not busy")
    func notBusy() {
        var judge = MirrorBusyJudge()
        for _ in 0..<9 { _ = judge.sample(cpu: 0.99, loadPerCore: 4) }
        _ = judge.sample(cpu: 0.2, loadPerCore: 0.4)
        for _ in 0..<9 { _ = judge.sample(cpu: 0.99, loadPerCore: 4) }
        #expect(!judge.busy)
        var waiting = MirrorBusyJudge()
        for _ in 0..<20 { _ = waiting.sample(cpu: 0.5, loadPerCore: 2) }
        #expect(!waiting.busy)
    }

    @Test("A very long queue counts even if the processors are not all in use")
    func longQueue() {
        var judge = MirrorBusyJudge()
        for _ in 0..<10 { _ = judge.sample(cpu: 0.6, loadPerCore: 5) }
        #expect(judge.busy)
    }
}

/// What the viewer is told when the Mac cannot do something: plain words for the person holding it.
@Suite("Mirror: problems said for the viewer")
struct MirrorProblemTests {
    private func describe(_ doing: String, _ code: String, _ technical: String, name: String? = "Demo") -> MirrorProblem {
        MirrorProblem.describe(doing: doing, errorCode: code, technical: technical, name: name)
    }

    @Test("Nothing shown says simctl, xcrun or xcode-select; the Mac's own words wait in the detail")
    func noToolNames() {
        let cases = [describe("list", "xcodeUnavailable", "Could not start xcrun simctl. Select Xcode with xcode-select.", name: nil),
                     describe("open", "timeout", "simctl bootstatus did not finish within 300 seconds."),
                     describe("open", "commandFailed", "simctl boot failed (149): The iOS 27.2 simulator runtime is not available. runtime path not found"),
                     describe("delete", "commandFailed", "simctl delete failed (1): something odd"),
                     describe("fold", "commandFailed", "Context hinge sample timed out")]
        for problem in cases {
            for word in ["simctl", "xcrun", "xcode-select"] {
                #expect(!problem.title.contains(word) && !problem.message.contains(word))
            }
            #expect(problem.detail?.isEmpty == false)
        }
    }

    @Test("Each kind of failure is told apart and offers what can be done from the viewer")
    func kinds() {
        let tools = describe("list", "xcodeUnavailable", "Could not start xcrun simctl. Select Xcode with xcode-select.", name: nil)
        #expect(tools.code == MirrorProblem.macSetup && tools.action == MirrorProblem.retry)
        let slowBoot = describe("open", "timeout", "simctl bootstatus did not finish within 300 seconds.")
        #expect(slowBoot.code == MirrorProblem.timedOut && slowBoot.action == MirrorProblem.restart && slowBoot.title.contains("Demo"))
        let noRuntime = describe("open", "commandFailed", "simctl boot failed (149): The iOS 27.2 simulator runtime is not available.")
        #expect(noRuntime.code == MirrorProblem.runtimeMissing && noRuntime.action == MirrorProblem.refresh)
        let gone = describe("open", "commandFailed", "That simulator is no longer on this Mac.")
        #expect(gone.code == MirrorProblem.simulatorGone && gone.action == nil)
        let fold = describe("fold", "commandFailed", "The simulator lit its outer screen, not its inner one.")
        #expect(fold.code == MirrorProblem.foldFailed && fold.action == MirrorProblem.restart)
        let stuck = describe("shutDown", "timeout", "The simulator did not stop, even when forced. Quit Simulator.app and try again.")
        #expect(stuck.code == MirrorProblem.wontStop)
        let full = describe("create", "commandFailed", "simctl create failed (28): No space left on device")
        #expect(full.code == MirrorProblem.noSpace)
        let odd = describe("delete", "commandFailed", "simctl delete failed (1): something odd")
        #expect(odd.code == MirrorProblem.other && odd.action == MirrorProblem.retry && odd.title == "Your Mac couldn’t delete “Demo”")
    }

    @Test("A fold that a newer one has overtaken stops waiting at once, and so moves the hinge no more")
    func overtakenFoldStops() async {
        // An older fold waiting for the hinge to arrive, with five seconds to go.
        let older = Task { () -> (arrived: Bool, took: Double) in
            let start = ProcessInfo.processInfo.systemUptime
            let arrived = await MirrorFold.wait(5) { false }
            return (arrived, ProcessInfo.processInfo.systemUptime - start)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        older.cancel()      // what the session does when the viewer asks for another fold
        let result = await older.value
        #expect(!result.arrived && result.took < 1)
        // And what `perform` asks before each thing it does to the device then stops it.
        let cancelled = Task { () -> Bool in
            try? await Task.sleep(nanoseconds: 50_000_000)
            do { try Task.checkCancellation(); return false } catch { return true }
        }
        cancelled.cancel()
        #expect(await cancelled.value)
    }

    @Test("A viewer whose simulator another device shut down, deleted or restarted is told which, by name")
    func takenAway() {
        let down = MirrorProblem.takenAway(name: "Demo", action: MirrorSimulatorAction.shutDown)
        #expect(down.code == MirrorProblem.takenAway && down.title == "“Demo” was shut down from another device" && down.action == MirrorProblem.refresh)
        let gone = MirrorProblem.takenAway(name: "Demo", action: MirrorSimulatorAction.delete)
        #expect(gone.title == "“Demo” was deleted from another device" && gone.action == nil)
        #expect(MirrorProblem.takenAway(name: "Demo", action: MirrorSimulatorAction.restart).title == "“Demo” was restarted from another device")
    }

    @Test("A viewer from before problems ignores the new fields, and a Mac from before them still decodes")
    func compatible() throws {
        let old = try JSONDecoder().decode(MirrorSimulatorProgress.self, from: Data(#"{"step":"failed","message":"simctl list failed (1)"}"#.utf8))
        #expect(old.problem == nil && old.doing == nil && old.message == "simctl list failed (1)")
    }
}

