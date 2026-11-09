/*
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@_implementationOnly @preconcurrency import AccessibilityPlatformTranslation
import FBControlCore
import Foundation

/// Converts one validated pushed archive through the same translator used by simulator reads.
public enum FBPhysicalAXTreeProjection {
  public struct Entry: Sendable {
    let requestType: UInt64
    let pid: Int32?
    let objectID: UInt64?
    let attribute: UInt64

    public init(requestType: UInt64, pid: Int32?, objectID: UInt64?, attribute: UInt64) {
      self.requestType = requestType
      self.pid = pid
      self.objectID = objectID
      self.attribute = attribute
    }
  }

  public struct LiveRequest: Sendable {
    public let archive: Data
    public let requestType: UInt64
    public let attribute: UInt64
    public let pid: Int32
    public let objectID: UInt64
  }

  public struct PressTarget: Equatable, Sendable {
    public let identifier: String
    public let pid: Int32
    public let objectID: UInt64
    public let path: [Int]
    public let frame: CGRect
    public let value: Bool

    public func matchesReadback(_ other: Self) -> Bool {
      identifier == other.identifier && pid == other.pid && path == other.path && frame == other.frame
    }
  }

  public struct PreparedPress: Sendable {
    public let target: PressTarget
    public let request: LiveRequest
  }

  public static func json(archive: Data, entries: [Entry],
                          forward: ((LiveRequest) throws -> Data)? = nil) throws -> Data {
    try withTree(archive: archive, entries: entries, forward: forward) { element, token in
      let keys = FBAXKeys.defaultSet.union([.pid, .hidden, .enabled, .frameDict])
      let descriptions = try FBSimulatorAccessibilitySerializer.recursiveDescription(
        fromElement: element, token: token, nestedFormat: true, keys: keys,
        collector: nil, coverageGrid: nil, seenPids: nil
      )
      return try JSONSerialization.data(withJSONObject: descriptions, options: [.sortedKeys])
    }
  }

  public static func preparePress(archive: Data, entries: [Entry], identifier: String,
                                  displayBounds: CGRect) throws -> PreparedPress {
    try withTree(archive: archive, entries: entries, forward: nil) { root, token in
      var matches: [(AXPMacPlatformElement, [Int], Bool)] = []
      func visit(_ element: FBAXPlatformElement, path: [Int], visible: Bool) throws {
        try Task.checkCancellation()
        element.axSetBridgeDelegateToken(token)
        let visible = visible && !element.axIsHidden()
        if element.axIdentifier() == identifier, let native = element as? AXPMacPlatformElement {
          matches.append((native, path, visible))
        }
        for (index, child) in element.axChildren().enumerated() {
          try visit(child, path: path + [index], visible: visible)
        }
      }
      try visit(root, path: [], visible: true)
      guard matches.count == 1, let (element, path, visible) = matches.first,
            visible, element.axIsEnabled(), element.axRole() == "AXCheckBox",
            element.axActionNames().contains("AXPress"), let translation = element.translation,
            translation.pid > 0, translation.objectID > 0,
            let value = booleanValue(element.axValue()) else {
        throw ProjectionError.invalidPressTarget
      }
      let frame = element.axFrame()
      guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
            frame.width > 0, frame.height > 0, displayBounds.contains(frame),
            let request = AXPTranslatorRequest.request(withTranslation: translation) as? AXPTranslatorRequest else {
        throw ProjectionError.invalidPressTarget
      }
      request.requestType = 7
      request.actionType = 5
      request.clientType = 2
      let target = PressTarget(identifier: identifier, pid: translation.pid, objectID: translation.objectID,
                               path: path, frame: frame, value: value)
      return PreparedPress(target: target, request: try liveRequest(for: request))
    }
  }

  public static func acceptedPressReply(_ data: Data) throws -> Bool {
    let response = try decodeResponse(data)
    return response.error == 0 && response.boolResponse
  }

  private static func withTree<T>(archive: Data, entries: [Entry],
                                  forward: ((LiveRequest) throws -> Data)?,
                                  _ body: (FBAXPlatformElement, String) throws -> T) throws -> T {
    try Task.checkCancellation()
    let tree = try Tree(archive: archive, entries: entries)
    let bridge = LiveBridge(tree: tree, forward: forward)
    let dispatcher = FBSimulator.sharedAccessibilityTranslationDispatcher
    return try dispatcher.withPhysicalTree(answer: bridge.response) { translator, token in
      tree.root.bridgeDelegateToken = token
      guard let element = translator.macPlatformElement(fromTranslation: tree.root) as? FBAXPlatformElement else {
        throw ProjectionError.invalidArchive
      }
      let value = try body(element, token)
      try bridge.check()
      return value
    }
  }

  private static func booleanValue(_ value: Any?) -> Bool? {
    if let number = value as? NSNumber {
      switch number.doubleValue {
      case 0: return false
      case 1: return true
      default: return nil
      }
    }
    if let value = value as? String {
      switch value {
      case "0": return false
      case "1": return true
      default: return nil
      }
    }
    return nil
  }

  private static func liveRequest(for request: AXPTranslatorRequest) throws -> LiveRequest {
    guard let target = request.translation, target.pid > 0, target.objectID > 0 else {
      throw ProjectionError.invalidPressTarget
    }
    let data = try NSKeyedArchiver.archivedData(withRootObject: request, requiringSecureCoding: true)
    return LiveRequest(archive: data, requestType: request.requestType, attribute: request.attributeType,
                       pid: target.pid, objectID: target.objectID)
  }

  private static func decodeResponse(_ data: Data) throws -> AXPTranslatorResponse {
    let decoder = try NSKeyedUnarchiver(forReadingFrom: data)
    decoder.requiresSecureCoding = true
    decoder.decodingFailurePolicy = .setErrorAndReturn
    let response = decoder.decodeObject(of: AXPTranslatorResponse.self, forKey: NSKeyedArchiveRootObjectKey)
    decoder.finishDecoding()
    guard decoder.error == nil, let response else { throw ProjectionError.invalidArchive }
    return response
  }

  private final class LiveBridge {
    /// `AXPAttributeCustomActions`.
    private static let customActionsAttribute: UInt64 = 13
    private let tree: Tree
    private let forward: ((LiveRequest) throws -> Data)?
    private let lock = NSLock()
    private var error: Error?

    init(tree: Tree, forward: ((LiveRequest) throws -> Data)?) {
      self.tree = tree
      self.forward = forward
    }

    func check() throws {
      if let error = lock.withLock({ self.error }) { throw error }
    }

    func response(to request: AXPTranslatorRequest?) -> AXPTranslatorResponse? {
      if let cached = tree.response(to: request) { return cached }
      let empty = AXPTranslatorResponse.empty() as? AXPTranslatorResponse
      guard let request, let forward, request.translation != nil,
            request.requestType == 2 || request.requestType == 3 else { return empty }
      // Custom actions missing from the pushed tree are treated as none. With the iPad software keyboard
      // up, each key asked for them live, about 45 ms apiece, and the read exceeded its time bound.
      if request.requestType == 2, request.attributeType == Self.customActionsAttribute { return empty }
      do {
        try check()
        let live = try FBPhysicalAXTreeProjection.liveRequest(for: request)
        return try FBPhysicalAXTreeProjection.decodeResponse(forward(live))
      } catch {
        lock.withLock { self.error = error }
        return empty
      }
    }
  }

  private enum ProjectionError: LocalizedError {
    case invalidArchive
    case invalidPressTarget

    var errorDescription: String? {
      switch self {
      case .invalidArchive:
        "The physical accessibility tree could not be read by the platform translator."
      case .invalidPressTarget:
        "Physical semantic press requires one visible, enabled AXCheckBox with AXPress and a Boolean value."
      }
    }
  }

  private struct Identity: Hashable {
    let pid: Int32
    let objectID: UInt64

    init?(pid: Int32?, objectID: UInt64?) {
      guard let pid, let objectID, pid > 0, objectID != 0 else { return nil }
      self.pid = pid
      self.objectID = objectID
    }
  }

  private struct Tree {
    private typealias Value = NSObjectProtocol & NSCopying & NSSecureCoding

    let root: AXPTranslationObject
    private let rootResponse: AXPTranslatorResponse
    private let attributes: [Identity: [UInt64: Value]]
    private let canSet: [Identity: [UInt64: AXPTranslatorResponse]]
    private let global: [UInt64: AXPTranslatorResponse]

    init(archive: Data, entries: [Entry]) throws {
      let envelope = try FBPhysicalAXTreeProjection.decodeResponse(archive)
      guard let payload = envelope.resultData as? NSDictionary,
            let responses = payload["treeDump"] as? [AXPTranslatorResponse],
            responses.count == entries.count else { throw ProjectionError.invalidArchive }

      var rootResponse: AXPTranslatorResponse?
      var attributes: [Identity: [UInt64: Value]] = [:]
      var canSet: [Identity: [UInt64: AXPTranslatorResponse]] = [:]
      var global: [UInt64: AXPTranslatorResponse] = [:]
      for (entry, response) in zip(entries, responses) {
        try Task.checkCancellation()
        let identity = Identity(pid: entry.pid, objectID: entry.objectID)
        switch entry.requestType {
        case 4:
          guard rootResponse == nil, let translation = response.translationResponse,
                let identity, translation.pid == identity.pid, translation.objectID == identity.objectID else {
            throw ProjectionError.invalidArchive
          }
          rootResponse = response
        case 5:
          guard let identity, let values = response.resultData as? NSDictionary else {
            throw ProjectionError.invalidArchive
          }
          for (key, value) in values {
            guard let number = key as? NSNumber, let value = value as? Value else {
              throw ProjectionError.invalidArchive
            }
            attributes[identity, default: [:]][number.uint64Value] = value
          }
        case 3:
          if let identity { canSet[identity, default: [:]][entry.attribute] = response }
        case 2:
          if let identity, let value = response.resultData {
            attributes[identity, default: [:]][entry.attribute] = value
          } else if identity == nil {
            global[entry.attribute] = response
          }
        default: break
        }
      }

      guard let rootResponse, let root = rootResponse.translationResponse else {
        throw ProjectionError.invalidArchive
      }
      self.root = root
      self.rootResponse = rootResponse
      self.attributes = attributes
      self.canSet = canSet
      self.global = global
    }

    func response(to request: AXPTranslatorRequest?) -> AXPTranslatorResponse? {
      guard let request else { return nil }
      let identity = Identity(pid: request.translation?.pid, objectID: request.translation?.objectID)
      let attribute = request.attributeType
      switch request.requestType {
      case 4: return rootResponse
      case 2:
        if let identity, let value = attributes[identity]?[attribute] {
          let response = AXPTranslatorResponse()
          response.attribute = attribute
          response.resultData = value
          return response
        }
        if identity == nil, let response = global[attribute] { return response }
      case 3:
        if let identity, let response = canSet[identity]?[attribute] { return response }
      case 5:
        if let identity, let values = attributes[identity] {
          let response = AXPTranslatorResponse()
          response.resultData = Dictionary(uniqueKeysWithValues: values.map { (NSNumber(value: $0.key), $0.value) }) as NSDictionary
          return response
        }
      default: break
      }
      return nil
    }
  }
}
