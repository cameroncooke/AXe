import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import FBSimulatorControl

@Suite("Selected screenshot PNG admission")
struct FBSimulatorSelectedScreenshotTests {
  private func observation(_ rotation: FBSimulatorHIDDisplayRotation = .rot0,
                           boot: String = "boot-1", screen: UInt32 = 3,
                           pose: String = "open") throws -> FBSimulatorHIDSessionObservation {
    try .init(simulatorUDID: "test", bootIdentity: boot, screenID: screen,
      screenUniqueID: "769ED878-389B-4346-9C56-CB0703AB3E58", axDisplayID: screen,
      displayContext: .init(hidTarget: UInt64(screen), nativePixelSize: CGSize(width: 2, height: 3),
        scale: 1, rotation: rotation), poseRevision: pose)
  }

  private func encoded(_ width: Int, _ height: Int, type: String = "public.png") throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try #require(context.makeImage())
    let bytes = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(bytes, type as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return bytes as Data
  }

  @Test func acceptsCompletePNGWithoutChangingItsGeometry() throws {
    let bytes = try encoded(2, 3)
    let dimensions = try FBSelectedScreenshotRules.validatePNG(bytes, observation: observation())
    #expect(dimensions.width == 2 && dimensions.height == 3)
  }

  @Test func quarterTurnsRequireAlreadyUprightPixels() throws {
    for rotation in [FBSimulatorHIDDisplayRotation.rot90, .rot270] {
      let dimensions = try FBSelectedScreenshotRules.validatePNG(encoded(3, 2), observation: observation(rotation))
      #expect(dimensions.width == 3 && dimensions.height == 2)
      #expect(throws: (any Error).self) {
        _ = try FBSelectedScreenshotRules.validatePNG(encoded(2, 3), observation: observation(rotation))
      }
    }
  }

  @Test func rejectsOtherFormatTruncatedAndWrongSize() throws {
    let complete = try encoded(2, 3)
    for bytes in [try encoded(2, 3, type: "public.jpeg"), Data(complete.dropLast()),
                  try encoded(3, 3), Data("not an image".utf8)] {
      #expect(throws: (any Error).self) {
        _ = try FBSelectedScreenshotRules.validatePNG(bytes, observation: observation())
      }
    }
  }

  @Test func exactContextRejectsBootPanelPoseAndSameSizeRotationChanges() throws {
    let expected = try observation()
    try FBSelectedScreenshotRules.requireSame(expected, expected)
    for value in [try observation(boot: "boot-2"), try observation(screen: 1),
                  try observation(pose: "folded"), try observation(.rot180)] {
      #expect(throws: (any Error).self) { try FBSelectedScreenshotRules.requireSame(expected, value) }
    }
  }

  @Test func optionalExpectedBootNeverReplacesMeasuredBoot() throws {
    let expected = try observation()
    try FBSelectedScreenshotRules.requireBoot(expected, expectedBootIdentity: nil)
    try FBSelectedScreenshotRules.requireBoot(expected, expectedBootIdentity: "boot-1")
    #expect(throws: (any Error).self) {
      try FBSelectedScreenshotRules.requireBoot(expected, expectedBootIdentity: "boot-2")
    }
  }
}
