import Foundation
import FBControlCore
import FBSimulatorControl

// MARK: - HID Event Factory

struct HIDEventFactory {
    
    // MARK: - Event Creation
    
    /// Convert an event sequence to an array of FBSimulatorHIDEvent objects
    static func createHIDEvents(from sequence: EventSequence) throws -> [FBSimulatorHIDEvent] {
        var hidEvents: [FBSimulatorHIDEvent] = []
        
        let defaultDelay = sequence.settings?.defaultDelay ?? 0.0
        
        for (index, eventDef) in sequence.events.enumerated() {
            do {
                // Add pre-delay if specified
                if let preDelay = eventDef.preDelay, preDelay > 0 {
                    hidEvents.append(FBSimulatorHIDEvent.delay(preDelay))
                } else if defaultDelay > 0 && index > 0 {
                    // Add default delay between events (except before first event)
                    hidEvents.append(FBSimulatorHIDEvent.delay(defaultDelay))
                }
                
                // Create the main event
                let mainEvents = try createHIDEvent(from: eventDef)
                hidEvents.append(contentsOf: mainEvents)
                
                // Add post-delay if specified
                if let postDelay = eventDef.postDelay, postDelay > 0 {
                    hidEvents.append(FBSimulatorHIDEvent.delay(postDelay))
                }
                
            } catch {
                throw HIDEventFactoryError.eventCreationFailed(index: index, eventId: eventDef.id, error: error)
            }
        }
        
        return hidEvents
    }
    
    /// Create a single composite HID event from an event sequence
    static func createCompositeHIDEvent(from sequence: EventSequence) throws -> FBSimulatorHIDEvent {
        let events = try createHIDEvents(from: sequence)
        
        if events.count == 1 {
            return events[0]
        } else {
            return FBSimulatorHIDEvent(events: events)
        }
    }
    
    // MARK: - Individual Event Creation
    
    /// Create FBSimulatorHIDEvent(s) from a single event definition
    private static func createHIDEvent(from eventDef: HIDEventDefinition) throws -> [FBSimulatorHIDEvent] {
        switch eventDef.parameters {
        case .tap(let params):
            return [createTapEvent(params)]
            
        case .swipe(let params):
            return [createSwipeEvent(params)]
            
        case .type(let params):
            return try createTypeEvents(params)
            
        case .key(let params):
            return [createKeyEvent(params)]
            
        case .keySequence(let params):
            return createKeySequenceEvents(params)
            
        case .button(let params):
            return [try createButtonEvent(params)]
            
        case .touch(let params):
            return createTouchEvents(params)
            
        case .delay(let params):
            return [createDelayEvent(params)]
            
        case .gesture(let params):
            return [createGestureEvent(params)]
        }
    }
    
    // MARK: - Specific Event Creators
    
    private static func createTapEvent(_ params: TapParameters) -> FBSimulatorHIDEvent {
        return FBSimulatorHIDEvent.tapAt(x: params.x, y: params.y)
    }
    
    private static func createSwipeEvent(_ params: SwipeParameters) -> FBSimulatorHIDEvent {
        let duration = params.duration ?? 1.0
        let delta = params.delta ?? 50.0
        
        return FBSimulatorHIDEvent.swipe(
            params.startX,
            yStart: params.startY,
            xEnd: params.endX,
            yEnd: params.endY,
            delta: delta,
            duration: duration
        )
    }
    
    private static func createTypeEvents(_ params: TypeParameters) throws -> [FBSimulatorHIDEvent] {
        do {
            return try TextToHIDEvents.convertTextToHIDEvents(params.text)
        } catch {
            throw HIDEventFactoryError.textConversionFailed(text: params.text, error: error)
        }
    }
    
    private static func createKeyEvent(_ params: KeyParameters) -> FBSimulatorHIDEvent {
        if let duration = params.duration {
            // Create key down, delay, key up sequence
            let keyDownEvent = FBSimulatorHIDEvent.keyDown(UInt32(params.keycode))
            let delayEvent = FBSimulatorHIDEvent.delay(duration)
            let keyUpEvent = FBSimulatorHIDEvent.keyUp(UInt32(params.keycode))
            
            return FBSimulatorHIDEvent(events: [keyDownEvent, delayEvent, keyUpEvent])
        } else {
            return FBSimulatorHIDEvent.shortKeyPress(UInt32(params.keycode))
        }
    }
    
    private static func createKeySequenceEvents(_ params: KeySequenceParameters) -> [FBSimulatorHIDEvent] {
        var events: [FBSimulatorHIDEvent] = []
        let keyDelay = params.delay ?? 0.1
        
        for (index, keycode) in params.keycodes.enumerated() {
            // Add key press event
            let keyEvent = FBSimulatorHIDEvent.shortKeyPress(UInt32(keycode))
            events.append(keyEvent)
            
            // Add delay between keys (except after the last key)
            if index < params.keycodes.count - 1 && keyDelay > 0 {
                let delayEvent = FBSimulatorHIDEvent.delay(keyDelay)
                events.append(delayEvent)
            }
        }
        
        return events
    }
    
    private static func createButtonEvent(_ params: ButtonParameters) throws -> FBSimulatorHIDEvent {
        let buttonType = try mapButtonType(params.button)
        
        if let duration = params.duration {
            // Create button down, delay, button up sequence
            let buttonDownEvent = FBSimulatorHIDEvent.buttonDown(buttonType.hidButton)
            let delayEvent = FBSimulatorHIDEvent.delay(duration)
            let buttonUpEvent = FBSimulatorHIDEvent.buttonUp(buttonType.hidButton)
            
            return FBSimulatorHIDEvent(events: [buttonDownEvent, delayEvent, buttonUpEvent])
        } else {
            return FBSimulatorHIDEvent.shortButtonPress(buttonType.hidButton)
        }
    }
    
    private static func createTouchEvents(_ params: TouchParameters) -> [FBSimulatorHIDEvent] {
        var events: [FBSimulatorHIDEvent] = []
        
        // Touch down
        let touchDownEvent = FBSimulatorHIDEvent.touchDownAt(x: params.x, y: params.y)
        events.append(touchDownEvent)
        
        // Hold duration if specified
        if let duration = params.duration, duration > 0 {
            let delayEvent = FBSimulatorHIDEvent.delay(duration)
            events.append(delayEvent)
        }
        
        // Touch up
        let touchUpEvent = FBSimulatorHIDEvent.touchUpAt(x: params.x, y: params.y)
        events.append(touchUpEvent)
        
        return events
    }
    
    private static func createDelayEvent(_ params: DelayParameters) -> FBSimulatorHIDEvent {
        return FBSimulatorHIDEvent.delay(params.duration)
    }
    
    private static func createGestureEvent(_ params: GestureParameters) -> FBSimulatorHIDEvent {
        let duration = params.duration ?? 1.0
        let delta = params.delta ?? 50.0
        
        return FBSimulatorHIDEvent.swipe(
            params.startX,
            yStart: params.startY,
            xEnd: params.endX,
            yEnd: params.endY,
            delta: delta,
            duration: duration
        )
    }
    
    // MARK: - Helper Methods
    
    /// Map button string to ButtonType
    private static func mapButtonType(_ buttonString: String) throws -> ButtonType {
        switch buttonString.lowercased() {
        case "home":
            return .home
        case "lock":
            return .lock
        case "volumeup":
            return .volumeUp
        case "volumedown":
            return .volumeDown
        case "siri":
            return .siri
        default:
            throw HIDEventFactoryError.unsupportedButton(buttonString)
        }
    }
}

// MARK: - Button Type Mapping

/// Button types supported by the factory
enum ButtonType {
    case home
    case lock
    case volumeUp
    case volumeDown
    case siri
    
    /// Get the corresponding FBSimulatorHIDButton
    var hidButton: FBSimulatorHIDButton {
        switch self {
        case .home:
            return .homeButton
        case .lock:
            return .lockButton
        case .volumeUp:
            return .volumeUpButton
        case .volumeDown:
            return .volumeDownButton
        case .siri:
            return .siriButton
        }
    }
}

// MARK: - Factory Error Types

enum HIDEventFactoryError: Error, LocalizedError {
    case eventCreationFailed(index: Int, eventId: String?, error: Error)
    case textConversionFailed(text: String, error: Error)
    case unsupportedButton(String)
    
    var errorDescription: String? {
        switch self {
        case .eventCreationFailed(let index, let eventId, let error):
            let idString = eventId.map { " (id: \($0))" } ?? ""
            return "Failed to create event at index \(index)\(idString): \(error.localizedDescription)"
        case .textConversionFailed(let text, let error):
            return "Failed to convert text '\(text)' to HID events: \(error.localizedDescription)"
        case .unsupportedButton(let button):
            return "Unsupported button type: '\(button)'. Supported: home, lock, volumeUp, volumeDown, siri"
        }
    }
}

// MARK: - Execution Mode Support

extension HIDEventFactory {
    
    /// Execution modes for event sequences
    enum ExecutionMode {
        case composite  // Single composite FBSimulatorHIDEvent (single IPC call)
        case sequential // Individual events executed one by one (multiple IPC calls)
        case batch      // Events executed in configurable batches (multiple IPC calls)
    }
    
    /// Prepare events for the specified execution mode
    static func prepareEvents(
        from sequence: EventSequence,
        mode: ExecutionMode,
        batchSize: Int = 10
    ) throws -> EventExecutionPlan {
        
        switch mode {
        case .composite:
            let compositeEvent = try createCompositeHIDEvent(from: sequence)
            return .composite(compositeEvent)
            
        case .sequential:
            let individualEvents = try createHIDEvents(from: sequence)
            return .sequential(individualEvents)
            
        case .batch:
            let individualEvents = try createHIDEvents(from: sequence)
            let batches = individualEvents.chunked(into: batchSize).map { batch in
                batch.count == 1 ? batch[0] : FBSimulatorHIDEvent(events: Array(batch))
            }
            return .batch(batches)
        }
    }
}

/// Represents a plan for executing HID events
enum EventExecutionPlan {
    case composite(FBSimulatorHIDEvent)
    case sequential([FBSimulatorHIDEvent])
    case batch([FBSimulatorHIDEvent])
    
    /// Get the total estimated execution time
    func estimatedExecutionTime() -> TimeInterval {
        switch self {
        case .composite(let event):
            return estimateEventDuration(event)
        case .sequential(let events):
            return events.reduce(0) { total, event in
                total + estimateEventDuration(event)
            }
        case .batch(let events):
            return events.reduce(0) { total, event in
                total + estimateEventDuration(event)
            }
        }
    }
    
    /// Estimate the duration of a single HID event
    private func estimateEventDuration(_ event: FBSimulatorHIDEvent) -> TimeInterval {
        // This is a rough estimation - actual timing depends on the event type
        // For now, we'll use a simple heuristic
        return 0.1 // Default 100ms per event
    }
}

// MARK: - Validation Support

extension HIDEventFactory {
    
    /// Validate that all events in a sequence can be created
    static func validateEventSequence(_ sequence: EventSequence) throws {
        for (index, eventDef) in sequence.events.enumerated() {
            do {
                _ = try createHIDEvent(from: eventDef)
            } catch {
                throw HIDEventFactoryError.eventCreationFailed(
                    index: index,
                    eventId: eventDef.id,
                    error: error
                )
            }
        }
    }
    
    /// Get a summary of events that will be created
    static func getEventSummary(_ sequence: EventSequence) -> EventSequenceSummary {
        var eventCounts: [HIDEventType: Int] = [:]
        var totalEstimatedDuration: TimeInterval = 0
        var hasErrors = false
        var errorMessages: [String] = []
        
        for eventDef in sequence.events {
            eventCounts[eventDef.type, default: 0] += 1
            
            // Add estimated duration
            totalEstimatedDuration += eventDef.preDelay ?? 0
            totalEstimatedDuration += eventDef.postDelay ?? 0
            
            // Add base event duration estimate
            switch eventDef.type {
            case .delay:
                if case .delay(let params) = eventDef.parameters {
                    totalEstimatedDuration += params.duration
                }
            case .swipe, .gesture:
                totalEstimatedDuration += 1.0 // Default swipe duration
            case .touch:
                if case .touch(let params) = eventDef.parameters {
                    totalEstimatedDuration += params.duration ?? 0.1
                }
            default:
                totalEstimatedDuration += 0.1 // Default event duration
            }
            
            // Check for potential errors
            do {
                try eventDef.validate()
            } catch {
                hasErrors = true
                errorMessages.append("Event \(eventDef.id ?? "unknown"): \(error.localizedDescription)")
            }
        }
        
        return EventSequenceSummary(
            totalEvents: sequence.events.count,
            eventCounts: eventCounts,
            estimatedDuration: totalEstimatedDuration,
            hasErrors: hasErrors,
            errorMessages: errorMessages
        )
    }
}

/// Summary information about an event sequence
struct EventSequenceSummary {
    let totalEvents: Int
    let eventCounts: [HIDEventType: Int]
    let estimatedDuration: TimeInterval
    let hasErrors: Bool
    let errorMessages: [String]
    
    /// Get a human-readable description
    func description() -> String {
        var lines: [String] = []
        
        lines.append("Event Sequence Summary:")
        lines.append("  Total Events: \(totalEvents)")
        lines.append("  Estimated Duration: \(String(format: "%.2f", estimatedDuration))s")
        
        if !eventCounts.isEmpty {
            lines.append("  Event Types:")
            for (type, count) in eventCounts.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                lines.append("    \(type.rawValue): \(count)")
            }
        }
        
        if hasErrors {
            lines.append("  Errors:")
            for error in errorMessages {
                lines.append("    - \(error)")
            }
        }
        
        return lines.joined(separator: "\n")
    }
}


// MARK: - Array Extension for Batching

extension Array {
    /// Split array into chunks of specified size
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
