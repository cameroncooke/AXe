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
    return events.count == 1 ? events[0] : FBSimulatorHIDEvent.composite(events)
}

private func resolveBatchTapPoint(
    query: AccessibilityQuery,
    context: BatchContext,
    elementType: String?,
    logger: AxeLogger
) async throws -> (resolution: TapResolution, roots: [AccessibilityElement]) {
    var isFirstFetch = true
    var latestRoots: [AccessibilityElement] = []
    let resolution = try await AccessibilityPoller.pollForResolution(
        query: query,
        waitTimeout: context.waitTimeout,
        pollInterval: context.pollInterval,
        elementType: elementType,
        logger: logger
    ) {
        let forceRefresh = !isFirstFetch
        isFirstFetch = false
        let roots = try await context.accessibilityRoots(logger: logger, forceRefresh: forceRefresh)
        latestRoots = roots
        return roots
    }
    return (resolution, latestRoots)
}

func parseCommaSeparatedIntsStrict(_ rawValue: String, fieldName: String) throws -> [Int] {
    let rawTokens = rawValue
        .split(separator: ",", omittingEmptySubsequences: false)
        .map { String($0).trimmingCharacters(in: .whitespaces) }

    let invalidTokens = rawTokens.filter { token in
        token.isEmpty || Int(token) == nil
    }
    guard invalidTokens.isEmpty else {
        throw ValidationError("All \(fieldName) must be valid integers. Invalid token(s): \(invalidTokens.joined(separator: ", "))")
    }

    return rawTokens.compactMap(Int.init)
}

extension Tap: BatchConvertible {
    private func resolvedTapStyle(for resolution: TapResolution, context: BatchContext) -> TapStyle {
        let requestedStyle = tapStyle ?? context.tapStyle
        switch requestedStyle {
        case .automatic:
            return resolution.isSwitchLikeControl ? .physical : .simulator
        case .simulator:
            return .simulator
        case .physical:
            return .physical
        }
    }

    func toBatchPrimitives(context: BatchContext, logger: AxeLogger) async throws -> [BatchPrimitive] {
        let resolution: TapResolution
        let resolvedRoots: [AccessibilityElement]?

        if let pointX, let pointY {
            resolution = TapResolution(point: (x: pointX, y: pointY), isSwitchLikeControl: false)
            resolvedRoots = nil
        } else {
            let query: AccessibilityQuery
            if let elementID {
                query = .id(elementID)
            } else if let elementLabel {
                query = .label(elementLabel)
            } else if let elementValue {
                query = .value(elementValue)
            } else {
                throw CLIError(errorDescription: "Unexpected state: no coordinates and no element query.")
            }

            let resolved = try await resolveBatchTapPoint(
                query: query,
                context: context,
                elementType: elementType,
                logger: logger
            )
            resolution = resolved.resolution
            resolvedRoots = resolved.roots
        }

        let physicalPoint: (x: Double, y: Double)
        if let resolvedRoots {
            physicalPoint = try await OrientationAwareCoordinates.translate(
                point: resolution.point,
                roots: resolvedRoots,
                for: context.simulatorUDID,
                logger: logger
            )
        } else {
            physicalPoint = try await OrientationAwareCoordinates.translate(
                point: resolution.point,
                for: context.simulatorUDID,
                logger: logger
            )
        }

        let style = resolvedTapStyle(for: resolution, context: context)
        switch style {
        case .physical:
            return [.physicalTap(point: physicalPoint, preDelay: preDelay, postDelay: postDelay)]
        case .simulator:
            let tapEvent = FBSimulatorHIDEvent.tapAt(x: physicalPoint.x, y: physicalPoint.y)
            return [.hidMergeable(buildDelayedEvent(preDelay: preDelay, mainEvent: tapEvent, postDelay: postDelay))]
        case .automatic:
            throw CLIError(errorDescription: "Unexpected tap style resolution.")
        }
    }
}

extension Swipe: BatchConvertible {
    func toBatchPrimitives(context: BatchContext, logger: AxeLogger) async throws -> [BatchPrimitive] {
        let swipeDuration = duration ?? 1.0
        let swipeDelta = delta ?? 50.0
        let physicalPoints = try await OrientationAwareCoordinates.translateBatch(
            points: [(x: startX, y: startY), (x: endX, y: endY)],
            for: context.simulatorUDID,
            logger: logger
        )
        let physicalStart = physicalPoints[0]
        let physicalEnd = physicalPoints[1]

        let swipeEvent = FBSimulatorHIDEvent.swipe(
            physicalStart.x,
            yStart: physicalStart.y,
            xEnd: physicalEnd.x,
            yEnd: physicalEnd.y,
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
        let physicalPoint = try await OrientationAwareCoordinates.translate(
            point: (x: pointX, y: pointY),
            for: context.simulatorUDID,
            logger: logger
        )

        let touchDownEvent = FBSimulatorHIDEvent.touch(direction: .down, x: physicalPoint.x, y: physicalPoint.y)
        let touchUpEvent = FBSimulatorHIDEvent.touch(direction: .up, x: physicalPoint.x, y: physicalPoint.y)

        if touchDown && touchUp {
            let holdDelay = delay ?? TapTiming.defaultHoldDuration
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
            let composite = FBSimulatorHIDEvent.composite([
                .button(direction: .down, button: buttonType.hidButton),
                .delay(duration),
                .button(direction: .up, button: buttonType.hidButton)
            ])
            return [.hidMergeable(composite)]
        }

        return [.hidMergeable(.shortButtonPress(buttonType.hidButton))]
    }
}

extension Key: BatchConvertible {
    func toBatchPrimitives(context: BatchContext, logger: AxeLogger) async throws -> [BatchPrimitive] {
        if let duration {
            let composite = FBSimulatorHIDEvent.composite([
                .keyboard(direction: .down, keyCode: UInt32(keycode)),
                .delay(duration),
                .keyboard(direction: .up, keyCode: UInt32(keycode))
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

        return [.hidMergeable(FBSimulatorHIDEvent.composite(events))]
    }
}

extension KeyCombo: BatchConvertible {
    func toBatchPrimitives(context: BatchContext, logger: AxeLogger) async throws -> [BatchPrimitive] {
        let parsedModifiers = try parseCommaSeparatedIntsStrict(modifiersString, fieldName: "modifier keycodes")

        var events: [FBSimulatorHIDEvent] = []
        for modifier in parsedModifiers {
            events.append(.keyboard(direction: .down, keyCode: UInt32(modifier)))
        }
        events.append(.shortKeyPress(UInt32(key)))
        for modifier in parsedModifiers.reversed() {
            events.append(.keyboard(direction: .up, keyCode: UInt32(modifier)))
        }

        return [.hidMergeable(FBSimulatorHIDEvent.composite(events))]
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
            return [.hidMergeable(FBSimulatorHIDEvent.composite(hidEvents))]
        case .chunked:
            let chunkSize = max(1, context.typeChunkSize)
            var primitives: [BatchPrimitive] = []
            var start = 0
            while start < hidEvents.count {
                let end = min(start + chunkSize, hidEvents.count)
                let chunkEvents = Array(hidEvents[start..<end])
                primitives.append(.hidBarrier(FBSimulatorHIDEvent.composite(chunkEvents)))
                start = end
            }
            return primitives
        }
    }
}
