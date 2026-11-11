@preconcurrency import CoreSimulator
@preconcurrency import FBControlCore
import Foundation
import Darwin

public enum FBSimulatorContextError: Error, Sendable {
  case unavailable(String)
  case changedDuringRead
}

public enum FBSimulatorHingeCapability: String, Codable, Sendable {
  case supported, unsupported, unverified
}

public struct FBSimulatorContextCapability: Codable, Sendable {
  public let hinge: FBSimulatorHingeCapability
  public let activePanelSchemaPolicy: ActivePanelSchemaPolicy
  public let deviceTypeIdentifier: String
  public let modelIdentifier: String
  public let profileVersion: String
  public let integratedDigitizerIDs: [UInt32]
  public let reason: String
}

public struct FBSimulatorContextObservation: Codable, Sendable {
  public let simulatorUDID: String
  public let bootIdentity: String
  public let screenID: UInt32
  public let screenUniqueID: String
  public let axDisplayID: UInt32
  public let nativePixelWidth: Double
  public let nativePixelHeight: Double
  public let scale: Double
  public let rotation: Int
  public let poseRevision: String

  public func sessionObservation() throws -> FBSimulatorHIDSessionObservation {
    guard let rotation = FBSimulatorHIDDisplayRotation(rawValue: rotation) else {
      throw FBSimulatorContextError.unavailable("Unsupported guest rotation")
    }
    let context = try FBSimulatorHIDDisplayContext(hidTarget: UInt64(screenID),
      nativePixelSize: CGSize(width: nativePixelWidth, height: nativePixelHeight), scale: scale, rotation: rotation)
    return try FBSimulatorHIDSessionObservation(simulatorUDID: simulatorUDID,
      bootIdentity: bootIdentity, screenID: screenID, screenUniqueID: screenUniqueID,
      axDisplayID: axDisplayID, displayContext: context, poseRevision: poseRevision)
  }
}

public struct FBSimulatorContextReadback: Codable, Sendable {
  public let observation: FBSimulatorContextObservation
  public let capability: FBSimulatorContextCapability
  public let hingeBefore: FBSimulatorHingeObservation?
  public let hingeAfter: FBSimulatorHingeObservation?
  public let hostRawUIOrientation: UInt32
  public let hostRawPowerState: Int32
  public let hostRawBacklightState: Int32?
  public let joinedPanels: [ActivePanelIdentity]
  public let activeSnapshot: ActivePanelSnapshot
  public let activeChildReceipt: ActivePanelChildReceipt
  public let startedUptime: Double
  public let finishedUptime: Double
}

/// Full bounded read with selected active-panel admission. It is not an atomic input
/// transaction or a transition generation. Use the live feed between full observations.
public actor FBSimulatorNativeContextReader: FBSimulatorHIDFreshnessProvider, FBSimulatorHIDCleanupIdentityProvider {
  private let simulator: FBSimulator
  private let screenID: UInt32
  private let screenUniqueID: UUID

  public init(simulator: FBSimulator, screenID: UInt32, screenUniqueID: UUID) {
    self.simulator = simulator
    self.screenID = screenID
    self.screenUniqueID = screenUniqueID
  }

  public func observation() async throws -> FBSimulatorHIDSessionObservation {
    try await read().observation.sessionObservation()
  }

  /// A bounded host identity read for release on the existing connection. It does not establish
  /// active status, pose, guest rotation, or permission to dispatch any new input.
  public func cleanupIdentity() async throws -> FBSimulatorHIDCleanupIdentity {
    try Task.checkCancellation()
    let started = ProcessInfo.processInfo.systemUptime
    guard simulator.state == .booted else { throw FBSimulatorContextError.unavailable("Simulator is not booted during cleanup") }
    let capability = try Self.capability(for: simulator)
    guard capability.hinge != .unverified, capability.integratedDigitizerIDs.contains(screenID) else {
      throw FBSimulatorContextError.unavailable("Cleanup target is not in the verified device profile")
    }
    let bootBefore = try Self.bootIdentity(simulator.udid)
    let catalog = try Self.hostCatalog(await FBSimulatorDisplayDiscovery.displays(for: simulator),
      profileIDs: capability.integratedDigitizerIDs)
    guard let selected = catalog.first(where: { $0.screenID == screenID }),
          selected.panelUUID == screenUniqueID else {
      throw FBSimulatorContextError.unavailable("Original cleanup target ID/UUID is absent")
    }
    let bootAfter = try Self.bootIdentity(simulator.udid)
    guard bootBefore == bootAfter else { throw FBSimulatorContextError.changedDuringRead }
    try Task.checkCancellation()
    return FBSimulatorHIDCleanupIdentity(simulatorUDID: simulator.udid, bootIdentity: bootBefore,
      screenID: screenID, screenUUID: screenUniqueID.uuidString,
      nativePixelWidth: selected.nativePixelSize.width, nativePixelHeight: selected.nativePixelSize.height,
      scale: selected.scale, startedUptime: started, finishedUptime: ProcessInfo.processInfo.systemUptime)
  }

  public func read() async throws -> FBSimulatorContextReadback {
    try Task.checkCancellation()
    let started = ProcessInfo.processInfo.systemUptime
    guard simulator.state == .booted else { throw FBSimulatorContextError.unavailable("Simulator is not booted") }
    let capability = try Self.capability(for: simulator)
    guard capability.hinge != .unverified else {
      throw FBSimulatorContextError.unavailable(capability.reason)
    }
    guard capability.integratedDigitizerIDs.contains(screenID) else {
      throw FBSimulatorContextError.unavailable("Selected screen is not an integrated digitizer in this device profile")
    }
    let bootBefore = try Self.bootIdentity(simulator.udid)
    let beforeCatalog = try Self.hostCatalog(
      await FBSimulatorDisplayDiscovery.displays(for: simulator), profileIDs: capability.integratedDigitizerIDs)
    guard let before = beforeCatalog.first(where: { $0.screenID == screenID }),
          before.panelUUID == screenUniqueID else {
      throw FBSimulatorContextError.unavailable("Requested selected pair is absent from the host catalog")
    }
    let hingeBefore = capability.hinge == .supported ? try await FBSimulatorHingeReader.read(for: simulator) : nil
    guard let simulatorID = UUID(uuidString: simulator.udid) else {
      throw FBSimulatorContextError.unavailable("Active-panel simulator identity is unavailable")
    }
    // One in-process CoreDevice read supplies guest CAD identity, geometry, rotation and the
    // active flag, within the same host catalogue, hinge and boot bounds.
    let info = try await FBSimulatorDisplayInfoReader.read(for: simulator)
    let guestDisplays = info.rows.filter(\.integrated).map {
      GuestDisplay(displayId: $0.displayID, uniqueId: $0.uniqueID.uuidString,
        currentOrientation: $0.currentOrientation.rawValue,
        bounds: GuestDisplay.Bounds(x: $0.boundsX, y: $0.boundsY, width: $0.boundsWidth, height: $0.boundsHeight))
    }
    let joinedPanels = try Self.joinedCatalog(host: beforeCatalog, guest: guestDisplays)
    let matches = guestDisplays.filter { $0.displayId == screenID && UUID(uuidString: $0.uniqueId) == screenUniqueID }
    guard matches.count == 1,
          guestDisplays.filter({ $0.displayId == screenID }).count == 1,
          let selected = matches.first,
          selected.bounds.x == 0, selected.bounds.y == 0,
          selected.bounds.width == before.nativePixelSize.width,
          selected.bounds.height == before.nativePixelSize.height,
          let rotation = Self.rotation(selected.currentOrientation) else {
      throw FBSimulatorContextError.unavailable("Host and guest screen identity, geometry or rotation do not match")
    }
    guard let activeRotation = ActivePanelRotation(rawValue: selected.currentOrientation) else {
      throw FBSimulatorContextError.unavailable("Active-panel guest rotation is unavailable")
    }
    // The hinge sample already read for this observation decides a lit inactive report.
    let verdict = await FBSimulatorDisplaySteadiness.shared.verdict(info,
      simulatorUDID: simulator.udid, bootIdentity: bootBefore) { hingeBefore }
    let active = try FBSimulatorDisplayInfoReader.snapshot(info, simulatorUDID: simulatorID,
      expectedPanels: joinedPanels,
      selected: ActivePanelExpectation(identity: ActivePanelIdentity(displayID: screenID, uniqueID: screenUniqueID),
        nativePixelWidth: before.nativePixelSize.width, nativePixelHeight: before.nativePixelSize.height,
        scale: before.scale, rotation: activeRotation), acceptSteadyLitInactive: verdict == .steady)
    let hingeAfter = capability.hinge == .supported ? try await FBSimulatorHingeReader.read(for: simulator) : nil
    let afterCatalog = try Self.hostCatalog(
      await FBSimulatorDisplayDiscovery.displays(for: simulator), profileIDs: capability.integratedDigitizerIDs)
    guard let after = afterCatalog.first(where: { $0.screenID == screenID }) else {
      throw FBSimulatorContextError.unavailable("Selected panel disappeared during read")
    }
    guard try Self.bootIdentity(simulator.udid) == bootBefore,
          Self.sameCatalog(beforeCatalog, afterCatalog), Self.sameHinge(hingeBefore, hingeAfter) else {
      throw FBSimulatorContextError.changedDuringRead
    }
    try Task.checkCancellation()
    let pose: String
    if let hingeAfter {
      // Mechanical angle is measured. It is not a posture enum or active-panel threshold.
      pose = "mechanicalDegrees=\(hingeAfter.mechanicalDegrees);range=\(hingeAfter.minimumDegrees)...\(hingeAfter.maximumDegrees)"
    } else {
      pose = "rigid-device-type:\(capability.deviceTypeIdentifier)"
    }
    return FBSimulatorContextReadback(observation: FBSimulatorContextObservation(
      simulatorUDID: simulator.udid, bootIdentity: bootBefore, screenID: screenID,
      screenUniqueID: screenUniqueID.uuidString, axDisplayID: screenID,
      nativePixelWidth: before.nativePixelSize.width, nativePixelHeight: before.nativePixelSize.height,
      scale: before.scale, rotation: rotation, poseRevision: pose), capability: capability,
      hingeBefore: hingeBefore, hingeAfter: hingeAfter, hostRawUIOrientation: after.rawUIOrientation,
      hostRawPowerState: after.rawPowerState, hostRawBacklightState: after.rawBacklightState,
      joinedPanels: joinedPanels, activeSnapshot: active.snapshot, activeChildReceipt: active.receipt,
      startedUptime: started, finishedUptime: ProcessInfo.processInfo.systemUptime)
  }

  /// The device type's declared integrated digitizers, classified below.
  public static func capability(for simulator: FBSimulator) throws -> FBSimulatorContextCapability {
    guard let type = simulator.device.deviceType, let bundle = type.bundle,
          let identifier = type.identifier, let model = type.modelIdentifier,
          let version = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
          let url = bundle.url(forResource: "capabilities", withExtension: "plist") else {
      throw FBSimulatorContextError.unavailable("Device type metadata is unavailable")
    }
    let profile = try PropertyListDecoder().decode(CapabilityFile.self, from: Data(contentsOf: url))
    let ids = profile.capabilities.displays.filter { $0.displayType == "integrated" && $0.hasDigitizer }.map(\.screenID).sorted()
    return classifyCapability(identifier: identifier, model: model, version: version, integratedDigitizerIDs: ids)
  }

  /// Classifies by the device type's declared built-in touch displays, not by profile version or
  /// model. Every full read still validates the live display report, host catalogue and boot
  /// identity; a two-panel device must also return native hinge samples, or input fails closed.
  static func classifyCapability(identifier: String, model: String, version: String,
                                 integratedDigitizerIDs: [UInt32]) -> FBSimulatorContextCapability {
    let ids = integratedDigitizerIDs.sorted()
    let validIDs = !ids.isEmpty && Set(ids).count == ids.count && ids.allSatisfy { $0 > 0 }
    let hinge: FBSimulatorHingeCapability
    let reason: String
    if validIDs, ids.count == 1 {
      hinge = .unsupported
      reason = "One integrated digitizer (\(identifier) \(model) profile \(version)); no hinge request is made"
    } else if validIDs, ids.count == 2 {
      hinge = .supported
      reason = "Two integrated digitizers (\(identifier) \(model) profile \(version)); native hinge samples are required on every full read"
    } else {
      hinge = .unverified
      reason = "Device type declares \(ids.count) integrated digitizers with IDs \(ids); no input contract covers it"
    }
    return FBSimulatorContextCapability(hinge: hinge, activePanelSchemaPolicy: .explicitActiveFlag,
      deviceTypeIdentifier: identifier, modelIdentifier: model, profileVersion: version,
      integratedDigitizerIDs: ids, reason: reason)
  }

  // The device profile defines the integrated set. Virtual CAD displays are not classified by
  // names or guessed raw enums. The guest display report independently validates its full set.
  static func hostCatalog(_ values: [FBSimulatorDisplayInfo], profileIDs: [UInt32]) throws -> [FBSimulatorDisplayInfo] {
    guard !profileIDs.isEmpty, Set(profileIDs).count == profileIDs.count,
          Set(values.map(\.screenID)).count == values.count else {
      throw FBSimulatorContextError.unavailable("Invalid profile IDs or duplicate host screen IDs")
    }
    let catalog = values.filter { profileIDs.contains($0.screenID) }.sorted { $0.screenID < $1.screenID }
    let pairs = catalog.compactMap { value -> ActivePanelIdentity? in
      guard let uuid = value.panelUUID else { return nil }
      return ActivePanelIdentity(displayID: value.screenID, uniqueID: uuid)
    }
    // Only a single-panel profile can have the legacy display.
    guard profileIDs.count == 1 || !catalog.contains(where: { $0.uniqueID == FBSimulatorLegacyDisplay.hostName }) else {
      throw FBSimulatorContextError.unavailable("Host integrated catalog names a legacy display in a multi-panel profile")
    }
    guard catalog.count == profileIDs.count, pairs.count == catalog.count,
          Set(pairs.map(\.uniqueID)).count == pairs.count,
          catalog.allSatisfy({ value in
            [value.nativePixelSize.width, value.nativePixelSize.height].allSatisfy { $0.isFinite && $0 > 0 && $0 <= 65536 }
              && value.scale.isFinite && value.scale > 0 && value.scale <= 16
          }) else {
      throw FBSimulatorContextError.unavailable("Host integrated catalog is incomplete, duplicated or invalid")
    }
    return catalog
  }

  static func joinedCatalog(host: [FBSimulatorDisplayInfo], guest: [GuestDisplay]) throws -> [ActivePanelIdentity] {
    guard guest.count <= 32, Set(guest.map(\.displayId)).count == guest.count else {
      throw FBSimulatorContextError.unavailable("Guest catalog is oversized or has duplicate screen IDs")
    }
    var pairs: [ActivePanelIdentity] = []
    for panel in host {
      guard let uuid = panel.panelUUID,
            let row = guest.first(where: { $0.displayId == panel.screenID }),
            UUID(uuidString: row.uniqueId) == uuid,
            row.bounds.x == 0, row.bounds.y == 0,
            row.bounds.width == panel.nativePixelSize.width,
            row.bounds.height == panel.nativePixelSize.height,
            Self.rotation(row.currentOrientation) != nil else {
        throw FBSimulatorContextError.unavailable("Complete host/guest integrated catalog does not match")
      }
      pairs.append(ActivePanelIdentity(displayID: panel.screenID, uniqueID: uuid))
    }
    guard !pairs.isEmpty, Set(pairs).count == pairs.count,
          Set(pairs.map(\.uniqueID)).count == pairs.count else {
      throw FBSimulatorContextError.unavailable("Joined panel identity is empty or duplicated")
    }
    return pairs
  }

  static func sameCatalog(_ before: [FBSimulatorDisplayInfo], _ after: [FBSimulatorDisplayInfo]) -> Bool {
    before.count == after.count && zip(before, after).allSatisfy { sameDisplay($0, $1) }
  }

  static func bootIdentity(_ udid: String) throws -> String {
    let processes = FBProcessFetcher().processes(withProcessName: "launchd_sim").filter {
      $0.arguments.contains { $0.localizedCaseInsensitiveContains(udid) }
    }
    guard processes.count == 1, let process = processes.first else {
      throw FBSimulatorContextError.unavailable("Expected exactly one launchd_sim for this device")
    }
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(process.processIdentifier, PROC_PIDTBSDINFO, 0, &info, size) == size else {
      throw FBSimulatorContextError.unavailable("Simulator boot process identity is unavailable")
    }
    return "\(process.processIdentifier):\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
  }

  private static func rotation(_ text: String) -> Int? {
    switch text { case "rot0": return 0; case "rot90": return 90; case "rot180": return 180; case "rot270": return 270; default: return nil }
  }

  private static func sameDisplay(_ a: FBSimulatorDisplayInfo, _ b: FBSimulatorDisplayInfo) -> Bool {
    a.screenID == b.screenID && a.panelUUID == b.panelUUID && a.nativePixelSize == b.nativePixelSize &&
      a.scale == b.scale && a.rawUIOrientation == b.rawUIOrientation && a.rawPowerState == b.rawPowerState &&
      a.rawBacklightState == b.rawBacklightState && a.rawScreenType == b.rawScreenType
  }

  private static func sameHinge(_ a: FBSimulatorHingeObservation?, _ b: FBSimulatorHingeObservation?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (a?, b?): return a.mechanicalDegrees == b.mechanicalDegrees && a.minimumDegrees == b.minimumDegrees && a.maximumDegrees == b.maximumDegrees
    default: return false
    }
  }

  private struct CapabilityFile: Decodable {
    let capabilities: Capabilities
    struct Capabilities: Decodable { let displays: [Display] }
    struct Display: Decodable { let displayType: String; let hasDigitizer: Bool; let screenID: UInt32 }
  }
  /// One integrated row of the guest display report, joined against the host catalogue.
  struct GuestDisplay {
    let displayId: UInt32
    let uniqueId: String
    let currentOrientation: String
    let bounds: Bounds
    struct Bounds { let x: Double; let y: Double; let width: Double; let height: Double }
  }
}
