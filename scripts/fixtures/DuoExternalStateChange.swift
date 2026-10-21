import AppKit
import Darwin
import Foundation
import FBControlCore
import FBSimulatorControl

final class ChangeReporter: NSObject, FBEventReporter {
  var metadata: [String: String] = [:]
  func report(_ event: FBEventReporterSubject) {}
  func addMetadata(_ metadata: [String: String]) {}
}
enum ChangeError: Error { case invalid(String) }
struct ChangeReceipt: Encodable {
  let mode: String
  let startedUptime: Double
  let finishedUptime: Double
  let before: FBSimulatorContextReadback
  let hinge: FBSimulatorHingeReceipt?
  let rotation: FBSimulatorRotationReceipt?
}

/// Isolated simulator-state operator. This sends no touch input and takes no AXe input lock.
/// The deliberate overlap represents a user folding/turning the device during an AXe gesture.
@main struct DuoExternalStateChange {
  @MainActor static func main() async {
    do {
      let args = Array(CommandLine.arguments.dropFirst())
      guard args.count == 8, ["fold", "rotate"].contains(args[0]),
            let screen = UInt32(args[2]), let uuid = UUID(uuidString: args[3]),
            UUID(uuidString: args[6]) != nil,
            let angle = Double(args[4]), angle.isFinite, (0...180).contains(angle) else {
        throw ChangeError.invalid("Expected mode, boot, screen, UUID, fold angle, marker path, owned device UUID, helper path")
      }
      let logger = FBControlCoreLoggerFactory.systemLoggerWriting(toStderr: true, withDebugLogging: false)
      FBControlCoreGlobalConfiguration.defaultLogger = logger
      try FBSimulatorControlFrameworkLoader.xcodeFrameworks.loadPrivateFrameworks(logger)
      let control = try FBSimulatorControl.withConfiguration(FBSimulatorControlConfiguration(
        deviceSetPath: nil, logger: logger, reporter: ChangeReporter()))
      guard let simulator = control.set.allSimulators.first(where: {
        UUID(uuidString: $0.udid) == UUID(uuidString: args[6])
      }), simulator.state == .booted else { throw ChangeError.invalid("Explicit Duo is not booted") }
      let helper = URL(fileURLWithPath: args[7])
      let reader = FBSimulatorNativeContextReader(simulator: simulator, helperURL: helper,
        screenID: screen, screenUniqueID: uuid)
      let before = try await reader.read()
      guard before.observation.bootIdentity == args[1] else { throw ChangeError.invalid("Boot changed") }
      let started = ProcessInfo.processInfo.systemUptime
      let marker = try JSONSerialization.data(withJSONObject: ["startedUptime": started, "mode": args[0]])
      try marker.write(to: URL(fileURLWithPath: args[5]), options: .withoutOverwriting)
      var hinge: FBSimulatorHingeReceipt?
      var rotation: FBSimulatorRotationReceipt?
      if args[0] == "fold" {
        hinge = try await FBSimulatorHingeNative.operation(for: simulator).set(
          FBSimulatorHingeRequest(degrees: angle, expectedBootIdentity: args[1], toleranceDegrees: 0.5, timeoutSeconds: 8))
      } else {
        rotation = try await FBSimulatorRotationNative.rotate(for: simulator, helperURL: helper,
          screenID: screen, screenUUID: uuid, expectedBootIdentity: args[1], direction: .right)
      }
      let value = ChangeReceipt(mode: args[0], startedUptime: started,
        finishedUptime: ProcessInfo.processInfo.systemUptime, before: before, hinge: hinge, rotation: rotation)
      let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      FileHandle.standardOutput.write(try encoder.encode(value))
      FileHandle.standardOutput.write(Data([10]))
    } catch {
      FileHandle.standardError.write(Data((String(reflecting: error) + "\n").utf8))
      exit(2)
    }
  }
}
