import Foundation

enum PhysicalAccessibilityCommands {
    private static let readBudget = PhysicalAccessibility.readBudget

    static func usesSimulatorOptions(input: SelectedInputOptions, ax: SelectedAXOptions,
                                     agent: AgentModeOptions) -> Bool {
        input.mode == .selected || input.screenID != nil || input.screenUUID != nil || ax.expectedPID != nil
            || agent.enabled || agent.view != nil || agent.snapshotID != nil || agent.elementRef != nil
    }

    static func pointJSON(at point: CGPoint, in snapshot: PhysicalAccessibilitySnapshot) throws -> Data {
        let tree = VisibleTree(snapshot)
        guard try tree.bounds.contains(point) else {
            throw CLIOutputFailure(code: "pointOutsideDisplay",
                message: "Describe-ui point must lie inside the physical display.")
        }
        guard let hit = try tree.hit(at: point) else {
            throw CLIOutputFailure(code: "elementNotFound",
                message: "No accessibility element covers this point on the physical device.")
        }

        let raw = try JSONDecoder().decode(CLIOutputValue.self, from: snapshot.json)
        var siblings = raw.arrayValue ?? [raw]
        var element: CLIOutputValue?
        for index in hit.path {
            guard siblings.indices.contains(index) else {
                throw CLIOutputFailure(code: "treeUnavailable",
                    message: "The serialized device tree did not contain the matched accessibility element.")
            }
            let node = siblings[index]
            element = node
            siblings = node["children"]?.arrayValue ?? []
        }
        guard let element else {
            throw CLIOutputFailure(code: "treeUnavailable", message: "The matched accessibility element had no tree path.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(raw.arrayValue == nil ? element : .array([element]))
    }

    static func tap(query: AccessibilityQuery, elementType: String?, waitTimeout: TimeInterval,
                    pollInterval requestedPollInterval: TimeInterval?, on input: PhysicalDeviceInput,
                    steps: ((CGPoint) -> [PhysicalTouchStep])? = nil) async throws {
        if let elementType, elementType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CLIOutputFailure(code: "invalidArguments", message: "Physical --element-type must not be empty.")
        }
        guard waitTimeout.isFinite, (0...SelectedAXWaitPolicy.maximumTimeout).contains(waitTimeout) else {
            throw CLIOutputFailure(code: "invalidArguments", message: "Physical --wait-timeout must be 0 to 30 seconds.")
        }
        let allowedPollInterval = SelectedAXWaitPolicy.minimumPollInterval...SelectedAXWaitPolicy.maximumPollInterval
        let pollInterval = requestedPollInterval ?? 0.25
        if waitTimeout > 0 {
            guard pollInterval.isFinite, allowedPollInterval.contains(pollInterval) else {
                throw CLIOutputFailure(code: "invalidArguments", message: "Physical --poll-interval must be 0.05 to 30 seconds.")
            }
        } else if requestedPollInterval != nil {
            throw CLIOutputFailure(code: "invalidArguments", message: "Physical --poll-interval requires a positive --wait-timeout.")
        }

        let clock = ContinuousClock()
        let deadline = waitTimeout > 0 ? clock.now + .seconds(waitTimeout) : nil
        func budget() throws -> TimeInterval {
            guard let deadline else { return readBudget }
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else { throw waitExpired }
            return min(readBudget, remaining.timeInterval)
        }

        // A target in the first read is tapped from that read, as on a simulator: a second read costs
        // one to three seconds on a device. A target that appeared while polling may still be moving
        // into place, so it is read once more and must not have changed. The tree read compared the
        // display before and after it, and the broker compares it again just before the touch.
        var fresh: Target
        var polled = false
        while true {
            try Task.checkCancellation()
            let snapshot = try await input.readAccessibility(timeout: budget())
            try snapshot.display.requireResolvedOrientation()
            if let target = try VisibleTree(snapshot).target(matching: query, elementType: elementType) {
                fresh = target
                break
            }
            guard deadline != nil else { throw missingTarget }
            polled = true
            try await Task.sleep(for: .seconds(min(pollInterval, try budget())))
        }
        if polled {
            let snapshot = try await input.readAccessibility(timeout: budget())
            guard let settled = try VisibleTree(snapshot).target(matching: query, elementType: elementType),
                  settled == fresh else {
                throw CLIOutputFailure(code: "targetChanged",
                    message: "The accessibility target or display changed before the tap. Read the screen again.")
            }
            fresh = settled
        }
        try Task.checkCancellation()
        _ = try budget()
        // A long press, double tap or two-finger tap supplies its own contact plan for the point.
        try await input.perform(steps?(fresh.point) ?? [
            PhysicalTouchStep(points: [fresh.point], phase: .down, delayAfter: 0.05),
            PhysicalTouchStep(points: [fresh.point], phase: .up),
        ], on: fresh.display, admissionDeadline: deadline)
    }

    /// One read of the device's screen for scrolling until an element is visible: whether one visible
    /// element that owns its tap point matches the selector, and what the screen holds. A read taken
    /// while the content is still moving can fail; it is tried up to three times.
    static func observe(_ query: AccessibilityQuery, on input: PhysicalDeviceInput) async throws -> ScrollUntilOptions.Observation {
        var lastError: Error = CLIOutputFailure(code: "readFailed", message: "The device's screen could not be read.")
        for _ in 0..<3 {
            do {
                let snapshot = try await input.readAccessibility(timeout: readBudget)
                try snapshot.display.requireResolvedOrientation()
                let signature = ScrollUntilOptions.signature(of: snapshot.roots)
                do {
                    let visible = try VisibleTree(snapshot).target(matching: query, elementType: nil) != nil
                    return .init(visible: visible, signature: signature)
                } catch let failure as CLIOutputFailure where failure.code == "elementNotHittable" {
                    // In the tree but not yet fully on screen, or under another control: keep scrolling.
                    return .init(visible: false, signature: signature)
                }
            } catch let failure as CLIOutputFailure where failure.code == "ambiguousElement" {
                throw failure
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                try await Task.sleep(for: .milliseconds(300))
            }
        }
        throw lastError
    }

    private static var missingTarget: CLIOutputFailure {
        CLIOutputFailure(code: "elementNotFound", message: "No accessibility element matches this selector on the physical device.")
    }

    private static var waitExpired: CLIOutputFailure {
        CLIOutputFailure(code: "timeout", message: "The physical device polling deadline expired before a target was verified.")
    }

    private struct VisibleTree {
        let display: PhysicalDeviceDisplay
        let entries: [Entry]

        var bounds: CGRect {
            get throws { try CGRect(x: 0, y: 0, width: display.width, height: display.height) }
        }

        init(_ snapshot: PhysicalAccessibilitySnapshot) {
            display = snapshot.display
            var entries: [Entry] = []
            func append(_ nodes: [AccessibilityElement], to parentPath: [Int], visible: Bool, rootPID: Int32?) {
                for (index, element) in nodes.enumerated() {
                    let path = parentPath + [index]
                    let isVisible = visible && element.hidden != true
                    let owner = rootPID ?? (parentPath.isEmpty ? element.pid : nil)
                    entries.append(Entry(element: element, path: path, visible: isVisible, rootPID: owner))
                    append(element.children ?? [], to: path, visible: isVisible, rootPID: owner)
                }
            }
            append(snapshot.roots, to: [], visible: true, rootPID: nil)
            self.entries = entries
        }

        func hit(at point: CGPoint) throws -> Entry? {
            let matches = entries.filter {
                $0.visible && $0.path.count > 1 && $0.frame?.contains(point) == true
            }
            guard let deepest = matches.max(by: { $0.path.count < $1.path.count }) else { return nil }
            // Tree dumps give geometry but no verified z-order for overlapping branches.
            guard matches.allSatisfy({ deepest.path.starts(with: $0.path) }) else {
                throw CLIOutputFailure(code: "ambiguousPoint",
                    message: "Accessibility elements from different branches cover this point.")
            }
            return deepest
        }

        func target(matching query: AccessibilityQuery, elementType: String?) throws -> Target? {
            let wanted: String
            switch query {
            case .id(let value), .label(let value), .value(let value):
                wanted = value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let matches = entries.filter { entry in
                let element = entry.element
                guard elementType == nil || element.type == elementType else { return false }
                switch query {
                case .id: return element.normalizedUniqueId == wanted
                case .label: return element.normalizedLabel == wanted
                case .value: return element.normalizedValue == wanted
                }
            }
            guard let match = matches.first else { return nil }
            guard matches.count == 1 else {
                throw CLIOutputFailure(code: "ambiguousElement",
                    message: "Multiple accessibility elements match this selector. Use a unique identifier.")
            }
            guard match.visible, match.element.enabled != false, let frame = match.frame,
                  try bounds.contains(frame), let pid = match.element.pid, pid > 0,
                  let rootPID = match.rootPID, rootPID > 0 else {
                throw CLIOutputFailure(code: "elementNotHittable",
                    message: "The selected accessibility element does not have a visible, enabled target inside the display.")
            }
            let point = CGPoint(x: frame.midX, y: frame.midY)
            guard let hit = try hit(at: point), hit.path.starts(with: match.path), hit.element.pid == pid else {
                throw CLIOutputFailure(code: "elementNotHittable",
                    message: "The matched accessibility element does not own its tap point.")
            }
            return Target(path: match.path, pid: pid, rootPID: rootPID,
                type: match.element.type, role: match.element.role, identifier: match.element.normalizedUniqueId,
                label: match.element.AXLabel, value: match.element.AXValue, frame: frame, display: display)
        }
    }

    private struct Entry {
        let element: AccessibilityElement
        let path: [Int]
        let visible: Bool
        let rootPID: Int32?

        var frame: CGRect? {
            guard let frame = element.frame,
                  [frame.x, frame.y, frame.width, frame.height,
                   frame.x + frame.width, frame.y + frame.height].allSatisfy(\.isFinite),
                  frame.width > 0, frame.height > 0 else { return nil }
            return CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        }
    }

    private struct Target: Equatable {
        let path: [Int]
        let pid: Int32
        let rootPID: Int32
        let type: String?
        let role: String?
        let identifier: String?
        let label: String?
        let value: String?
        let frame: CGRect
        let display: PhysicalDeviceDisplay

        var point: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
    }
}
