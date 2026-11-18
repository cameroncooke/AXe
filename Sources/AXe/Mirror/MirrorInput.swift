#if AXE_MIRROR
import CoreGraphics
import FBSimulatorControl
import Foundation

/// Takes the viewer's touches and plays them into the simulator.
///
/// Moves are replayed a short, steady time after they happened, at the spacing they had on the
/// viewer, so that network jitter does not change how fast a finger appears to move. See
/// `adaptiveDelay()` for how long that time is and `replay()` for how late and lost touches are handled.
final class MirrorInput {
    private enum Command { case discrete(MirrorTouch), tick }
    private let hid: FBSimulatorHID
    private let width: Double, height: Double       // the simulator's screen in points
    private let interval: TimeInterval
    private let lock = NSLock()
    private var commands: AsyncStream<Command>.Continuation?
    private var newestMove: MirrorTouch?
    private var active = false
    private var lastMove: TimeInterval = 0
    private var log: [String] = []
    // Replay mode: touches are played back `delay` seconds after they happened, at the times they
    // happened relative to each other, so network jitter does not change how fast a finger appears to move.
    private let delay: TimeInterval
    private var waiting: [MirrorTouch] = []        // downs, ups and cancels not yet due
    private var samples: [MirrorTouch] = []        // positions of the gesture being replayed, by touch time
    private var replaying: UInt32 = 0
    private var lastPlayed = CGPoint(x: -1, y: -1)
    private var seenDiscrete: [UInt64] = []
    private var singleOpen = false      // a one-finger touch is down in the simulator, perhaps under a pair
    var edgePoints = 0.0                // a one-finger touch beginning this close to an edge is sent with an edge hint
    private var edgeName = ""           // the edge the open one-finger touch began at, if any
    private var ages: [TimeInterval] = []        // how long after they were made recent touches arrived
    var delayRule = "gestures"
    var lead: TimeInterval = 0           // how far a one-finger replay may run ahead of the newest position
    var catchUpAfter: TimeInterval = 0.3 // how long a gesture must have lasted before waited time is won back
    private var gestureBegan: TimeInterval = 0
    private var ranAhead = false         // the last position played was a guess beyond the newest one
    private var openAges: [UInt32: [TimeInterval]] = [:]   // the same, for gestures still in progress
    private var needs: [TimeInterval] = []       // the delay each of the last five gestures would have needed
    private var timedAges: [(at: TimeInterval, age: TimeInterval)] = []   // arrival ages of the last 20 s, for the "steady" rule
    private var steadyDelay: TimeInterval = 0, steadySet: TimeInterval = 0
    private var seenMoves = Set<UInt64>()        // moves of recent gestures already in `samples`
    private var arrivals: [String] = []          // every touch message as it arrived, for the arrivals log
    private var recoveredCount = 0, repeatedCount = 0
    private var currentDelay: TimeInterval = 0   // the replay delay in force for the gesture being replayed
    private var startShift: TimeInterval = 0     // how much later than that delay this gesture started
    private var stall: TimeInterval = 0          // time this gesture's clock has waited for late samples

    init(hid: FBSimulatorHID, width: Double, height: Double, hertz: Double, delay: TimeInterval = 0) {
        self.hid = hid
        self.width = width
        self.height = height
        self.delay = delay
        interval = 1 / hertz
        let (stream, input) = AsyncStream<Command>.makeStream()
        commands = input
        Task.detached(priority: .userInitiated) { [self] in
            for await command in stream { await handle(command) }
        }
        Task.detached(priority: .userInitiated) { [self] in
            var next = mirrorNow() + interval
            while true {
                // With no touch in hand, look again in a few milliseconds and do not spin.
                lock.lock()
                let idle = !active && waiting.isEmpty && newestMove == nil
                lock.unlock()
                if idle {
                    try? await Task.sleep(nanoseconds: 4_000_000)
                    next = mirrorNow() + interval
                    continue
                }
                // Sleep most of the way, then spin: a move that lands a few milliseconds early is dropped.
                let remaining = next - mirrorNow() - 0.004
                if remaining > 0 { try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
                while mirrorNow() < next {}
                input.yield(.tick)
                next += interval
                if next < mirrorNow() { next = mirrorNow() + interval }
            }
        }
    }

    func receive(_ message: MirrorTouch) {
        // Downs and ups arrive twice, on the reliable stream and as a datagram; whichever comes first is used.
        if message.kind != 4 {
            lock.lock()
            let key = UInt64(message.gesture) << 8 | UInt64(message.isDown ? 1 : 2)
            let repeated = seenDiscrete.contains(key)
            if !repeated {
                seenDiscrete.append(key)
                if seenDiscrete.count > 64 { seenDiscrete.removeFirst() }
            }
            lock.unlock()
            if repeated { return }
        }
        if delay > 0 {
            lock.lock()
            defer { lock.unlock() }
            if message.kind == 4 {
                // A move is used once: from its own datagram, or from the history of a later one.
                let key = UInt64(message.gesture) << 32 | UInt64(message.sequence)
                if seenMoves.contains(key) {
                    if !message.recovered { repeatedCount += 1 }
                    return
                }
                if seenMoves.count > 4096 { seenMoves.removeAll() }
                seenMoves.insert(key)
                if message.recovered { recoveredCount += 1 }
            }
            arrivals.append(String(format: "%u,%u,%d,%.6f,%.6f,%d", message.gesture, message.sequence, Int(message.kind), message.touchTime, message.received, message.recovered ? 1 : 0))
            if message.kind != 4 { waiting.append(message) }
            // An up carries the finger's last position and time, so it closes the track: if the last
            // moves were lost on the way, the replay glides to it instead of standing still and jumping.
            // Kept in touch-time order: a recovered move belongs before the message that carried it.
            let at = samples.lastIndex { $0.touchTime <= message.touchTime }.map { $0 + 1 } ?? 0
            samples.insert(message, at: at)
            if (message.isDown || message.kind == 4), !message.recovered {
                let age = message.received - message.touchTime
                ages.append(age)
                if ages.count > 400 { ages.removeFirst(ages.count - 400) }
                timedAges.append((message.received, age))
                if let first = timedAges.first, message.received - first.at > 25 { timedAges.removeAll { message.received - $0.at > 20 } }
                openAges[message.gesture, default: []].append(age)
            }
            // A gesture that has ended, or been overtaken by a newer one, says what delay it needed:
            // enough to cover 95% of its own touches. One touch says too little, so taps do not count.
            for (gesture, own) in openAges where gesture < message.gesture || (gesture == message.gesture && !message.isDown && message.kind != 4) {
                openAges[gesture] = nil
                guard own.count >= 5 else { continue }
                let ordered = own.sorted()
                needs.append(ordered[min(ordered.count - 1, Int(Double(ordered.count) * 0.95))])
                if needs.count > 5 { needs.removeFirst() }
            }
            return
        }
        if message.recovered { return }
        if message.kind == 4 {
            lock.lock()
            if newestMove == nil || newestMove!.gesture != message.gesture || message.sequence > newestMove!.sequence { newestMove = message }
            lock.unlock()
        } else {
            commands?.yield(.discrete(message))
        }
    }

    private func handle(_ command: Command) async {
        switch command {
        case .discrete(let message):
            lock.lock()
            // An up carries the final position, so an older move still waiting is no longer wanted.
            if let pending = newestMove, pending.gesture == message.gesture || message.isDown { newestMove = nil }
            lock.unlock()
            active = message.isDown
            if message.isDown { await injectDown(message) } else { await injectUp(message) }
        case .tick where delay > 0:
            await replay()
        case .tick:
            lock.lock()
            let move = newestMove
            newestMove = nil
            lock.unlock()
            guard active, let move else { return }
            // Never closer together than one interval: a move that follows the last one too soon is
            // dropped by the simulator. A late tick therefore delays the next move; it does not squeeze it.
            while mirrorNow() < lastMove + interval {}
            lastMove = mirrorNow()
            await inject(move, direction: .down)
        }
    }

    /// The delay for the next gesture: enough to cover how late 95% of recent touches arrived, plus
    /// 10 ms. Never under the configured delay, never over 200 ms. Wi-Fi stays at the configured
    /// 25 ms; cellular, where touches arrive 30 to 90 ms after they were made, gets what it needs.
    ///
    /// The "gestures" rule asks each of the last five gestures what it needed and takes the second
    /// highest answer. One gesture caught in a network hiccup is then ignored, where pooling every
    /// touch let a single half-second gap hold the delay at its limit for many gestures afterwards
    /// (experiment L). With one or two answers the higher is taken; with none, the pooled rule stands in.
    ///
    /// The "steady" rule covers 99% of the touches of the last 20 seconds (95% left one flick in fifteen
    /// short on a link with radio holes; experiment M). It rises at once and falls
    /// 4 ms a second, so the delay does not swing from one gesture to the next on a link whose radio
    /// goes away twice a second (experiment M). A touch over 150 ms late is a hiccup and is not counted.
    private func adaptiveDelay() -> TimeInterval {
        if delayRule == "fixed" { return delay }
        lock.lock()
        let recent = ages.sorted()
        let asked = needs.sorted()
        let window = timedAges.filter { mirrorNow() - $0.at <= 20 && $0.age <= 0.15 }.map(\.age).sorted()
        lock.unlock()
        if delayRule == "steady" {
            guard window.count >= 8 else { return max(delay, steadyDelay) }
            let target = min(0.2, max(delay, window[min(window.count - 1, Int(Double(window.count) * 0.99))] + 0.010))
            let time = mirrorNow()
            steadyDelay = target >= steadyDelay ? target : max(target, steadyDelay - 0.004 * (time - steadySet))
            steadySet = time
            return steadyDelay
        }
        if delayRule == "gestures", !asked.isEmpty {
            return min(0.2, max(delay, asked[asked.count >= 3 ? asked.count - 2 : asked.count - 1] + 0.010))
        }
        guard recent.count >= (delayRule == "gestures" ? 8 : 20) else { return delay }
        return min(0.2, max(delay, recent[min(recent.count - 1, Int(Double(recent.count) * 0.95))] + 0.010))
    }

    /// One tick of replay mode: inject any down or up whose time has come, then the position the
    /// finger had a moment ago, interpolated between the two samples around that moment.
    ///
    /// The moment is the gesture's own clock, and it never jumps forward to catch up. A gesture
    /// whose touch-down arrives late starts late and keeps its spacing. If a moving finger's samples
    /// stop arriving, the clock waits for them, for at most one delay more, because playing a gap
    /// and then jumping makes the finger look faster than it was (experiment J).
    private func replay() async {
        // The position played is the one for the moment it will be injected, which is never sooner
        // than one interval after the last move. Taking the moment this tick happened to run instead
        // put each position a millisecond or three off its time, and the simulator read that as the
        // finger changing speed by up to a tenth from step to step (experiment L).
        let time = max(mirrorNow(), lastMove + interval)
        lock.lock()
        let pending = waiting.sorted { $0.touchTime < $1.touchTime }
        lock.unlock()
        if !active {
            guard let first = pending.first else { return }
            currentDelay = adaptiveDelay()
            startShift = max(0, time - currentDelay - first.touchTime)
            stall = 0
            if first.kind == 1 {
                // A fresh touch-down goes in the moment it arrives: the delay exists to keep moves
                // evenly spaced, and a finger landing has no spacing to keep.
                lock.lock(); waiting.removeAll { $0.gesture == first.gesture && $0.kind == 1 }; lock.unlock()
                replaying = first.gesture
                active = true
                gestureBegan = time
                ranAhead = false
                lastPlayed = CGPoint(x: first.x1, y: first.y1)
                await injectDown(first)
                return
            }
        }
        var playhead = time - currentDelay - startShift - stall
        if active, let up = pending.first(where: { !$0.isDown && $0.gesture == replaying }) {
            // A plain tap: no moves arrived and the finger lifted where it landed. Lift at once too.
            lock.lock()
            let moved = samples.contains { $0.gesture == replaying && $0.kind == 4 }
            lock.unlock()
            if !moved, abs(up.x1 - lastPlayed.x) < 0.012, abs(up.y1 - lastPlayed.y) < 0.012 {
                while mirrorNow() < lastMove + interval {}
                await injectUp(up)
                active = false
                lock.lock()
                waiting.removeAll { $0.gesture == up.gesture && !$0.isDown }
                samples.removeAll { $0.gesture <= up.gesture }
                log.append(String(format: "%u,0,91,%d,0.0,0.0,%.6f,%.6f,%.6f,%.6f,", up.gesture, Int(up.contacts), up.touchTime, up.received, time, mirrorNow()))
                lock.unlock()
                return
            }
        }
        if active {
            lock.lock()
            let newest = samples.filter { $0.gesture >= replaying }.max { $0.touchTime < $1.touchTime }
            lock.unlock()
            let endKnown = pending.contains { $0.gesture >= replaying }
            // A single finger may run a little ahead of its newest position (see below), so the clock
            // waits only for what that does not cover.
            let allowed = newest.map { $0.contacts == 1 ? lead : 0 } ?? 0
            if let newest, newest.kind == 4, !endKnown, newest.touchTime + allowed < playhead, stall < currentDelay {
                let wait = min(playhead - newest.touchTime - allowed, currentDelay - stall)
                stall += wait
                playhead -= wait
            } else if stall > 0, time - gestureBegan >= catchUpAfter, let newest, newest.touchTime > playhead + interval {
                // Touches are arriving ahead of the clock again: win the waited time back slowly, 5% faster
                // than real time, so a long drag does not stay late for its whole length.
                let gain = min(stall, interval * 0.05)
                stall -= gain
                playhead += gain
            }
        }
        let due = pending.filter { $0.touchTime <= playhead }
        if !due.isEmpty {
            lock.lock(); waiting.removeAll { $0.touchTime <= playhead }; lock.unlock()
        }
        var lifted = false
        for message in due {
            if message.isDown {
                replaying = message.gesture
                active = true
                gestureBegan = time
                ranAhead = false
                lastPlayed = CGPoint(x: message.x1, y: message.y1)
                await injectDown(message)
            } else {
                while mirrorNow() < lastMove + interval {}
                // A finger that was played ahead of its last known position lifts where it is: going
                // back to the true end first would read as a reversal just before the lift.
                if ranAhead, message.contacts == 1 {
                    await injectUp(MirrorTouch(kind: message.kind, gesture: message.gesture, sequence: message.sequence, points: [lastPlayed],
                                                time: message.touchTime, received: message.received))
                } else {
                    await injectUp(message)
                }
                active = false
                lifted = true
                lock.lock()
                samples.removeAll { $0.gesture <= message.gesture }
                // One line per finished gesture: the delay it was replayed at and how long it waited for late touches.
                log.append(String(format: "%u,0,90,%d,%.1f,%.1f,%.6f,%.6f,%.6f,%.6f,", message.gesture, Int(message.contacts),
                                  currentDelay * 1000, (startShift + stall) * 1000, message.touchTime, message.received, time, mirrorNow()))
                lock.unlock()
            }
        }
        guard active, !lifted else { return }
        lock.lock()
        let track = samples.filter { $0.gesture == replaying }
        lock.unlock()
        guard let before = track.last(where: { $0.touchTime <= playhead }) else { return }
        var x1 = before.x1, y1 = before.y1, x2 = before.x2, y2 = before.y2
        ranAhead = false
        if let after = track.first(where: { $0.touchTime > playhead }), after.touchTime > before.touchTime {
            let share = (playhead - before.touchTime) / (after.touchTime - before.touchTime)
            x1 += (after.x1 - before.x1) * share; y1 += (after.y1 - before.y1) * share
            x2 += (after.x2 - before.x2) * share; y2 += (after.y2 - before.y2) * share
        } else if lead > 0, before.contacts == 1, before.kind == 4, playhead > before.touchTime,
                  let prior = track.last(where: { $0.touchTime < before.touchTime - 0.004 }), before.touchTime - prior.touchTime < 0.05 {
            // The next position is late. A finger standing still and then jumping reads as slower than
            // it was, and at the end of a flick that costs most of the fling. So for up to `lead`
            // the finger carries on as it was going, and the real position corrects it when it comes.
            let share = min(playhead - before.touchTime, lead) / (before.touchTime - prior.touchTime)
            x1 += (before.x1 - prior.x1) * share; y1 += (before.y1 - prior.y1) * share
            x1 = min(1, max(0, x1)); y1 = min(1, max(0, y1))
            ranAhead = true
        }
        guard abs(x1 - lastPlayed.x) > 0.00001 || abs(y1 - lastPlayed.y) > 0.00001 || before.contacts > 1 else { return }
        lastPlayed = CGPoint(x: x1, y: y1)
        while mirrorNow() < lastMove + interval {}
        lastMove = mirrorNow()
        let points = before.contacts > 1 ? [CGPoint(x: x1, y: y1), CGPoint(x: x2, y: y2)] : [CGPoint(x: x1, y: y1)]
        await inject(MirrorTouch(kind: 4, gesture: before.gesture, sequence: before.sequence, points: points, time: playhead), direction: .down)
    }

    /// A touch-down. A second finger joining (kind 5) goes in as a two-finger down while the first
    /// finger's own touch stays open: the simulator then sees the second finger arrive beside the
    /// first, where lifting and re-touching would read as a tap (experiment H).
    private func injectDown(_ message: MirrorTouch) async {
        if message.kind == 5 { while mirrorNow() < lastMove + interval {} }
        if message.kind == 1, message.contacts == 1 {
            singleOpen = true
            // Home, back and the other system gestures need the touch marked as starting at an edge.
            let x = message.x1 * width, y = message.y1 * height
            edgeName = edgePoints <= 0 ? "" : y > height - edgePoints ? "bottom" : y < edgePoints ? "top" : x < edgePoints ? "left" : x > width - edgePoints ? "right" : ""
        }
        await inject(message, direction: .down)
        lastMove = mirrorNow()
    }

    /// A lift. When a pair that began as one finger ends, the first finger's own touch is closed too.
    private func injectUp(_ message: MirrorTouch) async {
        await inject(message, direction: .up)
        guard singleOpen else { return }
        singleOpen = false
        guard message.contacts >= 2 else { return }
        await inject(MirrorTouch(kind: message.kind, gesture: message.gesture, sequence: message.sequence,
                                  points: [CGPoint(x: message.x1, y: message.y1)], time: message.touchTime), direction: .up)
    }

    private func inject(_ message: MirrorTouch, direction: FBSimulatorHIDDirection) async {
        let first = CGPoint(x: message.x1 * width, y: message.y1 * height)
        let second = CGPoint(x: message.x2 * width, y: message.y2 * height)
        let event: FBSimulatorHIDEvent = message.contacts >= 2
            ? .twoFingerTouch(direction: direction, finger1: first, finger2: second)
            : .touch(direction: direction, x: first.x, y: first.y)
        let start = mirrorNow()
        var failure = ""
        do {
            // An edge hint, for Home and the other system gestures, needs sendTouch(…nativeEdge:), which
            // is on its own branch and not yet in AXe; until then an edge swipe is sent as a plain touch.
            try await event.sendAsync(on: hid)
        } catch { failure = String(describing: error).prefix(60).replacingOccurrences(of: ",", with: ";") }
        if message.contacts < 2, direction == .up { edgeName = "" }
        let line = String(format: "%u,%u,%d,%d,%.2f,%.2f,%.6f,%.6f,%.6f,%.6f,%@", message.gesture, message.sequence, Int(message.kind),
                          Int(message.contacts), first.x, first.y, message.touchTime, message.received, start, mirrorNow(), failure)
        lock.lock()
        log.append(line)
        if log.count > 4000 { log.removeFirst(2000) }
        if arrivals.count > 8000 { arrivals.removeFirst(4000) }
        lock.unlock()
    }

    /// Presses a hardware button `count` times. `button` is FBSimulatorHIDButton's raw value:
    /// 2 Home, 3 Lock, 4 Side, 5 Siri. Two quick Home presses open the app switcher.
    func press(button: UInt8, count: UInt8) {
        guard let which = FBSimulatorHIDButton(rawValue: Int32(button)) else { return }
        Task.detached(priority: .userInitiated) { [self] in
            for index in 0..<max(1, Int(count)) {
                if index > 0 { try? await Task.sleep(nanoseconds: 120_000_000) }
                let start = mirrorNow()
                var failure = ""
                let event = FBSimulatorHIDEvent.composite([.button(direction: .down, button: which), .delay(0.05), .button(direction: .up, button: which)])
                do { try await event.sendAsync(on: hid) } catch { failure = String(describing: error).prefix(60).replacingOccurrences(of: ",", with: ";") }
                let line = String(format: "0,0,%d,0,0.00,0.00,%.6f,%.6f,%.6f,%.6f,%@", 100 + Int(button), start, start, start, mirrorNow(), failure)
                lock.lock(); log.append(line); lock.unlock()
            }
        }
    }

    func csv() -> String {
        lock.lock(); defer { lock.unlock() }
        return "gesture,sequence,kind,contacts,x,y,touchTime,received,injectStart,injectDone,error\n" + log.joined(separator: "\n") + "\n"
    }

    /// Every touch message as it arrived (replay mode only): recovered is 1 for a move taken from a later message's history.
    func arrivalsCSV() -> String {
        lock.lock(); defer { lock.unlock() }
        return "gesture,sequence,kind,touchTime,received,recovered\n" + arrivals.joined(separator: "\n") + "\n"
    }

    var summary: String { lock.lock(); defer { lock.unlock() }; return "moves recovered from history \(recoveredCount), moves that arrived after their recovery \(repeatedCount)" }
}
#endif
