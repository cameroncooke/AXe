import Foundation
import FBSimulatorControl

/// Private reference authority. Semantic and native-object modes never fall back to each other.
/// Native UInt64 values use the native type's decimal-string Codable contract.
enum SelectedNativeTarget: Codable, Sendable, Equatable {
    case semantic(kind: SelectedAXRequest.SelectorKind, value: String, elementType: String?)
    case nativeObject(identity: FBSimulatorAXNativeIdentity, elementType: String)

    var semanticID: String? {
        guard case let .semantic(kind, value, _) = self, kind == .id else { return nil }
        return value
    }

    var nativeIdentity: FBSimulatorAXNativeIdentity? {
        guard case let .nativeObject(identity, _) = self else { return nil }
        return identity
    }

    var elementType: String? {
        switch self {
        case let .semantic(_, _, type): return type
        case let .nativeObject(_, type): return type
        }
    }

    func validate() throws {
        switch self {
        case let .semantic(_, value, type):
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.utf8.count <= 4096 else {
                throw SelectedHIDFailure.invalid("The semantic target must contain bounded native selector text.")
            }
            if let type { try Self.validateType(type) }
        case let .nativeObject(identity, type):
            try identity.validate()
            try Self.validateType(type)
        }
    }

    func nativeSelector() throws -> FBSimulatorAXSelector {
        try validate()
        switch self {
        case let .nativeObject(identity, type):
            return .nativeObject(identity: identity, elementType: type)
        case let .semantic(kind, value, type):
            switch kind {
            case .id:
                if let type { return .identifierWithType(value, elementType: type) }
                return .identifier(value)
            case .label:
                if let type { return .labelWithType(value, elementType: type) }
                return .label(value)
            case .value:
                if let type { return .valueWithType(value, elementType: type) }
                return .value(value)
            }
        }
    }

    private static func validateType(_ type: String) throws {
        guard !type.isEmpty, type.utf8.count <= 256,
              type == type.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw SelectedHIDFailure.invalid("The native target requires one exact bounded element type.")
        }
    }
}
