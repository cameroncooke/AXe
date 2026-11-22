import CoreGraphics
import Foundation
import Testing
@testable import FBSimulatorControl

/// With no DTUHID service (Xcode 26, #101), only input Indigo can address takes the Indigo fallback.
struct FBSimulatorIndigoFallbackTests {
  private func observation(screenID: UInt32 = FBSimulatorLegacyDisplay.screenID,
                           rotation: FBSimulatorHIDDisplayRotation = .rot0) throws -> FBSimulatorHIDSessionObservation {
    let context = try FBSimulatorHIDDisplayContext(hidTarget: UInt64(screenID),
      nativePixelSize: CGSize(width: 1206, height: 2622), scale: 3, rotation: rotation)
    return try FBSimulatorHIDSessionObservation(simulatorUDID: "indigo-fallback", bootIdentity: "boot",
      screenID: screenID, screenUniqueID: FBSimulatorLegacyDisplay.uuid.uuidString, axDisplayID: screenID,
      displayContext: context, poseRevision: "rigid")
  }

  @Test func singleScreenRuntimeBeforeIOS27TakesIndigo() throws {
    #expect(FBSimulatorHIDSession.indigoFallbackApplies(runtimeMajorVersion: 26,
      observation: try observation(), nativeEdge: .none))
  }

  @Test func anythingIndigoCannotAddressStaysOnDTUHID() throws {
    #expect(!FBSimulatorHIDSession.indigoFallbackApplies(runtimeMajorVersion: 27,
      observation: try observation(), nativeEdge: .none))
    #expect(!FBSimulatorHIDSession.indigoFallbackApplies(runtimeMajorVersion: 26,
      observation: try observation(screenID: 3), nativeEdge: .none))
    #expect(!FBSimulatorHIDSession.indigoFallbackApplies(runtimeMajorVersion: 26,
      observation: try observation(rotation: .rot90), nativeEdge: .none))
    #expect(!FBSimulatorHIDSession.indigoFallbackApplies(runtimeMajorVersion: 26,
      observation: try observation(), nativeEdge: .bottom))
  }
}
