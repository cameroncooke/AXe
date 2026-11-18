import Foundation
import Network
import Testing

/// Agent mode on web pages: a sign-in in the Playground's own WKWebView (not inspectable) and a
/// sign-in on a local site in Safari. Each case reads web controls with `describe-ui --agent --web`,
/// types with `type --focus` and taps with `tap`, all by `w` ref, and checks the outcome outside
/// AXe's own replies: the app's native status line for the web view, and the requests the local
/// site received for Safari.
@Suite("Playground Agent Web E2E", .serialized,
       .enabled(if: isE2EEnabled && !isDuoPlaygroundE2EEnabled))
struct PlaygroundAgentWebTests {
    private static let email = "grace@example.com"
    private static let password = "cobol1959"

    @Test("Sign in through the Playground's WKWebView with web refs")
    func webViewSignIn() async throws {
        let check = try PlaygroundWebCheck(name: "web-view-sign-in")
        let app = check.app
        let pid = try await app.open("web-sign-in", readyID: "web-sign-in.status")
        try await app.waitForValue("web-sign-in.status", equals: "Ready")

        let first = try await check.capture("initial", pid: pid)
        try #require(first.capture.webContent?.controls == 5 && first.capture.webContent?.failure == nil,
            "The sign-in page should list exactly its five controls.")
        let email = try first.row(label: "Email", role: "text-field", action: "typeText")
        _ = try first.row(label: "Password", role: "text-field", action: "typeText")
        _ = try first.row(label: "Remember me", role: "switch", action: "tap")
        _ = try first.row(label: "Sign in", role: "button", action: "tap")
        _ = try first.row(label: "Forgot password?", role: "link", action: "tap")

        // Web fields report no focus, so typing without --focus is refused before any input.
        let refused = try await check.run("type-without-focus", ["type", "x", "--agent", "--expected-pid", String(pid),
            "--snapshot-id", first.capture.snapshotID.uuidString, "--ref", email.ref], allowFailure: true)
        try #require(refused.exitCode != 0 && refused.envelope.didError
            && refused.envelope.error?.code == "unsupportedReference" && refused.envelope.data.action == nil)
        try await app.waitForValue("web-sign-in.status", equals: "Ready")

        var current = try await check.capture("fresh", pid: pid)
        // Two stray characters, then two Backspaces on the web field ref: keys tap the field first,
        // so the caret is at the end of its text.
        current = try await check.type(Self.email + "zz", into: "Email", from: current, pid: pid)
        let typedEmail = try current.row(label: "Email", role: "text-field", action: "typeText")
        try #require(typedEmail.value == Self.email + "zz")
        let keys = try await check.run("backspaces", ["key-sequence", "--keycodes", "42,42", "--agent",
            "--expected-pid", String(pid), "--snapshot-id", current.capture.snapshotID.uuidString, "--ref", typedEmail.ref])
        let keyAction = try #require(keys.envelope.data.action)
        try #require(keyAction.kind == "keySequence" && keyAction.outcome == "enqueuedAndDrained"
            // The focus tap's down and up count too: 2 + 4 key events.
            && keyAction.enqueuedEventCount == 6 && !keyAction.replayed)
        current = try PlaygroundWebScreen(keys.envelope)
        try #require(try current.row(label: "Email", role: "text-field", action: "typeText").value == Self.email)
        current = try await check.type(Self.password, into: "Password", from: current, pid: pid)
        let password = try current.row(label: "Password", role: "text-field", action: "typeText").value
        try #require(!password.isEmpty && password != Self.password, "The password field must not show the password.")
        current = try await check.tap("Remember me", role: "switch", from: current, pid: pid)
        try #require(try current.row(label: "Remember me", role: "switch", action: "tap").value == "1")
        current = try await check.tap("Sign in", role: "button", from: current, pid: pid)

        // The page itself reports what it received to the native status line.
        try await app.waitForValue("web-sign-in.status",
            equals: "Signed in: \(Self.email), password \(Self.password.count) characters, remember on")
        current = try await check.awaitRow("Sign out", role: "button", after: current, pid: pid)
        try #require(current.webRows.allSatisfy { $0.label != "Email" }, "The sign-in form should be gone.")
        _ = try await check.tap("Sign out", role: "button", from: current, pid: pid)
        try await app.waitForValue("web-sign-in.status", equals: "Signed out")
    }

    @Test("Sign in on a local site in Safari with web refs")
    func safariSignIn() async throws {
        let check = try PlaygroundWebCheck(name: "safari-sign-in")
        let site = try await PlaygroundSignInSite.start()
        defer { site.stop() }
        _ = try await check.simctl(["terminate", check.app.udid, "com.apple.mobilesafari"], allowFailure: true)
        _ = try await check.simctl(["openurl", check.app.udid, site.url("/signin")])
        var current = try await check.awaitRow("Sign in", role: "button", after: nil, pid: nil, timeout: 30)
        try #require(site.requests.contains { $0.path == "/signin" }, "Safari did not load the local sign-in page.")
        _ = try current.row(label: "Email", role: "text-field", action: "typeText")
        _ = try current.row(label: "Create account", role: "link", action: "tap")

        current = try await check.type(Self.email, into: "Email", from: current, pid: nil)
        current = try await check.type(Self.password, into: "Password", from: current, pid: nil)
        current = try await check.tap("Sign in", role: "button", from: current, pid: nil)

        // The site, not AXe, says what the form sent.
        let session = try await site.waitFor("/session")
        try #require(session.query == ["email": Self.email, "password": Self.password],
            "The site received \(session.query) instead of the typed email and password.")
        current = try await check.awaitRow("Sign out", role: "link", after: current, pid: nil, dismissSavePassword: true)
        _ = try await check.tap("Sign out", role: "link", from: current, pid: nil)
        _ = try await site.waitFor("/signout")
        _ = try await check.simctl(["terminate", check.app.udid, "com.apple.mobilesafari"], allowFailure: true)
    }
}

/// One case's commands, each saved with its output to the case's artifact directory.
struct PlaygroundWebCheck {
    let app: AgentPlaygroundSession
    let artifacts: URL

    init(name: String) throws {
        app = try AgentPlaygroundSession()
        let directory = ProcessInfo.processInfo.environment["AXE_E2E_ARTIFACT_DIR"] ?? NSTemporaryDirectory()
        artifacts = URL(fileURLWithPath: directory).appendingPathComponent(name + "-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
    }

    struct Reply {
        let exitCode: Int32
        let envelope: PlaygroundWebEnvelope
    }

    func run(_ name: String, _ arguments: [String], allowFailure: Bool = false) async throws -> Reply {
        let result = try await app.run(arguments, allowFailure: true)
        try Data(result.output.utf8).write(to: artifacts.appendingPathComponent(name + ".txt"))
        let envelope = try PlaygroundWebEnvelope.decode(result.output)
        if !allowFailure {
            try #require(result.exitCode == 0 && !envelope.didError, "\(name) failed: \(result.output)")
        }
        return Reply(exitCode: result.exitCode, envelope: envelope)
    }

    func simctl(_ arguments: [String], allowFailure: Bool = false) async throws -> CommandOutput {
        let command = (["xcrun", "simctl"] + arguments).map(shellQuote).joined(separator: " ")
        let result = try await CommandRunner.run(command, allowFailure: allowFailure, timeout: 30)
        return CommandOutput(output: result.output, exitCode: result.exitCode)
    }

    private func pidArguments(_ pid: Int32?) -> [String] { pid.map { ["--expected-pid", String($0)] } ?? [] }

    func capture(_ name: String, pid: Int32?) async throws -> PlaygroundWebScreen {
        let reply = try await run("capture-" + name, ["describe-ui", "--agent", "--web"] + pidArguments(pid))
        return try PlaygroundWebScreen(reply.envelope)
    }

    /// `type --focus` into the named web field from the current screen: a focus tap, then keys.
    func type(_ text: String, into label: String, from screen: PlaygroundWebScreen, pid: Int32?) async throws -> PlaygroundWebScreen {
        let field = try screen.row(label: label, role: "text-field", action: "typeText")
        let reply = try await run("type-" + label, ["type", text, "--agent", "--focus"] + pidArguments(pid)
            + ["--snapshot-id", screen.capture.snapshotID.uuidString, "--ref", field.ref])
        let action = try #require(reply.envelope.data.action)
        try #require(action.kind == "focusAndType" && action.outcome == "enqueuedAndDrained"
            && action.enqueuedEventCount > 0 && action.cleanup != "uncertain" && !action.replayed)
        try #require(!reply.envelope.nextSteps.contains { $0.contains("does not show the text") },
            "AXe read the field back without the typed text.")
        return try PlaygroundWebScreen(reply.envelope)
    }

    func tap(_ label: String, role: String, from screen: PlaygroundWebScreen, pid: Int32?) async throws -> PlaygroundWebScreen {
        let control = try screen.row(label: label, role: role, action: "tap")
        let reply = try await run("tap-" + label, ["tap", "--agent"] + pidArguments(pid)
            + ["--snapshot-id", screen.capture.snapshotID.uuidString, "--ref", control.ref])
        let action = try #require(reply.envelope.data.action)
        try #require(action.kind == "tap" && action.outcome == "enqueuedAndDrained"
            && action.enqueuedEventCount == 2 && !action.replayed)
        return try PlaygroundWebScreen(reply.envelope)
    }

    /// The first screen, from `screen` or new web captures, that lists the control. Safari can put
    /// its own "Save Password?" sheet over the page after a sign-in; with `dismissSavePassword` the
    /// sheet's Not Now button is tapped by its app ref, as an agent would.
    func awaitRow(_ label: String, role: String, after screen: PlaygroundWebScreen?, pid: Int32?,
                  timeout: TimeInterval = 15, dismissSavePassword: Bool = false) async throws -> PlaygroundWebScreen {
        if let screen, screen.hasRow(label: label, role: role) { return screen }
        let deadline = Date().addingTimeInterval(timeout)
        var attempt = 0
        var last = "no capture"
        while Date() < deadline {
            attempt += 1
            // While an app launches, a read can find another app coming to the front; AXe refuses
            // it with observationFailed, and an agent captures again.
            let reply = try await run("capture-await-\(label)-\(attempt)", ["describe-ui", "--agent", "--web"]
                + pidArguments(pid), allowFailure: true)
            if reply.envelope.error?.code == "observationFailed" {
                last = "observationFailed"
                try await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            try #require(reply.exitCode == 0 && !reply.envelope.didError, "A capture failed while waiting for \(label).")
            let current = try PlaygroundWebScreen(reply.envelope)
            if current.hasRow(label: label, role: role) { return current }
            last = current.capture.targets.joined(separator: "\n")
            if dismissSavePassword, let notNow = current.appRow(label: "Not Now") {
                _ = try await run("save-password-not-now-\(attempt)", ["tap", "--agent"] + pidArguments(pid)
                    + ["--snapshot-id", current.capture.snapshotID.uuidString, "--ref", notNow])
                continue
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw TestError.unexpectedState("No \(role) row \(label) appeared.\n\(last)")
    }
}

struct PlaygroundWebEnvelope: Decodable {
    struct Failure: Decodable { let code: String; let message: String }
    struct WebContent: Decodable { let controls: Int; let failure: String? }
    struct Capture: Decodable {
        let snapshotID: UUID
        let applicationPID: Int32
        let targets: [String]
        let webContent: WebContent?
    }
    struct Payload: Decodable {
        let capture: Capture?
        let action: AgentPlaygroundResult.Action?
    }
    let schema: String
    let didError: Bool
    let error: Failure?
    let data: Payload
    let nextSteps: [String]

    static func decode(_ output: String) throws -> Self {
        for line in output.split(separator: "\n") where line.first == "{" {
            if let value = try? JSONDecoder().decode(Self.self, from: Data(line.utf8)), value.schema == "axe.output.agent-result" {
                return value
            }
        }
        throw TestError.invalidJSON("No axe.output.agent-result envelope.\n\(output)")
    }
}

/// A capture's rows: `ref|action|role|label|value|id`, web rows first named `w`.
struct PlaygroundWebScreen {
    struct Row { let ref: String; let action: String; let role: String; let label: String; let value: String }
    let capture: PlaygroundWebEnvelope.Capture
    let webRows: [Row]

    init(_ envelope: PlaygroundWebEnvelope) throws {
        capture = try #require(envelope.data.capture, "The reply has no capture.")
        try #require(capture.webContent != nil, "The capture did not read web content.")
        webRows = capture.targets.compactMap { line in
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 6, fields[0].first == "w", Int(fields[0].dropFirst()) != nil else { return nil }
            return Row(ref: fields[0], action: fields[1], role: fields[2], label: fields[3], value: fields[4])
        }
    }

    func hasRow(label: String, role: String) -> Bool { webRows.contains { $0.label == label && $0.role == role } }

    func row(label: String, role: String, action: String) throws -> Row {
        let matches = webRows.filter { $0.label == label && $0.role == role }
        try #require(matches.count == 1, "Expected one \(role) row \(label).\n\(capture.targets.joined(separator: "\n"))")
        let row = try #require(matches.first)
        try #require(row.action == action, "\(label) offers \(row.action), not \(action).")
        return row
    }

    /// An app control's ref by its exact label.
    func appRow(label: String) -> String? {
        capture.targets.first { line in
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            return fields.count == 6 && fields[0].first == "e" && fields[1] == "tap" && fields[3] == label
        }.map { String($0.prefix { $0 != "|" }) }
    }
}

/// A local sign-in site on the loopback interface, which the simulator shares with the Mac. It
/// records every page request, so a test can check what Safari submitted.
final class PlaygroundSignInSite: @unchecked Sendable {
    struct Request: Equatable { let path: String; let query: [String: String] }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "axe.e2e.sign-in-site")
    private let lock = NSLock()
    private var received: [Request] = []
    private(set) var port: UInt16 = 0

    private init(listener: NWListener) { self.listener = listener }

    static func start() async throws -> PlaygroundSignInSite {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let site = PlaygroundSignInSite(listener: try NWListener(using: parameters))
        site.listener.newConnectionHandler = { [site] connection in site.serve(connection) }
        let ready = PlaygroundOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            site.listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if ready.claim() { continuation.resume() }
                case .failed(let error): if ready.claim() { continuation.resume(throwing: error) }
                default: break
                }
            }
            site.listener.start(queue: site.queue)
        }
        site.port = try #require(site.listener.port?.rawValue)
        return site
    }

    func stop() { listener.cancel() }

    func url(_ path: String) -> String { "http://127.0.0.1:\(port)\(path)" }

    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return received }

    func waitFor(_ path: String, timeout: TimeInterval = 15) async throws -> Request {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let match = requests.last(where: { $0.path == path }) { return match }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw TestError.unexpectedState("The site received no \(path) request. It received: \(requests)")
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, complete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                respond(connection, head: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if error == nil, !complete, buffer.count < 65_536 {
                receive(connection, buffer: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    private func respond(_ connection: NWConnection, head: String) {
        let target = head.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let components = URLComponents(string: "http://site" + target.replacingOccurrences(of: "+", with: "%20"))
        let path = components?.path ?? "/"
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let page = Self.page(path, query: query)
        if page != nil {
            lock.lock(); received.append(Request(path: path, query: query)); lock.unlock()
        }
        let body = Data((page ?? "Not found").utf8)
        let status = page == nil ? "404 Not Found" : "200 OK"
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func page(_ path: String, query: [String: String]) -> String? {
        let head = "<!doctype html><html><head><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
            + "<style>body{font:17px -apple-system;margin:20px} input{display:block;width:100%;box-sizing:border-box;"
            + "font-size:17px;padding:8px;margin:4px 0 12px} button{font-size:17px;padding:8px 16px}</style>"
        switch path {
        case "/signin":
            return head + "<title>Sign in</title></head><body><h1>Sign in</h1>"
                + "<form action=\"/session\" method=\"get\">"
                + "<label for=\"email\">Email</label><input id=\"email\" name=\"email\" type=\"email\" aria-label=\"Email\" autocomplete=\"username\">"
                + "<label for=\"password\">Password</label><input id=\"password\" name=\"password\" type=\"password\" aria-label=\"Password\" autocomplete=\"current-password\">"
                + "<button type=\"submit\">Sign in</button></form>"
                + "<p><a href=\"/register\">Create account</a></p></body></html>"
        case "/session":
            let email = (query["email"] ?? "").replacingOccurrences(of: "<", with: "&lt;")
            return head + "<title>Welcome</title></head><body><h1>Welcome, \(email)</h1>"
                + "<p>You are signed in.</p><p><a href=\"/signout\">Sign out</a></p></body></html>"
        case "/signout":
            return head + "<title>Signed out</title></head><body><h1>Signed out</h1>"
                + "<p><a href=\"/signin\">Sign in again</a></p></body></html>"
        case "/register":
            return head + "<title>Register</title></head><body><h1>Create account</h1></body></html>"
        default:
            return nil
        }
    }
}

/// Resumes a continuation once from a callback that can fire more than once.
private final class PlaygroundOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
