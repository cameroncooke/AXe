import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import AXeCore

@Suite("TypeSafe Simulator Agent Policy")
struct AgentPolicyTests {
    @Test("Builds one operation head and operation-specific target heads")
    func buildsDynamicQuestions() throws {
        let prepared = try AgentPolicy().prepareRequest(
            goal: "Open Settings, tap General, then search for 'Keyboard'",
            screen: makeScreen(elements: [
                makeElement(key: "general", label: "General", tap: true),
                makeElement(key: "privacy", label: "Privacy", tap: true),
                makeElement(key: "search", label: "Search", tap: true, text: true),
                makeElement(key: "name", label: "Name", tap: true, text: true),
            ]),
            applications: [
                AgentApplication(name: "Settings", bundleIdentifier: "com.apple.Preferences"),
                AgentApplication(name: "Safari", bundleIdentifier: "com.apple.mobilesafari"),
            ],
            history: []
        )

        #expect(prepared.payload.questions[AgentPolicy.operationQuestion] != nil)
        #expect(prepared.payload.questions[AgentPolicy.tapTargetQuestion] != nil)
        #expect(prepared.payload.questions[AgentPolicy.typeTextTargetQuestion] != nil)
        #expect(prepared.payload.questions[AgentPolicy.openAppTargetQuestion] == nil)
        #expect(prepared.soleApplication?.bundleIdentifier == "com.apple.Preferences")
        #expect(prepared.textCandidatesByChoice.values.contains("Keyboard"))
    }

    @Test("Only validates the target head selected by the operation head")
    func validatesOnlySelectedTargetHead() throws {
        let prepared = try AgentPolicy().prepareRequest(
            goal: "Tap Continue",
            screen: makeScreen(elements: [
                makeElement(key: "continue", label: "Continue", tap: true),
                makeElement(key: "cancel", label: "Cancel", tap: true),
                makeElement(key: "email", label: "Email", tap: true, text: true),
                makeElement(key: "password", label: "Password", tap: true, text: true),
            ]),
            applications: [],
            history: []
        )

        let operationChoices = Set(prepared.availableOperations.map(\.rawValue))
        let tapChoices = try #require(prepared.elementChoicesByOperation[.tap])
        let continueChoice = try #require(
            tapChoices.first(where: { $0.value.label == "Continue" })?.key
        )
        let response = TypeSafeSystemOneResponse(
            model: "jev-latest",
            answers: [
                AgentPolicy.operationQuestion: answer(
                    choosing: AgentOperation.tap.rawValue,
                    from: operationChoices
                ),
                AgentPolicy.tapTargetQuestion: answer(
                    choosing: continueChoice,
                    from: Set(tapChoices.keys)
                ),
                // The speculative TYPE_TEXT head is intentionally omitted. It cannot cause a tap.
            ],
            usage: nil
        )

        let decision = try AgentPolicy().resolveDecision(
            response: response,
            prepared: prepared
        )

        #expect(decision.operation == .tap)
        #expect(decision.element?.label == "Continue")
    }

    @Test("Rejects probability maps that do not exactly match offered choices")
    func rejectsInvalidProbabilityMap() throws {
        let prepared = try AgentPolicy().prepareRequest(
            goal: "Wait for the screen",
            screen: makeScreen(elements: []),
            applications: [],
            history: []
        )
        let response = TypeSafeSystemOneResponse(
            model: "jev-latest",
            answers: [
                AgentPolicy.operationQuestion: TypeSafeChoiceAnswer(
                    type: "choice",
                    choice: AgentOperation.wait.rawValue,
                    confidence: 0.9,
                    probabilities: [AgentOperation.wait.rawValue: 1]
                )
            ],
            usage: nil
        )

        #expect(throws: AgentPolicyError.self) {
            try AgentPolicy().resolveDecision(response: response, prepared: prepared)
        }
    }

    @Test("Uses a sole target without requiring a target answer")
    func soleTargetIsDeterministic() throws {
        let prepared = try AgentPolicy().prepareRequest(
            goal: "Tap Continue",
            screen: makeScreen(elements: [
                makeElement(key: "continue", label: "Continue", tap: true),
            ]),
            applications: [],
            history: []
        )
        let operationChoices = Set(prepared.availableOperations.map(\.rawValue))
        let response = TypeSafeSystemOneResponse(
            model: "jev-latest",
            answers: [
                AgentPolicy.operationQuestion: answer(
                    choosing: AgentOperation.tap.rawValue,
                    from: operationChoices
                )
            ],
            usage: nil
        )

        let decision = try AgentPolicy().resolveDecision(response: response, prepared: prepared)
        #expect(decision.element?.label == "Continue")
    }

    @Test("Extracts explicit text without inventing values")
    func extractsTextCandidates() {
        let candidates = AgentTextCandidateExtractor.candidates(
            from: "Open Notes, write ‘Buy milk’, then search for weather@example.com"
        )

        #expect(candidates.contains("Buy milk"))
        #expect(candidates.contains("weather@example.com"))
        #expect(!AgentTextCandidateExtractor.candidates(from: "Enter my email address").contains("my email address"))
        #expect(AgentTextCandidateExtractor.candidates(from: "Search for cats then tap Images").contains("cats"))
        #expect(!AgentTextCandidateExtractor.candidates(from: "Search for cats then tap Images").contains("cats then tap Images"))
    }

    @Test("Ranks the app explicitly named in the goal first")
    func filtersApplications() {
        let applications = [
            AgentApplication(name: "Safari", bundleIdentifier: "com.apple.mobilesafari"),
            AgentApplication(name: "Settings", bundleIdentifier: "com.apple.Preferences"),
            AgentApplication(name: "Notes", bundleIdentifier: "com.apple.mobilenotes"),
        ]

        let filtered = AgentApplicationFilter.relevantApplications(
            from: applications,
            goal: "Open Settings and tap General",
            currentBundleIdentifier: nil
        )

        #expect(filtered.first?.name == "Settings")
    }

    @Test("Does not offer the already-frontmost application for relaunch")
    func excludesCurrentApplication() {
        let filtered = AgentApplicationFilter.relevantApplications(
            from: [
                AgentApplication(name: "Settings", bundleIdentifier: "com.apple.Preferences"),
            ],
            goal: "Open Settings and tap General",
            currentBundleIdentifier: "com.apple.Preferences"
        )

        #expect(filtered.isEmpty)
    }

    @Test("Screen fingerprint ignores accessibility traversal order")
    func fingerprintIgnoresOrder() {
        let lines = ["Utilities folder", "Passwords", "Shortcuts", "Contacts"]
        let elements = [
            makeElement(key: "safari", label: "Safari", tap: true),
            makeElement(key: "messages", label: "Messages", tap: true),
        ]
        let original = AgentScreenFingerprint.make(screenTextLines: lines, elements: elements)

        #expect(original == AgentScreenFingerprint.make(
            screenTextLines: ["Utilities folder", "Shortcuts", "Passwords", "Contacts"],
            elements: elements.reversed()
        ))
        #expect(original != AgentScreenFingerprint.make(
            screenTextLines: lines + ["Calendar"],
            elements: elements
        ))
        #expect(original != AgentScreenFingerprint.make(
            screenTextLines: lines,
            elements: [elements[0]]
        ))
    }

    @Test("Usage summary totals tokens and prices input only")
    func summarizesUsage() {
        var summary = TypeSafeUsageSummary(inputUSDPerMillionTokens: 0.042)
        summary.record(TypeSafeSystemOneResponse(
            model: "jev-1.13.0",
            answers: [:],
            usage: TypeSafeUsage(inputTokens: 600_000, outputTokens: 500)
        ))
        summary.record(TypeSafeSystemOneResponse(
            model: "jev-1.13.0",
            answers: [:],
            usage: TypeSafeUsage(inputTokens: 400_000, outputTokens: 300)
        ))
        summary.record(TypeSafeSystemOneResponse(model: "jev-1.13.0", answers: [:], usage: nil))

        #expect(summary.calls == 3)
        #expect(summary.callsWithoutUsage == 1)
        #expect(summary.inputTokens == 1_000_000)
        #expect(summary.outputTokens == 800)
        #expect(abs(summary.estimatedCostUSD - 0.042) < 1e-12)
    }

    @Test("Posts the documented SystemOne request shape")
    func postsSystemOneRequest() async throws {
        final class CapturedRequest: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: URLRequest?

            func store(_ request: URLRequest) {
                lock.lock()
                stored = request
                lock.unlock()
            }

            func read() -> URLRequest? {
                lock.lock()
                defer { lock.unlock() }
                return stored
            }
        }

        let captured = CapturedRequest()
        let client = try TypeSafeClient(
            apiKey: "secret",
            baseURL: try #require(URL(string: "https://typesafe.test")),
            maximumRetries: 0,
            transport: { request in
                captured.store(request)
                let requestURL = try #require(request.url)
                let response = try #require(
                    HTTPURLResponse(
                        url: requestURL,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )
                )
                let data = Data(
                    """
                    {"model":"jev-latest","answers":{"operation":{"type":"choice","choice":"DONE","confidence":1,"probabilities":{"DONE":1}}},"usage":{"input_tokens":1,"output_tokens":1}}
                    """.utf8
                )
                return (data, response)
            }
        )
        let payload = TypeSafeSystemOneRequest(
            model: "jev-latest",
            state: .object(["screen": .string("ready")]),
            questions: [
                "operation": TypeSafeChoiceQuestion(criteria: ["DONE": .string("complete")])
            ]
        )

        _ = try await client.systemOne(payload)
        let request = try #require(captured.read())
        #expect(request.url?.absoluteString == "https://typesafe.test/v1/systemone")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(request.httpMethod == "POST")
        let decoded = try JSONDecoder().decode(TypeSafeSystemOneRequest.self, from: try #require(request.httpBody))
        #expect(decoded == payload)
    }

    @Test("Text helper accepts exactly one text key and rejects extra instructions")
    func validatesTextHelperOutput() async throws {
        func makeClient(content: String) throws -> AgentTextModelClient {
            try AgentTextModelClient(
                apiKey: "secret",
                baseURL: try #require(URL(string: "https://text.test/v1")),
                model: "small-model",
                transport: { request in
                    let requestURL = try #require(request.url)
                    let response = try #require(
                        HTTPURLResponse(
                            url: requestURL,
                            statusCode: 200,
                            httpVersion: nil,
                            headerFields: nil
                        )
                    )
                    let data = try JSONSerialization.data(
                        withJSONObject: [
                            "choices": [
                                ["message": ["content": content]]
                            ]
                        ]
                    )
                    return (data, response)
                }
            )
        }

        let context = AgentTextFieldContext(
            goal: "Enter 'hello'",
            fieldLabel: "Message",
            fieldType: "TextField",
            currentValue: nil,
            screenText: "Message",
            recentActions: []
        )
        let valid = try await makeClient(content: #"{"text":"hello"}"#).text(for: context)
        #expect(valid == "hello")

        do {
            _ = try await makeClient(content: #"{"text":"hello","action":"tap"}"#).text(for: context)
            Issue.record("Expected an extra text-helper key to be rejected.")
        } catch is AgentTextModelError {
            // Expected: the executor accepts field text, not arbitrary instructions.
        }
    }

    private func makeScreen(elements: [AgentObservedElement]) -> AgentScreenSnapshot {
        AgentScreenSnapshot(
            fingerprint: "screen-1",
            applicationName: "Example",
            bundleIdentifier: "com.example.app",
            text: elements.compactMap(\.label).joined(separator: "\n"),
            applicationFrame: AgentFrame(x: 0, y: 0, width: 390, height: 844),
            elements: elements
        )
    }

    private func makeElement(
        key: String,
        label: String,
        tap: Bool,
        text: Bool = false
    ) -> AgentObservedElement {
        AgentObservedElement(
            stableKey: key,
            type: text ? "TextField" : "Button",
            role: nil,
            roleDescription: nil,
            label: label,
            identifier: key,
            value: nil,
            frame: AgentFrame(x: 10, y: 20, width: 100, height: 44),
            isSwitchLike: false,
            supportsTap: tap,
            supportsTextEntry: text
        )
    }

    private func answer(
        choosing choice: String,
        from choices: Set<String>
    ) -> TypeSafeChoiceAnswer {
        let alternatives = choices.subtracting([choice])
        var probabilities = Dictionary(uniqueKeysWithValues: alternatives.map { ($0, 0.0) })
        probabilities[choice] = 1
        return TypeSafeChoiceAnswer(
            type: "choice",
            choice: choice,
            confidence: 1,
            probabilities: probabilities
        )
    }
}
