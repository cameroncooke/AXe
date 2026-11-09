import ArgumentParser
import Foundation
import Testing
@testable import AXe

@Suite("Agent mode options")
struct AgentModeOptionsTests {
    private let snapshot = "3FF70D78-26DA-4314-B37B-4CB57D2A1A85"

    @Test("A published ref parses", arguments: ["e1", "e12", "e4096", "e" + String(repeating: "9", count: 31)])
    func publishedRefParses(_ ref: String) throws {
        let options = try AgentModeOptions.parse(["--agent", "--snapshot-id", snapshot, "--ref", ref])
        #expect(options.elementRef == ref)
    }

    @Test("A malformed ref fails before any broker request",
          arguments: ["", "e", "e0", "e012", "E12", "12", "e+5", "e1 ", " e1", "e1a", "e١٢",
                      "e" + String(repeating: "9", count: 32)])
    func malformedRefFails(_ ref: String) {
        #expect(throws: (any Error).self) {
            _ = try AgentModeOptions.parse(["--agent", "--snapshot-id", snapshot, "--ref", ref])
        }
    }

    @Test("A non-positive expected PID has its own code")
    func nonPositivePIDCode() {
        do {
            _ = try AgentModePIDPolicy.expectedPID(assertion: 0, snapshot: nil)
            Issue.record("A zero PID assertion was accepted.")
        } catch let failure as AgentModeFailure {
            #expect(failure.code == "invalidExpectedPID")
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }
}
