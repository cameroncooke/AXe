import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct TypeSafeChoiceQuestion: Codable, Equatable, Sendable {
    public let type: String
    public let instructions: AgentJSONValue?
    public let criteria: [String: AgentJSONValue]

    public init(
        instructions: AgentJSONValue? = nil,
        criteria: [String: AgentJSONValue]
    ) {
        self.type = "choice"
        self.instructions = instructions
        self.criteria = criteria
    }
}

public struct TypeSafeSystemOneRequest: Codable, Equatable, Sendable {
    public let model: String
    public let state: AgentJSONValue
    public let questions: [String: TypeSafeChoiceQuestion]

    public init(
        model: String,
        state: AgentJSONValue,
        questions: [String: TypeSafeChoiceQuestion]
    ) {
        self.model = model
        self.state = state
        self.questions = questions
    }
}

public struct TypeSafeChoiceAnswer: Codable, Equatable, Sendable {
    public let type: String
    public let choice: String
    public let confidence: Double
    public let probabilities: [String: Double]
}

public struct TypeSafeUsage: Codable, Equatable, Sendable {
    public let inputTokens: Int
    public let outputTokens: Int

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

public struct TypeSafeSystemOneResponse: Codable, Equatable, Sendable {
    public let model: String
    public let answers: [String: TypeSafeChoiceAnswer]
    public let usage: TypeSafeUsage?
}

public enum TypeSafePricing {
    /// Jev input price in USD per million tokens. Output tokens are free.
    /// Source: https://docs.typesafe.ai/models (jev-1.13.0, checked 2026-09-17).
    public static let defaultInputUSDPerMillionTokens = 0.042
}

/// Running token totals for a sequence of SystemOne responses, with an estimated cost.
public struct TypeSafeUsageSummary: Codable, Equatable, Sendable {
    public let inputUSDPerMillionTokens: Double
    public private(set) var calls = 0
    public private(set) var callsWithoutUsage = 0
    public private(set) var inputTokens = 0
    public private(set) var outputTokens = 0
    public private(set) var estimatedCostUSD = 0.0

    public init(inputUSDPerMillionTokens: Double = TypeSafePricing.defaultInputUSDPerMillionTokens) {
        self.inputUSDPerMillionTokens = inputUSDPerMillionTokens
    }

    public mutating func record(_ response: TypeSafeSystemOneResponse) {
        calls += 1
        guard let usage = response.usage else {
            callsWithoutUsage += 1
            return
        }
        inputTokens += usage.inputTokens
        outputTokens += usage.outputTokens
        estimatedCostUSD = Double(inputTokens) * inputUSDPerMillionTokens / 1_000_000
    }
}

public enum TypeSafeClientError: LocalizedError, Sendable {
    case invalidAPIKey
    case invalidBaseURL(String)
    case invalidHTTPResponse
    case requestFailed(statusCode: Int, message: String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            return "No TypeSafe API key was provided. Set TYPESAFE_API_KEY or pass one to the client."
        case .invalidBaseURL(let value):
            return "The TypeSafe base URL is invalid: \(value)"
        case .invalidHTTPResponse:
            return "TypeSafe returned an invalid HTTP response."
        case .requestFailed(let statusCode, let message):
            return "TypeSafe returned HTTP \(statusCode): \(message)"
        case .invalidResponse(let message):
            return "TypeSafe returned an invalid response: \(message)"
        }
    }
}

public struct TypeSafeClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public static let defaultBaseURL = URL(string: "https://api.typesafe.ai")!
    public static let defaultModel = "jev-latest"

    private let apiKey: String
    private let baseURL: URL
    private let timeout: TimeInterval
    private let maximumRetries: Int
    private let transport: Transport

    public init(
        apiKey: String,
        baseURL: URL = TypeSafeClient.defaultBaseURL,
        timeout: TimeInterval = 25,
        maximumRetries: Int = 2,
        transport: Transport? = nil
    ) throws {
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAPIKey.isEmpty else {
            throw TypeSafeClientError.invalidAPIKey
        }
        guard timeout > 0 else {
            throw TypeSafeClientError.invalidResponse("timeout must be greater than zero")
        }
        guard maximumRetries >= 0 else {
            throw TypeSafeClientError.invalidResponse("maximumRetries must not be negative")
        }

        self.apiKey = trimmedAPIKey
        self.baseURL = baseURL
        self.timeout = timeout
        self.maximumRetries = maximumRetries
        self.transport = transport ?? { request in
            try await Self.liveTransport(request)
        }
    }

    /// Opens the HTTPS connection before the first decision, so DNS and TLS setup are not paid inside
    /// the agent loop. Failures are ignored; the first real request reconnects.
    public func warmUp() async {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        _ = try? await transport(request)
    }

    public func systemOne(_ payload: TypeSafeSystemOneRequest) async throws -> TypeSafeSystemOneResponse {
        let endpoint = baseURL
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("systemone", isDirectory: false)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("axe-typesafe-agent/1", forHTTPHeaderField: "User-Agent")
        request.httpBody = try Self.makeEncoder().encode(payload)

        var latestError: Error?
        for attempt in 0...maximumRetries {
            do {
                let (data, response) = try await transport(request)
                if response.statusCode >= 200 && response.statusCode < 300 {
                    do {
                        return try Self.makeDecoder().decode(TypeSafeSystemOneResponse.self, from: data)
                    } catch {
                        throw TypeSafeClientError.invalidResponse(error.localizedDescription)
                    }
                }

                let error = TypeSafeClientError.requestFailed(
                    statusCode: response.statusCode,
                    message: Self.errorMessage(from: data)
                )
                guard attempt < maximumRetries, Self.isRetryable(statusCode: response.statusCode) else {
                    throw error
                }
                latestError = error
                try await Self.sleepBeforeRetry(attempt: attempt, response: response)
            } catch let error as TypeSafeClientError {
                throw error
            } catch {
                guard attempt < maximumRetries, Self.isRetryable(error: error) else {
                    throw error
                }
                latestError = error
                try await Self.sleepBeforeRetry(attempt: attempt, response: nil)
            }
        }

        throw latestError ?? TypeSafeClientError.invalidHTTPResponse
    }

    private static func liveTransport(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TypeSafeClientError.invalidHTTPResponse
        }
        return (data, httpResponse)
    }

    private static func isRetryable(statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
    }

    private static func isRetryable(error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    private static func sleepBeforeRetry(
        attempt: Int,
        response: HTTPURLResponse?
    ) async throws {
        let retryAfter: TimeInterval?
        if let rawValue = response?.value(forHTTPHeaderField: "Retry-After"),
           let seconds = TimeInterval(rawValue) {
            retryAfter = min(seconds, 10)
        } else {
            retryAfter = nil
        }

        let exponential = min(0.5 * pow(2, Double(attempt)), 5)
        let seconds = max(retryAfter ?? 0, exponential)
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func errorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["message", "error", "detail"] {
                if let value = object[key] as? String, !value.isEmpty {
                    return value
                }
                if let dictionary = object[key] as? [String: Any],
                   let value = dictionary["message"] as? String,
                   !value.isEmpty {
                    return value
                }
            }
        }

        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return "No response body"
        }
        return String(text.prefix(500))
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }
}
