import Foundation

/// RTP H.264 non-interleaved packetization (RFC 6184).
/// A gap discards the affected access unit and waits for a complete IDR before writing again.
struct H264RTPDepacketizer {
    private static let startCode = Data([0, 0, 0, 1])
    private static let maximumUnitBytes = 24 * 1024 * 1024

    let payloadType: UInt8
    private var source: UInt32?
    private var lastSequence: UInt16?
    private var timestamp: UInt32?
    private var damaged = false
    private var hasReference = false
    private var units: [Data] = []
    private var unitBytes = 0
    private var fragment: Data?
    private var sps: [Data] = []
    private var pps: [Data] = []

    init(payloadType: UInt8) {
        self.payloadType = payloadType
    }

    mutating func accept(_ datagram: Data) throws -> Data? {
        guard let packet = Packet(datagram, payloadType: payloadType) else { return nil }
        if let source, source != packet.source {
            throw CLIOutputFailure(code: "deviceStreamChanged", message: "The device changed the RTP source during the stream.")
        }
        source = packet.source

        var gap = false
        if let lastSequence {
            let distance = packet.sequence &- lastSequence
            guard distance > 0, distance < 32_768 else { return nil }
            gap = distance != 1
        }
        lastSequence = packet.sequence

        if packet.payload.first == 0x92, let config = AVCConfiguration(packet.payload) {
            sps = config.sps
            pps = config.pps
            hasReference = false
            resetUnit()
            return nil
        }

        if timestamp != packet.timestamp {
            if timestamp != nil {
                hasReference = false
                resetUnit()
            }
            timestamp = packet.timestamp
        }
        if gap {
            damaged = true
            hasReference = false
        }
        if !damaged, try !appendPayload(packet.payload) {
            damaged = true
            hasReference = false
        }
        if packet.marker {
            defer { resetUnit() }
            return finishUnit()
        }
        return nil
    }

    private mutating func appendPayload(_ payload: Data) throws -> Bool {
        guard let first = payload.first, first & 0x80 == 0 else { return false }
        switch first & 0x1f {
        case 1...23:
            return fragment == nil && appendNAL(payload)
        case 24:
            guard fragment == nil else { return false }
            return appendAggregation(payload)
        case 28:
            return appendFragment(payload)
        default:
            throw CLIOutputFailure(code: "unsupportedRTPPacketization",
                message: "The device sent an unsupported H.264 RTP packet type.")
        }
    }

    private mutating func appendAggregation(_ payload: Data) -> Bool {
        var offset = payload.startIndex + 1
        guard offset < payload.endIndex else { return false }
        while offset < payload.endIndex {
            guard payload.endIndex - offset >= 2 else { return false }
            let length = Int(payload[offset]) << 8 | Int(payload[offset + 1])
            offset += 2
            guard length > 0, length <= payload.endIndex - offset else { return false }
            guard appendNAL(Data(payload[offset..<(offset + length)])) else { return false }
            offset += length
        }
        return true
    }

    private mutating func appendFragment(_ payload: Data) -> Bool {
        guard payload.count >= 2 else { return false }
        let offset = payload.startIndex
        let flags = payload[offset + 1]
        let start = flags & 0x80 != 0
        let end = flags & 0x40 != 0
        let type = flags & 0x1f
        guard flags & 0x20 == 0, (1...23).contains(type), !(start && end) else { return false }

        let header = (payload[offset] & 0xe0) | type
        let body = payload[(offset + 2)...]
        if start {
            guard fragment == nil, body.count + 1 <= Self.maximumUnitBytes - unitBytes else { return false }
            var nal = Data([header])
            nal.append(body)
            fragment = nal
            return true
        }
        guard fragment?.first == header, let existingCount = fragment?.count,
              body.count <= Self.maximumUnitBytes - unitBytes - existingCount else { return false }
        fragment?.append(body)
        if end, let complete = fragment {
            fragment = nil
            return appendNAL(complete)
        }
        return true
    }

    private mutating func appendNAL(_ data: Data) -> Bool {
        guard let header = data.first, header & 0x80 == 0,
              (1...23).contains(header & 0x1f),
              data.count + Self.startCode.count <= Self.maximumUnitBytes - unitBytes else { return false }
        units.append(data)
        unitBytes += data.count + Self.startCode.count
        return true
    }

    private mutating func finishUnit() -> Data? {
        guard !damaged, fragment == nil else {
            hasReference = false
            return nil
        }
        let types = units.map { $0.first.map { $0 & 0x1f } ?? 0 }
        let inBandSPS = units.filter { $0.first.map { $0 & 0x1f } == 7 && $0.count <= 65_535 }
        let inBandPPS = units.filter { $0.first.map { $0 & 0x1f } == 8 && $0.count <= 65_535 }
        if !inBandSPS.isEmpty { sps = inBandSPS }
        if !inBandPPS.isEmpty { pps = inBandPPS }
        guard types.contains(where: { (1...5).contains($0) }) else { return nil }

        let keyframe = types.contains(5)
        var bytes = Data()
        if keyframe {
            guard !sps.isEmpty, !pps.isEmpty else {
                hasReference = false
                return nil
            }
            let configuration = (inBandSPS.isEmpty ? sps : []) + (inBandPPS.isEmpty ? pps : [])
            for parameterSet in configuration {
                bytes.append(Self.startCode)
                bytes.append(parameterSet)
            }
            hasReference = true
        }
        guard hasReference else { return nil }
        for nal in units {
            bytes.append(Self.startCode)
            bytes.append(nal)
        }
        return bytes
    }

    private mutating func resetUnit() {
        timestamp = nil
        damaged = false
        units.removeAll(keepingCapacity: true)
        unitBytes = 0
        fragment = nil
    }

    /// The display service carries decoder settings in an avcC atom outside the video NAL units.
    private struct AVCConfiguration {
        let sps: [Data]
        let pps: [Data]

        init?(_ payload: Data) {
            guard let tag = payload.range(of: Data("avcC".utf8)), tag.lowerBound >= payload.startIndex + 4 else {
                return nil
            }
            let atomStart = tag.lowerBound - 4
            let atomSize = payload[atomStart..<tag.lowerBound].reduce(0) { ($0 << 8) | Int($1) }
            guard atomSize >= 15, atomSize <= payload.endIndex - atomStart else { return nil }

            let start = tag.upperBound
            let end = atomStart + atomSize
            guard payload[start] == 1, payload[start + 4] & 0xfc == 0xfc,
                  payload[start + 5] & 0xe0 == 0xe0 else { return nil }
            var offset = start + 6
            guard let sps = Self.parameterSets(in: payload, offset: &offset, end: end,
                                               count: Int(payload[start + 5] & 0x1f), type: 7),
                  offset < end else { return nil }
            let ppsCount = Int(payload[offset])
            offset += 1
            guard let pps = Self.parameterSets(in: payload, offset: &offset, end: end,
                                               count: ppsCount, type: 8) else { return nil }
            self.sps = sps
            self.pps = pps
        }

        private static func parameterSets(in payload: Data, offset: inout Int, end: Int,
                                          count: Int, type: UInt8) -> [Data]? {
            guard count > 0 else { return nil }
            var sets: [Data] = []
            for _ in 0..<count {
                guard end - offset >= 2 else { return nil }
                let length = Int(payload[offset]) << 8 | Int(payload[offset + 1])
                offset += 2
                guard length > 0, length <= end - offset, payload[offset] & 0x9f == type else { return nil }
                sets.append(Data(payload[offset..<(offset + length)]))
                offset += length
            }
            return sets
        }
    }

    private struct Packet {
        let sequence: UInt16
        let timestamp: UInt32
        let source: UInt32
        let marker: Bool
        let payload: Data

        init?(_ bytes: Data, payloadType: UInt8) {
            let start = bytes.startIndex
            guard bytes.count >= 12, bytes[start] >> 6 == 2, bytes[start + 1] & 0x7f == payloadType else { return nil }
            let header = bytes[start]
            var payloadStart = start + 12 + Int(header & 0x0f) * 4
            var payloadEnd = bytes.endIndex
            guard payloadStart < payloadEnd else { return nil }
            if header & 0x10 != 0 {
                guard payloadEnd - payloadStart >= 4 else { return nil }
                let words = Int(bytes[payloadStart + 2]) << 8 | Int(bytes[payloadStart + 3])
                payloadStart += 4 + words * 4
            }
            if header & 0x20 != 0 {
                guard let padding = bytes.last, padding > 0 else { return nil }
                payloadEnd -= Int(padding)
            }
            guard payloadStart < payloadEnd else { return nil }
            sequence = UInt16(bytes[start + 2]) << 8 | UInt16(bytes[start + 3])
            timestamp = bytes[(start + 4)..<(start + 8)].reduce(0) { ($0 << 8) | UInt32($1) }
            source = bytes[(start + 8)..<(start + 12)].reduce(0) { ($0 << 8) | UInt32($1) }
            marker = bytes[start + 1] & 0x80 != 0
            payload = Data(bytes[payloadStart..<payloadEnd])
        }
    }
}
