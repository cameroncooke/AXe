@testable import FBSimulatorControl
import Foundation
import Testing
@preconcurrency import XPC

@Suite("Hinge wire samples")
struct FBSimulatorHingeWireTests {
  private func quantity(_ value: Double, _ symbol: String) -> xpc_object_t {
    FBSimulatorHIDHingeWire.dictionary(["value": xpc_double_create(value),
      "unit": FBSimulatorHIDHingeWire.dictionary(["symbol": FBSimulatorHIDHingeWire.string(symbol),
        "converter": FBSimulatorHIDHingeWire.dictionary(["coefficient": xpc_double_create(1), "constant": xpc_double_create(0)])])])
  }

  private func event(channel: UUID, angleValid: Bool, velocityValid: Bool, velocity: xpc_object_t?) -> xpc_object_t {
    var fields: [String: xpc_object_t] = [
      "isAngleValid": xpc_bool_create(angleValid), "isVelocityValid": xpc_bool_create(velocityValid),
      "timestamp": xpc_double_create(ProcessInfo.processInfo.systemUptime),
      "minAngle": quantity(0, "°"), "maxAngle": quantity(180, "°"),
      "mechanicalAngle": quantity(90, "°"), "angle": quantity(90, "°")]
    fields["velocity"] = velocity
    let elements = xpc_array_create(nil, 0)
    xpc_array_append_value(elements, FBSimulatorHIDHingeWire.dictionary(fields))
    return FBSimulatorHIDHingeWire.dictionary([
      "XPCSideChannel.uniqueIdentifier": FBSimulatorHIDHingeWire.string(channel.uuidString),
      "CoreDevice.XPCMessageKey.sideChannelStatus": FBSimulatorHIDHingeWire.dictionary([
        "pushing": FBSimulatorHIDHingeWire.dictionary(["elements": elements])])])
  }

  @Test("A valid sample is accepted")
  func validSample() throws {
    let channel = UUID()
    let samples = try FBSimulatorHIDHingeWire.samples(
      event(channel: channel, angleValid: true, velocityValid: true, velocity: quantity(0, "°/s")), channel: channel, notBefore: 0)
    #expect(samples.map(\.sensedDegrees) == [90])
  }

  @Test("A valid angle with an invalid velocity, as iOS 27.1 reports it, reads as at rest")
  func invalidVelocity() throws {
    let channel = UUID()
    let samples = try FBSimulatorHIDHingeWire.samples(
      event(channel: channel, angleValid: true, velocityValid: false, velocity: quantity(37, "°/s")), channel: channel, notBefore: 0)
    #expect(samples.map(\.sensedDegrees) == [90])
    #expect(samples.map(\.velocityDegreesPerSecond) == [0])
  }

  @Test("A refused sample names the flags and values it carried")
  func refusedSampleDetail() {
    let channel = UUID()
    let refused = event(channel: channel, angleValid: false, velocityValid: false, velocity: nil)
    do {
      _ = try FBSimulatorHIDHingeWire.samples(refused, channel: channel, notBefore: 0)
      Issue.record("The sample was accepted")
    } catch {
      let text = "\(error)"
      #expect(text.contains("Motion sample reports invalid angle or velocity"))
      #expect(text.contains("isAngleValid=false, isVelocityValid=false, angle=90.0, mechanicalAngle=90.0, velocity=unreadable, minAngle=0.0, maxAngle=180.0"))
    }
  }
}
