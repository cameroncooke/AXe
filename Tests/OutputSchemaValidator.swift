import Foundation

/// A JSON value. The validator keeps its own type, without AXe's, so the Playground checks
/// package, which copies test sources and does not link AXe, can use it.
indirect enum OutputSchemaJSON: Codable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case unsignedInteger(UInt64)
    case floatingPoint(Double)
    case string(String)
    case array([OutputSchemaJSON])
    case object([String: OutputSchemaJSON])

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }
        else if let decoded = try? value.decode(Int64.self) { self = .integer(decoded) }
        else if let decoded = try? value.decode(UInt64.self) { self = .unsignedInteger(decoded) }
        else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
        else if let decoded = try? value.decode(Double.self) { self = .floatingPoint(decoded) }
        else if let decoded = try? value.decode([OutputSchemaJSON].self) { self = .array(decoded) }
        else { self = .object(try value.decode([String: OutputSchemaJSON].self)) }
    }

    init(json data: Data) throws {
        self = try JSONDecoder().decode(OutputSchemaJSON.self, from: data)
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case let .bool(decoded): try value.encode(decoded)
        case let .integer(decoded): try value.encode(decoded)
        case let .unsignedInteger(decoded): try value.encode(decoded)
        case let .floatingPoint(decoded): try value.encode(decoded)
        case let .string(decoded): try value.encode(decoded)
        case let .array(decoded): try value.encode(decoded)
        case let .object(decoded): try value.encode(decoded)
        }
    }

    subscript(_ key: String) -> OutputSchemaJSON? {
        guard case let .object(values) = self else { return nil }
        return values[key]
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var arrayValue: [OutputSchemaJSON]? {
        guard case let .array(value) = self else { return nil }
        return value
    }
}

/// Validates AXe JSON output against the published schemas in `schemas/`.
///
/// It supports only the JSON Schema 2020-12 keywords those schemas use and rejects any other
/// keyword, so a schema cannot rely on a rule that is silently skipped here. In strict mode an
/// object whose schema lists `properties` without `additionalProperties` may not carry other
/// fields: the published schemas let consumers ignore new fields, but AXe's own tests require
/// every emitted field to be declared.
struct OutputSchemaValidator: Sendable {
    struct SchemaError: Error, CustomStringConvertible {
        let description: String
    }

    private static let annotations: Set<String> = ["$schema", "$id", "$comment", "$defs", "title", "description"]
    private static let assertions: Set<String> = [
        "$ref", "type", "const", "enum", "properties", "required", "additionalProperties", "items",
        "prefixItems", "minItems", "maxItems", "minimum", "pattern", "oneOf", "anyOf",
        "if", "then", "else", "not",
    ]

    let root: OutputSchemaJSON

    init(schema: OutputSchemaJSON) throws {
        root = schema
        try Self.checkKeywords(schema, path: "#")
    }

    /// Returns one message per violation, each prefixed with the instance path.
    func validate(_ instance: OutputSchemaJSON, strict: Bool) -> [String] {
        var errors: [String] = []
        check(instance, against: root, path: "$", strict: strict, errors: &errors)
        return errors
    }

    private static func checkKeywords(_ schema: OutputSchemaJSON, path: String) throws {
        if case .bool = schema { return }
        guard case let .object(fields) = schema else {
            throw SchemaError(description: "\(path): a schema must be an object or a boolean.")
        }
        for (keyword, value) in fields {
            guard annotations.contains(keyword) || assertions.contains(keyword) else {
                throw SchemaError(description: "\(path): unsupported keyword \(keyword).")
            }
            switch keyword {
            case "$defs", "properties":
                guard case let .object(children) = value else {
                    throw SchemaError(description: "\(path)/\(keyword) must be an object.")
                }
                for (name, child) in children { try checkKeywords(child, path: "\(path)/\(keyword)/\(name)") }
            case "items", "additionalProperties", "if", "then", "else", "not":
                try checkKeywords(value, path: "\(path)/\(keyword)")
            case "prefixItems", "oneOf", "anyOf":
                guard let children = value.arrayValue, !children.isEmpty else {
                    throw SchemaError(description: "\(path)/\(keyword) must be a non-empty array.")
                }
                for (index, child) in children.enumerated() { try checkKeywords(child, path: "\(path)/\(keyword)/\(index)") }
            case "$ref":
                guard let reference = value.stringValue, reference.hasPrefix("#/$defs/") else {
                    throw SchemaError(description: "\(path): only local #/$defs/ references are supported.")
                }
            case "pattern":
                guard let pattern = value.stringValue, (try? NSRegularExpression(pattern: pattern)) != nil else {
                    throw SchemaError(description: "\(path): invalid pattern.")
                }
            default:
                break
            }
        }
    }

    private func resolve(_ reference: String) -> OutputSchemaJSON? {
        let name = String(reference.dropFirst("#/$defs/".count))
        return root["$defs"]?[name]
    }

    private func check(_ instance: OutputSchemaJSON, against schema: OutputSchemaJSON, path: String, strict: Bool,
                       errors: inout [String]) {
        if case let .bool(allowed) = schema {
            if !allowed { errors.append("\(path): no value is allowed here.") }
            return
        }
        if let reference = schema["$ref"]?.stringValue {
            guard let target = resolve(reference) else {
                errors.append("\(path): unresolved reference \(reference).")
                return
            }
            check(instance, against: target, path: path, strict: strict, errors: &errors)
        }
        if let type = schema["type"] {
            let names = type.arrayValue?.compactMap(\.stringValue) ?? [type.stringValue].compactMap { $0 }
            guard names.contains(where: { Self.matches(instance, type: $0) }) else {
                errors.append("\(path): expected \(names.joined(separator: " or ")), found \(Self.typeName(instance)).")
                return
            }
        }
        if let constant = schema["const"], !Self.equal(instance, constant) {
            errors.append("\(path): expected \(Self.describe(constant)), found \(Self.describe(instance)).")
        }
        if let options = schema["enum"]?.arrayValue, !options.contains(where: { Self.equal(instance, $0) }) {
            errors.append("\(path): \(Self.describe(instance)) is not one of \(options.map(Self.describe).joined(separator: ", ")).")
        }
        if let minimum = schema["minimum"].flatMap(Self.number), let value = Self.number(instance), value < minimum {
            errors.append("\(path): \(value) is below the minimum \(minimum).")
        }
        if let pattern = schema["pattern"]?.stringValue, let text = instance.stringValue,
           let expression = try? NSRegularExpression(pattern: pattern),
           expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil {
            errors.append("\(path): \(Self.describe(instance)) does not match \(pattern).")
        }
        if case let .object(fields) = instance { checkObject(fields, schema: schema, path: path, strict: strict, errors: &errors) }
        if case let .array(elements) = instance { checkArray(elements, schema: schema, path: path, strict: strict, errors: &errors) }
        if let branches = schema["oneOf"]?.arrayValue {
            let results = branches.map { branch -> [String] in
                var branchErrors: [String] = []
                check(instance, against: branch, path: path, strict: strict, errors: &branchErrors)
                return branchErrors
            }
            let passed = results.filter(\.isEmpty).count
            if passed > 1 { errors.append("\(path): matched \(passed) oneOf branches, expected 1.") }
            // Report the branch the value came closest to, not every branch's mismatches.
            if passed == 0 { errors += results.min { $0.count < $1.count } ?? [] }
        }
        // `if` and `not` only test a condition, so they never report undeclared fields.
        if let condition = schema["if"] {
            var conditionErrors: [String] = []
            check(instance, against: condition, path: path, strict: false, errors: &conditionErrors)
            if let branch = conditionErrors.isEmpty ? schema["then"] : schema["else"] {
                check(instance, against: branch, path: path, strict: strict, errors: &errors)
            }
        }
        if let negated = schema["not"] {
            var negatedErrors: [String] = []
            check(instance, against: negated, path: path, strict: false, errors: &negatedErrors)
            if negatedErrors.isEmpty { errors.append("\(path): matches a schema it must not match.") }
        }
        if let branches = schema["anyOf"]?.arrayValue {
            let results = branches.map { branch -> [String] in
                var branchErrors: [String] = []
                check(instance, against: branch, path: path, strict: strict, errors: &branchErrors)
                return branchErrors
            }
            if !results.contains(where: \.isEmpty) { errors += results.min { $0.count < $1.count } ?? [] }
        }
    }

    private func checkObject(_ fields: [String: OutputSchemaJSON], schema: OutputSchemaJSON, path: String, strict: Bool,
                             errors: inout [String]) {
        for name in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where fields[name] == nil {
            errors.append("\(path): missing required field \(name).")
        }
        guard case let .object(properties)? = schema["properties"] else {
            if let extra = schema["additionalProperties"] {
                for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
                    check(value, against: extra, path: "\(path).\(name)", strict: strict, errors: &errors)
                }
            }
            return
        }
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            if let property = properties[name] {
                check(value, against: property, path: "\(path).\(name)", strict: strict, errors: &errors)
            } else if let extra = schema["additionalProperties"] {
                check(value, against: extra, path: "\(path).\(name)", strict: strict, errors: &errors)
            } else if strict {
                errors.append("\(path): field \(name) is not declared in the schema.")
            }
        }
    }

    private func checkArray(_ elements: [OutputSchemaJSON], schema: OutputSchemaJSON, path: String, strict: Bool,
                            errors: inout [String]) {
        if let minimum = schema["minItems"].flatMap(Self.number), Double(elements.count) < minimum {
            errors.append("\(path): \(elements.count) items, expected at least \(Int(minimum)).")
        }
        if let maximum = schema["maxItems"].flatMap(Self.number), Double(elements.count) > maximum {
            errors.append("\(path): \(elements.count) items, expected at most \(Int(maximum)).")
        }
        let prefix = schema["prefixItems"]?.arrayValue ?? []
        for (index, element) in elements.enumerated() {
            if index < prefix.count {
                check(element, against: prefix[index], path: "\(path)[\(index)]", strict: strict, errors: &errors)
            } else if let items = schema["items"] {
                check(element, against: items, path: "\(path)[\(index)]", strict: strict, errors: &errors)
            }
        }
    }

    private static func matches(_ value: OutputSchemaJSON, type: String) -> Bool {
        switch (type, value) {
        case ("null", .null), ("boolean", .bool), ("string", .string), ("array", .array), ("object", .object):
            return true
        case ("number", _):
            return number(value) != nil
        case ("integer", .integer), ("integer", .unsignedInteger):
            return true
        case ("integer", _):
            return number(value).map { $0.rounded() == $0 } ?? false
        default:
            return false
        }
    }

    private static func number(_ value: OutputSchemaJSON) -> Double? {
        switch value {
        case let .integer(number): return Double(number)
        case let .unsignedInteger(number): return Double(number)
        case let .floatingPoint(number): return number
        default: return nil
        }
    }

    private static func equal(_ left: OutputSchemaJSON, _ right: OutputSchemaJSON) -> Bool {
        if let left = number(left), let right = number(right) { return left == right }
        switch (left, right) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.array(a), .array(b)): return a.count == b.count && zip(a, b).allSatisfy { equal($0, $1) }
        case let (.object(a), .object(b)):
            return a.count == b.count && a.allSatisfy { key, value in b[key].map { equal(value, $0) } ?? false }
        default: return false
        }
    }

    private static func typeName(_ value: OutputSchemaJSON) -> String {
        switch value {
        case .null: return "null"
        case .bool: return "boolean"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        case .integer, .unsignedInteger, .floatingPoint: return "number"
        }
    }

    private static func describe(_ value: OutputSchemaJSON) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return typeName(value) }
        let text = String(decoding: data, as: UTF8.self)
        return text.count > 80 ? String(text.prefix(77)) + "..." : text
    }
}

/// The published output schemas, chosen by each result's `schema` and `schemaVersion`.
enum OutputSchemas {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("schemas")

    /// Schema file names keyed by "schema/schemaVersion".
    static let files = [
        "axe.output.agent-result/1": "axe.output.agent-result.v1.schema.json",
        "axe.output.agent-result/2": "axe.output.agent-result.v2.schema.json",
        "axe.output.command-result/1": "axe.output.command-result.v1.schema.json",
    ]

    private static let loaded: Result<[String: OutputSchemaValidator], OutputSchemaValidator.SchemaError> = {
        do {
            var validators: [String: OutputSchemaValidator] = [:]
            for (key, file) in files {
                let data = try Data(contentsOf: directory.appendingPathComponent(file))
                validators[key] = try OutputSchemaValidator(schema: JSONDecoder().decode(OutputSchemaJSON.self, from: data))
            }
            return .success(validators)
        } catch {
            return .failure(OutputSchemaValidator.SchemaError(description: "Cannot load output schemas: \(error)"))
        }
    }()

    /// Per-command `data.result` definitions, keyed by the envelope's `command`.
    static let payloadFile = "axe.output.command-payloads.v1.schema.json"

    private static let payloads: Result<[String: OutputSchemaJSON], OutputSchemaValidator.SchemaError> = {
        do {
            let schema = try OutputSchemaJSON(json: Data(contentsOf: directory.appendingPathComponent(payloadFile)))
            _ = try OutputSchemaValidator(schema: schema)
            guard case let .object(definitions)? = schema["$defs"] else {
                throw OutputSchemaValidator.SchemaError(description: "The payload schema has no $defs.")
            }
            return .success(definitions)
        } catch let error as OutputSchemaValidator.SchemaError {
            return .failure(error)
        } catch {
            return .failure(OutputSchemaValidator.SchemaError(description: "Cannot load the payload schema: \(error)"))
        }
    }()

    static func payloadDefinitions() throws -> [String: OutputSchemaJSON] { try payloads.get() }

    /// Strictly validates one success payload against `$defs[command]`; returns the violations.
    static func validatePayload(command: String, result: OutputSchemaJSON) throws -> [String] {
        let definitions = try payloadDefinitions()
        guard definitions[command] != nil else {
            throw OutputSchemaValidator.SchemaError(description: "The payload schema does not describe \(command).")
        }
        let root = OutputSchemaJSON.object(["$defs": .object(definitions), "$ref": .string("#/$defs/" + command)])
        return try OutputSchemaValidator(schema: root).validate(result, strict: true)
    }

    static func validator(schema: String, version: String) throws -> OutputSchemaValidator? {
        try loaded.get()["\(schema)/\(version)"]
    }

    /// Strictly validates one AXe result. Throws for an unknown schema or version and for any violation.
    static func validate(_ result: OutputSchemaJSON) throws {
        guard let schema = result["schema"]?.stringValue, schema.hasPrefix("axe.output.") else { return }
        let version = result["schemaVersion"]?.stringValue ?? "missing"
        guard let validator = try validator(schema: schema, version: version) else {
            throw OutputSchemaValidator.SchemaError(description: "No published schema for \(schema) version \(version).")
        }
        let errors = validator.validate(result, strict: true)
        guard errors.isEmpty else {
            throw OutputSchemaValidator.SchemaError(description:
                "\(schema) version \(version) does not match its published schema:\n" + errors.joined(separator: "\n"))
        }
    }

    /// Strictly validates every complete JSON line of command output that is an AXe result.
    /// Other lines, including partial lines from an interrupted process, are ignored.
    static func validate(output: String) throws {
        for line in output.split(separator: "\n") where line.first == "{" && line.contains("\"axe.output.") {
            guard let value = try? OutputSchemaJSON(json: Data(line.utf8)) else { continue }
            try validate(value)
        }
    }
}
