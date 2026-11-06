@_implementationOnly import AccessibilityPlatformTranslation
import AppKit
import Foundation
import MachO

public struct FBSimulatorAXPressTarget: Codable, Sendable, Equatable {
  public let identifier: String
  public let pid: Int32
  public let objectID: String
  public let frame: CGRect
  public let contextID: UInt32
  public let displayID: UInt32
}

/// AXe submits one native action, with no accessibilityPerformPress, HID or mouse fallback.
/// The native action may still produce guest touch events.
public enum FBSimulatorAXSemanticPress {
  public static func perform(for simulator: FBSimulator, expectedPID: Int32, identifier: String,
    observation: FBSimulatorHIDSessionObservation,
    freshnessProvider: any FBSimulatorHIDLiveFreshnessProvider) async throws -> FBSimulatorAXPressReceipt {
    guard expectedPID > 0, !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          identifier.utf8.count <= 4096 else { throw FBSimulatorAXSnapshotError.invalidSelection }
    let reservation = try FBAXTargetReservation.acquire()
    defer { withExtendedLifetime(reservation) {} }
    let budget = FBAXAcquisitionBudget(seconds: 8)
    return await withTaskCancellationHandler(operation: {
      await FBSimulatorAXWorker.shared.semanticPress(for: simulator, expectedPID: expectedPID,
        identifier: identifier, observation: observation, provider: freshnessProvider,
        budget: budget)
    }, onCancel: { budget.stop(.cancelled) })
  }
}

/// Restrict numeric request mapping to the current inspected host image.
/// This checks the loaded image, not a file that might differ from the shared cache.
enum FBAXPressImage {
  static let verifiedUUID = UUID(uuidString: "390A28DA-ADF5-35B0-BC15-9E8C5874E5B4")!
  static func validate() throws {
    let expected = "/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/"
    var matches = 0
    for index in 0..<_dyld_image_count() {
      guard let name = _dyld_get_image_name(index), String(cString: name).hasPrefix(expected),
            String(cString: name).hasSuffix("/AccessibilityPlatformTranslation"),
            let rawHeader = _dyld_get_image_header(index) else { continue }
      matches += 1
      let raw = UnsafeRawPointer(rawHeader)
      let header = raw.load(as: mach_header_64.self)
      guard header.magic == MH_MAGIC_64, header.cputype == CPU_TYPE_ARM64,
            UInt32(bitPattern: header.cpusubtype) & 0x00ff_ffff == 2,
            header.ncmds > 0, header.ncmds <= 4096, header.sizeofcmds <= 1_048_576 else {
        throw FBAXPressError.rejected("Unverified semantic press image architecture")
      }
      var offset = MemoryLayout<mach_header_64>.size
      let end = offset + Int(header.sizeofcmds)
      var uuids: [UUID] = []
      for _ in 0..<header.ncmds {
        guard offset + MemoryLayout<load_command>.size <= end else { throw FBAXPressError.rejected("Malformed image commands") }
        let command = raw.advanced(by: offset).load(as: load_command.self)
        guard Int(command.cmdsize) >= MemoryLayout<load_command>.size, command.cmdsize % 8 == 0,
              Int(command.cmdsize) <= end - offset else { throw FBAXPressError.rejected("Malformed image command size") }
        if command.cmd == LC_UUID {
          guard Int(command.cmdsize) == MemoryLayout<uuid_command>.size else { throw FBAXPressError.rejected("Malformed image UUID") }
          uuids.append(UUID(uuid: raw.advanced(by: offset).load(as: uuid_command.self).uuid))
        }
        offset += Int(command.cmdsize)
      }
      guard offset == end, uuids == [verifiedUUID] else { throw FBAXPressError.rejected("Unverified semantic press image UUID") }
    }
    guard matches == 1 else { throw FBAXPressError.rejected("Semantic press image missing or ambiguous") }
  }
}

/// The same bounded exact-ID search runs before and after the provider await.
/// Closures read typed native children in production; no platform handle escapes the worker.
enum FBAXPressTreeSelection {
  static func exactlyOne<Node: AnyObject>(root: Node, identifier: String,
    check: () throws -> Void, readIdentifier: (Node) throws -> String?,
    readChildren: (Node) throws -> [Node]?) throws -> Node {
    var matches: [Node] = []
    var retained: [Node] = []
    var edges = 0
    func walk(_ node: Node, depth: Int, ancestors: Set<ObjectIdentifier>) throws {
      try check()
      guard depth <= 32, retained.count < 512, !ancestors.contains(ObjectIdentifier(node)) else {
        throw FBAXPressError.rejected("Incomplete semantic target tree")
      }
      retained.append(node)
      if try readIdentifier(node) == identifier { matches.append(node) }
      try check()
      guard let children = try readChildren(node) else {
        throw FBAXPressError.rejected("Unknown semantic target children")
      }
      try check()
      var next = ancestors; next.insert(ObjectIdentifier(node))
      for child in children {
        edges += 1
        guard edges <= 1024 else { throw FBAXPressError.rejected("Semantic target edge limit") }
        try walk(child, depth: depth + 1, ancestors: next)
      }
    }
    try walk(root, depth: 0, ancestors: [])
    guard matches.count == 1, let selected = matches.first else {
      throw FBAXPressError.rejected("Semantic target is missing or ambiguous")
    }
    return selected
  }
}

struct FBAXPressTargetIdentity: Equatable {
  let target: FBSimulatorAXPressTarget
  let rawData: Data?
  func requireSame(as expected: Self) throws {
    guard self == expected else {
      throw FBAXPressError.rejected("Semantic target identity changed after context validation")
    }
  }
}

/// Worker-local owned selection. No native wrapper or translation leaves this class's worker.
final class FBAXSemanticPressSelection {
  private let native: AXPMacPlatformElement
  private let request: FBAXTranslationRequest
  private let dispatcher: FBAXTranslationDispatcher
  private let budget: FBAXAcquisitionBudget
  private let routing: FBAXIdentityRoutingRecorder
  private let identifier: String
  private let pid: Int32
  private let rootContext: UInt32
  private let display: UInt32
  private let originalRawData: Data?
  private let translationIdentity: ObjectIdentifier
  let target: FBSimulatorAXPressTarget

  init(root: FBAXPlatformElement, request: FBAXTranslationRequest, dispatcher: FBAXTranslationDispatcher,
    identifier: String, pid: Int32, rootContext: UInt32, display: UInt32,
    budget: FBAXAcquisitionBudget, routing: FBAXIdentityRoutingRecorder) throws {
    guard let root = root as? AXPMacPlatformElement else { throw FBAXPressError.rejected("Native AX root missing") }
    let native = try FBAXPressTreeSelection.exactlyOne(root: root, identifier: identifier,
      check: { try budget.check(); try Task.checkCancellation() },
      readIdentifier: { node in
        node.axSetBridgeDelegateToken(request.token)
        return node.axIdentifier()
      }, readChildren: { node in
        guard let children = node.accessibilityChildren() else { return nil }
        guard children.count <= 1024 else { throw FBAXPressError.rejected("Semantic target edge limit") }
        return try children.map { child in
          guard let typed = child as? AXPMacPlatformElement else {
            throw FBAXPressError.rejected("Unsupported semantic target child")
          }
          return typed
        }
      })
    let candidateTranslation = native.translation
    let candidateRawData = candidateTranslation?.rawElementData
    guard let translation = candidateTranslation, translation.pid == pid, translation.objectID > 0,
          candidateRawData?.isEmpty != true else {
      let actualPID = candidateTranslation.map { String($0.pid) } ?? "nil"
      let objectID = candidateTranslation.map { String($0.objectID) } ?? "nil"
      let rawDataByteCount = candidateRawData.map { String($0.count) } ?? "nil"
      throw FBAXPressError.rejected(
        "Semantic target is not one direct native identity: " +
        "translationPresent=\(candidateTranslation != nil), actualPID=\(actualPID), " +
        "objectID=\(objectID), rawDataPresent=\(candidateRawData != nil), " +
        "rawDataByteCount=\(rawDataByteCount)")
    }
    self.native = native; self.request = request; self.dispatcher = dispatcher
    self.budget = budget; self.routing = routing; self.identifier = identifier; self.pid = pid
    self.rootContext = rootContext; self.display = display; self.originalRawData = candidateRawData
    self.translationIdentity = ObjectIdentifier(translation)
    target = try Self.read(native, request: request, identifier: identifier, pid: pid,
      context: rootContext, display: display, budget: budget, routing: routing)
  }

  func requireSame(as expected: FBAXSemanticPressSelection) throws {
    try FBAXPressTargetIdentity(target: target, rawData: originalRawData).requireSame(
      as: .init(target: expected.target, rawData: expected.originalRawData))
  }

  private static func read(_ native: AXPMacPlatformElement, request: FBAXTranslationRequest,
    identifier: String, pid: Int32, context: UInt32, display: UInt32,
    budget: FBAXAcquisitionBudget, routing: FBAXIdentityRoutingRecorder) throws -> FBSimulatorAXPressTarget {
    try budget.check(); try Task.checkCancellation()
    guard let translation = native.translation, translation.pid == pid,
          translation.bridgeDelegateToken == request.token,
          native.axIdentifier() == identifier, native.axRole() == NSAccessibility.Role.checkBox.rawValue,
          native.axIsEnabled(), !native.axIsHidden() else {
      throw FBAXPressError.rejected("Semantic CheckBox target changed or is unavailable")
    }
    let frame = native.axFrame()
    guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
          frame.width > 0, frame.height > 0 else { throw FBAXPressError.rejected("Invalid semantic target frame") }
    let raw = try FBAXIdentityRecorder.readRootContext(native, token: request.token, budget: budget, routing: routing)
    guard try positive(raw.windowContext, attribute: "12") == context,
          try positive(raw.display, attribute: "63") == display,
          native.axActionNames().contains(NSAccessibility.Action.press.rawValue) else {
      throw FBAXPressError.rejected("Semantic target context or AXPress declaration differs")
    }
    try budget.check(); try Task.checkCancellation()
    return .init(identifier: identifier, pid: pid, objectID: String(translation.objectID),
      frame: frame, contextID: context, displayID: display)
  }

  static func positive(_ raw: FBAXIdentityAttribute, attribute: String) throws -> UInt32 {
    guard raw.state == "nativeResponse", raw.nativeResponsePresent == true, raw.translatorResponsePresent,
          raw.responseError == "0", raw.responseAttribute == attribute, raw.bridgeObserved,
          raw.firstBridgeSequence == raw.lastBridgeSequence, raw.value.state == "uint32",
          let text = raw.value.decimalValue, let value = UInt32(text), value > 0, String(value) == text else {
      throw FBAXPressError.rejected("Missing positive semantic target context/display")
    }
    return value
  }

  static func validateRootDisplay(_ raw: FBAXIdentityAttribute, selected: UInt32) throws {
    guard selected > 0, raw.state == "nativeResponse", raw.nativeResponsePresent == true,
          raw.translatorResponsePresent, raw.responseError == "0", raw.responseAttribute == "63",
          raw.bridgeObserved, raw.firstBridgeSequence == raw.lastBridgeSequence,
          (raw.value.state == "numericZeroUnknownMeaning" && raw.value.decimalValue == "0") ||
          (raw.value.state == "uint32" && raw.value.decimalValue == String(selected)) else {
      throw FBAXPressError.rejected("Frontmost display conflicts or is unavailable")
    }
  }

  private func requireCurrentIdentity() throws {
    guard try Self.read(native, request: request, identifier: identifier, pid: pid,
      context: rootContext, display: display, budget: budget, routing: routing) == target,
      let translation = native.translation, ObjectIdentifier(translation) == translationIdentity,
      translation.rawElementData == originalRawData else {
      throw FBAXPressError.rejected("Semantic target identity changed during value read")
    }
  }

  func readBooleanState() throws -> Bool {
    try requireCurrentIdentity()
    let value = try FBAXSwitchBoolean.decode(native.axValue())
    try budget.check(); try Task.checkCancellation()
    try requireCurrentIdentity()
    return value
  }

  func send(provider: any FBSimulatorHIDLiveFreshnessProvider,
    observation: FBSimulatorHIDSessionObservation, expectedState: Bool) throws -> FBSimulatorAXPressReceipt {
    try requireCurrentIdentity()
    guard let translation = native.translation,
      let translator = request.translator, translator.supportsDelegateTokens,
      (translator.bridgeTokenDelegate as AnyObject?) === dispatcher,
      let action = AXPTranslatorRequest.request(withTranslation: translation) as? AXPTranslatorRequest else {
      throw FBAXPressError.rejected("Semantic target binding or token delegate changed")
    }
    try FBAXPressImage.validate()
    action.requestType = 7; action.actionType = 5; action.clientType = 2
    guard let binding = FBAXPressBinding.capture(action, token: request.token) else {
      throw FBAXPressError.rejected("Semantic request binding missing")
    }
    let gate = FBAXPressGate(binding: binding) { [budget] in
      try budget.check(); try Task.checkCancellation()
      try provider.validateCurrentRevision(expected: observation)
    }
    guard request.semanticPressGate == nil else { throw FBAXPressError.rejected("Semantic action already armed") }
    guard try readBooleanState() == expectedState else {
      throw FBAXPressError.rejected("Semantic CheckBox value changed before action; no input")
    }
    request.semanticPressGate = gate
    defer { request.semanticPressGate = nil }
    try budget.check(); try provider.validateCurrentRevision(expected: observation)
    try gate.beginTranslatorCall()
    _ = translator.sendRequest(action)
    var receipt = gate.snapshot()
    do {
      try budget.check(); try Task.checkCancellation()
      try provider.validateCurrentRevision(expected: observation)
      guard receipt.callbackCount == 1, receipt.sendCount == 1,
            receipt.delivery == "nativeReplyAccepted" else {
        throw FBAXPressError.rejected("Semantic action lacks one successful native reply; no replay")
      }
    } catch { gate.stop(error); receipt = gate.snapshot() }
    receipt.target = target
    return receipt
  }
}

extension FBSimulatorAXWorker {
  func semanticPress(for simulator: FBSimulator, expectedPID: Int32, identifier: String,
    observation: FBSimulatorHIDSessionObservation, provider: any FBSimulatorHIDLiveFreshnessProvider,
    budget: FBAXAcquisitionBudget) async -> FBSimulatorAXPressReceipt {
    var receipt = FBSimulatorAXPressReceipt()
    var root: FBAccessibilityElement?
    defer { root?.close() }
    do {
      try budget.check(); try Task.checkCancellation(); try FBAXPressImage.validate()
      try await validateSelection(simulator, observation: observation, provider: provider)
      try budget.check()
      let commands = FBSimulatorAccessibilityCommands(simulator: simulator)
      try budget.check(); try Task.checkCancellation()
      try commands.validateAccessibility()
      try budget.check()
      let routing = FBAXIdentityRoutingRecorder()
      func request() -> FBAXTranslationRequest {
        let value = FBAXTranslationRequest(kind: .frontmostApplication,
          pointDisplayID: observation.axDisplayID, displayContext: observation.displayContext)
        value.acquisitionBudget = budget; value.identityRoutingRecorder = routing
        value.semanticPressRequiresSuccessfulReads = true
        return value
      }
      let initialRequest = request()
      let handle = try await commands.accessibilityElementForAcquisition(request: initialRequest, worker: self)
      root = handle
      guard handle.acquisitionPID == expectedPID else { throw FBAXPressError.rejected("Frontmost PID differs") }
      let initialContext = try handle.identityRootContext(budget: budget, routing: routing)
      let context = try FBAXSemanticPressSelection.positive(initialContext.windowContext, attribute: "12")
      try FBAXSemanticPressSelection.validateRootDisplay(initialContext.display, selected: observation.axDisplayID)
      let selected = try handle.semanticPressSelection(identifier: identifier, pid: expectedPID,
        rootContext: context, display: observation.axDisplayID, budget: budget, routing: routing)
      receipt.target = selected.target
      let size = observation.displayContext.logicalSize
      guard CGRect(origin: .zero, size: size).contains(selected.target.frame) else {
        throw FBAXPressError.rejected("Semantic target frame is outside the selected panel")
      }
      try budget.check()
      try await validateSelection(simulator, observation: observation, provider: provider)
      try budget.check()
      // Fresh frontmost identity after the full provider await. No target query retries.
      let finalRoot = try await commands.accessibilityElementForAcquisition(request: request(), worker: self)
      defer { finalRoot.close() }
      func selection(from handle: FBAccessibilityElement) throws -> FBAXSemanticPressSelection {
        guard handle.acquisitionPID == expectedPID else { throw FBAXPressError.rejected("Frontmost PID changed") }
        let currentContext = try handle.identityRootContext(budget: budget, routing: routing)
        try FBAXSemanticPressSelection.validateRootDisplay(currentContext.display, selected: observation.axDisplayID)
        guard currentContext.translationPID == initialContext.translationPID,
              currentContext.translationObjectID == initialContext.translationObjectID,
              try FBAXSemanticPressSelection.positive(currentContext.windowContext, attribute: "12") == context else {
          throw FBAXPressError.rejected("Frontmost window changed")
        }
        let current = try handle.semanticPressSelection(identifier: identifier, pid: expectedPID,
          rootContext: context, display: observation.axDisplayID, budget: budget, routing: routing)
        try current.requireSame(as: selected)
        return current
      }
      let finalSelection = try selection(from: finalRoot)
      let before = try finalSelection.readBooleanState()
      receipt.stateBefore = before
      // The fresh tree's unique target stays owned until the one send returns.
      receipt = try finalSelection.send(provider: provider, observation: observation, expectedState: before)
      receipt.stateBefore = before
      guard receipt.outcome == "nativeReplyAccepted" else { return receipt }
      receipt.readbackCount = 0
      // Read-only samples share the original eight-second transaction budget.
      // A native reply does not authorize a second action, even when no change is seen.
      for attempt in 1...4 {
        try budget.check(); try Task.checkCancellation()
        try await validateSelection(simulator, observation: observation, provider: provider)
        try budget.check()
        let valueRoot = try await commands.accessibilityElementForAcquisition(request: request(), worker: self)
        let after = try {
          defer { valueRoot.close() }
          let current = try selection(from: valueRoot)
          let value = try current.readBooleanState()
          try provider.validateCurrentRevision(expected: observation)
          try budget.check(); try Task.checkCancellation()
          return value
        }()
        receipt.readbackCount = attempt
        receipt.stateAfter = after
        if after != before {
          receipt.outcome = "switchValueChangedObserved"
          return receipt
        }
        if attempt < 4 { try await Task.sleep(nanoseconds: 100_000_000) }
      }
      receipt.outcome = "failedNoReplay"
      receipt.failure = "Semantic CheckBox value did not change after one native press; no replay"
    } catch {
      receipt.failure = String(reflecting: error)
      if receipt.translatorCallAttempted {
        if receipt.delivery != "nativeReplyAccepted" { receipt.delivery = "uncertain" }
        receipt.outcome = "failedNoReplay"
      }
    }
    return receipt
  }
}
