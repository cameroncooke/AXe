import AccessibilityPlatformTranslation
import FBControlCore
import Foundation
import Testing
@testable import FBSimulatorControl

@Suite("Native point client routing", .serialized)
@MainActor
struct FBSimulatorAXClientTypeRoutingTests {
  @Test("A native point keeps its factory client type, translation and exact parameters")
  func pointPreservesFactoryRequest() throws {
    let request = try makeRequest(type: 6)
    let factoryClientType = request.clientType
    let translation = try #require(request.translation)
    let parameters = try #require(request.parameters)
    FBAXClientTypeRouting.apply(to: request)
    let currentParameters = try #require(request.parameters)
    #expect(request.clientType == factoryClientType)
    #expect(request.requestType == 6 && request.attributeType == 0 && request.actionType == 0)
    #expect(request.translation === translation)
    #expect(NSDictionary(dictionary: parameters).isEqual(to: currentParameters))
  }

  @Test("Frontmost, attribute and action requests retain IDB client type 2", arguments: [UInt64(1), 2, 7])
  func nonPointKeepsExistingClient(_ type: UInt64) throws {
    let request = try makeRequest(type: type)
    let translation = request.translation
    let parameters = try #require(request.parameters)
    FBAXClientTypeRouting.apply(to: request)
    let currentParameters = try #require(request.parameters)
    #expect(request.clientType == 2 && request.requestType == type)
    #expect(request.translation === translation)
    #expect(NSDictionary(dictionary: parameters).isEqual(to: currentParameters))
  }

  @Test("Diagnostic point copies keep the factory client and one-send guard",
        arguments: FBSimulatorAXPointContextMode.allCases)
  func contextCopyKeepsNativeClient(_ mode: FBSimulatorAXPointContextMode) throws {
    let request = try makeRequest(type: 6)
    let factoryClientType = request.clientType
    let gate = try makeGate(mode: mode)
    FBAXClientTypeRouting.apply(to: request)
    let effective = try gate.admitCallback(request, token: token, source: "point")
    FBAXClientTypeRouting.apply(to: effective)
    #expect(effective !== request && effective.clientType == factoryClientType)
    #expect(effective.translation === request.translation)
    let fact = FBAXRoutingRequest.capture(effective, token: token, source: "point")
    #expect(fact.point.x == 340 && fact.point.y == 434 && fact.displayID.decimalValue == "1")
    #expect(mode == .absent ? fact.contextID.state == "absent"
      : fact.contextID.decimalValue == (mode == .explicitZero ? "0" : "123"))
    try gate.willSend()
    try gate.requireComplete()
    #expect(throws: FBAXPointContextError.self) { try gate.willSend() }
    #expect(gate.snapshot().enteredNativeSends == 1)
  }

  @Test("Point routing does not admit changed identity, geometry or callback ownership",
        arguments: ["pid", "point", "display", "action", "type", "token", "keys"])
  func contextGuardsStillReject(_ variant: String) throws {
    let request = try makeRequest(type: 6)
    let gate = try makeGate(mode: .absent)
    switch variant {
    case "pid": request.translation?.pid = 99
    case "point": request.parameters = ["point": NSValue(point: .init(x: 340, y: 435)), "displayId": NSNumber(value: 1)]
    case "display": request.parameters = ["point": NSValue(point: .init(x: 340, y: 434)), "displayId": NSNumber(value: 2)]
    case "action": request.actionType = 5
    case "type": request.requestType = 2
    case "keys": request.parameters = ["point": NSValue(point: .init(x: 340, y: 434)), "displayId": NSNumber(value: 1), "extra": NSNumber(value: 1)]
    default: break
    }
    FBAXClientTypeRouting.apply(to: request)
    #expect(throws: FBAXPointContextError.self) {
      try gate.admitCallback(request, token: variant == "token" ? "foreign" : token, source: "point")
    }
    #expect(throws: FBAXPointContextError.self) { try gate.willSend() }
    #expect(gate.snapshot().enteredNativeSends == 0)
  }

  private let token = "point-owned"

  private func makeRequest(type: UInt64) throws -> AXPTranslatorRequest {
    // Load the declared classes without opening a simulator or changing an AX mode.
    try FBSimulatorControlFrameworkLoader.accessibilityFrameworks.loadPrivateFrameworks(nil)
    let translation = try #require(AXPTranslationObject())
    translation.pid = 0
    translation.bridgeDelegateToken = token
    let request = try #require(AXPTranslatorRequest.request(withTranslation: translation) as? AXPTranslatorRequest)
    request.requestType = type
    request.parameters = ["point": NSValue(point: .init(x: 340, y: 434)), "displayId": NSNumber(value: 1)]
    return request
  }

  private func makeGate(mode: FBSimulatorAXPointContextMode) throws -> FBAXPointContextGate {
    try FBAXPointContextGate(mode: mode, rootContext: .inspect(NSNumber(value: 123)),
      rootResponseValid: true, token: token, point: .init(x: 340, y: 434), displayID: 1)
  }
}
