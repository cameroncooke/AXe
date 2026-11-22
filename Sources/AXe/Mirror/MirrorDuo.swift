#if AXE_MIRROR
@preconcurrency import FBControlCore
import FBSimulatorControl
import Foundation
import IOSurface

/// The screen of the simulator that is lit now, as its display report gives it.
///
/// An iPhone Duo has two screens and lights one at a time: the outer screen while it is closed,
/// the inner one while it is open. Measured on an iOS 27.2 Duo simulator (20 November 2026):
/// the framebuffer `FBFramebuffer.mainScreenSurface` gives is always the inner screen, and goes
/// still while the Duo is closed, so the host takes each screen's own surface
/// (`FBFramebuffer.builtInDisplaySurfaces`) and streams the lit one. The default touch connection
/// sends to the outer screen whichever is lit, so touches go on a connection aimed at the lit
/// screen (`FBSimulatorHID.ready(for:displayContext:)`), in its upright points.
struct MirrorLitScreen: Equatable, Sendable {
    var displayID: UInt32
    var uniqueID: UUID
    var nativeWidth: Double         // pixels, in the panel's own unturned shape
    var nativeHeight: Double
    var scale: Int
    var rotation: Int               // degrees, as the display reports it
    var role: String                // main, outer or inner

    var quarterTurned: Bool { rotation == 90 || rotation == 270 }

    /// The screen's upright size in points.
    var logicalWidth: Double { (quarterTurned ? nativeHeight : nativeWidth) / Double(max(scale, 1)) }
    var logicalHeight: Double { (quarterTurned ? nativeWidth : nativeHeight) / Double(max(scale, 1)) }

    /// What `pick` needs of one row of a display report.
    struct Row: Equatable, Sendable {
        var displayID: UInt32
        var uniqueID: UUID
        var integrated: Bool
        var active: Bool?
        var rotation: Int?          // nil for a rotation this code does not know
        var nativeWidth: Double
        var nativeHeight: Double
        var scale: Int

        init(displayID: UInt32, uniqueID: UUID, integrated: Bool, active: Bool?, rotation: Int?, nativeWidth: Double, nativeHeight: Double, scale: Int) {
            self.displayID = displayID; self.uniqueID = uniqueID; self.integrated = integrated; self.active = active
            self.rotation = rotation; self.nativeWidth = nativeWidth; self.nativeHeight = nativeHeight; self.scale = scale
        }

        init(_ row: FBSimulatorDisplayInfoRow) {
            let rotation: Int?
            switch row.currentOrientation {
            case .rot0: rotation = 0
            case .rot90: rotation = 90
            case .rot180: rotation = 180
            case .rot270: rotation = 270
            @unknown default: rotation = nil
            }
            self.init(displayID: row.displayID, uniqueID: row.uniqueID, integrated: row.integrated, active: row.active,
                      rotation: rotation, nativeWidth: row.nativeWidth, nativeHeight: row.nativeHeight, scale: row.pointScale)
        }
    }

    /// The lit screen among a display report's rows: the built-in screen marked active, or the only
    /// built-in screen. With two, the smaller is the outer one. Nil when none can be told.
    ///
    /// With two screens and the hinge's angle in `hinge`, a Duo open flat has its inner screen lit
    /// whatever the report marks active. The report can be wrong for a long time: a Duo open at 180
    /// degrees, its inner screen showing the home screen, had its outer screen marked active, and
    /// most reads of it timed out or found the screens still changing, while its hinge read
    /// correctly at once (iOS 27.2, 20 November 2026).
    ///
    /// A closed Duo is another matter: there the report is believed when it marks a screen active.
    /// iOS can leave the inner screen lit with the hinge shut, after the Duo has stood half open for
    /// a second or more, and then the outer screen really is dark: a capture of the inner screen
    /// showed the home screen, and the report said so, with the hinge at 0 (iOS 27.3, 21 November
    /// 2026). Only when the report marks neither is the closed Duo's outer screen taken as lit.
    /// In between, where iOS chooses the screen by the angle and the way the Duo is held, the report
    /// decides.
    static func pick(from rows: [Row], hinge: Double? = nil) -> MirrorLitScreen? {
        let screens = rows.filter { $0.integrated && $0.nativeWidth > 0 && $0.nativeHeight > 0 }
        var lit = screens.count == 1 ? screens.first : screens.first { $0.active == true }
        if screens.count == 2, let hinge {
            let bySize = screens.sorted { $0.nativeWidth * $0.nativeHeight < $1.nativeWidth * $1.nativeHeight }
            if hinge >= openFlat { lit = bySize[1] } else if hinge <= shut, lit == nil { lit = bySize[0] }
        }
        guard let lit, let rotation = lit.rotation else { return nil }
        let role: String
        if screens.count == 2, let other = screens.first(where: { $0.displayID != lit.displayID }) {
            role = lit.nativeWidth * lit.nativeHeight <= other.nativeWidth * other.nativeHeight ? "outer" : "inner"
        } else {
            role = "main"
        }
        return MirrorLitScreen(displayID: lit.displayID, uniqueID: lit.uniqueID, nativeWidth: lit.nativeWidth,
                               nativeHeight: lit.nativeHeight, scale: lit.scale, rotation: rotation, role: role)
    }

    /// At or past this hinge angle a Duo is open flat; at or below `shut` it is closed.
    static let openFlat = 175.0
    static let shut = 5.0

    static func read(for simulator: FBSimulator) async -> MirrorLitScreen? {
        await readAnswer(for: simulator).screen
    }

    /// The lit screen, and whether the simulator answered the read at all: a read that fails, as on
    /// a simulator that has stopped answering, is told apart from one that found no lit screen. On a
    /// simulator with two screens the hinge is read too, about 3 ms, for `pick`, and given back: it
    /// is read even when the display report could not be, as the hinge answers when that does not.
    /// `hinged` says whether the simulator has two screens, when the caller knows.
    static func readAnswer(for simulator: FBSimulator, hinged: Bool? = nil) async -> (answered: Bool, screen: MirrorLitScreen?, hinge: Double?) {
        let info = try? await FBSimulatorDisplayInfoReader.read(for: simulator)
        let rows = info?.rows.map(Row.init) ?? []
        let two = hinged ?? (rows.filter(\.integrated).count == 2)
        let hinge = two ? (try? await FBSimulatorHingeReader.read(for: simulator))?.sensedDegrees : nil
        guard info != nil else { return (false, nil, hinge) }
        return (true, pick(from: rows, hinge: hinge), hinge)
    }

    /// The geometry a touch connection aimed at this screen needs.
    func context() throws -> FBSimulatorHIDDisplayContext {
        guard let turn = FBSimulatorHIDDisplayRotation(rawValue: rotation) else {
            throw CLIError(errorDescription: "The simulator's screen reported an unsupported rotation.", code: .captureFailed)
        }
        return try FBSimulatorHIDDisplayContext(hidTarget: UInt64(displayID),
            nativePixelSize: CGSize(width: nativeWidth, height: nativeHeight), scale: Double(scale), rotation: turn)
    }

    /// Whether `surface` is this screen's, by its size: the Duo's two screens differ in size.
    func owns(_ surface: IOSurface) -> Bool {
        let width = Double(IOSurfaceGetWidth(surface)), height = Double(IOSurfaceGetHeight(surface))
        return (abs(width - nativeWidth) < 2 && abs(height - nativeHeight) < 2) || (abs(width - nativeHeight) < 2 && abs(height - nativeWidth) < 2)
    }
}

/// Folds and turns an iPhone Duo simulator for the viewer, one message for the hinge and one for
/// the way the device is held (`FBSimulatorDuoControl`), as dragging Device Hub's hinge slider and
/// choosing an orientation there do. The Duo ignores the orientation event the mirror sends to other
/// simulators (measured on iOS 27.2).
///
/// A Duo has one orientation, the way the device is held, and a hinge. Which screen is lit and how
/// each screen's picture is turned are what iOS makes of those two, and the host reports them; they
/// are never asked for directly. Measured on an iOS 27.3 Duo simulator (21 November 2026):
///
/// - A hinge message takes 0.33 s to arrive wherever it starts, and the lit screen changes as it
///   gets there. A message for the way it is held shows in the display report in 0.03 to 0.04 s,
///   a half turn included. Sent together they take 0.33 s.
/// - Held upright, like a book, the outer screen is upright and the inner one wide; opening from
///   closed lights the inner screen from 18 degrees. Held on its left side, like a laptop, the inner
///   screen is tall, and stays lit down to 30 degrees when folded from open; opened from closed held
///   that way the outer screen stays lit at any angle short of flat, and turning the device then
///   does not light the inner one.
/// - Closed and on the home screen, the outer screen stays upright however the device is held. A
///   device left on its right side and then opened has its inner screen at 180 degrees.
/// - Shut from half open, where it had stood a second, the Duo kept its inner screen lit and its
///   outer one dark in 32 of 40 tries, however the hinge got there: in one message, in steps of 15
///   or 30 degrees, or by way of 20 degrees. Turning it then changed nothing. Opening it to 8
///   degrees, waiting for the hinge to get there and shutting it again lit the outer screen in 26
///   of 26; shut again a tenth of a second later, without that wait, it did not in 5 of 5. Shut
///   from flat it mostly lit the outer screen by itself.
enum MirrorFold {
    /// What a fold asks of the device: where the hinge goes and how the device is then held, nil to
    /// leave that as it is.
    struct Plan: Equatable {
        var hinge: Double
        var held: FBSimulatorDuoOrientation?
        /// The device is first held upright, and turned only once its inner screen is lit.
        var viaBook = false
        /// The device is turned before the hinge moves.
        var heldFirst = false
    }

    /// - Closed: held upright, so its outer screen is upright in any app and the next opening is a
    ///   book's. It is turned before it shuts: the inner screen, which is going dark, does the
    ///   turning, and the outer one lights upright. Turned after, an app that can be on its side
    ///   lights the outer screen on its side and then turns it, which the viewer sees.
    /// - Open flat: held for the picture's shape asked for, if one is.
    /// - Book: held upright. Tabletop: on its left side, by way of a book when the outer screen is
    ///   lit, which is the only way the inner one lights short of flat.
    /// - A bare angle: the hinge alone.
    static func plan(_ request: MirrorFoldRequest, outerLit: Bool) -> Plan {
        let hinge = request.hingeDegrees
        switch request.posture {
        case MirrorFoldRequest.angle:
            return Plan(hinge: hinge)
        case MirrorFoldRequest.closed:
            return Plan(hinge: 0, held: .portrait, heldFirst: true)
        case MirrorFoldRequest.book:
            return Plan(hinge: hinge, held: .portrait)
        case MirrorFoldRequest.tabletop:
            return Plan(hinge: hinge, held: .landscapeLeft, viaBook: outerLit)
        default:
            return Plan(hinge: hinge, held: request.orientation.flatMap { held(forPicture: $0, role: "inner") })
        }
    }

    /// How the device is held for a screen's picture to have a shape, `portrait` or `landscape`.
    /// The inner screen's picture is a quarter turn on from the device: wide with it upright, and
    /// tall with it on its left side. On its right side, half open, it would stand like a tent.
    static func held(forPicture shape: String, role: String) -> FBSimulatorDuoOrientation? {
        switch shape {
        case MirrorRotationRequest.landscape: return role == "inner" ? .portrait : .landscapeRight
        case MirrorRotationRequest.portrait: return role == "inner" ? .landscapeLeft : .portrait
        default: return nil
        }
    }

    /// How the device is held after a turn the viewer asks for, given the lit screen and its
    /// picture's rotation now: a quarter turn `left` or `right`, or to `landscape` or `portrait` if
    /// the picture is not that shape already. Nil when there is nothing to do. A left turn takes 90
    /// degrees off the rotation and a right turn adds 90; the outer screen skips upside down.
    static func held(turning wanted: String, role: String, rotation: Int) -> FBSimulatorDuoOrientation? {
        let outer = role == "outer"
        let wide = rotation == 90 || rotation == 270
        var target: Int
        switch wanted {
        case MirrorRotationRequest.left, MirrorRotationRequest.right:
            let step = wanted == MirrorRotationRequest.left ? 270 : 90
            target = (rotation + step) % 360
            if outer, target == 180 { target = (target + step) % 360 }
        case MirrorRotationRequest.landscape:
            guard !wide else { return nil }
            target = 90
        case MirrorRotationRequest.portrait:
            guard rotation != 0 else { return nil }
            target = 0
        default:
            return nil
        }
        let degrees = outer ? target : (target + 270) % 360
        return FBSimulatorDuoOrientation.allCases.first { $0.degrees == degrees }
    }

    /// Carries out a plan. Nothing here waits for a time: the waits are for the inner screen to
    /// light and for the hinge to arrive, each read every 30 ms and given up after a second and a half.
    ///
    /// A Duo that is shut and still has its inner screen lit is opened to 8 degrees and shut again,
    /// which lights the outer one, twice at most: see the measurements above.
    ///
    /// A plan takes up to a few seconds, and a newer fold may be asked for meanwhile. The session
    /// cancels the older plan's task then, and a cancelled plan moves nothing more: before each
    /// thing it would do to the device it stops (`CancellationError`). Otherwise an older plan to
    /// shut the Duo could send its 8 degrees and its shut after a newer one had opened it.
    static func perform(_ plan: Plan, control: FBSimulatorDuoControl, simulator: FBSimulator) async throws {
        try Task.checkCancellation()
        if plan.viaBook {
            try control.setOrientation(.portrait)
        } else if plan.heldFirst, let held = plan.held {
            try control.setOrientation(held)
        }
        try control.setHinge(plan.hinge)
        if plan.hinge <= MirrorLitScreen.shut {
            for _ in 0..<2 {
                guard await arrived(plan.hinge, simulator: simulator, within: 1.5) else { break }
                if await wait(0.15, until: { await MirrorLitScreen.read(for: simulator)?.role == "outer" }) { break }
                try Task.checkCancellation()
                try control.setHinge(nudge)
                _ = await arrived(nudge, simulator: simulator, within: 1.5)
                try Task.checkCancellation()
                try control.setHinge(plan.hinge)
            }
        }
        guard let held = plan.held, !plan.heldFirst else { return }
        if plan.viaBook {
            _ = await wait(1.5) { await MirrorLitScreen.read(for: simulator)?.role == "inner" }
        }
        try Task.checkCancellation()
        try control.setOrientation(held)
    }

    /// How far a shut Duo is opened, in degrees, to make iOS light its outer screen.
    static let nudge = 8.0

    /// Whether the hinge gets to within two degrees of `degrees` in time.
    static func arrived(_ degrees: Double, simulator: FBSimulator, within seconds: Double) async -> Bool {
        await wait(seconds) {
            guard let hinge = try? await FBSimulatorHingeReader.read(for: simulator) else { return false }
            return abs(hinge.mechanicalDegrees - degrees) <= 2
        }
    }

    /// Whether `condition` comes true within `seconds`, looking every 30 ms. False at once when
    /// the task has been cancelled: nobody is waiting for the answer.
    static func wait(_ seconds: Double, until condition: () async -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while true {
            if Task.isCancelled { return false }
            if await condition() { return true }
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }
}

/// A time until which the screen is read more often, set on one thread and read on another.
final class MirrorBurst: @unchecked Sendable {
    private let lock = NSLock()
    private var until: TimeInterval = 0

    func start(for seconds: Double) { lock.withLock { until = max(until, ProcessInfo.processInfo.systemUptime + seconds) } }
    var active: Bool { lock.withLock { ProcessInfo.processInfo.systemUptime < until } }
}

/// Runs reads of a simulator with a deadline of the host's own. A read can block before its own
/// time limit starts, while it reaches a simulator that has frozen (seen with every process of one
/// paused), and such a read is never cancelled. So the caller gets nil at the deadline, the read is
/// left to finish whenever it does, and no other read starts while it is outstanding.
final class MirrorBoundedReads: @unchecked Sendable {
    private let lock = NSLock()
    private var outstanding = 0

    /// `work`'s result, or nil at `seconds` or while an earlier read is still outstanding.
    func run<T: Sendable>(within seconds: Double, _ work: @escaping @Sendable () async -> T) async -> T? {
        let busy = lock.withLock { () -> Bool in
            guard outstanding == 0 else { return true }
            outstanding += 1
            return false
        }
        guard !busy else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = NSLock()
            var done = false
            let finish = { (value: T?) in
                let first = once.withLock { () -> Bool in defer { done = true }; return !done }
                if first { continuation.resume(returning: value) }
            }
            Task.detached { [self] in
                let value = await work()
                lock.withLock { outstanding -= 1 }
                finish(value)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { finish(nil) }
        }
    }
}

/// Passes one framebuffer's callbacks on to the session, marked with the attachment they belong
/// to. A Duo's picture moves from one screen's framebuffer to the other's, and a callback the old
/// one had already queued must not put its surface back.
final class MirrorSurfaceTap: NSObject, FBFramebufferConsumer, @unchecked Sendable {
    let number: Int
    private let changed: (Int, IOSurface?) -> Void
    private let damaged: (Int) -> Void

    init(number: Int, changed: @escaping (Int, IOSurface?) -> Void, damaged: @escaping (Int) -> Void) {
        self.number = number
        self.changed = changed
        self.damaged = damaged
    }

    func didChange(_ surface: IOSurface?) { changed(number, surface) }
    func didReceiveDamageRect() { damaged(number) }
}
#endif
