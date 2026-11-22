#if AXE_MIRROR
import CoreGraphics
import Foundation

// The mirror host's wire format, shared with the viewer. Everything is little-endian.
//
// Control stream and video streams carry messages framed as: UInt32 length of what follows, UInt8
// type, payload. Datagrams carry: UInt8 type, payload.
// Host to viewer: 1 decoder configuration, 2 video frame, 3 pong, 23 session info (JSON, with the
// simulator's UDID and name), 24 a line about the host's own network link, 25 the simulators to
// choose from, 27 progress of a choice, 38 which screen is shown and the hinge angle, 39 whether the
// simulator is answering, 46 how busy the Mac is. Viewer to host:
// 10 ping, 11 frame report, 12 keyframe request, 13 viewer info (JSON), 30 profile (JSON), 31 send the
// simulators, 32 open or create a simulator, 34 leave the simulator, 35 shut down or delete a
// simulator, 36 turn the simulator, 37 fold an iPhone Duo simulator, 40 touch down, up or cancel,
// 41 touch move, 43 hardware button. Those from 25 to 39, and 46, that are not listed in this file's code are
// in `Shared/MirrorSimulators.swift`.

func mirrorNow() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
/// Writes a log line. A write that fails, as to a terminal that has been closed, is dropped: the
/// non-throwing `write(_:)` would stop the host with an exception.
func mirrorNote(_ text: String) { try? FileHandle.standardError.write(contentsOf: Data((text + "\n").utf8)) }

extension Data {
    mutating func put<T>(_ value: T) { Swift.withUnsafeBytes(of: value) { append(contentsOf: $0) } }
    func read<T>(_ type: T.Type, at offset: Int) -> T {
        var value: T!
        withUnsafeBytes { value = $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        return value
    }
}

func mirrorMessage(type: UInt8, payload: Data) -> Data {
    var data = Data(capacity: payload.count + 5)
    data.put(UInt32(payload.count + 1))
    data.put(type)
    data.append(payload)
    return data
}

// MARK: Input
// Client to host: 40 (reliable: touch down, up, cancel) and 41 (datagram: a move). Both carry
// UInt8 kind (1 down, 2 up, 3 cancel, 4 move, 5 a second finger joining the one already down), UInt8 contacts (1 or 2), UInt32 gesture, UInt32 sequence,
// four Float32 positions x1 y1 x2 y2 as fractions of the picture, Float64 touch time on the client's
// clock and Float64 clock offset to this host. 

struct MirrorTouch {
    let kind: UInt8
    let contacts: UInt8
    let gesture: UInt32
    let sequence: UInt32
    let x1: Double, y1: Double, x2: Double, y2: Double
    let touchTime: TimeInterval     // host clock
    let received: TimeInterval
    var recovered = false           // a move taken from a later message's history, because its own never arrived
    var isDown: Bool { kind == 1 || kind == 5 }

    init(kind: UInt8, gesture: UInt32, sequence: UInt32, points: [CGPoint], time: TimeInterval, received: TimeInterval? = nil) {
        self.kind = kind
        contacts = UInt8(points.count)
        self.gesture = gesture
        self.sequence = sequence
        x1 = points[0].x; y1 = points[0].y
        x2 = points.count > 1 ? points[1].x : 0; y2 = points.count > 1 ? points[1].y : 0
        touchTime = time
        self.received = received ?? time
    }

    /// The bytes of one touch message, as the viewer builds them. `history` is the moves just before
    /// this one, newest first; see `history(in:received:)`.
    static func payload(kind: UInt8, gesture: UInt32, sequence: UInt32, points: [CGPoint], time: TimeInterval,
                        history: [(points: [CGPoint], time: TimeInterval)] = []) -> Data {
        var data = Data(capacity: 42 + 20 * history.count)
        data.put(kind); data.put(UInt8(points.count)); data.put(gesture); data.put(sequence)
        data.put(Float32(points[0].x)); data.put(Float32(points[0].y))
        data.put(Float32(points.count > 1 ? points[1].x : 0)); data.put(Float32(points.count > 1 ? points[1].y : 0))
        data.put(time); data.put(Double(0))
        for earlier in history {
            data.put(Float32(earlier.points[0].x)); data.put(Float32(earlier.points[0].y))
            data.put(Float32(earlier.points.count > 1 ? earlier.points[1].x : 0)); data.put(Float32(earlier.points.count > 1 ? earlier.points[1].y : 0))
            data.put(Float32(time - earlier.time))
        }
        return data
    }

    /// A move may carry the moves just before it, newest first, 20 bytes each after the first 42:
    /// both fingers' positions and how many seconds earlier that move was made. Their sequence
    /// numbers count down from this message's. A move whose own datagram was lost is recovered from
    /// the next one or the one after.
    static func history(in payload: Data, received: TimeInterval) -> [MirrorTouch] {
        guard payload.count >= 62, let main = MirrorTouch(payload, received: received), main.kind == 4 else { return [] }
        var earlier: [MirrorTouch] = []
        for index in 0..<min(4, (payload.count - 42) / 20) {
            let at = 42 + 20 * index
            guard main.sequence > UInt32(index + 1) else { break }
            let ago = Double(payload.read(Float32.self, at: at + 16))
            guard ago.isFinite, ago >= 0, [0, 4, 8, 12].allSatisfy({ payload.read(Float32.self, at: at + $0).isFinite }) else { break }
            var points = [CGPoint(x: Double(payload.read(Float32.self, at: at)), y: Double(payload.read(Float32.self, at: at + 4)))]
            if main.contacts > 1 { points.append(CGPoint(x: Double(payload.read(Float32.self, at: at + 8)), y: Double(payload.read(Float32.self, at: at + 12)))) }
            var message = MirrorTouch(kind: 4, gesture: main.gesture, sequence: main.sequence - UInt32(index + 1), points: points,
                                       time: main.touchTime - ago, received: received)
            message.recovered = true
            earlier.append(message)
        }
        return earlier
    }

    /// How far ahead of its arrival a touch may say it was made. A viewer's clock is matched to
    /// the host's to within milliseconds, so a touch from the future is a mistake or mischief, and
    /// one kept waiting for its time to come would wait for ever.
    static let furthestAhead: TimeInterval = 1

    /// Nil for a message that is too short or holds a number that is not one. Positions are shares
    /// of the picture and are kept inside it; the time is the viewer's word, kept to `furthestAhead`.
    init?(_ payload: Data, received: TimeInterval) {
        guard payload.count >= 42 else { return nil }
        let positions = [10, 14, 18, 22].map { Double(payload.read(Float32.self, at: $0)) }
        let made = payload.read(Double.self, at: 26) + payload.read(Double.self, at: 34)
        guard positions.allSatisfy(\.isFinite), made.isFinite else { return nil }
        kind = payload.read(UInt8.self, at: 0)
        contacts = payload.read(UInt8.self, at: 1)
        gesture = payload.read(UInt32.self, at: 2)
        sequence = payload.read(UInt32.self, at: 6)
        x1 = min(1, max(0, positions[0])); y1 = min(1, max(0, positions[1]))
        x2 = min(1, max(0, positions[2])); y2 = min(1, max(0, positions[3]))
        touchTime = min(made, received + Self.furthestAhead)
        self.received = received
    }
}
#endif
