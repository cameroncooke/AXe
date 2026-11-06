import Foundation
import FBControlCore
import ImageIO

public enum FBSimulatorSelectedScreenshotError: Error {
  case invalidRequest
  case changedContext
  case invalidPNG
  case wrongDimensions
}

/// Apple-selected PNG bytes. No IOSurface identity or frame-presentation time is exposed.
public struct FBSimulatorSelectedScreenshot: Sendable {
  public let png: Data
  public let before: FBSimulatorContextReadback
  public let after: FBSimulatorContextReadback
  public let pixelWidth: Int
  public let pixelHeight: Int
  public let child: FBSimulatorScreenshotChildReceipt
}

public struct FBSimulatorScreenshotChildReceipt: Codable, Sendable {
  public let executable: String
  public let arguments: [String]
  public let processIdentifier: Int32?
  public let exitConfirmed: Bool
  public let terminationStatus: Int32?
  public let startedUptime: Double
  public let finishedUptime: Double
  public let stderr: Data

  init(_ receipt: ActivePanelChildReceipt) {
    executable = receipt.executable; arguments = receipt.arguments
    processIdentifier = receipt.processIdentifier; exitConfirmed = receipt.exitConfirmed
    terminationStatus = receipt.terminationStatus
    startedUptime = receipt.startedUptime; finishedUptime = receipt.finishedUptime
    stderr = receipt.stderr
  }
}

public enum FBSimulatorSelectedScreenshotCapture {
  /// One read, no retry or alternate display. The child has a ten-second operation limit;
  /// inherited context reads, cleanup and synchronous ImageIO decoding are additional work.
  /// The caller owns the common device lease until output publication or failure.
  public static func png(for simulator: FBSimulator,
                         screenID: UInt32, screenUniqueID: UUID,
                         expectedBootIdentity: String? = nil) async throws -> FBSimulatorSelectedScreenshot {
    guard expectedBootIdentity == nil || expectedBootIdentity?.isEmpty == false,
          !FBXcodeConfiguration.developerDirectory.isEmpty else {
      throw FBSimulatorSelectedScreenshotError.invalidRequest
    }
    try Task.checkCancellation()
    let reader = FBSimulatorNativeContextReader(simulator: simulator,
      screenID: screenID, screenUniqueID: screenUniqueID)
    let feed = try await FBSimulatorHIDNativeFreshnessProvider.start(for: simulator, authoritativeProvider: reader)
    do {
      let expected = feed.initialObservation
      try FBSelectedScreenshotRules.requireBoot(expected, expectedBootIdentity: expectedBootIdentity)
      let before = try await reader.read()
      try FBSelectedScreenshotRules.requireSame(expected, before.observation.sessionObservation())
      try feed.validateCurrentRevision(expected: expected)
      try Task.checkCancellation()
      let developer = URL(fileURLWithPath: FBXcodeConfiguration.developerDirectory, isDirectory: true)
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent("axe-selected-png-" + UUID().uuidString)
      let output = directory.appendingPathComponent("capture.png")
      var environment = ProcessInfo.processInfo.environment
      environment["DEVELOPER_DIR"] = developer.path
      let arguments = ["io", simulator.udid, "screenshot", "--display=\(screenID)", output.path]
      let command = ActivePanelChildCommand(executable: developer.appendingPathComponent("usr/bin/simctl"),
        arguments: arguments, environment: environment, directory: directory, responseURL: output,
        timeout: 10, maximumBytes: FBSelectedScreenshotRules.maximumBytes)
      // The existing owner reads arbitrary bounded file bytes. Its internal json field contains
      // PNG here; the public receipt omits that field. No process-lifecycle behavior is changed.
      let child = try await OwnedActivePanelChild(command: command).run()
      try Task.checkCancellation()
      try feed.validateCurrentRevision(expected: expected)
      let dimensions = try FBSelectedScreenshotRules.validatePNG(child.json, observation: expected)
      let after = try await reader.read()
      try FBSelectedScreenshotRules.requireSame(expected, after.observation.sessionObservation())
      try feed.validateCurrentRevision(expected: expected)
      try Task.checkCancellation()
      await feed.closeAndWait()
      try Task.checkCancellation()
      return FBSimulatorSelectedScreenshot(png: child.json, before: before, after: after,
        pixelWidth: dimensions.width, pixelHeight: dimensions.height,
        child: FBSimulatorScreenshotChildReceipt(child))
    } catch {
      await feed.closeAndWait()
      // The inherited child error retains unconfirmed cleanup as an error. No PNG is returned.
      throw error
    }
  }
}

enum FBSelectedScreenshotRules {
  static let maximumBytes = 64 * 1024 * 1024

  static func requireBoot(_ observation: FBSimulatorHIDSessionObservation, expectedBootIdentity: String?) throws {
    if let expectedBootIdentity, observation.bootIdentity != expectedBootIdentity {
      throw FBSimulatorSelectedScreenshotError.changedContext
    }
  }

  static func requireSame(_ expected: FBSimulatorHIDSessionObservation,
                          _ actual: FBSimulatorHIDSessionObservation) throws {
    guard expected == actual else { throw FBSimulatorSelectedScreenshotError.changedContext }
  }

  static func validatePNG(_ data: Data, observation: FBSimulatorHIDSessionObservation) throws -> (width: Int, height: Int) {
    let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    let end: [UInt8] = [0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130]
    guard data.count >= 33, data.count <= maximumBytes,
          data.prefix(signature.count).elementsEqual(signature), data.suffix(end.count).elementsEqual(end),
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          CGImageSourceGetCount(source) == 1,
          CGImageSourceGetType(source).map({ CFEqual($0, "public.png" as CFString) }) == true,
          CGImageSourceGetStatus(source) == .statusComplete,
          CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
      throw FBSimulatorSelectedScreenshotError.invalidPNG
    }
    let context = observation.displayContext
    let swapped = context.rotation == .rot90 || context.rotation == .rot270
    let size = context.nativePixelSize
    let width = swapped ? size.height : size.width
    let height = swapped ? size.width : size.height
    guard width.isFinite, height.isFinite, width > 0, height > 0,
          width.rounded() == width, height.rounded() == height,
          width * height <= 64_000_000,
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: NSObject],
          (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue == Double(width),
          (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue == Double(height) else {
      throw FBSimulatorSelectedScreenshotError.wrongDimensions
    }
    guard let image = CGImageSourceCreateImageAtIndex(source, 0,
      [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
      image.width == Int(width), image.height == Int(height) else {
      throw FBSimulatorSelectedScreenshotError.invalidPNG
    }
    // simctl returns upright pixels. Do not rotate the decoded image again.
    return (image.width, image.height)
  }
}
