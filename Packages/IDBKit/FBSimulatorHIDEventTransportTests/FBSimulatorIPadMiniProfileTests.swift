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
