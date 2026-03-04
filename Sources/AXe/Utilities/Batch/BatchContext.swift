import ArgumentParser
import Foundation

enum AXCachePolicy: String, CaseIterable, ExpressibleByArgument {
    case perBatch
    case perStep
    case none
}

enum TypeSubmissionMode: String, CaseIterable, ExpressibleByArgument {
    case chunked
    case composite
}

@MainActor
final class BatchContext {
    let simulatorUDID: String
    let axCachePolicy: AXCachePolicy
    let typeSubmissionMode: TypeSubmissionMode
    let typeChunkSize: Int
    let waitTimeout: TimeInterval
    let pollInterval: TimeInterval

    private var cachedRoots: [AccessibilityElement]?

    init(
        simulatorUDID: String,
        axCachePolicy: AXCachePolicy,
        typeSubmissionMode: TypeSubmissionMode,
        typeChunkSize: Int,
        waitTimeout: TimeInterval = 0,
        pollInterval: TimeInterval = 0.25
    ) {
        self.simulatorUDID = simulatorUDID
        self.axCachePolicy = axCachePolicy
        self.typeSubmissionMode = typeSubmissionMode
        self.typeChunkSize = typeChunkSize
        self.waitTimeout = waitTimeout
        self.pollInterval = pollInterval
    }

    func accessibilityRoots(logger: AxeLogger, forceRefresh: Bool = false) async throws -> [AccessibilityElement] {
        switch axCachePolicy {
        case .none:
            return try await AccessibilityFetcher.fetchAccessibilityElements(for: simulatorUDID, logger: logger)
        case .perStep:
            return try await AccessibilityFetcher.fetchAccessibilityElements(for: simulatorUDID, logger: logger)
        case .perBatch:
            if !forceRefresh, let cachedRoots {
                return cachedRoots
            }
            let roots = try await AccessibilityFetcher.fetchAccessibilityElements(for: simulatorUDID, logger: logger)
            cachedRoots = roots
            return roots
        }
    }
}

