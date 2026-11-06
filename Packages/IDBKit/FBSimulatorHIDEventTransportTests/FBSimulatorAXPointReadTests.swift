import CoreGraphics
import Foundation
import Testing
@testable import FBSimulatorControl

@Suite("Selected AX point read rules")
struct FBSimulatorAXPointReadTests {
  private func observation(_ rotation: FBSimulatorHIDDisplayRotation = .rot0,
                           boot: String = "boot-1", screen: UInt32 = 3,
                           uuid: String = "769ED878-389B-4346-9C56-CB0703AB3E58",
                           pose: String = "open") throws -> FBSimulatorHIDSessionObservation {
    try .init(simulatorUDID: "test", bootIdentity: boot, screenID: screen,
      screenUniqueID: uuid, axDisplayID: screen,
      displayContext: .init(hidTarget: UInt64(screen), nativePixelSize: CGSize(width: 2007, height: 2853),
        scale: 3, rotation: rotation), poseRevision: pose)
  }

  @Test func pointReadUsesExistingNativeAXTransform() throws {
    let cases: [(FBSimulatorHIDDisplayRotation, CGPoint, CGPoint)] = [
      (.rot0, CGPoint(x: 150, y: 325), CGPoint(x: 150, y: 325)),
      (.rot90, CGPoint(x: 150, y: 250), CGPoint(x: 250, y: 801)),
      (.rot180, CGPoint(x: 150, y: 325), CGPoint(x: 519, y: 626)),
      (.rot270, CGPoint(x: 150, y: 250), CGPoint(x: 419, y: 150))
    ]
    for (rotation, logical, expected) in cases {
      let actual = try FBAXPointReadRules.nativePoint(logical, observation: observation(rotation))
      #expect(abs(actual.x - expected.x) < 0.000001)
      #expect(abs(actual.y - expected.y) < 0.000001)
    }
  }

  @Test func pointReadRejectsOutsideAndNonfiniteCoordinates() throws {
    let selected = try observation(.rot90)
    for point in [CGPoint(x: -1, y: 0), CGPoint(x: 951, y: 0), CGPoint(x: 0, y: 669),
                  CGPoint(x: CGFloat.nan, y: 20), CGPoint(x: 20, y: CGFloat.infinity)] {
      #expect(throws: (any Error).self) { _ = try FBAXPointReadRules.nativePoint(point, observation: selected) }
    }
  }

  @Test func bothForegroundBracketsRequireExactPositivePID() throws {
    try FBAXPointReadRules.frontmost(42, expectedPID: 42)
    for pid in [Int32(0), -1, 43] {
      #expect(throws: (any Error).self) { try FBAXPointReadRules.frontmost(pid, expectedPID: 42) }
    }
    #expect(throws: (any Error).self) { try FBAXPointReadRules.frontmost(0, expectedPID: 0) }
  }

  @Test func pointReadRequiresOneDirectPIDResult() throws {
    let direct = try JSONDecoder().decode(FBSimulatorAXNode.self, from: Data(#"{"pid":42,"type":"CheckBox"}"#.utf8))
    let foreign = try JSONDecoder().decode(FBSimulatorAXNode.self, from: Data(#"{"pid":43,"type":"Link"}"#.utf8))
    let unknown = try JSONDecoder().decode(FBSimulatorAXNode.self, from: Data(#"{"type":"Group"}"#.utf8))
    try FBAXPointReadRules.directHit([direct], expectedPID: 42, hitPID: 42)
    for roots in [[], [foreign], [unknown], [direct, direct]] {
      #expect(throws: (any Error).self) { try FBAXPointReadRules.directHit(roots, expectedPID: 42, hitPID: 42) }
    }
    #expect(throws: (any Error).self) { try FBAXPointReadRules.directHit([direct], expectedPID: 42, hitPID: 43) }
  }

  @Test func pointReadContextCheckRejectsChangedBootPanelPoseAndRotation() throws {
    let selected = try observation()
    try FBSimulatorAXSnapshot.requireSame(selected, selected)
    for changed in [try observation(boot: "boot-2"), try observation(screen: 1),
                    try observation(uuid: "923D314A-8CCB-42DD-A6B7-A49441191665"),
                    try observation(pose: "closed"), try observation(.rot90)] {
      #expect(throws: (any Error).self) { try FBSimulatorAXSnapshot.requireSame(selected, changed) }
    }
  }
}
