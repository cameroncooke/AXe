import Foundation

/// Maps the CLI's logical gestures to the phone's contact phases.
enum PhysicalDeviceGestures {
    static func requireCoordinateInput(_ selection: SelectedInputOptions, agent: AgentModeOptions) throws {
        guard selection.mode == .legacy, selection.screenID == nil, selection.screenUUID == nil, !agent.enabled else {
            throw AutomationTarget.unsupportedOnDevice("Physical input uses coordinates without --agent or simulator display selection.")
        }
    }

    static func path(
        _ request: SelectedHIDPath,
        edge: PhysicalTouchEdge = .none,
        on input: PhysicalDeviceInput
    ) async throws {
        try request.validate()
        try await wait(request.preDelay)
        let display = try await input.display()
        // The client sleeps both outer delays, as `perform(_:preDelay:postDelay:on:)` does: a post-delay
        // inside the broker operation would make an interrupt after the lift report an unknown outcome.
        var path = request
        path.preDelay = 0
        path.postDelay = 0
        let primitives = try path.primitives(logicalSize: CGSize(width: display.width, height: display.height))
        try await input.perform(touchSteps(primitives, edge: edge), on: display)
        try await wait(request.postDelay)
    }

    /// Converts path primitives to contact phases. Each phase waits for every delay before the next phase:
    /// a drag holds after its down and then waits one movement interval before the first move. Delays before
    /// the first phase belong to the caller.
    static func touchSteps(_ primitives: [SelectedHIDPrimitive], edge: PhysicalTouchEdge) -> [PhysicalTouchStep] {
        var isDown = false
        var steps: [PhysicalTouchStep] = []
        for primitive in primitives {
            switch primitive.kind {
            case .delay:
                if !steps.isEmpty { steps[steps.count - 1].delayAfter += primitive.duration ?? 0 }
            case .up:
                steps.append(PhysicalTouchStep(points: [primitive.point], phase: .up, edge: edge))
                isDown = false
            case .down:
                steps.append(PhysicalTouchStep(points: [primitive.point], phase: isDown ? .move : .down, edge: edge))
                isDown = true
            }
        }
        return steps
    }

    static func pinch(_ request: SelectedHIDPinch, on input: PhysicalDeviceInput) async throws {
        try request.validate()
        let center = CGPoint(x: request.centerX, y: request.centerY)
        let distance = request.radius * request.scale - request.radius
        let segments = max(1, Int(ceil(abs(distance) / request.spacing)))
        let steps = pairMotion(duration: request.duration, segments: segments) { fraction in
            radialPoints(at: center, radius: request.radius + distance * fraction, radians: 0)
        }
        try await perform(steps, preDelay: request.preDelay, postDelay: request.postDelay, on: input)
    }

    static func complete(_ request: SelectedHIDCompleteGesture, on input: PhysicalDeviceInput) async throws {
        try request.validate()
        let steps: [PhysicalTouchStep]
        let timing: SelectedHIDCompleteGesture.Timing
        switch request {
        case .doubleTap(let tap):
            try await wait(tap.timing.preDelay)
            try await input.tap(at: tap.point.cgPoint, count: 2, hold: tap.hold, interval: tap.interval)
            try await wait(tap.timing.postDelay)
            return
        case .rotate(let rotation):
            let radians = rotation.degrees * .pi / 180
            let segments = max(1, Int(ceil(abs(radians) * rotation.radius / rotation.spacing)))
            steps = pairMotion(duration: rotation.duration, segments: segments) { fraction in
                radialPoints(at: rotation.center.cgPoint, radius: rotation.radius, radians: radians * fraction)
            }
            timing = rotation.timing
        case .twoFingerSwipe(let path):
            steps = try pairedSwipe(path)
            timing = path.timing
        case .twoFingerTap(let contact), .twoFingerHold(let contact):
            let points = [contact.first.cgPoint, contact.second.cgPoint]
            steps = [
                PhysicalTouchStep(points: points, phase: .down, delayAfter: contact.hold),
                PhysicalTouchStep(points: points, phase: .up),
            ]
            timing = contact.timing
        }
        try await perform(steps, preDelay: timing.preDelay, postDelay: timing.postDelay, on: input)
    }

    private static func pairedSwipe(_ path: SelectedHIDCompleteGesture.PairPath) throws -> [PhysicalTouchStep] {
        let firstStart = path.firstStart.cgPoint
        let firstEnd = path.firstEnd.cgPoint
        let secondStart = path.secondStart.cgPoint
        let secondEnd = path.secondEnd.cgPoint
        let startX = firstStart.x - secondStart.x
        let startY = firstStart.y - secondStart.y
        let endX = firstEnd.x - secondEnd.x
        let endY = firstEnd.y - secondEnd.y
        // Collinear relative vectors on opposite rays meet at a shared point during motion.
        let cross = startX * endY - startY * endX
        let dot = startX * endX + startY * endY
        guard cross.isFinite, dot.isFinite, cross != 0 || dot > 0 else {
            throw SelectedHIDFailure.invalid("Two-finger swipe contacts must remain distinct during motion")
        }

        let distance = max(hypot(firstEnd.x - firstStart.x, firstEnd.y - firstStart.y),
                           hypot(secondEnd.x - secondStart.x, secondEnd.y - secondStart.y))
        let segments = max(1, Int(ceil(distance / path.spacing)))
        return pairMotion(duration: path.duration, segments: segments) { fraction in
            [interpolate(firstStart, firstEnd, fraction), interpolate(secondStart, secondEnd, fraction)]
        }
    }

    private static func pairMotion(
        duration: TimeInterval,
        segments: Int,
        pointsAt: (Double) -> [CGPoint]
    ) -> [PhysicalTouchStep] {
        var steps = (0...segments).map { index in
            PhysicalTouchStep(points: pointsAt(Double(index) / Double(segments)),
                phase: index == 0 ? .down : .move,
                delayAfter: index < segments ? duration / Double(segments) : 0)
        }
        steps.append(PhysicalTouchStep(points: pointsAt(1), phase: .up))
        return steps
    }

    private static func radialPoints(at center: CGPoint, radius: Double, radians: Double) -> [CGPoint] {
        let x = radius * cos(radians)
        let y = radius * sin(radians)
        return [CGPoint(x: center.x - x, y: center.y - y), CGPoint(x: center.x + x, y: center.y + y)]
    }

    private static func interpolate(_ start: CGPoint, _ end: CGPoint, _ fraction: Double) -> CGPoint {
        if fraction == 1 { return end }
        return CGPoint(x: start.x + (end.x - start.x) * fraction,
                       y: start.y + (end.y - start.y) * fraction)
    }

    private static func perform(
        _ steps: [PhysicalTouchStep],
        preDelay: TimeInterval,
        postDelay: TimeInterval,
        on input: PhysicalDeviceInput
    ) async throws {
        try await wait(preDelay)
        try await input.perform(steps)
        try await wait(postDelay)
    }

    private static func wait(_ seconds: TimeInterval) async throws {
        if seconds > 0 { try await Task.sleep(for: .seconds(seconds)) }
    }
}
