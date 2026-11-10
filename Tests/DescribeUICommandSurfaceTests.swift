import Testing
import Foundation

@Suite("Describe UI Command Surface Tests")
struct DescribeUICommandSurfaceTests {
    @Test("--point appears in describe-ui --help")
    func describeUIHelpIncludesPoint() async throws {
        let result = try await TestHelpers.runAxeCommand("describe-ui --help")
        #expect(result.output.contains("--point <x,y>"))
    }

    @Test("--point appears in help describe-ui")
    func helpDescribeUIIncludesPoint() async throws {
        let result = try await TestHelpers.runAxeCommand("help describe-ui")
        #expect(result.output.contains("--point <x,y>"))
    }

    @Test("Invalid --point format fails with guidance")
    func invalidPointFormatFails() async throws {
        let result = try await TestHelpers.runAxeCommandAllowFailure("describe-ui --udid invalid --point nope")
        #expect(result.exitCode != 0)
        #expect(result.output.contains("--point must be in the form x,y using non-negative numbers."))
    }
}
