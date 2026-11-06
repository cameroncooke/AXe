/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

/// An exact ID must identify one TextField, even when containers inherit that ID.
/// Count fields before filtering focus, process or state so duplicate fields cannot select themselves.
struct FBAXFocusedTextFieldSelection {
  let identifier: String
  private(set) var matchingCount = 0

  mutating func include(identifier actual: String?, role: String?) throws -> Bool {
    guard actual == identifier, role == "AXTextField" || role == "TextField" else { return false }
    matchingCount += 1
    guard matchingCount == 1 else {
      throw FBSimulatorAXSnapshotError.ambiguous(count: matchingCount)
    }
    return true
  }

  func validate(_ field: FBSimulatorAXNode, expectedPID: Int32) throws {
    guard matchingCount == 1, expectedPID > 0,
          !identifier.isEmpty, identifier.utf8.count <= 4096,
          identifier == identifier.trimmingCharacters(in: .whitespacesAndNewlines),
          field.identifier == identifier, field.pid == expectedPID, field.type == "TextField",
          field.focused == true, field.enabled == true, field.hidden == false,
          let frame = field.frame, frame.origin.x.isFinite, frame.origin.y.isFinite,
          frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else {
      throw FBSimulatorAXTargetError.targetMismatch
    }
  }
}

/// Opaque uniqueness is counted before any role, focus, owner or state filter.
struct FBAXFocusedNativeTextFieldSelection {
  let identity: FBSimulatorAXNativeIdentity
  private(set) var matchingCount = 0

  mutating func include(identity actual: FBSimulatorAXNativeIdentity?) throws -> Bool {
    guard actual == identity else { return false }
    matchingCount += 1
    guard matchingCount == 1 else { throw FBSimulatorAXSnapshotError.ambiguous(count: matchingCount) }
    return true
  }

  func validate(_ field: FBSimulatorAXNode, expectedPID: Int32, logicalSize: CGSize) throws {
    try identity.validate()
    guard matchingCount == 1, identity.pid == expectedPID, field.nativeIdentity == identity,
          field.identifier?.isEmpty != false, field.pid == expectedPID,
          field.type == "TextField", field.role == "AXTextField",
          field.focused == true, field.enabled == true, field.hidden == false,
          logicalSize.width.isFinite, logicalSize.height.isFinite, logicalSize.width > 0, logicalSize.height > 0,
          let frame = field.frame, frame.origin.x.isFinite, frame.origin.y.isFinite,
          frame.size.width.isFinite, frame.size.height.isFinite, frame.size.width > 0, frame.size.height > 0,
          CGRect(origin: .zero, size: logicalSize).contains(frame) else {
      throw FBSimulatorAXTargetError.targetMismatch
    }
  }
}
