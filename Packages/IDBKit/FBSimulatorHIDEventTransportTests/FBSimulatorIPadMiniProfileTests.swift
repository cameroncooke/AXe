import Foundation
import Testing
@testable import FBSimulatorControl

@Suite("Device classification and iPad mini A17 Pro rigid profile")
struct FBSimulatorIPadMiniProfileTests {
  private func capability(identifier: String = "com.apple.CoreSimulator.SimDeviceType.iPad-mini-A17-Pro",
                          model: String = "iPad16,2", version: String = "405",
                          ids: [UInt32] = [1]) -> FBSimulatorContextCapability {
    FBSimulatorNativeContextReader.classifyCapability(identifier: identifier, model: model,
      version: version, integratedDigitizerIDs: ids)
  }

  @Test func oneIntegratedDigitizerIsRigid() {
    let actual = capability()
    #expect(actual.hinge == .unsupported)
    #expect(actual.activePanelSchemaPolicy == .explicitActiveFlag)
    #expect(actual.integratedDigitizerIDs == [1])
  }

  /// Profile version, model and identifier do not decide support; the declared panels do.
  @Test(arguments: ["identifier", "model", "older", "newer"])
  func anyProfileVersionOrModelWithOnePanelIsRigid(change: String) {
    var identifier = "com.apple.CoreSimulator.SimDeviceType.iPad-mini-A17-Pro"
    var model = "iPad16,2"
    var version = "405"
    switch change {
    case "identifier": identifier = "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro"
    case "model": model = "iPad16,1"
    case "older": version = "404"
    default: version = "407"
    }
    let actual = capability(identifier: identifier, model: model, version: version, ids: [1])
    #expect(actual.hinge == .unsupported)
    #expect(actual.profileVersion == version)
  }

  @Test(arguments: ["405", "407", "500"])
  func twoIntegratedDigitizersRequireTheHinge(version: String) {
    let duo = capability(identifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
      model: "iPhone19,4", version: version, ids: [3, 1])
    #expect(duo.hinge == .supported)
    #expect(duo.integratedDigitizerIDs == [1, 3])
    #expect(duo.activePanelSchemaPolicy == .explicitActiveFlag)
  }

  private func profile(_ capabilities: [String: Any]?) throws -> Data {
    let root: [String: Any] = capabilities.map { ["capabilities": $0] } ?? [:]
    return try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
  }

  @Test func listedDisplaysGiveTheIntegratedDigitizers() throws {
    let displays: [[String: Any]] = [
      ["displayType": "integrated", "hasDigitizer": true, "screenID": 3],
      ["displayType": "external", "hasDigitizer": false, "screenID": 2],
      ["displayType": "integrated", "hasDigitizer": true, "screenID": 1],
    ]
    let ids = try FBSimulatorNativeContextReader.integratedDigitizerIDs(
      profile: profile(["displays": displays]), productFamilyID: 1)
    #expect(ids == [1, 3])
  }

  /// Device types installed with Xcode 26 list no displays (#101).
  @Test(arguments: [Int32(1), 2])
  func phoneOrPadProfileWithoutDisplaysHasTheLegacyDisplay(family: Int32) throws {
    for capabilities in [["SupportsTouchID": false], nil] as [[String: Any]?] {
      let ids = try FBSimulatorNativeContextReader.integratedDigitizerIDs(
        profile: profile(capabilities), productFamilyID: family)
      #expect(ids == [FBSimulatorLegacyDisplay.screenID])
      #expect(capability(ids: ids).hinge == .unsupported)
    }
  }

  @Test(arguments: [Int32(3), 4, 0])
  func otherProfileWithoutDisplaysHasNoTouchDisplay(family: Int32) throws {
    let ids = try FBSimulatorNativeContextReader.integratedDigitizerIDs(
      profile: profile([:]), productFamilyID: family)
    #expect(ids.isEmpty)
    #expect(throws: FBSimulatorContextError.self) { try FBSimulatorNativeContextReader.requireTouchDisplay(ids) }
  }

  @Test(arguments: ["empty", "zeroID", "duplicate", "three"])
  func unsupportedPanelSetsRemainUnverified(change: String) {
    let ids: [UInt32]
    switch change {
    case "empty": ids = []
    case "zeroID": ids = [0]
    case "duplicate": ids = [1, 1]
    default: ids = [1, 2, 3]
    }
    let actual = capability(ids: ids)
    #expect(actual.hinge == .unverified)
  }
}
