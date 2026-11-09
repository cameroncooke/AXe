import Foundation
import Testing
@testable import AXe

@Suite("Agent command base URLs")
struct AgentCommandURLTests {
    @Test("Plain HTTP is refused for a remote host, because the API key would be sent unencrypted",
          arguments: ["http://api.typesafe.ai", "http://192.168.1.10:8080/v1", "http://localhost.example.com"])
    func remotePlainHTTPIsRefused(_ raw: String) {
        #expect(throws: (any Error).self) { try AgentCommand.validatedHTTPURL(raw, optionName: "--base-url") }
    }

    @Test("HTTPS and plain HTTP on this Mac are accepted",
          arguments: ["https://api.typesafe.ai", "http://localhost:8080", "http://127.0.0.1:9000/v1",
                      "http://[::1]:8080", "HTTP://LOCALHOST"])
    func secureOrLocalIsAccepted(_ raw: String) throws {
        _ = try AgentCommand.validatedHTTPURL(raw, optionName: "--base-url")
    }

    @Test("Other schemes and hostless URLs are refused", arguments: ["ftp://example.com", "https://", "localhost"])
    func invalidIsRefused(_ raw: String) {
        #expect(throws: (any Error).self) { try AgentCommand.validatedHTTPURL(raw, optionName: "--base-url") }
    }
}
