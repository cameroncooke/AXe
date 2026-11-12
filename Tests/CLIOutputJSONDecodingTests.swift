import Foundation
import Testing
@testable import AXe

/// `CLIOutputValue.decodingJSON` must return exactly what `JSONDecoder` returns through
/// `init(from:)`, so `--output json` prints the same bytes it did before the fast path.
@Suite("CLI output JSON decoding")
struct CLIOutputJSONDecodingTests {
    /// Pretty-printed the way `JSONSerialization` prints describe-ui trees.
    private static let tree = #"""
    [
      {
        "AXFrame" : "{{0, 406.33333333333337}, {402, 44.333333333333314}}",
        "AXLabel" : "Wi\u2011Fi \/ Bluetooth \"On\"",
        "AXUniqueId" : null,
        "AXValue" : "caf\u00e9 cafe\u0301 \ud83d\ude00 tab\there\nline \\ end",
        "content_required" : false,
        "custom_actions" : [

        ],
        "enabled" : true,
        "frame" : {
          "height" : 44.333333333333314,
          "width" : 402,
          "x" : 0,
          "y" : 406.33333333333337
        },
        "help" : null,
        "pid" : 53878,
        "role" : "AXButton",
        "traits" : [
          "button",
          "selected"
        ],
        "children" : [
          {
            "children" : [

            ],
            "frame" : {
              "height" : 0.5,
              "width" : 361.66666666666669,
              "x" : -12.25,
              "y" : 1e-7
            },
            "nested" : [[[], {}], [1, [2.5, [null, true]]], {}],
            "numbers" : [0, -0, 1.0, 1e2, 2.5E-3, -9223372036854775808, 9223372036854775807, 9223372036854775808, 18446744073709551616, 0.1, 0.30000000000000004, 123456789.123456789],
            "raw" : "naïve ünïcödé"
          }
        ]
      }
    ]
    """#

    /// Rendered by main before the fast path.
    private static let renderedTree = #"""
    {"command":"describe-ui","data":{"result":[{"AXFrame":"{{0, 406.33333333333337}, {402, 44.333333333333314}}","AXLabel":"Wi‑Fi \/ Bluetooth \"On\"","AXUniqueId":null,"AXValue":"café café 😀 tab\there\nline \\ end","children":[{"children":[],"frame":{"height":0.5,"width":361.66666666666669,"x":-12.25,"y":1e-07},"nested":[[[],{}],[1,[2.5,[null,true]]],{}],"numbers":[0,0,1,100,0.0025,-9223372036854775808,9223372036854775807,9223372036854775808,18446744073709551616,0.1,0.30000000000000004,123456789.123456789],"raw":"naïve ünïcödé"}],"content_required":false,"custom_actions":[],"enabled":true,"frame":{"height":44.333333333333314,"width":402,"x":0,"y":406.33333333333337},"help":null,"pid":53878,"role":"AXButton","traits":["button","selected"]}]},"didError":false,"nextSteps":[],"schema":"axe.output.command-result","schemaVersion":"1"}

    """#

    /// describe-ui --point prints one element object.
    private static let point = #"""
    {
      "AXFrame" : "{{20, 120.66666666666667}, {362, 52}}",
      "AXLabel" : "General",
      "AXUniqueId" : "com.apple.settings.general",
      "AXValue" : null,
      "children" : [

      ],
      "enabled" : true,
      "frame" : {
        "height" : 52,
        "width" : 362,
        "x" : 20,
        "y" : 120.66666666666667
      },
      "pid" : 53878,
      "role" : "AXButton",
      "subrole" : null,
      "traits" : [
        "button"
      ]
    }
    """#

    private static let renderedPoint = #"""
    {"command":"describe-ui","data":{"result":{"AXFrame":"{{20, 120.66666666666667}, {362, 52}}","AXLabel":"General","AXUniqueId":"com.apple.settings.general","AXValue":null,"children":[],"enabled":true,"frame":{"height":52,"width":362,"x":20,"y":120.66666666666667},"pid":53878,"role":"AXButton","subrole":null,"traits":["button"]}},"didError":false,"nextSteps":[],"schema":"axe.output.command-result","schemaVersion":"1"}

    """#

    @Test("describe-ui trees render the same bytes as before", arguments: [
        (tree, renderedTree), (point, renderedPoint),
    ])
    func describeUIBytesArePinned(input: String, expected: String) throws {
        let context = CLIOutputContext(format: .json, command: "describe-ui", agent: false)
        try CLIOutput.$context.withValue(context) { try CLIOutput.writeJSONText(input) }
        #expect(String(decoding: try CLIOutput.rendered(context), as: UTF8.self) == expected)
        try expectSameAsDecoder(Data(input.utf8))
    }

    @Test("Random doubles from both encoders decode as the decoder decodes them")
    func randomNumbersMatchDecoder() throws {
        var generator = SplitMix64(seed: 0x5EED_A11E)
        var literals: [String] = []
        let encoder = JSONEncoder()
        for index in 0..<20_000 {
            let value: Double
            switch index % 4 {
            case 0: value = Double(Int.random(in: 0..<3000, using: &generator))
                / Double([3, 6, 7, 9, 12, 1000].randomElement(using: &generator)!)
            case 1: value = Double(bitPattern: generator.next())
            case 2: value = Double.random(in: -1e6...1e6, using: &generator)
            default: value = Double.random(in: 0...1, using: &generator)
                * pow(10, Double(Int.random(in: -30...30, using: &generator)))
            }
            guard value.isFinite else { continue }
            let serialized = try JSONSerialization.data(withJSONObject: [value])
            literals.append(String(decoding: serialized.dropFirst().dropLast(), as: UTF8.self))
            literals.append(String(decoding: try encoder.encode(value), as: UTF8.self))
        }
        for chunk in stride(from: 0, to: literals.count, by: 500) {
            let slice = literals[chunk..<min(chunk + 500, literals.count)]
            try expectSameAsDecoder(Data(("[" + slice.joined(separator: ",") + "]").utf8))
        }
    }

    @Test("Input the parser leaves to the decoder gets the decoder's result or error", arguments: [
        #"{"a": 1, "a": 2}"#, #"["\ud800"]"#, #"["\udc00"]"#, #"["\ud800\u0041"]"#, "[1] x", "[01]", "[1e400]",
        "[-1e400]", "[1,]", #"{"a" 1}"#, "[\"a\u{01}b\"]", "[\"\\x\"]", "[-]", "[1.]", "[.5]", "[1e]", "", "  ",
        "nul", "[true false]", #""top""#, "1.0", "true", "null", "-0", "1e2", "-9223372036854775809",
        "18446744073709551616", "[1E400, 2]", #"["\u0000"]"#, "\u{FEFF}[1]",
    ])
    func fallbackMatchesDecoder(input: String) throws {
        try expectSameAsDecoder(Data(input.utf8))
    }

    @Test("Nesting deeper than the parser's limit gets the decoder's result", arguments: [256, 257, 600])
    func deepNestingMatchesDecoder(depth: Int) throws {
        let documents = [
            String(repeating: "[", count: depth) + String(repeating: "]", count: depth),
            String(repeating: "{\"a\":", count: depth) + "1" + String(repeating: "}", count: depth),
        ]
        for document in documents {
            let data = Data(document.utf8)
            // The decoder recurses through Codable, which outgrows a test thread's stack here.
            let (expected, actual) = Self.onLargeStack {
                (Self.outcome { try JSONDecoder().decode(CLIOutputValue.self, from: data) },
                 Self.outcome { try CLIOutputValue.decodingJSON(data) })
            }
            #expect(actual == expected, "depth \(depth)")
        }
    }

    private static func outcome(_ decode: () throws -> CLIOutputValue) -> String {
        guard let value = try? decode() else { return "error" }
        return structure(value)
    }

    private static func onLargeStack(_ body: @escaping @Sendable () -> (String, String)) -> (String, String) {
        final class Box: @unchecked Sendable { var result: (String, String)? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.result = body()
            done.signal()
        }
        thread.stackSize = 64 << 20
        thread.start()
        done.wait()
        return box.result!
    }

    @Test("Invalid UTF-8 and UTF-16 input get the decoder's result or error")
    func encodingsMatchDecoder() throws {
        try expectSameAsDecoder(Data([0x5B, 0x22, 0xFF, 0xFE, 0x22, 0x5D]))
        try expectSameAsDecoder(Data([0x5B, 0x22, 0xC3, 0x22, 0x5D]))
        try expectSameAsDecoder(Data("[\"caf\u{e9}\", 1.5]".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }))
    }

    /// A raw U+FEFF at the start of a string is a character, not a byte-order mark to drop.
    @Test("Strings and keys that start with U+FEFF keep it", arguments: [
        "[\"\u{FEFF}A\"]", "[\"\u{FEFF}\"]", "{\"\u{FEFF}key\": \"caf\u{e9}\"}", "[\"\u{FEFF}\u{FEFF}caf\u{e9}\"]",
    ])
    func leadingZeroWidthNoBreakSpaceIsKept(input: String) throws {
        try expectSameAsDecoder(Data(input.utf8))
    }

    private func expectSameAsDecoder(_ data: Data, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let expected = Result { try JSONDecoder().decode(CLIOutputValue.self, from: data) }
        let actual = Result { try CLIOutputValue.decodingJSON(data) }
        switch (expected, actual) {
        case let (.success(expected), .success(actual)):
            #expect(Self.structure(actual) == Self.structure(expected), sourceLocation: sourceLocation)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            #expect(try encoder.encode(actual) == encoder.encode(expected), sourceLocation: sourceLocation)
        case (.failure, .failure):
            break
        default:
            Issue.record("decoder \(expected), parser \(actual)", sourceLocation: sourceLocation)
        }
    }

    /// Each value's case and payload, so a number decoded as Decimal cannot pass for a Double.
    private static func structure(_ value: CLIOutputValue) -> String {
        switch value {
        case .null: return "null"
        case let .bool(value): return "bool(\(value))"
        case let .integer(value): return "integer(\(value))"
        case let .unsignedInteger(value): return "unsigned(\(value))"
        case let .number(value): return "number(\(value))"
        case let .floatingPoint(value): return "double(\(value.bitPattern))"
        case let .string(value): return "string(\(Array(value.unicodeScalars.map(\.value))))"
        case let .array(values): return "[" + values.map(structure).joined(separator: ",") + "]"
        case let .object(values):
            return "{" + values.keys.sorted().map { "\($0.debugDescription):\(structure(values[$0]!))" }
                .joined(separator: ",") + "}"
        }
    }
}

private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
