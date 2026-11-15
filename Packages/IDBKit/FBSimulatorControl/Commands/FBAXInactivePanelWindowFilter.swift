import CoreSimulator
import Foundation

/// On a two-panel device SpringBoard lists the top-level windows of both panels under the
/// frontmost application, so every Home-screen control appears twice and no ref can be unique
/// (issue #87). Each of those windows exactly covers one panel. A top-level window at the origin
/// whose size is another integrated panel's, in points or pixels and in either orientation,
/// belongs to that panel and is left out of the active panel's tree.
struct FBAXInactivePanelWindowFilter: Equatable {
  struct Panel: Equatable {
    let screenID: UInt32
    let pixelSize: CGSize
    let scale: Double
  }

  let excludedSizes: [CGSize]

  /// Nil on a single-panel device, for an unknown active panel, or when every other panel
  /// shares the active panel's size, since no window could then be attributed to a panel.
  init?(panels: [Panel], activeScreenID: UInt32) {
    guard panels.count > 1, let active = panels.first(where: { $0.screenID == activeScreenID }) else {
      return nil
    }
    let kept = Self.sizes(of: active)
    var excluded: [CGSize] = []
    for size in panels.filter({ $0.screenID != activeScreenID }).flatMap(Self.sizes)
      where !kept.contains(size) && !excluded.contains(size) {
      excluded.append(size)
    }
    guard !excluded.isEmpty else { return nil }
    excludedSizes = excluded
  }

  func excludes(_ frame: CGRect) -> Bool {
    frame.origin == .zero && excludedSizes.contains(frame.size)
  }

  private static func sizes(of panel: Panel) -> [CGSize] {
    let pixels = panel.pixelSize
    let points = CGSize(width: pixels.width / panel.scale, height: pixels.height / panel.scale)
    return [pixels, points].flatMap { [$0, CGSize(width: $0.height, height: $0.width)] }
  }
}

/// On a quarter-turned panel SpringBoard's top-level windows keep the panel's native portrait
/// size, and every frame inside them is in native points, while app windows report oriented
/// frames (issue #87; measured on the iPhone Duo's inner panel in landscape). Such a window is
/// at the origin with exactly the panel's native point size; its subtree is converted with the
/// inverse of `FBSimulatorHIDDisplayContext.normalizedPoint(from:)`. Half turns keep the window
/// shape, so they cannot be recognised and are left alone.
struct FBAXPanelFrameTransform: Equatable {
  let nativeSize: CGSize
  let rotation: FBSimulatorHIDDisplayRotation

  init?(context: FBSimulatorHIDDisplayContext) {
    guard context.rotation == .rot90 || context.rotation == .rot270 else { return nil }
    nativeSize = CGSize(width: context.nativePixelSize.width / context.scale,
      height: context.nativePixelSize.height / context.scale)
    rotation = context.rotation
  }

  /// A window covering the panel in native orientation. Oriented windows are transposed.
  func isNativeWindow(_ frame: CGRect) -> Bool {
    frame.origin == .zero && frame.size == nativeSize
  }

  func isOrientedWindow(_ frame: CGRect) -> Bool {
    frame.origin == .zero && frame.size == CGSize(width: nativeSize.height, height: nativeSize.width)
  }

  func logicalPoint(_ point: CGPoint) -> CGPoint {
    switch rotation {
    case .rot90: return CGPoint(x: nativeSize.height - point.y, y: point.x)
    case .rot270: return CGPoint(x: point.y, y: nativeSize.width - point.x)
    case .rot0, .rot180: return point
    }
  }

  /// A zero frame is a structural element without geometry and stays zero.
  func logicalFrame(_ frame: CGRect) -> CGRect {
    guard [frame.origin.x, frame.origin.y, frame.width, frame.height].allSatisfy(\.isFinite),
          frame != .zero else { return frame }
    switch rotation {
    case .rot90:
      return CGRect(x: nativeSize.height - frame.maxY, y: frame.minX, width: frame.height, height: frame.width)
    case .rot270:
      return CGRect(x: frame.minY, y: nativeSize.width - frame.maxX, width: frame.height, height: frame.width)
    case .rot0, .rot180:
      return frame
    }
  }
}

/// What a two-panel or rotated read does with the frontmost application's direct children.
struct FBAXPanelWindowRules: Equatable {
  let filter: FBAXInactivePanelWindowFilter?
  let transform: FBAXPanelFrameTransform?

  init?(filter: FBAXInactivePanelWindowFilter?, transform: FBAXPanelFrameTransform?) {
    guard filter != nil || transform != nil else { return nil }
    self.filter = filter
    self.transform = transform
  }

  /// Nil leaves another panel's window out. Otherwise the transform for the window's subtree.
  func window(rawFrame: CGRect) -> FBAXPanelSubtree? {
    if filter?.excludes(rawFrame) == true { return nil }
    return FBAXPanelSubtree(transform: transform?.isNativeWindow(rawFrame) == true ? transform : nil)
  }
}

struct FBAXPanelSubtree: Equatable {
  let transform: FBAXPanelFrameTransform?
}

/// One selected read of a frontmost application on a two-panel or quarter-turned display.
///
/// SpringBoard lists Home-screen icon views of one panel inside the other panel's windows: the
/// same objects appear under both panels' icon lists with the first panel's frames, while the
/// views drawn on the other panel are absent from the tree (#87). Only SpringBoard lists another
/// panel's windows, so only a read whose root has such a window asks each button for its AX
/// display (one request per button) and leaves out a button drawn on another display. A missing
/// or zero display is unknown and kept.
final class FBAXPanelRead {
  let rules: FBAXPanelWindowRules
  let activeDisplayID: UInt32
  private let processKey: FBAXNativeFrameProcesses.DisplayKey?
  private(set) var checksButtonDisplays = false

  init(rules: FBAXPanelWindowRules, activeDisplayID: UInt32, processKey: FBAXNativeFrameProcesses.DisplayKey?) {
    self.rules = rules
    self.activeDisplayID = activeDisplayID
    self.processKey = processKey
  }

  /// Called once with the root's direct children before any of them is serialized.
  func prepare(pid: pid_t, windowFrames: [CGRect]) {
    if let filter = rules.filter { checksButtonDisplays = windowFrames.contains(where: filter.excludes) }
    // Just after boot the application can list no windows yet; that is no classification to keep.
    if let transform = rules.transform, let processKey, pid > 0, !windowFrames.isEmpty {
      FBAXNativeFrameProcesses.record(FBAXNativeFrameProcesses.classify(windowFrames, transform: transform),
        for: processKey.process(pid))
    }
  }

  func subtree(_ element: FBAXPlatformElement, attributes: FBAXElementAttributes, depth: Int,
    inherited: FBAXPanelFrameTransform?) -> FBAXPanelSubtree? {
    if depth == 1 { return rules.window(rawFrame: attributes.rawFrame()) }
    guard depth >= 2, checksButtonDisplays, attributes.role() == "AXButton",
          let display = element.axDisplayID(), display > 0, display != activeDisplayID else {
      return FBAXPanelSubtree(transform: inherited)
    }
    return nil
  }
}

/// Which application processes draw native-oriented windows on a quarter-turned display. A point
/// read has no window ancestry, so it converts a hit's frames only for a process whose panel-sized
/// windows were all native-oriented when its tree was last read (SpringBoard on the Duo's inner
/// panel); app processes draw oriented windows. A process with both, or none, is left unchanged.
enum FBAXNativeFrameProcesses {
  enum Space: Equatable { case native, oriented, mixed }

  struct DisplayKey: Hashable {
    let device: String
    let displayID: UInt32
    let rotation: FBSimulatorHIDDisplayRotation
    func process(_ pid: pid_t) -> ProcessKey { ProcessKey(display: self, pid: pid) }
  }

  struct ProcessKey: Hashable {
    let display: DisplayKey
    let pid: pid_t
  }

  nonisolated(unsafe) private static var spaces: [ProcessKey: Space] = [:]
  private static let lock = NSLock()

  static func classify(_ windowFrames: [CGRect], transform: FBAXPanelFrameTransform) -> Space {
    let native = windowFrames.contains(where: transform.isNativeWindow)
    let oriented = windowFrames.contains(where: transform.isOrientedWindow)
    if native && !oriented { return .native }
    if oriented && !native { return .oriented }
    return .mixed
  }

  static func record(_ space: Space, for key: ProcessKey) {
    lock.lock()
    defer { lock.unlock() }
    if spaces.count > 64 { spaces.removeAll() }
    spaces[key] = space
  }

  static func space(for key: ProcessKey) -> Space? {
    lock.lock()
    defer { lock.unlock() }
    return spaces[key]
  }
}

/// The integrated touch panels a device type declares, read once per device type bundle.
enum FBAXIntegratedPanelCatalog {
  nonisolated(unsafe) private static var cache: [String: [FBAXInactivePanelWindowFilter.Panel]] = [:]
  private static let lock = NSLock()

  static func panels(for device: SimDevice) -> [FBAXInactivePanelWindowFilter.Panel] {
    guard let url = device.deviceType?.bundle?.url(forResource: "capabilities", withExtension: "plist") else {
      return []
    }
    lock.lock()
    defer { lock.unlock() }
    if let cached = cache[url.path] { return cached }
    let panels = (try? Data(contentsOf: url)).flatMap { try? decode($0) } ?? []
    cache[url.path] = panels
    return panels
  }

  static func decode(_ data: Data) throws -> [FBAXInactivePanelWindowFilter.Panel] {
    try PropertyListDecoder().decode(CapabilityFile.self, from: data).capabilities.displays
      .filter { $0.displayType == "integrated" && $0.hasDigitizer }
      .compactMap { display in
        guard let width = display.width, let height = display.height, let scale = display.scale,
              width > 0, height > 0, scale > 0 else { return nil }
        return .init(screenID: display.screenID, pixelSize: CGSize(width: width, height: height), scale: scale)
      }
  }

  private struct CapabilityFile: Decodable {
    let capabilities: Capabilities
    struct Capabilities: Decodable { let displays: [Display] }
    struct Display: Decodable {
      let displayType: String
      let hasDigitizer: Bool
      let screenID: UInt32
      let width: Double?
      let height: Double?
      let scale: Double?
    }
  }
}
