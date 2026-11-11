import FBSimulatorControl
import Foundation
import Testing
import XPC

/// Replies follow the measured dtdeviceinfod `displayinfo` output for iPhone 18 Pro (no active key)
/// and iPhone Duo (explicit active flags, inner panel at rot90 while the cover is at rot0).
@Suite("In-process CoreDevice display info")
struct FBSimulatorDisplayInfoReaderTests {
  private let simulator = UUID(uuidString: "2154413A-7E31-4566-A03E-598AC9B5D4D7")!
  private let cover = UUID(uuidString: "682E7192-7AC8-4BF7-95C9-F01CA06D4053")!
  private let inner = UUID(uuidString: "6A81DC89-92B1-4B27-AB68-F6870D1EF642")!
  private let rigid = UUID(uuidString: "AA9A9ACC-A21D-4534-BCF4-B4ED099F7E6E")!

  @Test func rigidReplySelectsTheOnlyLitPrimaryIntegratedPanel() throws {
    let rows = try FBSimulatorDisplayInfoReader.decode(reply([rigidRow()] + virtualRows(startingAt: 2)))
    #expect(rows.count == 4 && rows.filter(\.integrated).count == 1)
    let snapshot = try discover(rows, catalog: [entry(1, rigid, 1206, 2622)]).snapshot
    #expect(snapshot.selectionBasis == .verifiedSingleIntegratedPanel)
    #expect(snapshot.panels.count == 1 && snapshot.activePanel.identity == .init(displayID: 1, uniqueID: rigid))
    #expect(snapshot.activePanel.active == nil && snapshot.activePanel.currentOrientation == .rot0)
  }

  @Test func rigidReplyWithoutActiveFlagNeedsPrimaryStartedPanel() throws {
    for row in [rigidRow(primary: false), rigidRow(backlight: "unknown"), rigidRow(backlight: nil)] {
      let rows = try FBSimulatorDisplayInfoReader.decode(reply([row]))
      #expect(failure { try discover(rows, catalog: [entry(1, rigid, 1206, 2622)]) } == .missingActiveFlag)
    }
  }

  @Test func rigidReplySelectsALockedOrDarkPanel() throws {
    for backlight in ["inactiveOn", "off", "activeDimmed"] {
      let rows = try FBSimulatorDisplayInfoReader.decode(reply([rigidRow(backlight: backlight)]))
      let snapshot = try discover(rows, catalog: [entry(1, rigid, 1206, 2622)]).snapshot
      #expect(snapshot.selectionBasis == .verifiedSingleIntegratedPanel)
      #expect(snapshot.activePanel.backlightState == backlight)
    }
  }

  /// A host with CoreDevice 642.16 (Xcode 27.0) gets backlightState for the device, not on the display row.
  @Test func rigidReplyTakesTheDeviceBacklightWhenTheRowHasNone() throws {
    // A device that has not started yet is still refused.
    let starting = try FBSimulatorDisplayInfoReader.decode(reply([rigidRow(backlight: nil)], deviceBacklight: "unknown"))
    #expect(starting.first?.backlightState == "unknown")
    #expect(failure { try discover(starting, catalog: [entry(1, rigid, 1206, 2622)]) } == .missingActiveFlag)

    let rows = try FBSimulatorDisplayInfoReader.decode(
      reply([rigidRow(backlight: nil)] + virtualRows(startingAt: 2), deviceBacklight: "activeOn"))
    let snapshot = try discover(rows, catalog: [entry(1, rigid, 1206, 2622)]).snapshot
    #expect(snapshot.selectionBasis == .verifiedSingleIntegratedPanel)
    #expect(snapshot.activePanel.backlightState == "activeOn")

    let ownState = try FBSimulatorDisplayInfoReader.decode(reply([rigidRow(backlight: "off")], deviceBacklight: "activeOn"))
    #expect(ownState.first?.backlightState == "off")

    let duo = duoRows(coverActive: true).map { row in
      let copy = xpc_dictionary_create(nil, nil, 0)
      xpc_dictionary_apply(row) { key, value in
        if String(cString: key) != "backlightState" { xpc_dictionary_set_value(copy, key, value) }
        return true
      }
      return copy
    }
    let duoDecoded = try FBSimulatorDisplayInfoReader.decode(reply(duo, deviceBacklight: "activeOn"))
    #expect(duoDecoded.allSatisfy { $0.backlightState == nil })
  }

  @Test func duoReplyFollowsTheExplicitActiveFlagAndPerPanelRotation() throws {
    let rows = try FBSimulatorDisplayInfoReader.decode(reply(duoRows(coverActive: true)))
    let readback = try discover(rows, catalog: duoCatalog)
    #expect(readback.snapshot.selectionBasis == .explicitActiveFlag)
    #expect(readback.snapshot.activePanel.identity == .init(displayID: 1, uniqueID: cover))
    #expect(readback.snapshot.panels.first { $0.identity.displayID == 3 }?.currentOrientation == .rot90)
    #expect(readback.receipt.exitConfirmed && readback.receipt.processIdentifier == nil)

    let unfolded = try FBSimulatorDisplayInfoReader.decode(reply(duoRows(coverActive: false)))
    let selected = try FBSimulatorDisplayInfoReader.snapshot(response(unfolded), simulatorUDID: simulator,
      expectedPanels: duoCatalog.map(\.identity), selected: expectation(3, inner, 2007, 2853, .rot90))
    #expect(selected.snapshot.activePanel.identity.displayID == 3)
  }

  @Test func duoSelectionRejectsInactivePanelAndStaleRotation() throws {
    let rows = try FBSimulatorDisplayInfoReader.decode(reply(duoRows(coverActive: true)))
    let identities = duoCatalog.map(\.identity)
    let inactive = failure {
      try FBSimulatorDisplayInfoReader.snapshot(response(rows), simulatorUDID: simulator,
        expectedPanels: identities, selected: expectation(3, inner, 2007, 2853, .rot90))
    }
    #expect(inactive == .inactiveSelection(requested: .init(displayID: 3, uniqueID: inner),
      observed: .init(displayID: 1, uniqueID: cover)))
    let rotated = failure {
      try FBSimulatorDisplayInfoReader.snapshot(response(rows), simulatorUDID: simulator,
        expectedPanels: identities, selected: expectation(1, cover, 1398, 2034, .rot90))
    }
    #expect(rotated == .selectedRotationMismatch)
  }

  @Test func duoReplyNeedsExactlyOneExplicitActivePanel() throws {
    let both = duoRows(coverActive: true).enumerated().map { $0.offset == 2 ? row($0.element, active: true) : $0.element }
    #expect(failure { try discover(FBSimulatorDisplayInfoReader.decode(reply(both)), catalog: duoCatalog) }
      == .activeStateUnavailable(2))
    let missing = duoRows(coverActive: true).enumerated().map { $0.offset == 2 ? row($0.element, active: nil) : $0.element }
    #expect(failure { try discover(FBSimulatorDisplayInfoReader.decode(reply(missing)), catalog: duoCatalog) }
      == .missingActiveFlag)
  }

  /// Measured fold and unfold reports: the incoming panel is active while the outgoing one is still lit.
  @Test func litInactivePanelMeansTheFoldIsStillChanging() throws {
    let transitions = [duoRows(coverActive: true, coverLight: "activeOn", innerLight: "activeOn"),
                       duoRows(coverActive: false, coverLight: "activeOn", innerLight: "activeOn"),
                       duoRows(coverActive: true, coverLight: "activeOn", innerLight: "activeDimmed")]
    for rows in transitions {
      let decoded = try FBSimulatorDisplayInfoReader.decode(reply(rows))
      #expect(throws: FBSimulatorContextError.self) { _ = try discover(decoded, catalog: duoCatalog) }
      #expect(throws: FBSimulatorContextError.self) {
        _ = try FBSimulatorDisplayInfoReader.snapshot(response(decoded), simulatorUDID: simulator,
          expectedPanels: duoCatalog.map(\.identity), selected: expectation(1, cover, 1398, 2034, .rot0))
      }
    }
    let settled = try FBSimulatorDisplayInfoReader.decode(reply(duoRows(coverActive: true, coverLight: "activeDimmed", innerLight: "off")))
    #expect(try discover(settled, catalog: duoCatalog).snapshot.activePanel.identity.displayID == 1)
    let dimmedRigid = try FBSimulatorDisplayInfoReader.decode(reply([rigidRow(backlight: "activeDimmed")]))
    #expect(try discover(dimmedRigid, catalog: [entry(1, rigid, 1206, 2622)]).snapshot.selectionBasis == .verifiedSingleIntegratedPanel)
  }

  @Test func nonIntegratedRowsCanNeverBeSelected() throws {
    for change in [{ (r: xpc_object_t) in xpc_dictionary_set_bool(r, "primary", true) },
                   { (r: xpc_object_t) in xpc_dictionary_set_bool(r, "active", true) }] {
      var rows = [rigidRow()] + virtualRows(startingAt: 2)
      rows[1] = copy(rows[1]); change(rows[1])
      #expect(failure { try discover(FBSimulatorDisplayInfoReader.decode(reply(rows)),
        catalog: [entry(1, rigid, 1206, 2622)]) } == .catalogMismatch)
    }
  }

  @Test func hostGeometryAndIdentityRemainRequired() throws {
    let rows = try FBSimulatorDisplayInfoReader.decode(reply([rigidRow()]))
    #expect(failure { try discover(rows, catalog: [entry(1, rigid, 1206, 2622, scale: 2)]) }
      == .catalogGeometryMismatch(1))
    #expect(failure { try discover(rows, catalog: [entry(1, inner, 1206, 2622)]) } == .catalogMismatch)
  }

  @Test func malformedOrRejectedRepliesFail() throws {
    let error = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_value(error, "CoreDevice.error", xpc_dictionary_create(nil, nil, 0))
    let stale = reply([rigidRow()])
    xpc_dictionary_set_bool(xpc_dictionary_get_value(stale, "CoreDevice.output")!, "current", false)
    let badActive = copy(rigidRow())
    xpc_dictionary_set_string(badActive, "active", "true")
    let badRotation = copy(rigidRow())
    xpc_dictionary_set_string(badRotation, "currentOrientation", "rot45")
    for value in [error, stale, reply([badActive]), reply([badRotation]), reply([])] {
      #expect(throws: (any Error).self) { _ = try FBSimulatorDisplayInfoReader.decode(value) }
    }
  }

  // MARK: Helpers

  private var duoCatalog: [ActivePanelCatalogEntry] {
    [entry(1, cover, 1398, 2034), entry(3, inner, 2007, 2853)]
  }

  private func discover(_ rows: [FBSimulatorDisplayInfoRow], catalog: [ActivePanelCatalogEntry]) throws -> ActivePanelReadback {
    try FBSimulatorDisplayInfoReader.discovery(response(rows), simulatorUDID: simulator, expectedCatalog: catalog)
  }

  private func response(_ rows: [FBSimulatorDisplayInfoRow]) -> FBSimulatorDisplayInfoResponse {
    FBSimulatorDisplayInfoResponse(rows: rows, coreDeviceVersion: "689.2", startedUptime: 1, finishedUptime: 2)
  }

  private func failure(_ body: () throws -> Any) -> ActivePanelValidationError? {
    do { _ = try body(); return nil } catch let error as ActivePanelReadError { return error.validationFailure } catch { return nil }
  }

  private func entry(_ id: UInt32, _ uuid: UUID, _ w: Double, _ h: Double, scale: Double = 3) -> ActivePanelCatalogEntry {
    .init(identity: .init(displayID: id, uniqueID: uuid), nativePixelWidth: w, nativePixelHeight: h, scale: scale)
  }

  private func expectation(_ id: UInt32, _ uuid: UUID, _ w: Double, _ h: Double, _ rotation: ActivePanelRotation) -> ActivePanelExpectation {
    .init(identity: .init(displayID: id, uniqueID: uuid), nativePixelWidth: w, nativePixelHeight: h, scale: 3, rotation: rotation)
  }

  private func rigidRow(primary: Bool = true, backlight: String? = "activeOn") -> xpc_object_t {
    display(id: 1, uuid: rigid, kind: "integrated", primary: primary, active: nil, rotation: "rot0",
      size: (1206, 2622), backlight: backlight)
  }

  private func duoRows(coverActive: Bool, coverLight: String? = nil, innerLight: String? = nil) -> [xpc_object_t] {
    [display(id: 1, uuid: cover, kind: "integrated", primary: true, active: coverActive, rotation: "rot0",
             size: (1398, 2034), backlight: coverLight ?? (coverActive ? "activeOn" : "off")),
     display(id: 2, uuid: UUID(), kind: "external", primary: false, active: false, rotation: "rot0", size: (0, 0), backlight: "off"),
     display(id: 3, uuid: inner, kind: "integrated", primary: false, active: !coverActive, rotation: "rot90",
             size: (2007, 2853), backlight: innerLight ?? (coverActive ? "off" : "activeOn")),
     display(id: 4, uuid: UUID(), kind: "wireless", primary: false, active: false, rotation: "rot0", size: (0, 0), backlight: "off"),
     display(id: 5, uuid: UUID(), kind: "virtual", primary: false, active: false, rotation: "rot0", size: (0, 0), backlight: "off")]
  }

  private func virtualRows(startingAt first: UInt64) -> [xpc_object_t] {
    ["external", "wireless", "virtual"].enumerated().map { index, kind in
      display(id: first + UInt64(index), uuid: UUID(), kind: kind, primary: false, active: nil, rotation: "rot0",
              size: (0, 0), backlight: "off")
    }
  }

  private func row(_ source: xpc_object_t, active: Bool?) -> xpc_object_t {
    let result = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_apply(source) { key, value in
      if String(cString: key) != "active" { xpc_dictionary_set_value(result, key, value) }
      return true
    }
    if let active { xpc_dictionary_set_bool(result, "active", active) }
    return result
  }

  private func copy(_ source: xpc_object_t) -> xpc_object_t { xpc_copy(source)! }

  private func reply(_ rows: [xpc_object_t], deviceBacklight: String? = nil) -> xpc_object_t {
    let displays = xpc_array_create(nil, 0)
    rows.forEach { xpc_array_append_value(displays, $0) }
    let output = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_bool(output, "current", true)
    if let deviceBacklight { xpc_dictionary_set_string(output, "backlightState", deviceBacklight) }
    xpc_dictionary_set_value(output, "displays", displays)
    let result = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_value(result, "CoreDevice.output", output)
    return result
  }

  private func display(id: UInt64, uuid: UUID, kind: String, primary: Bool, active: Bool?, rotation: String,
                       size: (Double, Double), backlight: String?) -> xpc_object_t {
    let row = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_uint64(row, "displayId", id)
    xpc_dictionary_set_string(row, "uniqueId", uuid.uuidString)
    let type = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_value(type, kind, xpc_dictionary_create(nil, nil, 0))
    xpc_dictionary_set_value(row, "type", type)
    xpc_dictionary_set_bool(row, "primary", primary)
    if let active { xpc_dictionary_set_bool(row, "active", active) }
    xpc_dictionary_set_string(row, "currentOrientation", rotation)
    xpc_dictionary_set_string(row, "nativeOrientation", "rot0")
    xpc_dictionary_set_value(row, "nativeSize", pair(size.0, size.1))
    let bounds = xpc_array_create(nil, 0)
    xpc_array_append_value(bounds, pair(0, 0))
    xpc_array_append_value(bounds, pair(size.0, size.1))
    xpc_dictionary_set_value(row, "bounds", bounds)
    xpc_dictionary_set_int64(row, "pointScale", kind == "integrated" ? 3 : 1)
    if let backlight { xpc_dictionary_set_string(row, "backlightState", backlight) }
    return row
  }

  private func pair(_ a: Double, _ b: Double) -> xpc_object_t {
    let value = xpc_array_create(nil, 0)
    xpc_array_append_value(value, xpc_double_create(a))
    xpc_array_append_value(value, xpc_double_create(b))
    return value
  }
}
