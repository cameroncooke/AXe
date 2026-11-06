/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import Foundation

/// The core, transport-agnostic HID value types. Every transport (Indigo, DTUHID) and the
/// `FBSimulatorHIDEvent` dispatch share these; they are intentionally independent of any one
/// transport's wire format. Each carries a single canonical `name` — the source of truth for the
/// string forms used in event descriptions and (upper-cased) in CLI arguments.

/// The direction of a HID event.
public enum FBSimulatorHIDDirection: Int32, Sendable, CaseIterable {
  case down = 1
  case up = 2

  /// The canonical lower-snake-case name for this direction.
  public var name: String {
    switch self {
    case .down: return "down"
    case .up: return "up"
    }
  }
}

/// A hardware button press.
public enum FBSimulatorHIDButton: Int32, Sendable, CaseIterable {
  case applePay = 1
  case homeButton = 2
  case lock = 3
  case sideButton = 4
  case siri = 5

  /// The canonical lower-snake-case name for this button.
  public var name: String {
    switch self {
    case .applePay: return "apple_pay"
    case .homeButton: return "home"
    case .lock: return "lock"
    case .sideButton: return "side_button"
    case .siri: return "siri"
    }
  }
}

/// Device orientation. Values match UIDeviceOrientation (1-4, excluding faceUp/faceDown).
public enum FBSimulatorHIDDeviceOrientation: Int32, Sendable, CaseIterable {
  case portrait = 1
  case portraitUpsideDown = 2
  case landscapeRight = 3
  case landscapeLeft = 4

  /// The canonical lower-snake-case name for this orientation.
  public var name: String {
    switch self {
    case .portrait: return "portrait"
    case .portraitUpsideDown: return "portrait_upside_down"
    case .landscapeRight: return "landscape_right"
    case .landscapeLeft: return "landscape_left"
    }
  }
}

/// Guest CADisplay currentOrientation, independent of requested device orientation.
public enum FBSimulatorHIDDisplayRotation: Int, Sendable, CaseIterable {
  case rot0 = 0
  case rot90 = 90
  case rot180 = 180
  case rot270 = 270
}

/// Invalid measured display geometry or an input outside the selected logical display.
public enum FBSimulatorHIDDisplayContextError: Error, LocalizedError {
  case invalidGeometry
  case pointOutsideDisplay

  public var errorDescription: String? {
    switch self {
    case .invalidGeometry:
      return "Display pixel size and scale must be finite and positive"
    case .pointOutsideDisplay:
      return "Touch point must be finite and inside the selected logical display"
    }
  }
}

/// Immutable measured context for one display-targeted HID connection.
/// The caller must refresh it after display, boot or orientation changes. The HID target is a
/// modern digitizer target, not an AX display ID or a legacy Indigo target mask.
public struct FBSimulatorHIDDisplayContext: Equatable, Sendable {
  public let hidTarget: UInt64
  public let nativePixelSize: CGSize
  public let scale: Double
  public let rotation: FBSimulatorHIDDisplayRotation

  public init(
    hidTarget: UInt64, nativePixelSize: CGSize, scale: Double,
    rotation: FBSimulatorHIDDisplayRotation
  ) throws {
    guard nativePixelSize.width.isFinite, nativePixelSize.height.isFinite,
          nativePixelSize.width > 0, nativePixelSize.height > 0,
          scale.isFinite, scale > 0,
          (Double(nativePixelSize.width) / scale).isFinite,
          (Double(nativePixelSize.height) / scale).isFinite,
          Double(nativePixelSize.width) / scale > 0,
          Double(nativePixelSize.height) / scale > 0 else {
      throw FBSimulatorHIDDisplayContextError.invalidGeometry
    }
    self.hidTarget = hidTarget
    self.nativePixelSize = nativePixelSize
    self.scale = scale
    self.rotation = rotation
  }

  /// Current oriented display size in logical points, with a top-left origin.
  public var logicalSize: CGSize {
    let native = CGSize(width: nativePixelSize.width / scale, height: nativePixelSize.height / scale)
    switch rotation {
    case .rot0, .rot180: return native
    case .rot90, .rot270: return CGSize(width: native.height, height: native.width)
    }
  }

  /// Converts an oriented logical point to the panel-native normalized digitizer coordinates.
  /// These quarter-turn transforms were checked against guest CADisplay readback in the Duo
  /// routing audit. Points are rejected rather than clamped or silently sent to another display.
  public func normalizedPoint(from point: CGPoint) throws -> CGPoint {
    let size = logicalSize
    guard point.x.isFinite, point.y.isFinite,
          point.x >= 0, point.y >= 0, point.x <= size.width, point.y <= size.height else {
      throw FBSimulatorHIDDisplayContextError.pointOutsideDisplay
    }
    let width = nativePixelSize.width / scale
    let height = nativePixelSize.height / scale
    switch rotation {
    case .rot0: return CGPoint(x: point.x / width, y: point.y / height)
    case .rot90: return CGPoint(x: point.y / width, y: 1 - point.x / height)
    case .rot180: return CGPoint(x: 1 - point.x / width, y: 1 - point.y / height)
    case .rot270: return CGPoint(x: 1 - point.y / width, y: point.x / height)
    }
  }
}
