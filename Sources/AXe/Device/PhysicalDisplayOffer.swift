import Darwin
import Foundation
import zlib

enum PhysicalDisplayOffer {
    static let payloadType: UInt8 = 123

    static func make() throws -> (data: Data, receiverSSRC: UInt32) {
        let receiverSSRC = UInt32.random(in: 1 ... .max)
        let receiver = mediaReceiver(ssrc: receiverSSRC)
        let media = ProtoMessage {
            $0.number(1, 1)
            $0.number(2, 1)
            $0.message(5, receiver)
            $0.string(6, "Viceroy 1.7.0")
            $0.number(8, 0)
            // Receiver capability records from the observed AVC-only offer.
            let capabilities: [(UInt64, UInt64, UInt64?)] = [
                (4074, 0, 16384), (0, 75_000_000, 524288), (0, 40_000_000, 12288),
                (16, 4100, nil), (0, 20_000_000, 98304), (4, 6500, nil),
                (0, 6_000_000, 131072), (0, 100_000_000, 1048576),
                (0, 60_000_000, 262144), (1, 299, nil),
            ]
            for (kind, rate, mask) in capabilities {
                $0.message(9, ProtoMessage {
                    $0.number(1, kind)
                    $0.number(2, rate)
                    if let mask { $0.number(3, mask) }
                })
            }
            $0.number(13, 17_137_042_128_614_416_384)
            $0.number(14, 2)
            $0.number(16, 0)
            $0.number(18, 1)
        }
        let model = try systemString("hw.model")
        let build = try systemString("kern.osversion")
        let endpoint = ProtoMessage {
            $0.number(1, 0)
            $0.number(2, 1)
            $0.string(3, model)
            $0.string(4, "2205.3.1")
            $0.string(5, build)
        }
        let data = try PropertyListSerialization.data(fromPropertyList: [
            "avcMediaStreamNegotiatorMediaBlob": compress(media.data),
            "avcMediaStreamNegotiatorMode": 5,
            "avcMediaStreamOptionCallID": UUID().uuidString,
            "avcMediaStreamOptionRemoteEndpointInfo": endpoint.data,
        ], format: .binary, options: 0)
        return (data, receiverSSRC)
    }

    private static func mediaReceiver(ssrc: UInt32) -> ProtoMessage {
        let avc = ProtoMessage {
            $0.number(1, UInt64(payloadType))
            for direction: UInt64 in [1, 2, 1, 2] {
                $0.message(2, ProtoMessage {
                    $0.number(1, 1)
                    $0.number(2, direction)
                    $0.number(3, 50115)
                    $0.number(4, 0)
                })
            }
            $0.string(3, "")
            $0.number(4, 1)
        }
        return ProtoMessage {
            $0.number(1, UInt64(ssrc))
            $0.number(2, 0)
            $0.message(3, avc)
            $0.number(7, 0)
            $0.number(8, 63)
            $0.number(10, 1)
            $0.number(12, 1)
        }
    }

    private static func compress(_ data: Data) throws -> Data {
        var size = compressBound(uLong(data.count))
        var result = Data(count: Int(size))
        let code = result.withUnsafeMutableBytes { output in
            data.withUnsafeBytes { input in
                compress2(output.bindMemory(to: Bytef.self).baseAddress, &size,
                    input.bindMemory(to: Bytef.self).baseAddress, uLong(data.count), Z_BEST_COMPRESSION)
            }
        }
        guard code == Z_OK else { throw DeviceServiceError.invalidProtocol("could not encode the display stream offer") }
        result.count = Int(size)
        return result
    }

    private static func systemString(_ name: String) throws -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, (2...256).contains(size) else {
            throw DeviceServiceError.invalidProtocol("could not read host metadata for the display stream offer")
        }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0,
              let string = String(validatingUTF8: bytes), !string.isEmpty else {
            throw DeviceServiceError.invalidProtocol("could not read host metadata for the display stream offer")
        }
        return string
    }

    private struct ProtoMessage {
        private(set) var data = Data()

        init(_ build: (inout Self) -> Void) { build(&self) }

        mutating func number(_ field: UInt64, _ value: UInt64) {
            varint(field << 3)
            varint(value)
        }

        mutating func string(_ field: UInt64, _ value: String) {
            bytes(field, Data(value.utf8))
        }

        mutating func message(_ field: UInt64, _ value: Self) {
            bytes(field, value.data)
        }

        private mutating func bytes(_ field: UInt64, _ value: Data) {
            varint(field << 3 | 2)
            varint(UInt64(value.count))
            data.append(value)
        }

        private mutating func varint(_ value: UInt64) {
            var remaining = value
            while remaining >= 128 {
                data.append(UInt8(remaining & 127) | 128)
                remaining >>= 7
            }
            data.append(UInt8(remaining))
        }
    }
}
