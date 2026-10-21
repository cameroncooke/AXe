import AppKit
import Darwin
import Foundation
import FBControlCore
import FBSimulatorControl

final class HardwareReporter: NSObject, FBEventReporter {
  var metadata: [String: String] = [:]
  func report(_ event: FBEventReporterSubject) {}
  func addMetadata(_ metadata: [String: String]) {}
}
enum HardwareProbeError: Error { case invalid(String) }
struct HardwareDownMarker: Encodable {
  let source = "publicLibrarySessionStatus"
  let button: String
  let normalDownSentCount = 1
  let state: String
  let capturedUptime: Double
  let normalSendCompleted = true
  let wholeGestureDrainCompleted = false
  let device: String
  let boot: String
  let screenID: UInt32
  let screenUUID: String
}
struct HardwareProbeEvidence: Encodable {
  let source = "realLibraryHardwareSession"
  let frameworkPath: String
  let button: String
  let expectedRelease: String
  let downMarkerWritten: Bool
  let outcome: String
  let normalEventCount: Int
  let phase: String?
  let error: String?
  let interruption: String?
  let executionStartedUptime: Double?
  let executionFinishedUptime: Double?
  let allInputsReleasedBeforeCleanup: Bool?
  let normalDrainCompleted: Bool?
  let cleanup: String
  let cleanupEvidence: FBSimulatorHIDCleanupEvidence?
}

/// An isolated library caller. It uses the real transport and no production hook.
@main struct DuoHeldHardwareProbe {
  @MainActor static func main() async {
    do {
      let args = Array(CommandLine.arguments.dropFirst())
      guard args.count == 7, UUID(uuidString: args[0]) != nil,
            let screen = UInt32(args[2]), let uuid = UUID(uuidString: args[3]),
            ["home", "side-button"].contains(args[5]) else {
        throw HardwareProbeError.invalid("Expected owned device, boot, screen, UUID, helper, button, marker path")
      }
      let button: FBSimulatorHIDButton = args[5] == "home" ? .homeButton : .sideButton
      let logger = FBControlCoreLoggerFactory.systemLoggerWriting(toStderr: true, withDebugLogging: false)
      FBControlCoreGlobalConfiguration.defaultLogger = logger
      try FBSimulatorControlFrameworkLoader.xcodeFrameworks.loadPrivateFrameworks(logger)
      let control = try FBSimulatorControl.withConfiguration(FBSimulatorControlConfiguration(
        deviceSetPath: nil, logger: logger, reporter: HardwareReporter()))
      guard let simulator = control.set.allSimulators.first(where: {
        UUID(uuidString: $0.udid) == UUID(uuidString: args[0])
      }), simulator.state == .booted else { throw HardwareProbeError.invalid("Explicit Duo is not booted") }
      let feed = try await FBSimulatorHIDNativeFreshnessProvider.start(for: simulator,
        helperURL: URL(fileURLWithPath: args[4]), screenID: screen, screenUniqueID: uuid)
      guard feed.initialObservation.bootIdentity == args[1] else {
        await feed.closeAndWait(); throw HardwareProbeError.invalid("Boot changed")
      }
      let session: FBSimulatorHIDSession
      do {
        session = try await FBSimulatorHIDSession.open(for: simulator,
          observation: feed.initialObservation, liveFreshnessProvider: feed)
      } catch {
        await feed.closeAndWait(); throw error
      }
      let event = FBSimulatorHIDEvent.composite([
        .button(direction: .down, button: button), .delay(6), .button(direction: .up, button: button)])
      let task = Task { try await session.execute(event) }
      var markerWritten = false
      var probeFailure: String?
      let markerDeadline = ProcessInfo.processInfo.systemUptime + 8
      do {
        while ProcessInfo.processInfo.systemUptime < markerDeadline {
          let status = await session.status()
          if status.state == .executing && status.enqueuedEventCount == 1 {
            let marker = HardwareDownMarker(button: args[5], state: status.state.rawValue,
              capturedUptime: ProcessInfo.processInfo.systemUptime, device: args[0], boot: args[1],
              screenID: screen, screenUUID: uuid.uuidString)
            try JSONEncoder().encode(marker).write(to: URL(fileURLWithPath: args[6]), options: .withoutOverwriting)
            markerWritten = true
            break
          }
          if status.enqueuedEventCount > 1 || status.state == .invalidated || status.state == .closed { break }
          try await Task.sleep(nanoseconds: 10_000_000)
        }
        if !markerWritten {
          probeFailure = "No held-down status marker; no external state change is authorized"
          task.cancel()
        }
      } catch {
        probeFailure = String(reflecting: error)
        task.cancel()
      }
      var executionFailure: String?
      do { _ = try await task.value } catch { executionFailure = String(reflecting: error) }
      do { _ = try await session.close() } catch { probeFailure = String(reflecting: error) }
      await feed.closeAndWait()
      let status = await session.status()
      let execution = await session.executionEvidence()
      let evidence = HardwareProbeEvidence(frameworkPath: Bundle(for: FBSimulator.self).bundleURL.path,
        button: args[5], expectedRelease: FBSimulatorHIDEvent.button(direction: .up, button: button).description,
        downMarkerWritten: markerWritten, outcome: executionFailure == nil ? "enqueuedAndDrained" : "failedNoReplay",
        normalEventCount: status.enqueuedEventCount, phase: execution?.phase.rawValue,
        error: probeFailure ?? executionFailure, interruption: execution?.interruption.map { String(reflecting: $0) },
        executionStartedUptime: execution?.startedUptime, executionFinishedUptime: execution?.finishedUptime,
        allInputsReleasedBeforeCleanup: execution?.allInputsReleasedBeforeCleanup,
        normalDrainCompleted: execution?.drainCompleted, cleanup: status.lastCleanup.rawValue,
        cleanupEvidence: await session.cleanupEvidence())
      let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      FileHandle.standardOutput.write(try encoder.encode(evidence)); FileHandle.standardOutput.write(Data([10]))
      if probeFailure != nil { exit(2) }
      if executionFailure != nil { exit(1) }
    } catch {
      FileHandle.standardError.write(Data((String(reflecting: error) + "\n").utf8)); exit(2)
    }
  }
}
