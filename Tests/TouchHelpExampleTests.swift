import ArgumentParser
import Testing
@testable import AXe

@Suite("Touch help examples")
struct TouchHelpExampleTests {
    @Test("Every touch help example parses and validates")
    func examplesParse() throws {
        let examples = Touch.configuration.discussion
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("axe touch ") }
        #expect(examples.count == 4)

        for example in examples {
            let command = example.split(separator: "#", maxSplits: 1)[0]
            let arguments = command.split(separator: " ").dropFirst(2).map(String.init)
            #expect(throws: Never.self, "\(example)") {
                _ = try Touch.parse(arguments)
            }
        }
    }
}
