@preconcurrency import CoreSimulator
import Foundation

extension FBSimulatorHingeDisplayReadiness {
  /// Preflight the comparator while the caller owns the device, before any hinge write.
  public static func prepare(for simulator: FBSimulator, expectedBootIdentity: String,
                             expected: FBSimulatorHingeReadinessRequest) async throws -> FBSimulatorHingeDisplayReadiness {
    _ = try FBSimulatorHingeReadinessRequest(screenID: expected.screenID, screenUUID: expected.screenUUID,
      timeoutSeconds: expected.timeoutSeconds)
    try Task.checkCancellation()
    let capability = try NativeHingeReadinessBackend.validate(simulator, expectedBoot: expectedBootIdentity)
    let catalog = try FBSimulatorNativeContextReader.hostCatalog(
      await FBSimulatorDisplayDiscovery.displays(for: simulator), profileIDs: capability.integratedDigitizerIDs)
    guard let panel = catalog.first(where: { $0.screenID == expected.screenID }),
          panel.uniqueID.flatMap(UUID.init(uuidString:)) == expected.screenUUID else {
      throw FBSimulatorHingeReadinessError(.invalidRequest, "Expected display ID/UUID is absent from the verified host catalog")
    }
    _ = try NativeHingeReadinessBackend.validate(simulator, expectedBoot: expectedBootIdentity)
    try Task.checkCancellation()
    let identities = catalog.compactMap { panel -> ActivePanelIdentity? in
      guard let uuid = panel.uniqueID.flatMap(UUID.init(uuidString:)) else { return nil }
      return ActivePanelIdentity(displayID: panel.screenID, uniqueID: uuid)
    }
    return FBSimulatorHingeDisplayReadiness(expected: expected, expectedBoot: expectedBootIdentity,
      backend: NativeHingeReadinessBackend(simulator: simulator,
        expected: expected, expectedBoot: expectedBootIdentity, catalog: identities))
  }
}

actor NativeHingeReadinessBackend: FBSimulatorHingeReadinessBackend {
  private let simulator: FBSimulator
  private let reader: FBSimulatorNativeContextReader
  private let expected: FBSimulatorHingeReadinessRequest
  private let expectedBoot: String
  private let catalog: [ActivePanelIdentity]
  init(simulator: FBSimulator, expected: FBSimulatorHingeReadinessRequest,
       expectedBoot: String, catalog: [ActivePanelIdentity]) {
    self.simulator = simulator; self.expected = expected; self.expectedBoot = expectedBoot; self.catalog = catalog
    reader = FBSimulatorNativeContextReader(simulator: simulator,
      screenID: expected.screenID, screenUniqueID: expected.screenUUID)
  }

  static func validate(_ simulator: FBSimulator, expectedBoot: String) throws -> FBSimulatorContextCapability {
    guard simulator.state == .booted else { throw FBSimulatorHingeReadinessError(.bootChanged, "Simulator is not booted") }
    let boot: String
    do { boot = try NativeHingeBackend.bootIdentity(simulator.udid) }
    catch { throw FBSimulatorHingeReadinessError(.bootChanged, "Expected simulator boot identity is unavailable") }
    guard boot == expectedBoot else { throw FBSimulatorHingeReadinessError(.bootChanged, "Simulator boot identity changed") }
    let capability = try FBSimulatorNativeContextReader.capability(for: simulator)
    guard capability.hinge == .supported, capability.activePanelSchemaPolicy == .explicitActiveFlag else {
      throw FBSimulatorHingeReadinessError(.unsupported, capability.reason)
    }
    return capability
  }

  func read() async throws -> FBSimulatorHingeDisplayObservation {
    try Task.checkCancellation()
    _ = try Self.validate(simulator, expectedBoot: expectedBoot)
    let value: FBSimulatorContextReadback
    do { value = try await reader.read() }
    catch {
      let classified = Self.classify(error)
      // Never mask an unconfirmed child cleanup with a different read/boot failure.
      if classified.cleanup == .unconfirmed { throw classified }
      if classified.permitsTransitionRetry {
        let capability = try Self.validate(simulator, expectedBoot: expectedBoot)
        let refreshed = try FBSimulatorNativeContextReader.hostCatalog(
          await FBSimulatorDisplayDiscovery.displays(for: simulator), profileIDs: capability.integratedDigitizerIDs)
        let identities = refreshed.compactMap { panel -> ActivePanelIdentity? in
          guard let uuid = panel.uniqueID.flatMap(UUID.init(uuidString:)) else { return nil }
          return ActivePanelIdentity(displayID: panel.screenID, uniqueID: uuid)
        }
        guard identities == catalog else {
          throw FBSimulatorHingeReadinessError(.unavailable, "Host catalog changed after a transition read error")
        }
        _ = try Self.validate(simulator, expectedBoot: expectedBoot)
      }
      throw classified
    }
    _ = try Self.validate(simulator, expectedBoot: expectedBoot)
    try Task.checkCancellation()
    let observation = value.observation
    guard let udid = UUID(uuidString: observation.simulatorUDID), udid == UUID(uuidString: simulator.udid),
          observation.bootIdentity == expectedBoot, observation.bootIdentity.utf8.count <= 128,
          observation.screenID == expected.screenID, UUID(uuidString: observation.screenUniqueID) == expected.screenUUID,
          observation.axDisplayID == expected.screenID, observation.poseRevision.utf8.count <= 256,
          value.activeSnapshot.selectionBasis == .explicitActiveFlag, value.activeSnapshot.activePanel.active == true,
          value.activeSnapshot.activePanel.identity == ActivePanelIdentity(displayID: expected.screenID, uniqueID: expected.screenUUID),
          value.joinedPanels == catalog, value.joinedPanels.count <= 32,
          value.activeChildReceipt.exitConfirmed,
          let before = value.hingeBefore, let after = value.hingeAfter else {
      throw FBSimulatorHingeReadinessError(.unavailable, "Readiness identity, active selection, catalog or child completion differs")
    }
    guard [observation.nativePixelWidth, observation.nativePixelHeight].allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 65536 }),
          observation.scale.isFinite, observation.scale > 0, observation.scale <= 16,
          [0, 90, 180, 270].contains(observation.rotation),
          [before.mechanicalDegrees, after.mechanicalDegrees, before.velocityDegreesPerSecond,
           after.velocityDegreesPerSecond, value.startedUptime, value.finishedUptime].allSatisfy({ $0.isFinite }),
          value.finishedUptime >= value.startedUptime else {
      throw FBSimulatorHingeReadinessError(.unavailable, "Readiness geometry or sample fields exceed the reply contract")
    }
    return FBSimulatorHingeDisplayObservation(simulatorUDID: udid, bootIdentity: expectedBoot,
      screenID: observation.screenID, screenUUID: expected.screenUUID, axDisplayID: observation.axDisplayID,
      nativePixelWidth: observation.nativePixelWidth, nativePixelHeight: observation.nativePixelHeight,
      scale: observation.scale, rotation: observation.rotation, poseRevision: observation.poseRevision,
      hostRawPowerState: value.hostRawPowerState, hostRawBacklightState: value.hostRawBacklightState,
      joinedPanels: value.joinedPanels, mechanicalBefore: before.mechanicalDegrees, mechanicalAfter: after.mechanicalDegrees,
      velocityBefore: before.velocityDegreesPerSecond, velocityAfter: after.velocityDegreesPerSecond,
      startedUptime: value.startedUptime, finishedUptime: value.finishedUptime)
  }

  static func classify(_ error: Error) -> FBSimulatorHingeReadinessError {
    if let value = error as? FBSimulatorHingeReadinessError { return value }
    if error is CancellationError { return .init(.cancelled, "Readiness read was cancelled") }
    if let value = error as? FBSimulatorContextError {
      switch value {
      case .changedDuringRead: return .init(.changedDuringRead, "Full native context changed during read")
      case .unavailable(let detail): return .init(.unavailable, detail)
      }
    }
    if let value = error as? ActivePanelReadError {
      if value.childFailure == .cleanupUnconfirmed || value.receipt.map({ ($0.processIdentifier != nil || ($0.launchAttempted && !$0.launchReturned)) && !$0.exitConfirmed }) == true {
        return .init(.observationCleanupUnconfirmed, "Active-panel child exit is unconfirmed", cleanup: .unconfirmed)
      }
      if value.childFailure == .cancelled { return .init(.cancelled, "Active-panel read was cancelled") }
      if value.childFailure == nil, value.receipt?.exitConfirmed == true {
        switch value.validationFailure {
        case .selectedRotationMismatch: return .init(.selectedRotationMismatch, "Guest and active-panel rotations differ")
        case .inactiveSelection: return .init(.inactiveSelection, "Expected panel is not the active panel")
        default: break
        }
      }
      return .init(.unavailable, "Active-panel read failed outside the transition retry contract")
    }
    return .init(.unavailable, String(describing: error))
  }
}
