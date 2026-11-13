import ArgumentParser
import Testing
@testable import AXe

@Suite("Keyboard Layout Tests")
struct KeyboardLayoutTests {
    @Test("US layout is the unchanged default table")
    func usLayoutMatchesDefaultTable() {
        for character in "azAZ09@'<>-_;:\"|\\~" {
            let string = String(character)
            let us = KeyboardLayout.us.keyEvent(for: string)
            let table = KeyEvent.keyCodeForString(string)
            #expect(us.keyCode == table.keyCode && us.shift == table.shift && !us.option)
        }
    }

    @Test("German layout swaps y/z and moves symbols to their QWERTZ keys")
    func germanLayoutKeys() {
        func key(_ string: String) -> (Int, Bool, Bool) {
            let event = KeyboardLayout.de.keyEvent(for: string)
            return (event.keyCode, event.shift, event.option)
        }
        #expect(key("y") == (29, false, false))
        #expect(key("Z") == (28, true, false))
        #expect(key("@") == (15, false, true))
        #expect(key("'") == (49, true, false))
        #expect(key("<") == (53, false, false))
        #expect(key(">") == (53, true, false))
        #expect(key("\\") == (36, true, true))
        #expect(key("ß") == (45, false, false))
        #expect(key("-") == (56, false, false))
    }

    @Test("German layout rejects dead keys and converts text with Option held")
    func germanLayoutConversion() throws {
        #expect(!TextToHIDEvents.validateText("´", layout: .de))
        #expect(TextToHIDEvents.validateText("max.muster@caperwhite.de", layout: .de))
        // Option down, L down, L up, Option up
        #expect(try TextToHIDEvents.convertTextToHIDEvents("@", layout: .de).count == 4)
    }

    @Test("Keyboard identifiers map by their hw= part")
    func keyboardIdentifierMapping() {
        #expect(KeyboardLayout(keyboardIdentifier: "de_DE@sw=QWERTZ-German;hw=German") == .de)
        #expect(KeyboardLayout(keyboardIdentifier: "en_US@sw=QWERTY;hw=ABC") == .us)
        #expect(KeyboardLayout(keyboardIdentifier: "en_US@sw=QWERTY;hw=ABC;ml=1") == .us)
        #expect(KeyboardLayout(keyboardIdentifier: "de_DE@sw=QWERTZ-German;hw=ABC;ml=1") == .us)
        #expect(KeyboardLayout(keyboardIdentifier: "fr_FR@sw=AZERTY-French;hw=French") == nil)
        #expect(KeyboardLayout(keyboardIdentifier: "emoji@sw=Emoji") == nil)
    }

    @Test("Selected input types with the layout; agent and physical devices refuse a non-us layout")
    func layoutRoutes() throws {
        let screen = "00000000-0000-0000-0000-000000000003"
        let selected = try Type.parse(["@", "--udid", "00000000-0000-0000-0000-000000000001", "--input-mode", "selected",
            "--screen-id", "3", "--screen-uuid", screen, "--expected-pid", "123", "--focus-id", "field", "--layout", "de"])
        guard case let .keyboard(keyboard) = try selected.selectedRequest().payload else {
            Issue.record("Selected type must send a keyboard payload")
            return
        }
        #expect(keyboard.events.map(\.event) == (try TextToHIDEvents.convertTextToHIDEvents("@", layout: .de)))

        do {
            _ = try Type.parse(["Hello", "--agent", "--udid", "fixture", "--focus-id", "field", "--layout", "de"])
            Issue.record("Agent type must refuse --layout de")
        } catch {
            #expect(Type.message(for: error) == "--layout supports only us with --agent.")
        }
        let device = try Type.parse(["Hello", "--udid", "00000001-0000000000000001", "--layout", "auto"])
        #expect(throws: ValidationError.self) { try device.validateOnDevice(inBatch: false) }
    }

    @Test("Batch type steps convert with the layout")
    @MainActor
    func batchUsesLayout() async throws {
        let context = BatchContext(simulatorUDID: "fixture", axCachePolicy: .perBatch,
            typeSubmissionMode: .composite, typeChunkSize: 200)
        let step = try Type.parse(["y@", "--udid", "fixture", "--layout", "de"])
        let primitives = try await step.toBatchPrimitives(context: context, logger: AxeLogger())
        guard primitives.count == 1, case .hidMergeable(let event) = primitives[0] else {
            Issue.record("Batch type must be one composite event")
            return
        }
        #expect(event.subEvents == (try TextToHIDEvents.convertTextToHIDEvents("y@", layout: .de)))
    }
}
