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
