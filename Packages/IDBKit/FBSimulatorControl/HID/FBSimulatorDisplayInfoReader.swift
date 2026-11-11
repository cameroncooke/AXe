@preconcurrency import CoreSimulator
import Darwin
import Foundation
@preconcurrency import XPC

/// One display row from the guest CoreDevice display-info action (dtdeviceinfod).
/// These are the fields `devicectl device info displays` prints, read without a child process.
public struct FBSimulatorDisplayInfoRow: Sendable {
  public let displayID: UInt32
  public let uniqueID: UUID
  public let integrated: Bool
  public let active: Bool?
  public let primary: Bool
  public let currentOrientation: ActivePanelRotation
  public let nativeOrientation: ActivePanelRotation
  public let nativeWidth: Double
  public let nativeHeight: Double
  public let boundsX: Double
  public let boundsY: Double
  public let boundsWidth: Double
  public let boundsHeight: Double
  public let pointScale: Int
  public let backlightState: String?
}

public struct FBSimulatorDisplayInfoResponse: Sendable {
  public let rows: [FBSimulatorDisplayInfoRow]
  public let coreDeviceVersion: String
  /// No child process exists. The receipt records the XPC request interval for diagnostics.
  public let receipt: ActivePanelChildReceipt

  public init(rows: [FBSimulatorDisplayInfoRow], coreDeviceVersion: String,
              startedUptime: Double, finishedUptime: Double) {
    self.rows = rows
    self.coreDeviceVersion = coreDeviceVersion
    receipt = ActivePanelChildReceipt(executable: "xpc:" + FBSimulatorDisplayInfoReader.service,
      arguments: [FBSimulatorDisplayInfoReader.action], startedUptime: startedUptime,
      finishedUptime: finishedUptime, processIdentifier: nil, launchAttempted: false, launchReturned: false,
      exitConfirmed: true, terminationStatus: nil, terminationReason: nil, stopReason: nil,
      detail: "In-process CoreDevice display info", sentTerminate: false, sentKill: false,
      json: Data(), stderr: Data())
  }
}

/// In-process read of `com.apple.coredevice.action.displayinfo`: one XPC request to the
/// simulator's own CoreDevice service, with no child process or guest helper.
public enum FBSimulatorDisplayInfoReader {
  public static let service = "com.apple.coredevice.feature.getdisplayinfo"
  public static let action = "com.apple.coredevice.action.displayinfo"
  /// Backlight states of an illuminated display, as dtdeviceinfod reports them.
  static let litBacklightStates: Set<String> = ["activeOn", "activeDimmed"]

  public static func read(for simulator: FBSimulator) async throws -> FBSimulatorDisplayInfoResponse {
    try Task.checkCancellation()
    let started = ProcessInfo.processInfo.systemUptime
    let (request, version) = try makeRequest(deviceID: simulator.udid)
    let connection = try connect(simulator)
    defer { xpc_connection_cancel(connection) }
    let queue = DispatchQueue(label: "com.facebook.FBSimulatorControl.display-info")
    xpc_connection_set_target_queue(connection, queue)
    xpc_connection_set_event_handler(connection) { _ in }
    xpc_connection_resume(connection)
    let result = FBSimulatorBoundedResult<[FBSimulatorDisplayInfoRow]>()
    let rows = try await result.value(timeout: 3, operation: "Display info read") { finish in
      xpc_connection_send_message_with_reply(connection, request, queue) { reply in
        do { finish(.success(try decode(reply))) } catch { finish(.failure(error)) }
      }
    }
    try Task.checkCancellation()
    return FBSimulatorDisplayInfoResponse(rows: rows, coreDeviceVersion: version,
      startedUptime: started, finishedUptime: ProcessInfo.processInfo.systemUptime)
  }

  /// The active panel must be the selected one, with the selected geometry and rotation.
  /// `acceptSteadyLitInactive` is true only when `FBSimulatorDisplaySteadiness` has proved this
  /// lit inactive report steady and consistent with the hinge.
  public static func snapshot(_ response: FBSimulatorDisplayInfoResponse, simulatorUDID: UUID,
                       expectedPanels: [ActivePanelIdentity], selected: ActivePanelExpectation,
                       acceptSteadyLitInactive: Bool = false) throws -> ActivePanelReadback {
    do {
      try Self.validateExpected(expectedPanels, selected: selected)
      let snapshot = try catalogSnapshot(response, simulatorUDID: simulatorUDID, expectedPanels: expectedPanels,
        acceptSteadyLitInactive: acceptSteadyLitInactive)
      let panel = snapshot.activePanel
      guard panel.identity == selected.identity else {
        throw ActivePanelValidationError.inactiveSelection(requested: selected.identity, observed: panel.identity)
      }
      guard panel.nativePixelWidth == selected.nativePixelWidth, panel.nativePixelHeight == selected.nativePixelHeight,
            panel.boundsOriginX == 0, panel.boundsOriginY == 0,
            panel.boundsWidth == selected.nativePixelWidth, panel.boundsHeight == selected.nativePixelHeight,
            Double(panel.pointScale) == selected.scale else {
        throw ActivePanelValidationError.selectedGeometryMismatch
      }
      guard panel.currentOrientation == selected.rotation else {
        throw ActivePanelValidationError.selectedRotationMismatch
      }
      return ActivePanelReadback(snapshot: snapshot, receipt: response.receipt)
    } catch let error as ActivePanelValidationError {
      throw ActivePanelReadError(validationFailure: error, receipt: response.receipt)
    }
  }

  /// Every integrated panel must match the independent host catalogue entry.
  public static func discovery(_ response: FBSimulatorDisplayInfoResponse, simulatorUDID: UUID,
                        expectedCatalog: [ActivePanelCatalogEntry],
                        acceptSteadyLitInactive: Bool = false) throws -> ActivePanelReadback {
    do {
      try Self.validateCatalog(expectedCatalog)
      let snapshot = try catalogSnapshot(response, simulatorUDID: simulatorUDID,
        expectedPanels: expectedCatalog.map(\.identity), acceptSteadyLitInactive: acceptSteadyLitInactive)
      for panel in snapshot.panels {
        guard let expected = expectedCatalog.first(where: { $0.identity == panel.identity }),
              panel.nativePixelWidth == expected.nativePixelWidth, panel.nativePixelHeight == expected.nativePixelHeight,
              panel.boundsOriginX == 0, panel.boundsOriginY == 0,
              panel.boundsWidth == expected.nativePixelWidth, panel.boundsHeight == expected.nativePixelHeight,
              Double(panel.pointScale) == expected.scale else {
          throw ActivePanelValidationError.catalogGeometryMismatch(panel.identity.displayID)
        }
      }
      return ActivePanelReadback(snapshot: snapshot, receipt: response.receipt)
    } catch let error as ActivePanelValidationError {
      throw ActivePanelReadError(validationFailure: error, receipt: response.receipt)
    }
  }

  public static func validateExpected(_ panels: [ActivePanelIdentity], selected: ActivePanelExpectation) throws {
    guard !panels.isEmpty, panels.count <= 32,
          Set(panels.map(\.displayID)).count == panels.count,
          Set(panels.map(\.uniqueID)).count == panels.count else {
      throw ActivePanelValidationError.invalidExpectedCatalog
    }
    guard panels.contains(selected.identity),
          [selected.nativePixelWidth, selected.nativePixelHeight].allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 65536 }),
          selected.scale.isFinite, selected.scale > 0, selected.scale <= 16 else {
      throw ActivePanelValidationError.invalidSelectedExpectation
    }
  }

  public static func validateCatalog(_ catalog: [ActivePanelCatalogEntry]) throws {
    guard !catalog.isEmpty, catalog.count <= 32,
          Set(catalog.map { $0.identity.displayID }).count == catalog.count,
          Set(catalog.map { $0.identity.uniqueID }).count == catalog.count,
          catalog.allSatisfy({ entry in
            [entry.nativePixelWidth, entry.nativePixelHeight].allSatisfy { $0.isFinite && $0 > 0 && $0 <= 65536 }
              && entry.scale.isFinite && entry.scale > 0 && entry.scale <= 16
          }) else {
      throw ActivePanelValidationError.invalidExpectedCatalog
    }
  }

  public static func catalogSnapshot(_ response: FBSimulatorDisplayInfoResponse, simulatorUDID: UUID,
                              expectedPanels: [ActivePanelIdentity],
                              acceptSteadyLitInactive: Bool = false) throws -> ActivePanelSnapshot {
    let rows = response.rows
    guard !rows.isEmpty, rows.count <= 32 else { throw ActivePanelValidationError.invalidDisplayCount }
    guard Set(rows.map(\.displayID)).count == rows.count, Set(rows.map(\.uniqueID)).count == rows.count else {
      throw ActivePanelValidationError.duplicateIdentity
    }
    var panels: [ActivePanel] = []
    for row in rows {
      guard row.integrated else {
        // External, wireless and virtual rows are never input targets.
        guard !row.primary, row.active != true,
              !expectedPanels.contains(where: { $0.displayID == row.displayID || $0.uniqueID == row.uniqueID }) else {
          throw ActivePanelValidationError.catalogMismatch
        }
        continue
      }
      guard row.pointScale > 0, row.pointScale <= 16,
            [row.nativeWidth, row.nativeHeight, row.boundsWidth, row.boundsHeight].allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 65536 }),
            row.boundsX.isFinite, row.boundsY.isFinite else {
        throw ActivePanelValidationError.invalidGeometry(row.displayID)
      }
      panels.append(ActivePanel(identity: ActivePanelIdentity(displayID: row.displayID, uniqueID: row.uniqueID),
        active: row.active, primary: row.primary, currentOrientation: row.currentOrientation,
        nativeOrientation: row.nativeOrientation, nativePixelWidth: row.nativeWidth, nativePixelHeight: row.nativeHeight,
        boundsOriginX: row.boundsX, boundsOriginY: row.boundsY, boundsWidth: row.boundsWidth,
        boundsHeight: row.boundsHeight, pointScale: row.pointScale, backlightState: row.backlightState))
    }
    guard Set(panels.map(\.identity)) == Set(expectedPanels), panels.count == expectedPanels.count else {
      throw ActivePanelValidationError.catalogMismatch
    }
    let panel: ActivePanel
    let basis: ActivePanelSelectionBasis
    if panels.allSatisfy({ $0.active == nil }) {
      // Rigid devices omit the flag. Their one primary integrated panel is the screen whether it
      // is lit, locked or off, as the active panel of a locked Duo is. A panel that has not
      // reported a backlight state yet is still starting.
      guard panels.count == 1, let only = panels.first, only.primary,
            let backlight = only.backlightState, backlight != "unknown" else {
        throw ActivePanelValidationError.missingActiveFlag
      }
      panel = only
      basis = .verifiedSingleIntegratedPanel
    } else {
      guard panels.allSatisfy({ $0.active != nil }) else { throw ActivePanelValidationError.missingActiveFlag }
      // During a fold the incoming panel becomes active while the outgoing one is still lit, or the
      // reverse, for about 150-240 ms, and the inner panel stays lit for 3 s after a close. A lit
      // inactive display means the configuration is changing, unless the caller proved the report
      // steady and consistent with the hinge (see FBSimulatorLitInactivePolicy).
      let litInactive = FBSimulatorLitInactivePolicy.hasLitInactivePanel(rows)
      let active = panels.filter { $0.active == true }
      if litInactive {
        guard acceptSteadyLitInactive, active.count == 1,
              let only = active.first, Self.litBacklightStates.contains(only.backlightState ?? "") else {
          throw FBSimulatorContextError.changedDuringRead
        }
      }
      guard active.count == 1, let only = active.first else {
        throw ActivePanelValidationError.activeStateUnavailable(active.count)
      }
      panel = only
      basis = litInactive ? .steadyExplicitActiveFlag : .explicitActiveFlag
    }
    return ActivePanelSnapshot(requestedSimulatorUDID: simulatorUDID, sourceCommandType: action,
      sourceJSONVersion: 0, sourceVersion: response.coreDeviceVersion, activePanel: panel,
      selectionBasis: basis, panels: panels)
  }

  // MARK: Wire

  private static func failure(_ message: String) -> NSError { FBSimulatorError.describe(message).build() }

  private static func connect(_ simulator: FBSimulator) throws -> xpc_connection_t {
    typealias Endpoint = @convention(c) (mach_port_t, UInt64, UInt64) -> xpc_object_t?
    typealias Connect = @convention(c) (xpc_object_t) -> xpc_connection_t?
    typealias Enable = @convention(c) (xpc_connection_t) -> Void
    guard let handle = dlopen(nil, RTLD_NOW),
          let endpointSymbol = dlsym(handle, "xpc_endpoint_create_mach_port_4sim"),
          let connectSymbol = dlsym(handle, "xpc_connection_create_from_endpoint"),
          let enableSymbol = dlsym(handle, "xpc_connection_enable_sim2host_4sim") else {
      throw failure("Simulator XPC functions unavailable")
    }
    var error: NSError?
    let port = simulator.device.lookup(service, error: &error)
    guard port != 0,
          let endpoint = unsafeBitCast(endpointSymbol, to: Endpoint.self)(port, 0, 0),
          let connection = unsafeBitCast(connectSymbol, to: Connect.self)(endpoint) else {
      throw error ?? failure("Display info service unavailable")
    }
    unsafeBitCast(enableSymbol, to: Enable.self)(connection)
    return connection
  }

  private static func makeRequest(deviceID: String) throws -> (xpc_object_t, String) {
    guard let version = Bundle(path: "/Library/Developer/PrivateFrameworks/CoreDevice.framework")?
      .object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
      throw failure("CoreDevice version metadata unavailable")
    }
    let parts = version.split(separator: ".", omittingEmptySubsequences: false)
    let components = xpc_array_create(nil, 0)
    for part in parts {
      guard let value = UInt64(part) else { throw failure("CoreDevice version is not numeric") }
      xpc_array_append_value(components, xpc_uint64_create(value))
    }
    let coreDeviceVersion = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_value(coreDeviceVersion, "components", components)
    xpc_dictionary_set_int64(coreDeviceVersion, "originalComponentsCount", Int64(parts.count))
    xpc_dictionary_set_string(coreDeviceVersion, "stringValue", version)
    let request = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_string(request, "CoreDevice.actionIdentifier", action)
    xpc_dictionary_set_string(request, "CoreDevice.deviceIdentifier", deviceID)
    xpc_dictionary_set_string(request, "CoreDevice.invocationIdentifier", UUID().uuidString)
    xpc_dictionary_set_int64(request, "CoreDevice.CoreDeviceDDIProtocolVersion", 1)
    xpc_dictionary_set_value(request, "CoreDevice.coreDeviceVersion", coreDeviceVersion)
    xpc_dictionary_set_value(request, "CoreDevice.input", xpc_dictionary_create(nil, nil, 0))
    return (request, version)
  }

  public static func decode(_ reply: xpc_object_t) throws -> [FBSimulatorDisplayInfoRow] {
    guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY, xpc_dictionary_get_value(reply, "CoreDevice.error") == nil else {
      throw failure("Display info service rejected the request")
    }
    let output = try child(reply, "CoreDevice.output", XPC_TYPE_DICTIONARY)
    guard xpc_bool_get_value(try child(output, "current", XPC_TYPE_BOOL)) else {
      throw failure("Display info is not current")
    }
    let displays = try child(output, "displays", XPC_TYPE_ARRAY)
    let count = xpc_array_get_count(displays)
    guard count > 0, count <= 32 else { throw failure("Display info has an invalid display count") }
    // iOS 27.0 reports backlightState once for the device instead of on each display row.
    // That value can only describe a sole integrated panel; several panels must report their own.
    let integratedCount = (0..<count).filter { index in
      let row = xpc_array_get_value(displays, index)
      guard xpc_get_type(row) == XPC_TYPE_DICTIONARY,
            let kind = xpc_dictionary_get_value(row, "type"), xpc_get_type(kind) == XPC_TYPE_DICTIONARY else { return false }
      return xpc_dictionary_get_value(kind, "integrated") != nil
    }.count
    let deviceBacklight = integratedCount == 1
      ? xpc_dictionary_get_string(output, "backlightState").map { String(cString: $0) } : nil
    return try (0..<count).map { index in
      let row = xpc_array_get_value(displays, index)
      guard xpc_get_type(row) == XPC_TYPE_DICTIONARY else { throw failure("Display row is not a dictionary") }
      let kind = try child(row, "type", XPC_TYPE_DICTIONARY)
      guard xpc_dictionary_get_count(kind) == 1 else { throw failure("Display row has an ambiguous type") }
      let native = try pair(row, "nativeSize")
      let bounds = try child(row, "bounds", XPC_TYPE_ARRAY)
      guard xpc_array_get_count(bounds) == 2 else { throw failure("Display bounds are malformed") }
      let origin = try pair(xpc_array_get_value(bounds, 0))
      let size = try pair(xpc_array_get_value(bounds, 1))
      guard let uniqueID = UUID(uuidString: try string(row, "uniqueId")),
            let current = ActivePanelRotation(rawValue: try string(row, "currentOrientation")),
            let nativeOrientation = ActivePanelRotation(rawValue: try string(row, "nativeOrientation")) else {
        throw failure("Display row identity or orientation is malformed")
      }
      let displayID = xpc_uint64_get_value(try child(row, "displayId", XPC_TYPE_UINT64))
      guard displayID <= UInt64(UInt32.max) else { throw failure("Display ID is out of range") }
      let active = xpc_dictionary_get_value(row, "active")
      if let active, xpc_get_type(active) != XPC_TYPE_BOOL { throw failure("Display active flag is not a Bool") }
      let integrated = xpc_dictionary_get_value(kind, "integrated") != nil
      let rowBacklight = xpc_dictionary_get_string(row, "backlightState").map { String(cString: $0) }
      return FBSimulatorDisplayInfoRow(displayID: UInt32(displayID), uniqueID: uniqueID,
        integrated: integrated,
        active: active.map { xpc_bool_get_value($0) },
        primary: xpc_bool_get_value(try child(row, "primary", XPC_TYPE_BOOL)),
        currentOrientation: current, nativeOrientation: nativeOrientation,
        nativeWidth: native.0, nativeHeight: native.1, boundsX: origin.0, boundsY: origin.1,
        boundsWidth: size.0, boundsHeight: size.1,
        pointScale: Int(xpc_int64_get_value(try child(row, "pointScale", XPC_TYPE_INT64))),
        backlightState: rowBacklight ?? (integrated ? deviceBacklight : nil))
    }
  }

  private static func child(_ object: xpc_object_t, _ key: String, _ type: xpc_type_t) throws -> xpc_object_t {
    guard let value = xpc_dictionary_get_value(object, key), xpc_get_type(value) == type else {
      throw failure("Missing or invalid display info field: \(key)")
    }
    return value
  }

  private static func string(_ object: xpc_object_t, _ key: String) throws -> String {
    String(cString: xpc_string_get_string_ptr(try child(object, key, XPC_TYPE_STRING))!)
  }

  private static func pair(_ object: xpc_object_t, _ key: String) throws -> (Double, Double) {
    try pair(try child(object, key, XPC_TYPE_ARRAY))
  }

  private static func pair(_ array: xpc_object_t) throws -> (Double, Double) {
    guard xpc_get_type(array) == XPC_TYPE_ARRAY, xpc_array_get_count(array) == 2 else {
      throw failure("Display geometry pair is malformed")
    }
    let values = (0..<2).map { xpc_array_get_value(array, $0) }
    guard values.allSatisfy({ xpc_get_type($0) == XPC_TYPE_DOUBLE }) else { throw failure("Display geometry is not numeric") }
    let a = xpc_double_get_value(values[0]), b = xpc_double_get_value(values[1])
    guard a.isFinite, b.isFinite else { throw failure("Display geometry is not finite") }
    return (a, b)
  }
}
