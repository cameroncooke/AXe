import Foundation
@preconcurrency import FBControlCore

/// One optional idle transport for an explicit caller. Input ownership stays in each session.
/// Borrowed sessions must be closed. An abandoned reservation fails closed; it is never reused.
public actor FBSimulatorHIDTransportOwner {
  private struct Connection {
    let identifier: UUID
    let observation: FBSimulatorHIDSessionObservation
    let transport: FBSimulatorDTUHIDTransport
  }
  private struct Borrow {
    let identifier: UUID
    var allowsReuse: Bool
  }
  private var idle: Connection?
  private var borrowed: Borrow?
  private var closed = false

  public init() {}

  /// Discard idle transport. A current action retains its connection for owned cleanup,
  /// but cannot return that transport to this owner afterwards.
  public func invalidate() {
    idle?.transport.disconnect()
    idle = nil
    if borrowed != nil { borrowed?.allowsReuse = false }
  }

  /// Prevent new borrows and discard idle transport. Close active sessions first when
  /// waiting for all input cleanup; this method does not interrupt their release work.
  public func close() {
    closed = true
    invalidate()
  }

  func reserve(observation: FBSimulatorHIDSessionObservation) throws -> FBSimulatorHIDTransportReservation {
    guard !closed else { throw FBSimulatorHIDSessionError.closed }
    guard borrowed == nil else { throw FBSimulatorHIDSessionError.busy }
    let identifier = UUID()
    borrowed = Borrow(identifier: identifier, allowsReuse: true)
    let previous = idle
    idle = nil
    guard let previous else {
      return FBSimulatorHIDTransportReservation(identifier: identifier, connectionID: UUID(), transport: nil)
    }
    guard previous.observation == observation else {
      previous.transport.disconnect()
      return FBSimulatorHIDTransportReservation(identifier: identifier, connectionID: UUID(), transport: nil)
    }
    return FBSimulatorHIDTransportReservation(identifier: identifier,
      connectionID: previous.identifier, transport: previous.transport)
  }

  func discard(_ identifier: UUID) {
    guard borrowed?.identifier == identifier else { return }
    borrowed = nil
  }

  func finish(_ lease: FBSimulatorHIDTransportLease, reusable: Bool) {
    guard let active = borrowed, active.identifier == lease.reservationID else {
      lease.transport.disconnect()
      return
    }
    borrowed = nil
    guard reusable, active.allowsReuse, !closed else {
      lease.transport.disconnect()
      FBControlCoreGlobalConfiguration.defaultLogger.log("Selected HID transport discarded connection=\(lease.connectionID)")
      return
    }
    idle = Connection(identifier: lease.connectionID, observation: lease.observation, transport: lease.transport)
    FBControlCoreGlobalConfiguration.defaultLogger.log("Selected HID transport returned connection=\(lease.connectionID)")
  }
}

struct FBSimulatorHIDTransportReservation: Sendable {
  let identifier: UUID
  let connectionID: UUID
  let transport: FBSimulatorDTUHIDTransport?
}

struct FBSimulatorHIDTransportLease: Sendable {
  let owner: FBSimulatorHIDTransportOwner
  let reservationID: UUID
  let connectionID: UUID
  let observation: FBSimulatorHIDSessionObservation
  let transport: FBSimulatorDTUHIDTransport

  func finish(reusable: Bool) async {
    await owner.finish(self, reusable: reusable)
  }
}
