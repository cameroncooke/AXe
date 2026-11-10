import ArgumentParser
import Foundation

/// Repeats a scroll until an element is on screen. `swipe` and the scroll presets of `gesture` share it.
struct ScrollUntilOptions: ParsableArguments {
    @Option(name: .customLong("until-id"), help: "Repeat the scroll until the element with this accessibility identifier is on screen.")
    var untilID: String?

    @Option(name: .customLong("until-label"), help: "Repeat the scroll until an element with this accessibility label is on screen.")
    var untilLabel: String?

    @Option(name: .customLong("max-swipes"), help: "With --until-id or --until-label: the most scrolls to make, 1 to 50 (default 10).")
    var maxSwipes: Int?

    static let defaultMaxSwipes = 10
    /// Content keeps moving, or bounces back from its end, after the finger lifts; the next read waits this long.
    static let settle: TimeInterval = 0.4

    /// One read of the screen: whether the element can be tapped where it is, and what the screen holds.
    struct Observation: Equatable {
        let visible: Bool
        /// Every element's identity and frame. Two equal signatures mean a scroll moved nothing.
        let signature: String
    }

    var query: AccessibilityQuery? {
        if let untilID { return .id(untilID) }
        if let untilLabel { return .label(untilLabel) }
        return nil
    }

    func validate() throws {
        guard untilID == nil || untilLabel == nil else {
            throw ValidationError("Pass --until-id or --until-label, not both.")
        }
        guard query != nil else {
            guard maxSwipes == nil else { throw ValidationError("--max-swipes needs --until-id or --until-label.") }
            return
        }
        if let maxSwipes {
            guard (1...50).contains(maxSwipes) else { throw ValidationError("--max-swipes must be 1 to 50.") }
        }
    }

    /// Reads, then scrolls and reads again, until the element is visible. It reads before the first
    /// scroll, so an element already on screen costs no input, and it stops as soon as a scroll moves
    /// nothing: the content is at its end, and more scrolls would only make it bounce.
    func run(_ query: AccessibilityQuery, observe: () async throws -> Observation,
             scroll: () async throws -> Void) async throws {
        let limit = maxSwipes ?? Self.defaultMaxSwipes
        let name: String
        switch query {
        case .id(let value), .label(let value), .value(let value): name = value
        }
        var before: Observation?
        for scrolls in 0...limit {
            let seen = try await observe()
            if seen.visible {
                CLIOutput.message("✓ \(name) is on screen after \(scrolls) scroll\(scrolls == 1 ? "" : "s")")
                return
            }
            if let before, before.signature == seen.signature {
                throw CLIError(errorDescription: "\(name) was not found: the content stopped moving after \(scrolls - 1) scroll\(scrolls == 2 ? "" : "s"), so it is at its end. Check the direction.",
                    code: .elementNotFound)
            }
            guard scrolls < limit else { break }
            before = seen
            try await scroll()
            try await Task.sleep(for: .seconds(Self.settle))
        }
        throw CLIError(errorDescription: "\(name) was not on screen after \(limit) scrolls. Check the direction, or raise --max-swipes.",
            code: .elementNotFound)
    }

    static func signature(of roots: [AccessibilityElement]) -> String {
        var parts: [String] = []
        func walk(_ elements: [AccessibilityElement]) {
            for element in elements {
                let frame = element.frame.map { "\(Int($0.x)),\(Int($0.y)),\(Int($0.width)),\(Int($0.height))" } ?? "-"
                parts.append("\(element.type ?? "")|\(element.normalizedUniqueId ?? "")|\(element.normalizedLabel ?? "")|\(frame)")
                walk(element.children ?? [])
            }
        }
        walk(roots)
        return parts.joined(separator: ";")
    }

    /// A simulator's screen. The element counts as visible when it is in the tree, its centre is inside
    /// the application and a lookup at that centre finds the element itself: inside a strip of controls
    /// an element can be in the tree while it sits past the strip's edge or under another control.
    @MainActor
    static func observe(_ query: AccessibilityQuery, simulatorUDID: String, logger: AxeLogger) async throws -> Observation {
        let roots = try await AccessibilityFetcher.fetchAccessibilityElements(for: simulatorUDID, logger: logger)
        let signature = signature(of: roots)
        let match: AccessibilityMatch
        do {
            match = try AccessibilityTargetResolver.resolveElement(roots: roots, query: query, elementType: nil)
        } catch let error as ElementResolutionError where error.isNotFound {
            return Observation(visible: false, signature: signature)
        }
        guard let frame = match.element.frame, let screen = match.applicationFrame, frame.width > 0, frame.height > 0 else {
            return Observation(visible: false, signature: signature)
        }
        let x = frame.x + frame.width / 2, y = frame.y + frame.height / 2
        guard x >= screen.x, x <= screen.x + screen.width, y >= screen.y, y <= screen.y + screen.height else {
            return Observation(visible: false, signature: signature)
        }
        // A lookup that finds nothing at the point fails; either way the element is not there to tap.
        guard let data = try? await AccessibilityFetcher.fetchAccessibilityInfoJSONData(for: simulatorUDID,
            point: AccessibilityPoint(x: x, y: y), logger: logger) else {
            return Observation(visible: false, signature: signature)
        }
        let hit = (try? JSONDecoder().decode([AccessibilityElement].self, from: data))
            ?? (try? JSONDecoder().decode(AccessibilityElement.self, from: data)).map { [$0] } ?? []
        return Observation(visible: contains(match.element, in: hit), signature: signature)
    }

    /// Whether the lookup's result is the wanted element or holds it.
    static func contains(_ wanted: AccessibilityElement, in elements: [AccessibilityElement]) -> Bool {
        elements.contains { element in
            let same = element.type == wanted.type
                && element.normalizedUniqueId == wanted.normalizedUniqueId
                && element.normalizedLabel == wanted.normalizedLabel
            return same || contains(wanted, in: element.children ?? [])
        }
    }
}
