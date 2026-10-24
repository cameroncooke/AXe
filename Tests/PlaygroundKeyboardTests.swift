import Foundation
import Testing

@Suite("Playground Keyboard E2E", .serialized, .enabled(if: isE2EEnabled))
struct PlaygroundKeyboardTests {
    @Test("Backspace, Shift+A and Command+A change the real text field")
    func editTextWithKeys() async throws {
        let app = try AgentPlaygroundSession()
        do {
            _ = try await app.open("text-input", readyID: "text-input-field")
            _ = try await app.run(["tap", "--id", "text-input-field", "--element-type", "TextField"])
            _ = try await app.waitFor("focused text input") {
                UIStateParser.findElement(in: $0, withIdentifier: "typing-active-indicator") != nil
            }
            _ = try await app.run(["type", "AXe keys 123"])
            try await app.waitForValue("text-input-field", equals: "AXe keys 123")

            _ = try await app.run(["key", "42"])
            try await app.waitForValue("text-input-field", equals: "AXe keys 12")
            _ = try await app.run(["key-combo", "--modifiers", "225", "--key", "4"])
            try await app.waitForValue("text-input-field", equals: "AXe keys 12A")
            _ = try await app.run(["key-combo", "--modifiers", "227", "--key", "4"])
            _ = try await app.run(["key", "42"])
            try await app.waitForValue("text-input-field", equals: "empty")

            _ = try await app.run(["type", "Keys released"])
            try await app.waitForValue("text-input-field", equals: "Keys released")
            try await app.waitForValue("character-count", equals: "13")
        } catch {
            let originalFailure = error
            do {
                let observed = try await app.run(["describe-ui"])
                print("Keyboard failure read-only app capture:\n\(observed.output)")
            } catch {
                print("Keyboard failure read-only app capture also failed: \(error)")
            }
            throw originalFailure
        }
    }
}
