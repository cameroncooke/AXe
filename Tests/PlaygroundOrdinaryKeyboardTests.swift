import Foundation
import Testing

/// Plain typing and key commands on an ordinary iPhone or iPad, read back from the real field.
@Suite("Playground Ordinary Text E2E", .serialized, .enabled(if: isOrdinaryPlaygroundE2EEnabled))
struct PlaygroundOrdinaryTextTests {
    @Test("Text from --stdin and --file reaches the focused field", arguments: ["stdin", "file"])
    func sources(source: String) async throws {
        let app = try OrdinaryPlaygroundSession()
        try await app.focusTextField()
        let text = "Text from \(source) input"
        if source == "stdin" {
            let result = try await app.attempt(["type", "--stdin"], input: text + "\n")
            try #require(result.exitCode == 0, "type --stdin failed: \(result.output)")
        } else {
            let file = try app.artifact("type-input.txt")
            try text.write(to: file, atomically: true, encoding: .utf8)
            try await app.run(["type", "--file", file.path])
        }
        try await app.core.waitForValue("text-input-field", equals: text)
        try await app.core.waitForValue("character-count", equals: String(text.count))
    }

    @Test("Symbols, digits, mixed case, punctuation and long text are typed exactly", arguments: [
        "Test@123!$%&*", "HeLLo WoRLd 1234567890", "Hello, how are you? I'm fine!",
        "The quick brown fox jumps over the lazy dog. This is a longer piece of text to test typing accuracy.",
    ])
    func characters(text: String) async throws {
        let app = try OrdinaryPlaygroundSession()
        try await app.focusTextField()
        try await app.run(["type", text])
        try await app.core.waitForValue("text-input-field", equals: text)
        try await app.core.waitForValue("character-count", equals: String(text.count))
    }

    @Test("Empty text is a no-op and unsupported text is refused before input")
    func emptyAndUnsupported() async throws {
        let app = try OrdinaryPlaygroundSession()
        try await app.focusTextField()
        try await app.run(["type", "Initial text"])
        try await app.core.waitForValue("text-input-field", equals: "Initial text")
        let empty = try await app.attempt(["type", ""])
        try #require(empty.exitCode == 0, "type with empty text failed: \(empty.output)")
        let refused = try await app.attempt(["type", "Price: £50"])
        try #require(refused.exitCode != 0 && refused.output.contains("£"), "Unsupported text was not refused: \(refused.output)")
        try await TestHelpers.waitForSettledAccessibility(simulatorUDID: app.udid, description: "the text field after refusals")
        let state = try await app.core.state()
        try #require(app.core.value("text-input-field", in: state) == "Initial text"
            && app.core.value("character-count", in: state) == "12")
    }

    @Test("Typing into a navigation search field filters the list")
    func searchField() async throws {
        let app = try OrdinaryPlaygroundSession()
        let state = try await app.open("searchable-test", readyID: "searchable-test-query")
        try #require(app.core.value("searchable-test-query", in: state) == "empty")
        try #require(UIStateParser.findElement(in: state) { $0.type == "TextField" && $0.value == "Search Books" }?.frame != nil)
        try await app.run(["tap", "--value", "Search Books", "--element-type", "TextField"])
        try await TestHelpers.waitForSettledAccessibility(simulatorUDID: app.udid, description: "the focused search field")
        try await app.run(["type", "Alpha"])
        let filtered = try await app.core.waitFor("the Alpha query") { app.core.value("searchable-test-query", in: $0) == "Alpha" }
        try #require(UIStateParser.findElementByLabel(in: filtered, label: "Alpha Row") != nil
            && UIStateParser.findElementByLabel(in: filtered, label: "Beta Row") == nil)
    }

    @Test("A held key with --duration and Return reach the key-press screen")
    func keyPresses() async throws {
        let app = try OrdinaryPlaygroundSession()
        _ = try await app.open("key-press", readyID: "key-press-screen")
        let elapsed = try await app.timed(["key", "4", "--duration", "1"])
        try #require(elapsed >= 1, "The 1-second key hold took \(elapsed) seconds.")
        // The screen's identifier covers its text elements, so read the key from its label.
        try await app.waitForLabel("Last Key: a (4)")
        try await app.run(["key", "40"])
        try await app.waitForLabel("Last Key: Return (40)")
    }
}

/// Plain hardware buttons on an ordinary iPhone. Each case returns the same Playground process
/// to the front, so later cases start from the app.
@Suite("Playground Ordinary Button E2E", .serialized, .enabled(if: isOrdinaryPlaygroundE2EEnabled))
struct PlaygroundOrdinaryButtonTests {
    @Test("Home sends the Playground to the background")
    func home() async throws {
        let app = try OrdinaryPlaygroundSession()
        let pid = try await app.launchApp()
        try await app.run(["button", "home"])
        try await app.waitForPlaygroundInBackground()
        try await app.resume(pid)
    }

    @Test("Lock blanks and locks the screen, the side button wakes it and a swipe unlocks it")
    func lockAndWake() async throws {
        let app = try OrdinaryPlaygroundSession()
        let pid = try await app.launchApp()
        try await app.waitForSpringBoard("lockstate", 0)
        try await app.run(["button", "lock"])
        try await app.waitForSpringBoard("lockstate", 1)
        try await app.waitForSpringBoard("hasBlankedScreen", 1)
        try await app.run(["button", "side-button"])
        try await app.waitForSpringBoard("hasBlankedScreen", 0)
        try await app.waitForSpringBoard("lockstate", 1)
        let roots = try await app.systemRoots()
        let root = try #require(roots.first { $0.type == "Application" })
        let frame = try app.core.frame(of: root)
        let x = Int(frame.x + frame.width / 2)
        try await app.run(["swipe", "--start-x", String(x), "--start-y", String(Int(frame.y + frame.height - 2)),
            "--end-x", String(x), "--end-y", String(Int(frame.y + frame.height * 0.25)), "--duration", "0.5"])
        try await app.waitForSpringBoard("lockstate", 0)
        try await app.resume(pid)
    }

    @Test("A timed Siri press opens Siri; Home closes it")
    func siri() async throws {
        let app = try OrdinaryPlaygroundSession()
        let pid = try await app.launchApp()
        try await app.run(["button", "siri", "--duration", "0.2"])
        _ = try await app.waitForSystem("the Siri window") { roots in
            UIStateParser.findElement(in: roots, withIdentifier: "siri-interface-window") != nil
        }
        try await app.run(["button", "home"])
        _ = try await app.waitForSystem("Siri to close") { roots in
            UIStateParser.findElement(in: roots, withIdentifier: "siri-interface-window") == nil
        }
        try await app.resume(pid)
    }

    @Test("The Apple Pay button is delivered and the same app returns")
    func applePay() async throws {
        let app = try OrdinaryPlaygroundSession()
        let pid = try await app.launchApp()
        try await app.run(["button", "apple-pay"])
        let roots = try await app.systemRoots()
        if UIStateParser.findElement(in: roots, withIdentifier: "tap-test-screen") == nil {
            try await app.run(["button", "home"])
        }
        try await app.resume(pid)
    }
}

extension OrdinaryPlaygroundSession {
    func focusTextField() async throws {
        _ = try await open("text-input", readyID: "text-input-field")
        try await run(["tap", "--id", "text-input-field", "--element-type", "TextField"])
        _ = try await core.waitFor("the focused text field") {
            UIStateParser.findElement(in: $0, withIdentifier: "typing-active-indicator") != nil
        }
        // The keyboard rises after focus; type into a field that has stopped moving.
        try await TestHelpers.waitForSettledAccessibility(simulatorUDID: udid, description: "the focused text field")
    }

    /// Launches a fresh Playground on its Tap Test screen and returns its process identifier.
    func launchApp() async throws -> Int32 {
        let arguments = ["xcrun", "simctl", "launch", "--terminate-running-process", udid,
                         "com.cameroncooke.AxePlayground", "--launch-arg", "screen=tap-test"]
        let output = try await CommandRunner.run(arguments.map(shellQuote).joined(separator: " "), timeout: 30).output
        let pid = try #require(Self.launchedPID(output), "No process identifier in: \(output)")
        _ = try await core.waitFor("the Tap Test screen") { UIStateParser.findElement(in: $0, withIdentifier: "tap-test-screen") != nil }
        try await TestHelpers.waitForSettledAccessibility(simulatorUDID: udid, description: "screen tap-test")
        return pid
    }

    /// Brings the Playground back without restarting it.
    func resume(_ pid: Int32) async throws {
        let arguments = ["xcrun", "simctl", "launch", udid, "com.cameroncooke.AxePlayground"]
        let output = try await CommandRunner.run(arguments.map(shellQuote).joined(separator: " "), timeout: 30).output
        try #require(Self.launchedPID(output) == pid, "The Playground restarted instead of resuming: \(output)")
        _ = try await core.waitFor("the resumed Tap Test screen") {
            UIStateParser.findElement(in: $0, withIdentifier: "tap-test-screen") != nil
        }
    }

    func systemRoots() async throws -> [UIElement] {
        try UIStateParser.parseDescribeUIRoots(try await run(["describe-ui"]))
    }

    @discardableResult
    func waitForSystem(_ description: String, matches: ([UIElement]) -> Bool) async throws -> [UIElement] {
        let deadline = Date().addingTimeInterval(20)
        var last = "No system tree was read."
        repeat {
            do {
                let roots = try await systemRoots()
                if matches(roots) { return roots }
                last = roots.map { "\($0.type) \($0.label ?? "")" }.joined(separator: ", ")
            } catch {
                last = String(describing: error)
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        } while Date() < deadline
        throw TestError.unexpectedState("Timed out waiting for \(description). Last roots: \(last)")
    }

    func waitForPlaygroundInBackground() async throws {
        try await waitForSystem("the Playground to leave the foreground") { roots in
            !roots.contains { $0.type == "Application" && $0.label == "AxePlayground" }
        }
    }

    /// SpringBoard's own lock and screen-blank state, read through notifyutil in the simulator.
    /// `axe displays` cannot read a locked ordinary simulator's screen, so it is not used here.
    func waitForSpringBoard(_ name: String, _ expected: Int) async throws {
        let command = ["xcrun", "simctl", "spawn", udid, "notifyutil", "-g", "com.apple.springboard." + name]
        let deadline = Date().addingTimeInterval(15)
        var last = "No SpringBoard state was read."
        repeat {
            let output = try await CommandRunner.run(command.map(shellQuote).joined(separator: " "), timeout: 15).output
            last = output
            if output.split(whereSeparator: \.isWhitespace).last.flatMap({ Int($0) }) == expected { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        } while Date() < deadline
        throw TestError.unexpectedState("SpringBoard \(name) did not become \(expected). Last read: \(last)")
    }

    private static func launchedPID(_ output: String) -> Int32? {
        output.split(separator: "\n").last.flatMap { line in
            line.split(separator: ":").last.flatMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        }
    }
}
