import Foundation

@MainActor
struct AccessibilityPoller {
    static func resolveWithPolling(
        query: AccessibilityQuery,
        simulatorUDID: String,
        waitTimeout: TimeInterval,
        pollInterval: TimeInterval,
        elementType: String? = nil,
        logger: AxeLogger
    ) async throws -> TapResolution {
        try await pollForResolution(
            query: query,
            waitTimeout: waitTimeout,
            pollInterval: pollInterval,
            elementType: elementType,
            logger: logger
        ) {
            try await AccessibilityFetcher.fetchAccessibilityElements(for: simulatorUDID, logger: logger)
        }
    }

    static func pollForResolution(
        query: AccessibilityQuery,
        waitTimeout: TimeInterval,
        pollInterval: TimeInterval,
        elementType: String?,
        logger: AxeLogger,
        rootsFetcher: () async throws -> [AccessibilityElement]
    ) async throws -> TapResolution {
        let roots = try await rootsFetcher()
        do {
            return try AccessibilityTargetResolver.resolveTap(roots: roots, query: query, elementType: elementType)
        } catch let error as ElementResolutionError where error.isNotFound && waitTimeout > 0 {
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(waitTimeout)

            var lastError = error
            while clock.now < deadline {
                logger.info().log("Element not found, retrying in \(pollInterval)s…")
                try await Task.sleep(for: .seconds(pollInterval))

                let freshRoots = try await rootsFetcher()
                do {
                    return try AccessibilityTargetResolver.resolveTap(roots: freshRoots, query: query, elementType: elementType)
                } catch let retryError as ElementResolutionError where retryError.isNotFound {
                    lastError = retryError
                    continue
                }
            }

            throw lastError
        }
    }
}
