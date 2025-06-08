import Foundation

// MARK: - Event Sequence Models

/// Represents a sequence of HID events to be executed
struct EventSequence: Codable {
    /// Metadata about the sequence
    let metadata: SequenceMetadata?
    
    /// Array of events to execute in order
    let events: [HIDEventDefinition]
    
    /// Global settings for the sequence
    let settings: SequenceSettings?
    
    init(events: [HIDEventDefinition], metadata: SequenceMetadata? = nil, settings: SequenceSettings? = nil) {
        self.events = events
        self.metadata = metadata
        self.settings = settings
    }
}

/// Metadata about an event sequence
struct SequenceMetadata: Codable {
    /// Human-readable name for the sequence
    let name: String?
    
    /// Description of what the sequence does
    let description: String?
    
    /// Version of the sequence format
    let version: String?
    
    /// Author or creator of the sequence
    let author: String?
    
    /// Tags for categorizing sequences
    let tags: [String]?
}

/// Global settings for sequence execution
struct SequenceSettings: Codable {
    /// Default delay between events (in seconds)
    let defaultDelay: Double?
    
    /// Whether to stop execution on first error
    let stopOnError: Bool?
    
    /// Maximum total execution time (in seconds)
    let maxExecutionTime: Double?
    
    /// Whether to validate all events before execution
    let validateBeforeExecution: Bool?
    
    init(defaultDelay: Double? = nil, stopOnError: Bool? = nil, maxExecutionTime: Double? = nil, validateBeforeExecution: Bool? = nil) {
        self.defaultDelay = defaultDelay
        self.stopOnError = stopOnError
        self.maxExecutionTime = maxExecutionTime
        self.validateBeforeExecution = validateBeforeExecution
    }
}

/// Represents a single HID event in a sequence
struct HIDEventDefinition: Codable {
    /// Type of the event
    let type: HIDEventType
    
    /// Parameters specific to the event type
    let parameters: HIDEventParameters
    
    /// Delay before executing this event (in seconds)
    let preDelay: Double?
    
    /// Delay after executing this event (in seconds)
    let postDelay: Double?
    
    /// Optional identifier for this event (for debugging/logging)
    let id: String?
    
    /// Optional description of what this event does
    let description: String?
}

/// Types of HID events supported
enum HIDEventType: String, Codable, CaseIterable {
    case tap = "tap"
    case swipe = "swipe"
    case type = "type"
    case key = "key"
    case keySequence = "key_sequence"
    case button = "button"
    case touch = "touch"
    case delay = "delay"
    case gesture = "gesture"
}

/// Parameters for different event types
enum HIDEventParameters: Codable {
    case tap(TapParameters)
    case swipe(SwipeParameters)
    case type(TypeParameters)
    case key(KeyParameters)
    case keySequence(KeySequenceParameters)
    case button(ButtonParameters)
    case touch(TouchParameters)
    case delay(DelayParameters)
    case gesture(GestureParameters)
    
    // MARK: - Codable Implementation
    
    private enum CodingKeys: String, CodingKey {
        case type
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(HIDEventType.self, forKey: .type)
        
        switch type {
        case .tap:
            self = .tap(try TapParameters(from: decoder))
        case .swipe:
            self = .swipe(try SwipeParameters(from: decoder))
        case .type:
            self = .type(try TypeParameters(from: decoder))
        case .key:
            self = .key(try KeyParameters(from: decoder))
        case .keySequence:
            self = .keySequence(try KeySequenceParameters(from: decoder))
        case .button:
            self = .button(try ButtonParameters(from: decoder))
        case .touch:
            self = .touch(try TouchParameters(from: decoder))
        case .delay:
            self = .delay(try DelayParameters(from: decoder))
        case .gesture:
            self = .gesture(try GestureParameters(from: decoder))
        }
    }
    
    func encode(to encoder: Encoder) throws {
        switch self {
        case .tap(let params):
            try params.encode(to: encoder)
        case .swipe(let params):
            try params.encode(to: encoder)
        case .type(let params):
            try params.encode(to: encoder)
        case .key(let params):
            try params.encode(to: encoder)
        case .keySequence(let params):
            try params.encode(to: encoder)
        case .button(let params):
            try params.encode(to: encoder)
        case .touch(let params):
            try params.encode(to: encoder)
        case .delay(let params):
            try params.encode(to: encoder)
        case .gesture(let params):
            try params.encode(to: encoder)
        }
    }
}

// MARK: - Event Parameter Definitions

struct TapParameters: Codable {
    let x: Double
    let y: Double
}

struct SwipeParameters: Codable {
    let startX: Double
    let startY: Double
    let endX: Double
    let endY: Double
    let duration: Double?
    let delta: Double?
}

struct TypeParameters: Codable {
    let text: String
}

struct KeyParameters: Codable {
    let keycode: Int
    let duration: Double?
}

struct KeySequenceParameters: Codable {
    let keycodes: [Int]
    let delay: Double?
}

struct ButtonParameters: Codable {
    let button: String // "home", "lock", "volumeUp", "volumeDown", "siri"
    let duration: Double?
}

struct TouchParameters: Codable {
    let x: Double
    let y: Double
    let duration: Double?
}

struct DelayParameters: Codable {
    let duration: Double
}

struct GestureParameters: Codable {
    let startX: Double
    let startY: Double
    let endX: Double
    let endY: Double
    let duration: Double?
    let delta: Double?
}

// MARK: - Validation Extensions

extension EventSequence {
    /// Validates the entire event sequence
    func validate() throws {
        // Validate global settings
        try settings?.validate()
        
        // Validate each event
        for (index, event) in events.enumerated() {
            do {
                try event.validate()
            } catch {
                throw EventSequenceError.invalidEvent(index: index, error: error)
            }
        }
        
        // Validate sequence constraints
        if events.isEmpty {
            throw EventSequenceError.emptySequence
        }
        
        if events.count > 1000 {
            throw EventSequenceError.sequenceTooLong(count: events.count)
        }
    }
}

extension SequenceSettings {
    func validate() throws {
        if let defaultDelay = defaultDelay {
            guard defaultDelay >= 0 && defaultDelay <= 60.0 else {
                throw EventSequenceError.invalidDefaultDelay(defaultDelay)
            }
        }
        
        if let maxExecutionTime = maxExecutionTime {
            guard maxExecutionTime > 0 && maxExecutionTime <= 3600.0 else {
                throw EventSequenceError.invalidMaxExecutionTime(maxExecutionTime)
            }
        }
    }
}

extension HIDEventDefinition {
    func validate() throws {
        // Validate delays
        if let preDelay = preDelay {
            guard preDelay >= 0 && preDelay <= 60.0 else {
                throw EventSequenceError.invalidDelay("preDelay", preDelay)
            }
        }
        
        if let postDelay = postDelay {
            guard postDelay >= 0 && postDelay <= 60.0 else {
                throw EventSequenceError.invalidDelay("postDelay", postDelay)
            }
        }
        
        // Validate parameters based on type
        try parameters.validate()
    }
}

extension HIDEventParameters {
    func validate() throws {
        switch self {
        case .tap(let params):
            try params.validate()
        case .swipe(let params):
            try params.validate()
        case .type(let params):
            try params.validate()
        case .key(let params):
            try params.validate()
        case .keySequence(let params):
            try params.validate()
        case .button(let params):
            try params.validate()
        case .touch(let params):
            try params.validate()
        case .delay(let params):
            try params.validate()
        case .gesture(let params):
            try params.validate()
        }
    }
}

// MARK: - Parameter Validation

extension TapParameters {
    func validate() throws {
        guard x >= 0, y >= 0 else {
            throw EventSequenceError.invalidCoordinates(x: x, y: y)
        }
    }
}

extension SwipeParameters {
    func validate() throws {
        guard startX >= 0, startY >= 0, endX >= 0, endY >= 0 else {
            throw EventSequenceError.invalidCoordinates(x: startX, y: startY)
        }
        
        if let duration = duration {
            guard duration > 0 && duration <= 10.0 else {
                throw EventSequenceError.invalidDuration(duration)
            }
        }
        
        if let delta = delta {
            guard delta > 0 else {
                throw EventSequenceError.invalidDelta(delta)
            }
        }
    }
}

extension TypeParameters {
    func validate() throws {
        guard !text.isEmpty else {
            throw EventSequenceError.emptyText
        }
        
        // Validate that text can be converted to HID events
        guard TextToHIDEvents.validateText(text) else {
            throw EventSequenceError.unsupportedText(text)
        }
    }
}

extension KeyParameters {
    func validate() throws {
        guard keycode >= 0 && keycode <= 255 else {
            throw EventSequenceError.invalidKeycode(keycode)
        }
        
        if let duration = duration {
            guard duration > 0 && duration <= 10.0 else {
                throw EventSequenceError.invalidDuration(duration)
            }
        }
    }
}

extension KeySequenceParameters {
    func validate() throws {
        guard !keycodes.isEmpty else {
            throw EventSequenceError.emptyKeySequence
        }
        
        for keycode in keycodes {
            guard keycode >= 0 && keycode <= 255 else {
                throw EventSequenceError.invalidKeycode(keycode)
            }
        }
        
        if let delay = delay {
            guard delay >= 0 && delay <= 5.0 else {
                throw EventSequenceError.invalidDelay("keySequenceDelay", delay)
            }
        }
    }
}

extension ButtonParameters {
    func validate() throws {
        let validButtons = ["home", "lock", "volumeUp", "volumeDown", "siri"]
        guard validButtons.contains(button) else {
            throw EventSequenceError.invalidButton(button)
        }
        
        if let duration = duration {
            guard duration > 0 && duration <= 10.0 else {
                throw EventSequenceError.invalidDuration(duration)
            }
        }
    }
}

extension TouchParameters {
    func validate() throws {
        guard x >= 0, y >= 0 else {
            throw EventSequenceError.invalidCoordinates(x: x, y: y)
        }
        
        if let duration = duration {
            guard duration > 0 && duration <= 10.0 else {
                throw EventSequenceError.invalidDuration(duration)
            }
        }
    }
}

extension DelayParameters {
    func validate() throws {
        guard duration > 0 && duration <= 60.0 else {
            throw EventSequenceError.invalidDuration(duration)
        }
    }
}

extension GestureParameters {
    func validate() throws {
        guard startX >= 0, startY >= 0, endX >= 0, endY >= 0 else {
            throw EventSequenceError.invalidCoordinates(x: startX, y: startY)
        }
        
        if let duration = duration {
            guard duration > 0 && duration <= 10.0 else {
                throw EventSequenceError.invalidDuration(duration)
            }
        }
        
        if let delta = delta {
            guard delta > 0 else {
                throw EventSequenceError.invalidDelta(delta)
            }
        }
    }
}

// MARK: - Error Types

enum EventSequenceError: Error, LocalizedError {
    case emptySequence
    case sequenceTooLong(count: Int)
    case invalidEvent(index: Int, error: Error)
    case invalidDefaultDelay(Double)
    case invalidMaxExecutionTime(Double)
    case invalidDelay(String, Double)
    case invalidCoordinates(x: Double, y: Double)
    case invalidDuration(Double)
    case invalidDelta(Double)
    case emptyText
    case unsupportedText(String)
    case invalidKeycode(Int)
    case emptyKeySequence
    case invalidButton(String)
    
    var errorDescription: String? {
        switch self {
        case .emptySequence:
            return "Event sequence cannot be empty"
        case .sequenceTooLong(let count):
            return "Event sequence too long: \(count) events (maximum: 1000)"
        case .invalidEvent(let index, let error):
            return "Invalid event at index \(index): \(error.localizedDescription)"
        case .invalidDefaultDelay(let delay):
            return "Invalid default delay: \(delay) (must be between 0 and 60 seconds)"
        case .invalidMaxExecutionTime(let time):
            return "Invalid max execution time: \(time) (must be between 0 and 3600 seconds)"
        case .invalidDelay(let type, let delay):
            return "Invalid \(type): \(delay) (must be between 0 and 60 seconds)"
        case .invalidCoordinates(let x, let y):
            return "Invalid coordinates: (\(x), \(y)) (must be non-negative)"
        case .invalidDuration(let duration):
            return "Invalid duration: \(duration) (must be between 0 and 10 seconds)"
        case .invalidDelta(let delta):
            return "Invalid delta: \(delta) (must be greater than 0)"
        case .emptyText:
            return "Text cannot be empty"
        case .unsupportedText(let text):
            return "Text contains unsupported characters: \(text)"
        case .invalidKeycode(let keycode):
            return "Invalid keycode: \(keycode) (must be between 0 and 255)"
        case .emptyKeySequence:
            return "Key sequence cannot be empty"
        case .invalidButton(let button):
            return "Invalid button: \(button) (valid: home, lock, volumeUp, volumeDown, siri)"
        }
    }
}

