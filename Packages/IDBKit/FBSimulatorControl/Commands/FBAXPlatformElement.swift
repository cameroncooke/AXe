/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@_implementationOnly import AccessibilityPlatformTranslation
import AppKit
import FBControlCore
import Foundation

/// The accessibility attribute + action surface the serializer, translation
/// request, dispatcher, element handle, and facade depend on, expressed in plain
/// value types.
///
/// `AXPMacPlatformElement` is a private-framework class the unit tests cannot
/// subclass, so they previously flowed message-responding doubles through the code
/// via `unsafeBitCast(... to: AXPMacPlatformElement.self)`. Routing the production
/// code through this protocol instead lets both the real element (which conforms via
/// the adapter extension below) and the test doubles participate with no unsafe
/// casts. Expressing it as an adapter — rather than mirroring the overlay's own
/// signatures — also keeps the `NSAccessibility.Role`/`.Action` overlay types out of
/// callers, and folds in the `objc_msgSend`-forcing `as AnyObject` reads, the
/// `accessibilityAttributeValue:` traits reflection, and the children casting.
protocol FBAXPlatformElement: AnyObject {
  func axFrame() -> NSRect
  func axRole() -> String?
  func axLabel() -> String?
  func axValue() -> Any?
  func axIdentifier() -> String?
  func axTitle() -> String?
  func axHelp() -> String?
  func axRoleDescription() -> String?
  func axSubrole() -> String?
  func axPlaceholderValue() -> String?
  func axIsEnabled() -> Bool
  func axIsRequired() -> Bool
  func axIsExpanded() -> Bool
  func axIsHidden() -> Bool
  func axIsFocused() -> Bool
  func axCustomActionNames() -> [String]
  func axActionNames() -> [String]
  func axTraits() -> [String]?
  func axChildren() -> [FBAXPlatformElement]
  func axPerformPress() -> Bool
  func axScroll(_ direction: FBAccessibilityScrollDirection)
  func axSetValue(_ value: Any?)

  /// The pid of the backing translation object (0 when absent).
  var axTranslationPid: pid_t { get }
  func axNativeIdentity() -> FBSimulatorAXNativeIdentity?
  func axNativeIdentityChildren() -> FBAXNativeIdentityChildren
  /// Sets the backing translation object's bridge-delegate token (no-op when absent).
  func axSetBridgeDelegateToken(_ token: String?)
  /// One translator request for several attributes; nil when the adapter cannot batch.
  func axBatchedAttributes(_ names: [String]) -> [String: Any]?
}

extension AXPMacPlatformElement: FBAXPlatformElement {
  func axFrame() -> NSRect { accessibilityFrame() }
  func axRole() -> String? { accessibilityRole()?.rawValue }
  func axLabel() -> String? { accessibilityLabel() }
  func axValue() -> Any? { accessibilityValue() }
  func axIdentifier() -> String? { accessibilityIdentifier() }
  func axTitle() -> String? { accessibilityTitle() }
  func axHelp() -> String? { accessibilityHelp() }
  func axRoleDescription() -> String? { accessibilityRoleDescription() }
  func axSubrole() -> String? { accessibilitySubrole()?.rawValue }
  func axPlaceholderValue() -> String? { accessibilityPlaceholderValue() }
  func axIsEnabled() -> Bool { isAccessibilityEnabled() }
  func axIsRequired() -> Bool { isAccessibilityRequired() }
  func axIsExpanded() -> Bool { isAccessibilityExpanded() }
  func axIsHidden() -> Bool { isAccessibilityHidden() }
  func axIsFocused() -> Bool { isAccessibilityFocused() }
  func axCustomActionNames() -> [String] { (accessibilityCustomActions() ?? []).map { $0.name } }
  func axActionNames() -> [String] {
    // Read by message: the instance `accessibilityActionNames` is shadowed by a
    // class member of the same name on `AXPMacPlatformElement` in this context.
    let selector = NSSelectorFromString("accessibilityActionNames")
    guard responds(to: selector),
      let raw = perform(selector)?.takeUnretainedValue() as? NSArray
    else {
      return []
    }
    return raw.compactMap { $0 as? String }
  }

  func axTraits() -> [String]? {
    // `accessibilityAttributeValue:` is a Swift-unavailable deprecated NSAccessibility
    // API, so read AXTraits by message.
    let selector = NSSelectorFromString("accessibilityAttributeValue:")
    guard responds(to: selector) else {
      return nil
    }
    guard let result = perform(selector, with: "AXTraits")?.takeUnretainedValue() as? NSNumber else {
      return nil
    }
    return Array(AXExtractTraits(result.uint64Value))
  }

  func axChildren() -> [FBAXPlatformElement] {
    (accessibilityChildren() ?? []).compactMap { $0 as? FBAXPlatformElement }
  }

  func axPerformPress() -> Bool { accessibilityPerformPress() }

  func axScroll(_ direction: FBAccessibilityScrollDirection) {
    switch direction {
    case .down:
      performScrollDownByPageAction()
    case .up:
      performScrollUpByPageAction()
    case .left:
      performScrollLeftByPageAction()
    case .right:
      performScrollRightByPageAction()
    case .visible:
      performScrollToVisible()
    }
  }

  func axSetValue(_ value: Any?) { setAccessibilityValue(value) }

  func axNativeIdentity() -> FBSimulatorAXNativeIdentity? {
    guard let translation, translation.pid > 0, translation.objectID > 0 else { return nil }
    return .init(pid: translation.pid, objectID: translation.objectID)
  }

  func axNativeIdentityChildren() -> FBAXNativeIdentityChildren {
    guard let raw = accessibilityChildren() else { return .init(elements: [], reason: "nilChildren") }
    let children = raw.compactMap { $0 as? FBAXPlatformElement }
    return .init(elements: children, reason: children.count == raw.count ? nil : "unsupportedChildType")
  }

  var axTranslationPid: pid_t { translation?.pid ?? 0 }
  func axSetBridgeDelegateToken(_ token: String?) { translation?.bridgeDelegateToken = token }

  func axBatchedAttributes(_ names: [String]) -> [String: Any]? {
    accessibilityMultipleAttributes(names.map { NSAccessibility.Attribute(rawValue: $0) }) as [String: Any]?
  }
}

// Test doubles and other adapters keep the individual accessor reads.
extension FBAXPlatformElement {
  func axBatchedAttributes(_ names: [String]) -> [String: Any]? { nil }
}

// Diagnostic boundary only: the native AX API returns heterogeneous objects.
// Convert once on the owning AX worker; no platform object leaves this method.
extension FBAXPlatformElement {
  func axSliderAdjust(_ action: FBSimulatorSliderAction, deadline: Double) throws {
    guard let native = self as? AXPMacPlatformElement, axActionNames().contains(action.declaredName) else {
      throw FBSimulatorSliderError.unsupportedAction
    }
    try FBSimulatorSliderEndpointController.check(deadline)
    switch action {
    case .increment: native.performIncrementAction()
    case .decrement: native.performDecrementAction()
    }
  }

  func axSliderCapabilityData(token: String) throws -> Data {
    guard let native = self as? AXPMacPlatformElement else {
      throw FBSimulatorAXSnapshotError.invalidSelection
    }
    let namesSelector = NSSelectorFromString("accessibilityAttributeNames")
    let readSelector = NSSelectorFromString("accessibilityAttributeValue:")
    guard native.responds(to: namesSelector), native.responds(to: readSelector),
          let names = native.perform(namesSelector)?.takeUnretainedValue() as? [String] else {
      throw FBSimulatorAXSnapshotError.invalidSelection
    }
    let keys: [NSAccessibility.Attribute] = [.value, .minValue, .maxValue, .allowedValues,
      .valueDescription, .orientation, .children, .contents]
    var attributes: [String: Any] = [:]
    for key in keys {
      try Task.checkCancellation()
      guard names.contains(key.rawValue) else {
        attributes[key.rawValue] = ["state": "notAdvertised"]; continue
      }
      guard let raw = native.perform(readSelector, with: key.rawValue)?.takeUnretainedValue() else {
        attributes[key.rawValue] = ["state": "nil"]; continue
      }
      if key == .children || key == .contents {
        guard let children = raw as? [AXPMacPlatformElement], children.count <= 32 else {
          attributes[key.rawValue] = ["state": "unsupportedCollection", "objectType": String(describing: type(of: raw))]; continue
        }
        let values: [[String: Any]] = children.map { child in
          child.axSetBridgeDelegateToken(token)
          let frame = child.axFrame()
          return ["identifier": child.axIdentifier() ?? NSNull() as Any,
            "role": child.axRole() ?? NSNull() as Any,
            "rawPlatformFrame": ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]]
        }
        attributes[key.rawValue] = ["state": "value", "value": values,
          "geometryMeaning": "Raw platform frame; no thumb/track role inferred"]
      } else if JSONSerialization.isValidJSONObject(["value": raw]) {
        attributes[key.rawValue] = ["state": raw is NSNull ? "null" : "value", "value": raw]
      } else {
        attributes[key.rawValue] = ["state": "unsupportedValue", "objectType": String(describing: type(of: raw))]
      }
    }
    return try JSONSerialization.data(withJSONObject: ["advertisedAttributes": names.sorted(),
      "declaredActions": axActionNames(), "attributes": attributes, "inputDispatched": false,
      "geometryStatus": "unknown; inspect exposed child/contents roles, no thumb inference"], options: [.sortedKeys, .prettyPrinted])
  }
}

// AXDeviceElementToken is a declared AXP attribute. Its simulator payload was
// compared with an independent XCUI native identity before this route was added.
extension FBAXPlatformElement {
  func axSimulatorDeviceToken() throws -> FBAXSimulatorDeviceToken {
    guard let native = self as? AXPMacPlatformElement else {
      throw FBAXNativeSwitchError.rejected("Native simulator element unavailable")
    }
    let read = NSSelectorFromString("accessibilityAttributeValue:")
    guard native.responds(to: read),
          let value = native.perform(read, with: "AXDeviceElementToken")?.takeUnretainedValue() as? NSDictionary,
          value["TokenType"] as? String == "AXElementTokenSimulator",
          let data = value["ElementData"] as? Data else {
      throw FBAXNativeSwitchError.rejected("Native simulator element token unavailable")
    }
    return try FBAXSimulatorDeviceToken(data: data, expectedPID: axTranslationPid)
  }
}

// Existing semantic adapters and test doubles retain their old child behavior.
// Only the verified native adapter can certify complete identity metadata.
extension FBAXPlatformElement {
  func axNativeIdentity() -> FBSimulatorAXNativeIdentity? { nil }
  func axNativeIdentityChildren() -> FBAXNativeIdentityChildren {
    .init(elements: axChildren(), reason: "unsupportedAdapter")
  }
}
