import Foundation

/// Reception statistics and compound Receiver Reports for one unicast RTP source.
/// RFC 3550 sections 6.4, 6.5 and Appendix A.1.
struct PhysicalDisplayRTCP: Sendable {
    let payloadType: UInt8
    let senderSSRC: UInt32
    let receiverSSRC: UInt32
    let cname: String
    let reportInterval: TimeInterval

    private var nextReportAt: ContinuousClock.Instant?
    private var sequences = SequenceStatistics()
    private var lastSenderReport: SenderReport?
    private var lastArrival: ContinuousClock.Instant?
    private var lastRTPTimestamp: UInt32?
    private var clockRate: Double?
    private var jitter: Double = 0

    init(payloadType: UInt8, senderSSRC: UInt32, receiverSSRC: UInt32, cname: String, reportInterval: TimeInterval) {
        self.payloadType = payloadType
        self.senderSSRC = senderSSRC
        self.receiverSSRC = receiverSSRC
        self.cname = cname
        self.reportInterval = reportInterval
    }

    mutating func observe(_ bytes: Data, at now: ContinuousClock.Instant) throws {
        guard bytes.count >= 4, bytes[0] >> 6 == 2 else { return }
        if (192...223).contains(bytes[1]) {
            if let report = SenderReport.read(from: bytes, expectedSSRC: senderSSRC, at: now) {
                if let previous = lastSenderReport {
                    // Derive the sender's timestamp scale from its own clock pairs.
                    let elapsed = Double(report.ntpTimestamp &- previous.ntpTimestamp) / 4_294_967_296
                    let ticks = Double(report.rtpTimestamp &- previous.rtpTimestamp)
                    let rate = ticks / elapsed
                    if elapsed >= 0.1, elapsed <= 60, rate.isFinite, (1_000...1_000_000).contains(rate) {
                        if let clockRate, abs(rate - clockRate) > clockRate * 0.1 { jitter = 0 }
                        clockRate = rate
                    }
                }
                lastSenderReport = report
                armReports(at: now)
            }
            return
        }

        guard let packet = RTPHeader(bytes, payloadType: payloadType) else { return }
        guard packet.ssrc == senderSSRC else {
            throw CLIOutputFailure(code: "deviceStreamChanged",
                message: "The RTP sender did not match the negotiated display stream.")
        }
        guard sequences.observe(packet.sequence) else { return }
        if let previousArrival = lastArrival, let previousTimestamp = lastRTPTimestamp, let clockRate {
            let arrivalTicks = previousArrival.duration(to: now).timeInterval * clockRate
            let mediaTicks = Double(Int32(bitPattern: packet.timestamp &- previousTimestamp))
            jitter += (abs(arrivalTicks - mediaTicks) - jitter) / 16
        }
        lastArrival = now
        lastRTPTimestamp = packet.timestamp
        armReports(at: now)
    }

    mutating func reportIfDue(at now: ContinuousClock.Instant) -> Data? {
        guard let nextReportAt, now >= nextReportAt else { return nil }
        self.nextReportAt = now + .seconds(reportInterval)
        let loss = sequences.report()
        var bytes = Data([loss == nil ? 0x80 : 0x81, 201])
        bytes.appendNetwork(UInt16(loss == nil ? 1 : 7))
        bytes.appendNetwork(receiverSSRC)
        if let loss {
            bytes.appendNetwork(senderSSRC)
            bytes.append(loss.fraction)
            let lost = UInt32(bitPattern: loss.total)
            bytes.append(UInt8(truncatingIfNeeded: lost >> 16))
            bytes.append(UInt8(truncatingIfNeeded: lost >> 8))
            bytes.append(UInt8(truncatingIfNeeded: lost))
            bytes.appendNetwork(loss.highestSequence)
            bytes.appendNetwork(UInt32(min(max(jitter, 0), Double(UInt32.max))))
            if let report = lastSenderReport {
                bytes.appendNetwork(UInt32(truncatingIfNeeded: report.ntpTimestamp >> 16))
                let delay = report.receivedAt.duration(to: now).timeInterval * 65_536
                bytes.appendNetwork(UInt32(min(max(delay, 0), Double(UInt32.max))))
            } else {
                bytes.appendNetwork(UInt32(0))
                bytes.appendNetwork(UInt32(0))
            }
        }

        // Each regular report carries one CNAME. This pseudonym belongs only to
        // the stream and contains no account, host name or address.
        let name = Data(cname.utf8.prefix(255))
        let unpadded = 4 + 4 + 2 + name.count + 1
        let padding = (4 - unpadded % 4) % 4
        bytes.append(contentsOf: [0x81, 202])
        bytes.appendNetwork(UInt16((unpadded + padding) / 4 - 1))
        bytes.appendNetwork(receiverSSRC)
        bytes.append(contentsOf: [1, UInt8(name.count)])
        bytes.append(name)
        bytes.append(contentsOf: repeatElement(0, count: 1 + padding))
        return bytes
    }

    private mutating func armReports(at now: ContinuousClock.Instant) {
        if nextReportAt == nil { nextReportAt = now + .seconds(reportInterval) }
    }

    private struct RTPHeader {
        let ssrc: UInt32
        let sequence: UInt16
        let timestamp: UInt32

        init?(_ data: Data, payloadType: UInt8) {
            guard data.count >= 12, data[1] & 127 == payloadType else { return nil }
            var headerBytes = 12 + 4 * Int(data[0] & 15)
            if data[0] & 16 != 0 {
                guard data.count >= headerBytes + 4 else { return nil }
                headerBytes += 4 + 4 * Int(data.network16(at: headerBytes + 2))
            }
            if data[0] & 32 != 0 {
                guard let padding = data.last, padding != 0, data.count - headerBytes > padding else { return nil }
            } else {
                guard data.count > headerBytes else { return nil }
            }
            sequence = data.network16(at: 2)
            timestamp = data.network32(at: 4)
            ssrc = data.network32(at: 8)
        }
    }

    private struct SenderReport {
        let ntpTimestamp: UInt64
        let rtpTimestamp: UInt32
        let receivedAt: ContinuousClock.Instant

        static func read(from data: Data, expectedSSRC: UInt32, at now: ContinuousClock.Instant) -> Self? {
            var offset = 0
            var report: Self?
            while offset + 4 <= data.count {
                guard data[offset] >> 6 == 2 else { return nil }
                let size = (Int(data.network16(at: offset + 2)) + 1) * 4
                guard size <= data.count - offset else { return nil }
                let type = data[offset + 1]
                let count = Int(data[offset] & 31)
                if type == 200, size >= 28 + 24 * count,
                   data.network32(at: offset + 4) == expectedSSRC {
                    let seconds = UInt64(data.network32(at: offset + 8))
                    let fraction = UInt64(data.network32(at: offset + 12))
                    report = Self(ntpTimestamp: seconds << 32 | fraction,
                        rtpTimestamp: data.network32(at: offset + 16), receivedAt: now)
                }
                offset += size
            }
            return offset == data.count ? report : nil
        }
    }

    private struct SequenceStatistics {
        private var base: UInt16?
        private var highest: UInt16 = 0
        private var cycles: UInt64 = 0
        private var restartCandidate: UInt16?
        private var received: UInt64 = 0
        private var priorExpected: UInt64 = 0
        private var priorReceived: UInt64 = 0

        mutating func observe(_ sequence: UInt16) -> Bool {
            // This source is already bound to the negotiated IPv6 endpoint and SSRC.
            if base == nil {
                reset(at: sequence)
            } else {
                let distance = Int(sequence &- highest)
                if distance < 3_000 {
                    if sequence < highest { cycles += 65_536 }
                    highest = sequence
                } else if distance <= 65_536 - 100 {
                    guard restartCandidate == sequence else {
                        restartCandidate = sequence &+ 1
                        return false
                    }
                    reset(at: sequence)
                }
                // Reordered and duplicate packets count as received per RFC 3550.
            }
            received += 1
            return true
        }

        mutating func report() -> (fraction: UInt8, total: Int32, highestSequence: UInt32)? {
            guard let base else { return nil }
            let extendedHighest = cycles + UInt64(highest)
            let expected = extendedHighest - UInt64(base) + 1
            let totalLost = Int64(expected) - Int64(received)
            let expectedInterval = expected - priorExpected
            let lostInterval = Int64(expectedInterval) - Int64(received - priorReceived)
            priorExpected = expected
            priorReceived = received
            let fraction = expectedInterval > 0 && lostInterval > 0
                ? min(255, (UInt64(lostInterval) * 256) / expectedInterval) : 0
            return (UInt8(fraction), Int32(min(max(totalLost, -8_388_608), 8_388_607)),
                    UInt32(truncatingIfNeeded: extendedHighest))
        }

        private mutating func reset(at sequence: UInt16) {
            base = sequence
            highest = sequence
            cycles = 0
            restartCandidate = nil
            received = 0
            priorExpected = 0
            priorReceived = 0
        }
    }
}

private extension Data {
    func network16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }

    func network32(at offset: Int) -> UInt32 {
        UInt32(network16(at: offset)) << 16 | UInt32(network16(at: offset + 2))
    }

    mutating func appendNetwork<Integer: FixedWidthInteger>(_ value: Integer) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }
}
