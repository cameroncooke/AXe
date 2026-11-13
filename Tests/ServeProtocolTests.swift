import Foundation
import Testing
@testable import AXe

@Suite("Serve protocol")
@MainActor
struct ServeProtocolTests {
    private let udid = "9EE3F66D-075E-4B6C-8ACA-0FFA372FFE1A"

    @Test("Skips blank lines and comments")
    func skipsBlankLinesAndComments() {
        #expect(ServeProtocol.parse("", simulatorUDID: udid) == .skip)
        #expect(ServeProtocol.parse("   \t", simulatorUDID: udid) == .skip)
        #expect(ServeProtocol.parse("# tap -x 1 -y 2", simulatorUDID: udid) == .skip)
    }

    @Test("Answers ping without running a command")
    func answersPing() {
        #expect(ServeProtocol.parse(" ping ", simulatorUDID: udid) == .ping)
    }

    @Test("Runs a line as the JSON one-off command for the served simulator")
    func runsLineAsOneOffCommand() {
        #expect(ServeProtocol.parse("tap --label 'Sign In'", simulatorUDID: udid)
            == .command(["--output", "json", "tap", "--label", "Sign In", "--udid", udid]))
        #expect(ServeProtocol.parse("describe-ui --minimal-keys", simulatorUDID: udid)
            == .command(["--output", "json", "describe-ui", "--minimal-keys", "--udid", udid]))
    }

    @Test("Runs rotate and hinge, including hinge subcommands")
    func runsDeviceStateCommands() {
        #expect(ServeProtocol.parse("rotate left", simulatorUDID: udid)
            == .command(["--output", "json", "rotate", "left", "--udid", udid]))
        #expect(ServeProtocol.parse("hinge set tabletop", simulatorUDID: udid)
            == .command(["--output", "json", "hinge", "set", "tabletop", "--udid", udid]))
    }

    @Test("Keeps a screenshot's file path option")
    func keepsScreenshotPath() {
        #expect(ServeProtocol.parse("screenshot --output shot.png", simulatorUDID: udid)
            == .command(["--output", "json", "screenshot", "--output", "shot.png", "--udid", udid]))
    }

    @Test("Puts --udid before a -- terminator")
    func putsUDIDBeforeTerminator() {
        #expect(ServeProtocol.parse("type -- --literal", simulatorUDID: udid)
            == .command(["--output", "json", "type", "--udid", udid, "--", "--literal"]))
    }

    @Test("Text after -- may spell --udid or --stdin")
    func allowsOptionLikeTextAfterTerminator() {
        #expect(ServeProtocol.parse("type -- --udid", simulatorUDID: udid)
            == .command(["--output", "json", "type", "--udid", udid, "--", "--udid"]))
        #expect(ServeProtocol.parse("type -- --stdin", simulatorUDID: udid)
            == .command(["--output", "json", "type", "--udid", udid, "--", "--stdin"]))
    }

    @Test("Refuses commands that stream, read standard input or manage devices", arguments: [
        "batch --step 'tap -x 1 -y 1'", "serve", "record-video", "stream-video", "hid-broker --selected",
        "list-simulators", "shutdown", "agent 'Open Settings'", "--output json tap -x 1 -y 1",
    ])
    func refusesUnsupportedCommands(line: String) {
        guard case .refused = ServeProtocol.parse(line, simulatorUDID: udid) else {
            Issue.record("Expected a refusal for \(line)")
            return
        }
    }

    @Test("Refuses a line that names its own simulator")
    func refusesOwnUDID() {
        #expect(ServeProtocol.parse("tap -x 1 -y 1 --udid OTHER", simulatorUDID: udid)
            == .refused(command: "tap", message: "Leave out --udid: serve already targets \(udid)."))
        guard case .refused = ServeProtocol.parse("tap -x 1 -y 1 --udid=OTHER", simulatorUDID: udid) else {
            Issue.record("Expected a refusal for --udid=")
            return
        }
    }

    @Test("Refuses --stdin, which would read serve's own input")
    func refusesStandardInputText() {
        guard case .refused(let command, _) = ServeProtocol.parse("type --stdin", simulatorUDID: udid) else {
            Issue.record("Expected a refusal")
            return
        }
        #expect(command == "type")
    }

    @Test("Refuses a line with unbalanced quotes")
    func refusesUnbalancedQuotes() {
        guard case .refused = ServeProtocol.parse("tap --label 'Sign In", simulatorUDID: udid) else {
            Issue.record("Expected a refusal")
            return
        }
    }

    @Test("Ready, pong and refusal replies are one JSON line in the command-result schema")
    func repliesAreSingleLineCommandResults() throws {
        let ready = try decodeLine(ServeProtocol.ready(simulatorUDID: udid))
        #expect(ready["command"] as? String == "serve")
        #expect(ready["didError"] as? Bool == false)
        let readyResult = try #require((ready["data"] as? [String: Any])?["result"] as? [String: Any])
        #expect(readyResult["ready"] as? Bool == true)
        #expect(readyResult["udid"] as? String == udid)

        let pong = try decodeLine(ServeProtocol.pong())
        #expect(((pong["data"] as? [String: Any])?["result"] as? [String: Any])?["pong"] as? Bool == true)

        let refusal = try decodeLine(ServeProtocol.refusal(command: "batch", message: "No."))
        #expect(refusal["didError"] as? Bool == true)
        #expect((refusal["error"] as? [String: Any])?["code"] as? String == "invalidArguments")
        #expect((refusal["error"] as? [String: Any])?["message"] as? String == "No.")
    }

    @Test("A command that fails validation answers with one JSON line and a failing exit code")
    func failedCommandAnswersOneLine() async throws {
        let result = await Axe.formattedOutput(
            for: CLIOutputInvocation(arguments: ["--output", "json", "tap", "--udid", udid]), format: .json)
        let reply = try decodeLine(result.bytes)
        #expect(result.exitCode != EXIT_SUCCESS)
        #expect(reply["command"] as? String == "tap")
        #expect(reply["didError"] as? Bool == true)
        #expect((reply["error"] as? [String: Any])?["code"] as? String == "invalidArguments")
    }

    @Test("axe --output json serve is refused before serve starts")
    func refusesServeUnderOutputJSON() async throws {
        let result = await Axe.formattedOutput(
            for: CLIOutputInvocation(arguments: ["--output", "json", "serve", "--udid", udid]), format: .json)
        let reply = try decodeLine(result.bytes)
        #expect((reply["error"] as? [String: Any])?["code"] as? String == "unsupportedOutput")
    }

    @Test("Serve refuses a physical device")
    func refusesPhysicalDevice() {
        #expect(throws: (any Error).self) { try Serve.parse(["--udid", "00008110-001A2B3C4D5E801E"]) }
    }

    private func decodeLine(_ data: Data) throws -> [String: Any] {
        #expect(data.last == 0x0A)
        #expect(data.dropLast().contains(0x0A) == false)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

@Suite("Broker keep-alive")
struct BrokerKeepAliveTests {
    private func request(screenID: UInt32? = nil, token: UUID? = nil, activeDisplay: Bool? = nil) -> SelectedHIDRequest {
        var request = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
            screenID: screenID, screenUUID: screenID.map { _ in UUID() }, operation: .complete, token: token,
            payload: .keepAlive)
        request.activeDisplay = activeDisplay
        return request
    }

    @Test("Round-trips and validates with no screen, context or input")
    func validatesBareKeepAlive() throws {
        let decoded = try JSONDecoder().decode(SelectedHIDRequest.self, from: JSONEncoder().encode(request()))
        #expect(decoded.isKeepAlive)
        try decoded.validate()
    }

    @Test("Refuses a keep-alive that names a screen, a contact or the active display")
    func refusesKeepAliveWithFields() {
        #expect(throws: (any Error).self) { try request(screenID: 1).validate() }
        #expect(throws: (any Error).self) { try request(token: UUID()).validate() }
        #expect(throws: (any Error).self) { try request(activeDisplay: true).validate() }
    }

    @Test("Other requests are not keep-alives")
    func otherRequestsAreNotKeepAlives() {
        let tap = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(), screenID: nil,
            screenUUID: nil, operation: .complete, token: nil, payload: .contact([.touch(.down, x: 1, y: 1)]))
        #expect(!tap.isKeepAlive)
    }

    @Test("Serve sends one well inside the broker's 30 s idle limit, and waits briefly for its answer")
    func intervalIsInsideBrokerIdleLimit() {
        #expect(ServeInput.keepAliveInterval * 2 < .seconds(30))
        #expect(SelectedHIDBroker.keepAliveResponseMilliseconds <= 2000)
    }

    @Test("Resets an idle owner's clock, so maintenance keeps it running")
    @MainActor
    func keepAliveResetsIdleClock() async {
        final class Clock: @unchecked Sendable { var now: TimeInterval = 0 }
        let clock = Clock()
        let dependencies = SelectedAXDependencies(execute: { request, _, broker, _, _ in
            SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: request.requestID, brokerID: broker,
                outcome: "unused", token: nil, enqueuedEventCount: 0, cleanup: "notNeeded", error: nil, context: nil)
        }, persist: { _, _, _ in Issue.record("No quarantine expected") }, now: { clock.now })
        let owner = SelectedHIDOwner(simulatorUDID: UUID().uuidString, logger: AxeLogger(), dependencies: dependencies)
        clock.now = 25
        #expect(owner.keepAlive(request()).outcome == "keptAlive")
        clock.now = 40
        await owner.maintain()
        #expect(!owner.shouldStop)
        clock.now = 56
        await owner.maintain()
        #expect(owner.shouldStop)
        #expect(owner.keepAlive(request()).outcome == "rejectedBeforeInput")
    }
}

@Suite("describe-ui minimal keys")
@MainActor
struct DescribeUIMinimalKeysTests {
    private let udid = "9EE3F66D-075E-4B6C-8ACA-0FFA372FFE1A"

    @Test("Reads what UI-test drivers use and nothing else")
    func minimalKeySet() {
        #expect(AccessibilityFetcher.minimalRequestKeys == [
            .label, .frameDict, .value, .uniqueID, .type, .role, .roleDescription, .enabled,
        ])
        #expect(AccessibilityFetcher.minimalRequestKeys.isSubset(of: AccessibilityFetcher.accessibilityRequestKeys))
    }

    @Test("Parses with a plain read and a point read")
    func parsesPlainReads() throws {
        _ = try DescribeUI.parse(["--minimal-keys", "--udid", udid])
        _ = try DescribeUI.parse(["--minimal-keys", "--point", "10,20", "--udid", udid])
    }

    @Test("Is refused with agent mode and selected input")
    func refusedWithBrokerReads() {
        #expect(throws: (any Error).self) { try DescribeUI.parse(["--minimal-keys", "--agent", "--udid", udid]) }
        #expect(throws: (any Error).self) {
            try DescribeUI.parse(["--minimal-keys", "--input-mode", "selected", "--udid", udid])
        }
    }
}
