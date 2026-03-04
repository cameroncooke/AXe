import ArgumentParser
import Foundation
import FBSimulatorControl

@MainActor
protocol BatchConvertible {
    func toBatchPrimitives(context: BatchContext, logger: AxeLogger) async throws -> [BatchPrimitive]
}

private func buildDelayedEvent(
    preDelay: Double?,
    mainEvent: FBSimulatorHIDEvent,
    postDelay: Double?
) -> FBSimulatorHIDEvent {
    var events: [FBSimulatorHIDEvent] = []
    if let preDelay, preDelay > 0 {
        events.append(.delay(preDelay))
    }
    events.append(mainEvent)
    if let postDelay, postDelay > 0 {
        events.append(.delay(postDelay))
    }
    return events.count == 1 ? events[0] : FBSimulatorHIDEvent(events: events)
}

func parseCommaSeparatedIntsStrict(_ rawValue: String, fieldName: String) throws -> [Int] {
    let rawTokens = rawValue.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }

    let invalidTokens = rawTokens.filter { Int($0) == nil }
    guard invalidTokens.isEmpty else {
        throw ValidationError("All \(fieldName) must be valid integers. Invalid token(s): \(invalidTokens.joined(separator: ", "))")
    }

    return rawTokens.compactMap(Int.init)
}

extension Tap: BatchConvertible {
    func toBatchPrimitives(context: BatchContext, logger: AxeLogger) async throws -> [BatchPrimitive] {
        let resolvedPoint: (x: Double, y: Double)

        if let pointX, let pointY {
            resolvedPoint = (pointX, pointY)
        } else {
            let query: AccessibilityQuery
            if let elementID {
                query = .id(elementID)
            } else if let elementLabel {
                query = .label(elementLabel)
            } else {
                throw CLIError(errorDescription: "Unexpected state: no coordinates and no element query.")
            }

            resolvedPoint = try await resolveWithPolling(query: query, context: context, logger: logger)
        }

        let tapEvent = FBSimulatorHIDEvent.tapAt(x: resolvedPoint.x, y: resolvedPoint.y)
        return [.hidMergeable(buildDelayedEvent(preDelay: preDelay, mainEvent: tapEvent, postDelay: postDelay))]
    }

    private func resolveWithPolling(
        query: AccessibilityQuery,
        context: BatchContext,
        logger: AxeLogger
    ) async throws -> (x: Double, y: Double) {
        let roots = try await context.accessibilityRoots(logger: logger)
        do {
            return try AccessibilityTargetResolver.resolveCenterPoint(roots: roots, query: query)
        } catch let error as ElementResolutionError where error.isNotFound && context.waitTimeout > 0 {
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(context.waitTimeout)

            var lastError = error
            while clock.now < deadline {
                logger.info().log("Element not found, retrying in \(context.pollInterval)s…")
                try await Task.sleep(for: .seconds(context.pollInterval))

                let freshRoots = try await context.accessibilityRoots(logger: logger, forceRefresh: true)
                do {
                    return try AccessibilityTargetResolver.resolveCenterPoint(roots: freshRoots, query: query)
                } catch let retryError as ElementResolutionError where retryError.isNotFound {
                    lastError = retryError
                    continue
                }
            }

            throw lastError
        }
    }
}

extension Swipe: BatchConvertible {
    func toBatchPrimitives(context: BatchContext, logger: AxeLogger) async throws -> [BatchPrimitive] {
        let swipeDuration = duration ?? 1.0
        let swipeDelta = delta ?? 50.0
        let swipeEvent = FBSimulatorHIDEvent.swipe(
            startX,
            yStart: startY,
            xEnd: endX,
            yEnd: endY,
            delta: swipeDelta,
            duration: swipeDuration
        )
        return [.hidMergeable(buildDelayedEvent(preDelay: preDelay, mainEvent: swipeEvent, postDelay: postDelay))]
    }
}

extension Gesture: BatchConvertible {
    func toBatchPrimitives(context: BatchContext, logger: AxeLogger) async throws -> [BatchPrimitive] {
        let width = screenWidth ?? 390.0
        let height = screenHeight ?? 844.0
        let coords = preset.coordinates(screenWidth: width, screenHeight: height)
        let gestureDuration = duration ?? preset.defaultDuration
        let gestureDelta = delta ?? preset.defaultDelta

        let gestureEvent = FBSimulatorHIDEvent.swipe(
            coords.startX,
            yStart: coords.startY,
            xEnd: coords.endX,
            yEnd: coords.endY,
            delta: gestureDelta,
            duration: gestureDuration
        )

        return [.hidMergeable(buildDelayedEvent(preDelay: preDelay, mainEvent: gestureEvent, postDelay: postDelay))]
    }
}

extension Touch: BatchConvertible {
    func toBatchPrimitives(context: BatchContext, logger: AxeLogger) async throws -> [BatchPrimitive] {
        let touchDownEvent = FBSimulatorHIDEvent.touchDownAt(x: pointX, y: pointY)
        let touchUpEvent = FBSimulatorHIDEvent.touchUpAt(x: pointX, y: pointY)

        if touchDown && touchUp {
            let holdDelay = delay ?? 0.1
            return [
                .hidBarrier(touchDownEvent),
                .hostSleep(holdDelay),
                .hidBarrier(touchUpEvent)
            ]
        }

        if touchDown {
            return [.hidMergeable(touchDownEvent)]
        }

        return [.hidMergeable(touchUpEvent)]
    }
}

extension Button: BatchConvertible {
    func toBatchPrimitives(context: BatchContext, logger: AxeLogger) async throws -> [BatchPrimitive] {
        if let duration {
            let composite = FBSimulatorHIDEvent(events: [
                .buttonDown(buttonType.hidButton),
                .delay(duration),
                .buttonUp(buttonType.hidButton)
            ])
            return [.hidMergeable(composite)]
        }

        return [.hidMergeable(.shortButtonPress(buttonType.hidButton))]
    }
}

extension Key: BatchConvertible {
    func toBatchPrimitives(context: BatchContext, logger: AxeLogger) async throws -> [BatchPrimitive] {
        if let duration {
            let composite = FBSimulatorHIDEvent(events: [
                .keyDown(UInt32(keycode)),
                .delay(duration),
                .keyUp(UInt32(keycode))
            ])
            return [.hidMergeable(composite)]
        }

        return [.hidMergeable(.shortKeyPress(UInt32(keycode)))]
    }
}

extension KeySequence: BatchConvertible {
    func toBatchPrimitives(context: BatchContext, logger: AxeLogger) async throws -> [BatchPrimitive] {
        let parsedKeycodes = try parseCommaSeparatedIntsStrict(keycodesString, fieldName: "keycodes")
        let keyDelay = delay ?? 0.1
        var events: [FBSimulatorHIDEvent] = []

        for (index, keycode) in parsedKeycodes.enumerated() {
            events.append(.shortKeyPress(UInt32(keycode)))
            if index < parsedKeycodes.count - 1 && keyDelay > 0 {
                events.append(.delay(keyDelay))
            }
        }

        return [.hidMergeable(FBSimulatorHIDEvent(events: events))]
    }
}

extension KeyCombo: BatchConvertible {
    func toBatchPrimitives(context: BatchContext, logger: AxeLogger) async throws -> [BatchPrimitive] {
        let parsedModifiers = try parseCommaSeparatedIntsStrict(modifiersString, fieldName: "modifier keycodes")

        var events: [FBSimulatorHIDEvent] = []
        for modifier in parsedModifiers {
            events.append(.keyDown(UInt32(modifier)))
        }
        events.append(.shortKeyPress(UInt32(key)))
        for modifier in parsedModifiers.reversed() {
            events.append(.keyUp(UInt32(modifier)))
        }

        return [.hidMergeable(FBSimulatorHIDEvent(events: events))]
    }
}

extension Type: BatchConvertible {
    func toBatchPrimitives(context: BatchContext, logger: AxeLogger) async throws -> [BatchPrimitive] {
        let inputText: String
        switch (text, useStdin, inputFile) {
        case (let positionalText?, false, nil):
            inputText = positionalText
        case (nil, true, nil):
            inputText = readFromStdin()
        case (nil, false, let file?):
            inputText = try readFromFile(file)
        default:
            throw CLIError(errorDescription: "Invalid input configuration.")
        }

        guard TextToHIDEvents.validateText(inputText) else {
            let unsupportedChars = inputText.compactMap { char in
                let keyEvent = KeyEvent.keyCodeForString(String(char))
                return keyEvent.keyCode == 0 ? char : nil
            }
            throw TextToHIDEvents.TextConversionError.unsupportedCharacter(unsupportedChars.first ?? " ")
        }

        let hidEvents = try TextToHIDEvents.convertTextToHIDEvents(inputText)
        guard !hidEvents.isEmpty else {
            return []
        }

        switch context.typeSubmissionMode {
        case .composite:
            return [.hidMergeable(FBSimulatorHIDEvent(events: hidEvents))]
        case .chunked:
            let chunkSize = max(1, context.typeChunkSize)
            var primitives: [BatchPrimitive] = []
            var start = 0
            while start < hidEvents.count {
                let end = min(start + chunkSize, hidEvents.count)
                let chunkEvents = Array(hidEvents[start..<end])
                primitives.append(.hidBarrier(FBSimulatorHIDEvent(events: chunkEvents)))
                start = end
            }
            return primitives
        }
    }
}

