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
    let tapStyle: TapStyle
    let waitTimeout: TimeInterval
    let pollInterval: TimeInterval
    let duoOwner: SelectedHIDOwner?

    private var cachedRoots: [AccessibilityElement]?

    init(
        simulatorUDID: String,
        axCachePolicy: AXCachePolicy,
        typeSubmissionMode: TypeSubmissionMode,
        typeChunkSize: Int,
        tapStyle: TapStyle = .automatic,
        waitTimeout: TimeInterval = 0,
        pollInterval: TimeInterval = 0.25,
        duoOwner: SelectedHIDOwner? = nil
    ) {
        self.simulatorUDID = simulatorUDID
        self.axCachePolicy = axCachePolicy
        self.typeSubmissionMode = typeSubmissionMode
        self.typeChunkSize = typeChunkSize
        self.tapStyle = tapStyle
        self.waitTimeout = waitTimeout
        self.pollInterval = pollInterval
        self.duoOwner = duoOwner
    }

    func accessibilityRoots(logger: AxeLogger, forceRefresh: Bool = false) async throws -> [AccessibilityElement] {
        try await validateCurrentContext()
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

    func validateCurrentContext() async throws {
        guard let duoOwner else { return }
        do { try await duoOwner.validateLegacyBatchContext() }
        catch { cachedRoots = nil; throw error }
    }

    func inputPoint(_ point: (x: Double, y: Double), roots: [AccessibilityElement]? = nil,
                    logger: AxeLogger) async throws -> (x: Double, y: Double) {
        if duoOwner != nil { return point }
        if let roots {
            return try await OrientationAwareCoordinates.translate(point: point, roots: roots,
                for: simulatorUDID, logger: logger)
        }
        return try await OrientationAwareCoordinates.translate(point: point, for: simulatorUDID, logger: logger)
    }

    func inputPoints(_ points: [(x: Double, y: Double)], logger: AxeLogger) async throws -> [(x: Double, y: Double)] {
        if duoOwner != nil { return points }
        return try await OrientationAwareCoordinates.translateBatch(points: points, for: simulatorUDID, logger: logger)
    }

    func validateSwipeAllocation(from start: (x: Double, y: Double), to end: (x: Double, y: Double),
                                 duration: Double, delta: Double) throws {
        guard duoOwner != nil else { return }
        try LegacyDuoPath(kind: .swipe, startX: start.x, startY: start.y,
            endX: end.x, endY: end.y, duration: duration, delta: delta).validate()
    }
}

