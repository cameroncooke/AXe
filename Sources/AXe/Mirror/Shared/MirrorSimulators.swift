import Foundation
// Shared with the AXe Mirror app: this file is compiled into the Mac's `axe` and into the viewer.

// A host started without `--udid` mirrors no simulator until the viewer chooses one. The viewer is
// sent the Mac's simulators and what a new one can be made from; it names a simulator to open, or
// a name, device and iOS version to create one from. The host boots the simulator if it has to and
// starts the stream. All of it travels on the control stream as JSON.

/// The message types this exchange adds to the stream's protocol (see `MirrorWire.swift`).
enum MirrorMessage {
    /// Host to viewer: the simulators and runtimes, a `MirrorSimulatorList`.
    static let simulators: UInt8 = 25
    /// Host to viewer: how the viewer's choice is coming along, a `MirrorSimulatorProgress`.
    static let progress: UInt8 = 27
    /// Viewer to host: send the list again. No payload.
    static let list: UInt8 = 31
    /// Viewer to host: open or create this simulator, a `MirrorSimulatorChoice`.
    static let choose: UInt8 = 32
    /// Viewer to host: stop mirroring the simulator and send the list. No payload. The simulator
    /// stays booted.
    static let leave: UInt8 = 34
    /// Viewer to host: shut a simulator down or delete it, a `MirrorSimulatorAction`. The host
    /// answers with the list as it then is, or with a `failed` progress message.
    static let manage: UInt8 = 35
    /// Viewer to host: turn the simulator, a `MirrorRotationRequest`. The picture follows the
    /// screen whoever turns it, so the host does not answer.
    static let rotate: UInt8 = 36
    /// Viewer to host: fold an iPhone Duo simulator, a `MirrorFoldRequest`. The picture and the
    /// next `screen` message show what happened.
    static let fold: UInt8 = 37
    /// Host to viewer: which screen the picture is and how far the hinge is open, a
    /// `MirrorScreenState`. Sent when the stream starts and whenever either changes.
    static let screen: UInt8 = 38
    /// Host to viewer: whether the simulator is answering, a `MirrorSimulatorHealth`. Sent when
    /// that changes; nothing is sent while it is.
    static let health: UInt8 = 39
    /// Host to viewer: how busy the Mac is, a `MirrorHostLoad`. Sent when the stream starts and
    /// whenever the Mac becomes busy or stops being busy.
    static let hostLoad: UInt8 = 46     // past 40 to 43, the viewer's touches and buttons
}

/// How busy the Mac is. `busy` says that a simulator that is slow may be starved rather than stuck.
/// `load` is the one-minute load average per processor core, and `cpu` the share of processor time
/// in use, from 0 to 1.
struct MirrorHostLoad: Codable, Equatable, Sendable {
    var busy: Bool
    var load: Double
    var cpu: Double
}

/// Whether the Mac is busy, from a sample a second of its processor use and load per core. Busy
/// once the processors have been nearly all in use, with more work waiting than there are cores, for
/// `samplesToChange` seconds in a row; not busy again once both have been well down for as long.
/// A simulator starved like this answers late or not at all, the same as one that is stuck, so the
/// viewer says which is more likely (measured on 20 November 2026: load 5.8 per core, touches and
/// hinge reads timing out on a simulator that recovered once the load fell).
struct MirrorBusyJudge: Equatable, Sendable {
    private(set) var busy = false
    private var run = 0

    static let samplesToChange = 10

    /// Returns true when this sample changed whether the Mac is busy.
    mutating func sample(cpu: Double, loadPerCore: Double) -> Bool {
        let looksBusy = loadPerCore > 1.5 && (cpu > 0.85 || loadPerCore > 3)
        let looksIdle = loadPerCore < 1.2 && cpu < 0.75
        let pointsOtherWay = busy ? looksIdle : looksBusy
        run = pointsOtherWay ? run + 1 : 0
        guard run >= Self.samplesToChange else { return false }
        busy.toggle()
        run = 0
        return true
    }
}

/// Whether the simulator on screen is answering the host. A simulator can stop answering, as one
/// whose system processes crash and restart for ever does: the picture stands still, touches are
/// refused, and reads of its screens and hinge time out. `reason` says what the host saw.
struct MirrorSimulatorHealth: Codable, Equatable, Sendable {
    var responding: Bool
    var reason: String?
}

/// Whether a simulator is answering, from the host's reads of its screens, its touches, its folds
/// and a process started in it now and then. Three failures in a row of reads or of touches, two
/// of the process, one fold that timed out or did not finish, or a touch connection that did not
/// open, and it is not answering; it is again once three reads in a row have worked and nothing
/// else is failing.
///
/// Refused touches count once for each `touchSpacing`, so the moves of one swipe are one failure
/// and not three. A process that starts in the simulator shows that it is alive, and clears what
/// touches and folds said before: the viewer's card for a simulator that is not answering sits
/// over the picture, where it keeps away the very touch that would otherwise have to clear it.
struct MirrorResponsiveness: Equatable, Sendable {
    private(set) var responding = true
    private(set) var reason: String?
    private var readFailures = 0, readSuccesses = 0, touchFailures = 0, probeFailures = 0
    private var foldStuck = false, inputStuck = false
    private var lastTouchFailure: Double?

    static let failuresInARow = 3
    /// Refused touches closer together than this count as one.
    static let touchSpacing: Double = 0.25
    /// How long the host waits for a simulator's touch connection to open before it says the
    /// simulator is not answering. A stuck simulator does not open one, and says nothing.
    static let inputDeadline: Double = 20

    /// Returns true when this read changed whether the simulator is answering.
    mutating func read(ok: Bool) -> Bool {
        if ok { readSuccesses += 1; readFailures = 0 } else { readFailures += 1; readSuccesses = 0 }
        return settle(why: "Its screens are not answering.")
    }

    mutating func touch(ok: Bool, at time: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        if ok {
            touchFailures = 0
            lastTouchFailure = nil
        } else if lastTouchFailure.map({ time - $0 >= Self.touchSpacing }) ?? true {
            touchFailures += 1
            lastTouchFailure = time
        }
        return settle(why: "It is refusing touches.")
    }

    /// A process started in the simulator, which needs its own launchd to answer: the screen
    /// reads are answered on the Mac's side and go on working while the simulator itself is frozen.
    mutating func probe(ok: Bool) -> Bool {
        probeFailures = ok ? 0 : probeFailures + 1
        if ok {
            touchFailures = 0
            lastTouchFailure = nil
            foldStuck = false
        }
        return settle(why: "It is not answering at all.")
    }

    /// A fold that timed out stays against the simulator until a later fold finishes or a process
    /// starts in it: screen reads are no sign that it is answering again, as they go on working
    /// while it is stuck.
    mutating func fold(timedOut: Bool) -> Bool {
        foldStuck = timedOut
        return settle(why: "Its hinge is not answering.")
    }

    /// Whether the touch connection opened: false when it has not within `inputDeadline`.
    mutating func input(ready: Bool) -> Bool {
        inputStuck = !ready
        return settle(why: "Its touches are not answering.")
    }

    private mutating func settle(why: String) -> Bool {
        let stuck = readFailures >= Self.failuresInARow || touchFailures >= Self.failuresInARow || probeFailures >= 2 || foldStuck || inputStuck
        let before = responding
        if stuck, responding { responding = false; reason = why }
        if !stuck, !responding, readSuccesses >= Self.failuresInARow { responding = true; reason = nil }
        return before != responding
    }
}

/// How the viewer wants an iPhone Duo simulator folded. `posture` is one of the constants;
/// `degrees`, when given, is the hinge angle to set instead of the posture's own. Closed, the device
/// is held upright. Open flat, `orientation`, `portrait` or `landscape`, is the shape its inner
/// screen's picture is to have, and nil leaves the device held as it is. Book is half open and held
/// upright, with the fold down the middle of a wide picture; tabletop is half open and held on its
/// side, like a laptop, with the fold across a tall one. `angle` moves the hinge to `degrees` and
/// nothing else: iOS then lights whichever screen it lights at that angle.
struct MirrorFoldRequest: Codable, Equatable, Sendable {
    static let closed = "closed"
    static let tabletop = "tabletop"
    static let book = "book"
    static let open = "open"
    static let angle = "angle"

    var posture: String
    var degrees: Double?
    var orientation: String?

    /// The hinge angle the request sets.
    var hingeDegrees: Double {
        if let degrees { return min(180, max(0, degrees)) }
        switch posture {
        case Self.closed: return 0
        case Self.tabletop, Self.book, Self.angle: return 90
        default: return 180
        }
    }
}

/// The screen the picture shows. `role` is `main` on a simulator with one screen, and `outer` or
/// `inner` on an iPhone Duo. `width` and `height` are its upright size in points. `degrees` is the
/// hinge angle, nil when there is no hinge.
struct MirrorScreenState: Codable, Equatable, Sendable {
    var role: String
    var width: Double
    var height: Double
    var degrees: Double?

    /// Whether a Duo is bent short of flat.
    var isBent: Bool { (degrees ?? 180) < 175 }
}

/// Which way the viewer wants the simulator turned: a quarter turn left or right, as Simulator.app's
/// Rotate Left and Rotate Right, or to landscape or portrait if it is not already.
struct MirrorRotationRequest: Codable, Equatable, Sendable {
    static let left = "left"
    static let right = "right"
    static let landscape = "landscape"
    static let portrait = "portrait"

    var to: String
}

/// One simulator on the Mac.
struct MirrorSimulator: Codable, Equatable, Identifiable, Sendable {
    var udid: String
    var name: String
    var booted: Bool
    var model: String       // the device's name, such as "iPhone 18 Pro"
    var os: String          // the runtime's name, such as "iOS 27.2"
    /// When the simulator was last booted, as simctl gives it (ISO 8601, UTC, so two of them
    /// compare as text); nil for one that has never run. The viewer puts recent ones first.
    var lastUsed: String?
    var id: String { udid }
}

/// A kind of device a simulator can be made as.
struct MirrorDeviceType: Codable, Equatable, Identifiable, Sendable {
    var id: String          // CoreSimulator's identifier
    var name: String
    var family: String      // "iPhone" or "iPad"
}

/// An installed iOS version and the devices it can run on, newest device first.
struct MirrorRuntime: Codable, Equatable, Identifiable, Sendable {
    var id: String          // CoreSimulator's identifier
    var name: String        // "iOS 27.2"
    var deviceTypes: [MirrorDeviceType]
}

/// What the viewer chooses from: the simulators, running ones first, and the runtimes a new one
/// can be made with, newest first.
struct MirrorSimulatorList: Codable, Equatable, Sendable {
    var simulators: [MirrorSimulator]
    var runtimes: [MirrorRuntime]
}

/// The viewer's choice. With `udid`, an existing simulator. Without, a new one: `deviceType` and
/// `runtime` are identifiers from the list, and an empty `name` means the device's own name.
struct MirrorSimulatorChoice: Codable, Equatable, Sendable {
    var udid: String?
    var name: String?
    var deviceType: String?
    var runtime: String?

    /// The longest name a new simulator may be given.
    static let nameLimit = 60

    /// The name as it will be used, or nil when it cannot be: too long, more than one line, or
    /// starting with a hyphen, which `simctl` would read as an option.
    static func usableName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= nameLimit, !trimmed.hasPrefix("-"),
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return trimmed
    }
}

/// Something the viewer has done to a simulator other than open it. Shutting down the simulator on
/// screen is how a viewer leaves it without leaving it running. A deleted simulator is gone for
/// good, with everything in it, so the app asks first.
struct MirrorSimulatorAction: Codable, Equatable, Sendable {
    static let shutDown = "shutDown"
    static let delete = "delete"
    /// Shut it down, forcing it if it does not stop, then boot and open it again.
    static let restart = "restart"

    var action: String
    var udid: String
}

/// Something the Mac could not do, said for the person holding the viewer: they are not at the Mac
/// and cannot run a command there. `title` and `message` are plain words about what happened and
/// what it means for them; `action` is the one thing the viewer can offer to put it right, if there
/// is one; `detail` is the Mac's own technical message, which the app keeps behind Details.
struct MirrorProblem: Codable, Equatable, Sendable {
    /// What went wrong, for the app to choose an icon by and for tests to check.
    static let macSetup = "macSetup"               // Xcode's simulator tools did not start
    static let simulatorGone = "simulatorGone"     // no longer on the Mac
    static let runtimeMissing = "runtimeMissing"   // its iOS version is no longer installed
    static let timedOut = "timedOut"               // did not start in time
    static let wontStop = "wontStop"               // did not shut down, even when forced
    static let cannotCreate = "cannotCreate"       // that name, device or iOS version cannot be used
    static let noSpace = "noSpace"                 // the Mac's disk is full
    static let foldFailed = "foldFailed"
    static let takenAway = "takenAway"             // another device shut it down, deleted it or restarted it
    static let other = "other"

    /// What the viewer can offer: `retry` does the same thing again, `restart` restarts the
    /// simulator by force, `refresh` reads the list again.
    static let retry = "retry"
    static let restart = "restart"
    static let refresh = "refresh"

    var code: String
    var title: String
    var message: String
    var action: String?
    var detail: String?

    /// What a viewer is told when another paired device does something to the simulator it is
    /// watching: `action` is a `MirrorSimulatorAction`. Without this the picture froze and, after
    /// a while, the viewer said only that the simulator was not responding.
    static func takenAway(name: String, action: String) -> MirrorProblem {
        switch action {
        case MirrorSimulatorAction.delete:
            return MirrorProblem(code: takenAway, title: "“\(name)” was deleted from another device", message: "It is no longer on your Mac.", action: nil, detail: nil)
        case MirrorSimulatorAction.restart:
            return MirrorProblem(code: takenAway, title: "“\(name)” was restarted from another device", message: "Open it again once it has started.", action: refresh, detail: nil)
        default:
            return MirrorProblem(code: takenAway, title: "“\(name)” was shut down from another device", message: "Open it again to start it.", action: refresh, detail: nil)
        }
    }

    /// The problem behind a failure. `doing` is what the Mac was asked for: `list`, `open`, `create`,
    /// `shutDown`, `delete`, `restart` or `fold`. `errorCode` and `technical` are the Mac's own error;
    /// `name` is the simulator's, when there is one.
    static func describe(doing: String, errorCode: String, technical: String, name: String?) -> MirrorProblem {
        let it = name.map { "“\($0)”" } ?? "The simulator"
        let text = technical.lowercased()
        func problem(_ code: String, _ title: String, _ message: String, _ action: String?) -> MirrorProblem {
            MirrorProblem(code: code, title: title, message: message, action: action, detail: technical)
        }
        if errorCode == "xcodeUnavailable" {
            return problem(macSetup, "Your Mac can’t run its simulators right now",
                           "Xcode’s simulator tools did not start. This can happen for a moment while Xcode is being updated. If it stays, Xcode needs opening once on the Mac.", retry)
        }
        if text.contains("no space left") || text.contains("disk is full") || text.contains("not enough disk space") {
            return problem(noSpace, "Your Mac is out of disk space", "Free some space on the Mac, then try again.", retry)
        }
        if text.contains("runtime is not available") || text.contains("runtime profile not found") || text.contains("runtime path not found") {
            return problem(runtimeMissing, "\(it) can’t start",
                           "The iOS version it uses is no longer installed on your Mac, so it can’t be used from here. Make a new simulator instead.", refresh)
        }
        if text.contains("no longer on this mac") || text.contains("invalid device") || text.contains("is not a simulator’s udid") || text.contains("is not a simulator's udid") {
            return problem(simulatorGone, "That simulator is no longer on your Mac", "It was deleted since the list was read. The list is up to date now.", nil)
        }
        if doing == "fold" {
            return problem(foldFailed, "The simulator did not fold",
                           text.contains("timed out") ? "Its hinge did not answer. Try again, or restart the simulator if it keeps happening."
                                                      : "It did not end up as asked. Try again, or restart the simulator if it keeps happening.", restart)
        }
        if text.contains("did not stop, even when forced") {
            return problem(wontStop, "\(it) would not stop", "It did not shut down, even when forced. Quitting the Simulator app on the Mac frees it.", retry)
        }
        if errorCode == "timeout" {
            switch doing {
            case "open", "create", "restart":
                return problem(timedOut, "\(it) did not finish starting", "It took longer than five minutes. Your Mac may be busy. Restarting it usually helps.", name == nil ? retry : restart)
            case "list":
                return problem(timedOut, "Your Mac was slow to answer", "It did not list its simulators in time. It may be busy.", retry)
            default:
                return problem(timedOut, "\(it) was slow to answer", "It did not finish in time. Your Mac may be busy.", retry)
            }
        }
        if doing == "create" && (text.contains("cannot be combined") || text.contains("a simulator's name") || text.contains("incompatible device") || text.contains("invalid runtime") || text.contains("invalid device type")) {
            return problem(cannotCreate, "That simulator can’t be made",
                           text.contains("name") ? "Its name has to be one line of at most \(MirrorSimulatorChoice.nameLimit) characters and can’t start with a hyphen."
                                                 : "That device can’t run that iOS version on your Mac. Choose another of the two.", nil)
        }
        let named = name.map { "“\($0)”" } ?? "the simulator"
        let verbs = ["list": "list its simulators", "open": "open \(named)", "create": "make the simulator",
                     "shutDown": "shut \(named) down", "delete": "delete \(named)", "restart": "restart \(named)"]
        return problem(other, "Your Mac couldn’t \(verbs[doing] ?? "do that")", "Something went wrong on the Mac. Trying again often works.", retry)
    }
}

/// Where the host has got to with the viewer's choice. `step` is `creating`, `booting`, `opening`,
/// `restarting`, `failed` or `foldFailed`; `problem` says what failed. The stream starting is what says it succeeded.
struct MirrorSimulatorProgress: Codable, Equatable, Sendable {
    var step: String
    var udid: String?
    var name: String?
    /// The Mac's own words for a failure. A viewer shows `problem` in its place when there is one;
    /// this stays for a viewer from before `problem` existed.
    var message: String?
    /// What failed, said for the viewer, with what it can offer. Sent with `failed` and `foldFailed`.
    var problem: MirrorProblem?
    /// What the Mac was asked for when it failed, so the viewer can do it again: see `MirrorProblem.describe`.
    var doing: String?
}
