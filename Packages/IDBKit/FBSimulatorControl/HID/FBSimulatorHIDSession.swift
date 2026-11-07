import CoreGraphics
@preconcurrency import FBControlCore
import Foundation

/// Owns one fixed display context and one DTUHID connection. A new session and lookup are required
/// after invalidation. No raw connection or active contact can migrate to another revision.
public actor FBSimulatorHIDSession {
  private enum Contacts: Sendable {
    case single(CGPoint)
    case pair(CGPoint, CGPoint)
  }
  private enum SubmissionMode: Equatable { case complete, ownedPart, legacyBatch, legacyKeyboard }
  private enum OwnedStreamMode: Equatable { case strict, legacyBatch }
  private struct OwnedInputState {
    let contactCount: Int
    let keys: Set<UInt32>
    let buttons: Set<FBSimulatorHIDButton>
  }

  private let transport: any FBSimulatorHIDTransport
  private let transportLease: FBSimulatorHIDTransportLease?
  private let observation: FBSimulatorHIDSessionObservation
  private let freshnessProvider: any FBSimulatorHIDFreshnessProvider
  private let liveProvider: (any FBSimulatorHIDLiveFreshnessProvider)?
  private let sessionID = UUID()
  private var state: FBSimulatorHIDSessionState = .ready
  private var inFlight = false
  private var contacts: Contacts?
  private var token: FBSimulatorHIDContactToken?
  private var retainedMonitor: Task<Void, Never>?
  private var retainedMonitorID: UUID?
  private var idleCleanupInProgress = false
  private var idleCleanupWaiters: [CheckedContinuation<Void, Never>] = []
  private var heldKeys = Set<UInt32>()
  private var heldButtons = Set<FBSimulatorHIDButton>()
  private var ownedStreamMode: OwnedStreamMode?
  private var usesOwnedParts: Bool { ownedStreamMode != nil }
  private var sentCount = 0
  private var lastCleanup: FBSimulatorHIDCleanupOutcome = .notNeeded
  private var lastCleanupEvidence: FBSimulatorHIDCleanupEvidence?
  private var lastExecutionEvidence: FBSimulatorHIDExecutionEvidence?

  public func cleanupEvidence() -> FBSimulatorHIDCleanupEvidence? { lastCleanupEvidence }
  public func executionEvidence() -> FBSimulatorHIDExecutionEvidence? { lastExecutionEvidence }

  public static func open(for simulator: FBSimulator,
                          observation: FBSimulatorHIDSessionObservation,
                          freshnessProvider: any FBSimulatorHIDFreshnessProvider) async throws -> FBSimulatorHIDSession {
    try await openSession(for: simulator, observation: observation, freshnessProvider: freshnessProvider, liveProvider: nil)
  }

  /// Takes ownership of the live provider, including when opening fails.
  public static func open(for simulator: FBSimulator,
                          observation: FBSimulatorHIDSessionObservation,
                          liveFreshnessProvider: any FBSimulatorHIDLiveFreshnessProvider) async throws -> FBSimulatorHIDSession {
    do {
      return try await openSession(for: simulator, observation: observation,
        freshnessProvider: liveFreshnessProvider, liveProvider: liveFreshnessProvider)
    } catch { liveFreshnessProvider.close(); throw error }
  }

  /// Explicit healthy transport reuse. Each call creates a new session and input ledger.
  /// The caller owns the transport owner and must close each returned session.
  public static func open(for simulator: FBSimulator,
                          observation: FBSimulatorHIDSessionObservation,
                          liveFreshnessProvider: any FBSimulatorHIDLiveFreshnessProvider,
                          transportOwner: FBSimulatorHIDTransportOwner) async throws -> FBSimulatorHIDSession {
    do {
      return try await openSession(for: simulator, observation: observation,
        freshnessProvider: liveFreshnessProvider, liveProvider: liveFreshnessProvider,
        transportOwner: transportOwner)
    } catch { liveFreshnessProvider.close(); throw error }
  }

  /// Explicit opt-in hint for one fixed selected display. The hint is geometric;
  /// successful input delivery does not prove a system navigation effect.
  /// Takes ownership of the live provider, including when opening fails.
  public static func open(for simulator: FBSimulator,
                          observation: FBSimulatorHIDSessionObservation,
                          logicalEdge: FBSimulatorHIDLogicalEdge,
                          liveFreshnessProvider: any FBSimulatorHIDLiveFreshnessProvider) async throws -> FBSimulatorHIDSession {
    do {
      return try await openSession(for: simulator, observation: observation,
        freshnessProvider: liveFreshnessProvider, liveProvider: liveFreshnessProvider,
        nativeEdge: logicalEdge.nativeEdge(for: observation.displayContext.rotation))
    } catch { liveFreshnessProvider.close(); throw error }
  }

  private static func openSession(for simulator: FBSimulator,
                                  observation: FBSimulatorHIDSessionObservation,
                                  freshnessProvider: any FBSimulatorHIDFreshnessProvider,
                                  liveProvider: (any FBSimulatorHIDLiveFreshnessProvider)?,
                                  nativeEdge: FBSimulatorHIDNativeEdge = .none,
                                  transportOwner: FBSimulatorHIDTransportOwner? = nil) async throws -> FBSimulatorHIDSession {
    var reservation: FBSimulatorHIDTransportReservation?
    var transport: FBSimulatorDTUHIDTransport?
    do {
      if let transportOwner {
        let reserved = try await transportOwner.reserve(observation: observation)
        reservation = reserved
        transport = reserved.transport
      }
      guard simulator.udid == observation.simulatorUDID else {
        throw FBSimulatorHIDSessionError.invalidObservation("Simulator identity does not match")
      }
      let display: FBSimulatorDisplayInfo
      do { display = try await FBSimulatorDisplayDiscovery.display(for: simulator, screenID: observation.screenID) }
      catch is CancellationError { throw CancellationError() }
      catch { throw FBSimulatorHIDSessionError.invalidObservation("Runtime display lookup failed: \(error)") }
      guard display.uniqueID == observation.screenUniqueID,
            display.nativePixelSize == observation.displayContext.nativePixelSize,
            display.scale == observation.displayContext.scale,
            UInt64(display.screenID) == observation.displayContext.hidTarget else {
        throw FBSimulatorHIDSessionError.invalidObservation("Selected runtime display does not match the measured context")
      }
      guard try await freshnessProvider.observation() == observation else {
        throw FBSimulatorHIDSessionError.invalidObservation("Context changed before opening the connection")
      }
      try Task.checkCancellation()
      var connectionID = reservation?.connectionID ?? UUID()
      if let cached = transport, !(await cached.acceptsInput()) {
        cached.disconnect()
        transport = nil
        connectionID = UUID()
      }
      let reused = transport != nil
      if transport == nil {
        // The initial guest barrier carries no input. On Xcode 27.2 a new connection opened soon
        // after an earlier owned session can go unanswered for its whole timeout; the guest then
        // answers a fresh connection. Try one, after the context check, before any input.
        for attempt in 0..<2 {
          let opened = try FBSimulatorDTUHIDTransport.dtuhid(for: simulator,
            displayContext: observation.displayContext, nativeEdge: nativeEdge, ownedCleanup: true)
          transport = opened
          do {
            try await opened.prepareSelectedConnection()
            break
          } catch is CancellationError {
            throw CancellationError()
          } catch where attempt == 0 && !Task.isCancelled {
            opened.disconnect()
            transport = nil
            guard try await freshnessProvider.observation() == observation else {
              throw FBSimulatorHIDSessionError.invalidObservation("Context changed before opening the connection")
            }
            FBControlCoreGlobalConfiguration.defaultLogger.log("Selected HID initial barrier failed; opening one fresh connection: \(error)")
          }
        }
      }
      try Task.checkCancellation()
      guard let transport else { throw FBSimulatorHIDSessionError.invalidObservation("Missing owned transport") }
      var lease: FBSimulatorHIDTransportLease?
      if let transportOwner, let reservation {
        lease = FBSimulatorHIDTransportLease(owner: transportOwner, reservationID: reservation.identifier,
          connectionID: connectionID, observation: observation, transport: transport)
        FBControlCoreGlobalConfiguration.defaultLogger.log("Selected HID transport acquired connection=\(connectionID) reused=\(reused)")
      }
      if let lease {
        return FBSimulatorHIDSession(transport: transport, observation: observation,
          freshnessProvider: freshnessProvider, liveProvider: liveProvider, transportLease: lease)
      }
      return FBSimulatorHIDSession(transport: transport, observation: observation,
        freshnessProvider: freshnessProvider, liveProvider: liveProvider)
    } catch {
      transport?.disconnect()
      if let transportOwner, let reservation { await transportOwner.discard(reservation.identifier) }
      throw error
    }
  }

  // Internal dependency boundary also permits local transport checks without simulator input.
  init(transport: any FBSimulatorHIDTransport, observation: FBSimulatorHIDSessionObservation,
       freshnessProvider: any FBSimulatorHIDFreshnessProvider,
       liveProvider: (any FBSimulatorHIDLiveFreshnessProvider)? = nil) {
    self.transport = transport
    self.transportLease = nil
    self.observation = observation
    self.freshnessProvider = freshnessProvider
    self.liveProvider = liveProvider
  }

  init(transport: any FBSimulatorHIDTransport, observation: FBSimulatorHIDSessionObservation,
       freshnessProvider: any FBSimulatorHIDFreshnessProvider,
       liveProvider: (any FBSimulatorHIDLiveFreshnessProvider)?,
       transportLease: FBSimulatorHIDTransportLease) {
    self.transport = transport
    self.transportLease = transportLease
    self.observation = observation
    self.freshnessProvider = freshnessProvider
    self.liveProvider = liveProvider
  }

  deinit { retainedMonitor?.cancel() }

  public func status() -> FBSimulatorHIDSessionStatus {
    FBSimulatorHIDSessionStatus(state: state, hasRetainedContact: contacts != nil,
      enqueuedEventCount: sentCount, lastCleanup: lastCleanup)
  }

  /// Checks a real retained single-contact receipt before Slider-owned value feedback starts.
  /// This does not send input or change session ownership.
  func validateSliderValuePickup(_ receipt: FBSimulatorHIDSessionReceipt,
    expected: FBSimulatorHIDSessionObservation) throws {
    guard observation == expected, !inFlight, !usesOwnedParts,
          state == .retainedContacts, case .single? = contacts,
          heldKeys.isEmpty, heldButtons.isEmpty, sentCount == 1,
          receipt.outcome == .retained, receipt.enqueuedEventCount == 1,
          receipt.cleanup == .notNeeded, let receiptToken = receipt.token,
          receiptToken == token, receiptToken.sessionID == sessionID else {
      throw FBSimulatorHIDSessionError.invalidEvent("Slider value feedback requires this session's retained pickup")
    }
  }

  /// Pure full-composite validation. Execution repeats this check before sending.
  public static func preflight(_ event: FBSimulatorHIDEvent,
                               observation: FBSimulatorHIDSessionObservation) throws -> FBSimulatorHIDPreflight {
    let events = try prepare(event, context: observation.displayContext)
    return FBSimulatorHIDPreflight(primitiveCount: events.filter { if case .delay = $0 { return false }; return true }.count,
      requestedDelaySeconds: events.reduce(0) { total, item in
        if case let .delay(seconds) = item { return total + seconds }; return total
      })
  }

  public func execute(_ event: FBSimulatorHIDEvent) async throws -> FBSimulatorHIDSessionReceipt {
    try await executePrepared(event, admissionGuard: nil)
  }

  /// Complete raw keyboard input with legacy duplicate-key credits and no command-size limit.
  /// Every key must be released in this call. Only keyboard events and delays are accepted.
  /// Successful fully drained input can return a healthy connection to its transport owner;
  /// retained legacy batches and interrupted input remain ineligible for reuse.
  public func executeLegacyKeyboard(_ event: FBSimulatorHIDEvent) async throws -> FBSimulatorHIDSessionReceipt {
    try await executePrepared(event, admissionGuard: nil, mode: .legacyKeyboard)
  }

  /// Submit part of one owned logical-coordinate stream. Held single-contact, key and button
  /// state survives successful calls. Releases must match input retained here or begun in this part.
  /// An execution failure releases this session's possible input.
  /// Existing explicit retained tokens cannot enter this mode. Once started, it rejects complete
  /// execute and explicit retained-contact calls until the session is closed.
  public func submitOwnedPart(_ event: FBSimulatorHIDEvent) async throws -> FBSimulatorHIDSessionReceipt {
    try await executePrepared(event, admissionGuard: nil, mode: .ownedPart)
  }

  /// Preserve an ordinary batch's ordered keyboard chords, including duplicate modifier codes.
  /// Repeated keyboard DOWN credits must be released within this part. Only actual held state
  /// continues to another part. Touch/button releases stay strict; modes cannot be mixed.
  /// This uses the same measured connection and owned cleanup as submitOwnedPart. The first
  /// part performs a full context read; later parts use the continuous live feed, including
  /// after each part. Retained parts keep the connection open without its disconnect
  /// keepalive; their receipt is retained and execution evidence does not claim a drain.
  /// Released parts and close keep the normal drain. Call validateLegacyBatchBoundary
  /// before each ordinary command step.
  public func submitLegacyBatchPart(_ event: FBSimulatorHIDEvent) async throws -> FBSimulatorHIDSessionReceipt {
    try await executePrepared(event, admissionGuard: nil, mode: .legacyBatch)
  }

  /// Refresh the full context at a command boundary only when all input is released.
  /// While a touch, key or button is held, the continuous feed guards the original context
  /// without extending that hold with guest helper work. Failure invalidates the session.
  public func validateLegacyBatchBoundary() async throws {
    try enter()
    defer { inFlight = false }
    guard ownedStreamMode == nil || ownedStreamMode == .legacyBatch, token == nil, liveProvider != nil else {
      throw FBSimulatorHIDSessionError.invalidEvent("Legacy batch boundary requires a live batch session")
    }
    do { try await checkFreshness(authoritative: !hasOwnedInput) }
    catch { throw await interrupt(error) }
  }

  /// Guarded input requires a live feed so the final revision check does not await a full read.
  public func execute(_ event: FBSimulatorHIDEvent,
                      admissionGuard: any FBSimulatorHIDInputAdmissionGuard) async throws -> FBSimulatorHIDSessionReceipt {
    try await executePrepared(event, admissionGuard: admissionGuard)
  }

  /// Complete keyboard input with a fresh admission check before each key down.
  /// Existing first-event touch admission and unguarded execute overloads are unchanged.
  public func execute(_ event: FBSimulatorHIDEvent,
                      keyboardAdmissionGuard: any FBSimulatorHIDKeyboardAdmissionGuard) async throws -> FBSimulatorHIDSessionReceipt {
    try await executePrepared(event, admissionGuard: nil, keyboardAdmissionGuard: keyboardAdmissionGuard)
  }

  private func executePrepared(_ event: FBSimulatorHIDEvent,
                               admissionGuard: (any FBSimulatorHIDInputAdmissionGuard)?,
                               keyboardAdmissionGuard: (any FBSimulatorHIDKeyboardAdmissionGuard)? = nil,
                               mode: SubmissionMode = .complete) async throws -> FBSimulatorHIDSessionReceipt {
    try enter()
    defer { inFlight = false }
    lastExecutionEvidence = nil
    let firstLegacyBatchPart = mode == .legacyBatch && ownedStreamMode == nil
    let events: [FBSimulatorHIDEvent]
    switch mode {
    case .complete, .legacyKeyboard:
      guard !usesOwnedParts else { throw FBSimulatorHIDSessionError.invalidEvent("Owned-part sessions cannot execute complete input") }
      guard contacts == nil else { throw FBSimulatorHIDSessionError.retainedContactExists }
      events = try Self.prepare(event, context: observation.displayContext, legacyBatch: mode == .legacyKeyboard)
      if mode == .legacyKeyboard {
        guard events.allSatisfy({ item in
          switch item { case .keyboard, .delay: return true; default: return false }
        }) else { throw FBSimulatorHIDSessionError.invalidEvent("Complete legacy keyboard accepts only keyboard events and delays") }
      }
    case .ownedPart, .legacyBatch:
      let streamMode: OwnedStreamMode = mode == .legacyBatch ? .legacyBatch : .strict
      guard ownedStreamMode == nil || ownedStreamMode == streamMode else {
        throw FBSimulatorHIDSessionError.invalidEvent("Owned stream submission modes cannot be mixed")
      }
      guard token == nil else { throw FBSimulatorHIDSessionError.invalidToken }
      guard liveProvider != nil else { throw FBSimulatorHIDSessionError.invalidEvent("Owned parts require a live freshness provider") }
      let contactCount: Int
      switch contacts { case .single?: contactCount = 1; case .pair?: contactCount = 2; case nil: contactCount = 0 }
      do {
        events = try Self.prepare(event, context: observation.displayContext,
          ownedState: OwnedInputState(contactCount: contactCount, keys: heldKeys, buttons: heldButtons),
          legacyBatch: mode == .legacyBatch)
      } catch { throw await interrupt(error) }
      ownedStreamMode = streamMode
    }
    if admissionGuard != nil || keyboardAdmissionGuard != nil, liveProvider == nil {
      throw FBSimulatorHIDSessionError.invalidEvent("Guarded input requires a live freshness provider")
    }
    if admissionGuard != nil, !events.contains(where: { if case .delay = $0 { return false }; return true }) {
      throw FBSimulatorHIDSessionError.invalidEvent("Guarded input requires an input primitive")
    }
    if keyboardAdmissionGuard != nil {
      guard events.allSatisfy({ item in
        switch item { case .keyboard, .delay: return true; default: return false }
      }), events.contains(where: { if case .keyboard(.down, _) = $0 { return true }; return false }) else {
        throw FBSimulatorHIDSessionError.invalidEvent("Keyboard admission requires only keyboard events and delays, with at least one key down")
      }
    }
    var pendingGuard = admissionGuard
    let started = ProcessInfo.processInfo.systemUptime
    let before = sentCount
    let operationID = UUID()
    let planned = events.filter { if case .delay = $0 { return false }; return true }.count
    var phase = FBSimulatorHIDExecutionPhase.beforeInput
    var drainCompleted = false
    state = .executing
    do {
      try await checkFreshness(authoritative: mode != .legacyBatch || firstLegacyBatchPart)
      for item in events {
        try Task.checkCancellation()
        if case let .delay(seconds) = item {
          phase = .delay
          try await waitWithFreshness(seconds)
        } else {
          if let guardToRun = pendingGuard {
            phase = .admission
            do { try await guardToRun.validate(observation: observation, firstEvent: item) }
            catch is CancellationError { throw CancellationError() }
            catch where Task.isCancelled { throw CancellationError() }
            catch {
              throw FBSimulatorHIDSessionError.interrupted(
                reason: .inputAdmissionRejected(String(reflecting: error)), cleanup: .notNeeded)
            }
            pendingGuard = nil
            try Task.checkCancellation()
          }
          if case let .keyboard(.down, code) = item, let keyboardAdmissionGuard {
            phase = .admission
            do { try await keyboardAdmissionGuard.validateKeyDown(observation: observation, keyCode: code) }
            catch is CancellationError { throw CancellationError() }
            catch where Task.isCancelled { throw CancellationError() }
            catch {
              throw FBSimulatorHIDSessionError.interrupted(
                reason: .inputAdmissionRejected(String(reflecting: error)), cleanup: .notNeeded)
            }
            try Task.checkCancellation()
          }
          phase = .primitive
          try await checkFreshness()
          try await dispatch(item)
        }
      }
      // A retained legacy part keeps the same connection for the next part. Each primitive
      // already awaited host enqueue and the guest barrier; the disconnect keepalive must
      // not extend an open touch, key or button hold. Drain after its final release instead.
      if mode != .legacyBatch || !hasOwnedInput {
        phase = .drain
        try await completeDrain()
        drainCompleted = true
      }
      phase = .finalContextCheck
      try await checkFreshness(authoritative: mode != .legacyBatch)
      let retained = usesOwnedParts && hasOwnedInput
      state = retained ? .retainedInputs : .ready
      if usesOwnedParts {
        if retained { startRetainedMonitor() }
        else { stopRetainedMonitor() }
      }
      lastExecutionEvidence = .init(operationID: operationID, boundObservation: observation,
        phase: .completed, plannedPrimitiveCount: planned, sentPrimitiveCount: sentCount - before,
        allInputsReleasedBeforeCleanup: contacts == nil && heldKeys.isEmpty && heldButtons.isEmpty,
        drainCompleted: drainCompleted, interruption: nil, cleanup: .notNeeded,
        startedUptime: started, finishedUptime: ProcessInfo.processInfo.systemUptime)
      return receipt(retained ? .retained : .enqueuedAndDrained, started: started, before: before)
    } catch {
      let released = contacts == nil && heldKeys.isEmpty && heldButtons.isEmpty
      let sent = sentCount - before
      let failure = await interrupt(error)
      let reason: FBSimulatorHIDInterruption?
      if case let .interrupted(value, _) = failure { reason = value } else { reason = nil }
      lastExecutionEvidence = .init(operationID: operationID, boundObservation: observation,
        phase: phase, plannedPrimitiveCount: planned, sentPrimitiveCount: sent,
        allInputsReleasedBeforeCleanup: released, drainCompleted: drainCompleted,
        interruption: reason, cleanup: lastCleanup,
        startedUptime: started, finishedUptime: ProcessInfo.processInfo.systemUptime)
      throw failure
    }
  }

  public func begin(at point: CGPoint) async throws -> FBSimulatorHIDSessionReceipt {
    try await beginContacts(.single(point))
  }

  /// Validate the initial pickup inside this session's input reservation. Requires a live
  /// feed and checks its revision again after the guard returns, before the first DOWN.
  /// The guard must not call back into this HID session.
  public func begin(at point: CGPoint,
                    admissionGuard: any FBSimulatorHIDInputAdmissionGuard) async throws -> FBSimulatorHIDSessionReceipt {
    try await beginContacts(.single(point), admissionGuard: admissionGuard)
  }

  public func beginTwoFinger(first: CGPoint, second: CGPoint) async throws -> FBSimulatorHIDSessionReceipt {
    try await beginContacts(.pair(first, second))
  }

  public func move(_ token: FBSimulatorHIDContactToken, to point: CGPoint) async throws -> FBSimulatorHIDSessionReceipt {
    try await moveContacts(token, to: .single(point))
  }

  public func moveTwoFinger(_ token: FBSimulatorHIDContactToken, first: CGPoint, second: CGPoint) async throws -> FBSimulatorHIDSessionReceipt {
    try await moveContacts(token, to: .pair(first, second))
  }

  public func end(_ token: FBSimulatorHIDContactToken) async throws -> FBSimulatorHIDSessionReceipt {
    try enter()
    defer { inFlight = false }
    try requireToken(token)
    let started = ProcessInfo.processInfo.systemUptime
    let before = sentCount
    state = .executing
    do {
      try await checkFreshness()
      if let contacts { try await dispatch(Self.event(contacts, direction: .up)) }
      self.token = nil
      stopRetainedMonitor()
      try await completeDrain()
      try await checkFreshness(authoritative: true)
      state = .ready
      return receipt(.endedAndDrained, started: started, before: before)
    } catch { throw await interrupt(error) }
  }

  /// Close joins only owned idle cleanup. Concurrent caller execution still rejects as busy.
  /// Cancel the owning action task and await it before closing an active caller operation.
  public func close() async throws -> FBSimulatorHIDSessionReceipt {
    if idleCleanupInProgress {
      await withCheckedContinuation { idleCleanupWaiters.append($0) }
    }
    guard !inFlight else { throw FBSimulatorHIDSessionError.busy }
    stopRetainedMonitor()
    let started = ProcessInfo.processInfo.systemUptime
    let before = sentCount
    if state == .closed || state == .invalidated {
      // Interruption already attempted cleanup and disconnected. Preserve its evidence.
      state = .closed
      return receipt(.closed, started: started, before: before, cleanup: lastCleanup)
    }
    inFlight = true
    defer { inFlight = false }
    var reusable = state == .ready && !hasOwnedInput && token == nil && ownedStreamMode == nil && !Task.isCancelled
      && lastExecutionEvidence?.phase == .completed && lastExecutionEvidence?.drainCompleted == true
      && lastExecutionEvidence?.allInputsReleasedBeforeCleanup == true
    let cleanup = await cleanupContacts(uncertain: state == .invalidated, trigger: "close")
    if let liveProvider {
      do { try liveProvider.validateCurrentRevision(expected: observation) }
      catch { reusable = false }
    }
    if let transportLease {
      await transportLease.finish(reusable: reusable && cleanup == .notNeeded && !Task.isCancelled)
    } else { transport.disconnect() }
    liveProvider?.close()
    state = .closed
    return receipt(.closed, started: started, before: before, cleanup: cleanup)
  }

  private func beginContacts(_ next: Contacts,
                             admissionGuard: (any FBSimulatorHIDInputAdmissionGuard)? = nil) async throws -> FBSimulatorHIDSessionReceipt {
    try enter()
    defer { inFlight = false }
    guard !usesOwnedParts else { throw FBSimulatorHIDSessionError.invalidEvent("Owned-part sessions cannot create explicit contact tokens") }
    guard contacts == nil else { throw FBSimulatorHIDSessionError.retainedContactExists }
    try validate(next)
    if admissionGuard != nil, liveProvider == nil {
      throw FBSimulatorHIDSessionError.invalidEvent("Guarded input requires a live freshness provider")
    }
    let started = ProcessInfo.processInfo.systemUptime
    let before = sentCount
    state = .executing
    do {
      try await checkFreshness(authoritative: true)
      if let admissionGuard {
        do { try await admissionGuard.validate(observation: observation, firstEvent: Self.event(next, direction: .down)) }
        catch is CancellationError { throw CancellationError() }
        catch where Task.isCancelled { throw CancellationError() }
        catch {
          throw FBSimulatorHIDSessionError.interrupted(
            reason: .inputAdmissionRejected(String(reflecting: error)), cleanup: .notNeeded)
        }
        try Task.checkCancellation()
      }
      try await checkFreshness()
      try await dispatch(Self.event(next, direction: .down))
      try Task.checkCancellation()
      token = FBSimulatorHIDContactToken(sessionID: sessionID, contactID: UUID())
      state = .retainedContacts
      startRetainedMonitor()
      return receipt(.retained, started: started, before: before)
    } catch { throw await interrupt(error) }
  }

  private func moveContacts(_ candidate: FBSimulatorHIDContactToken, to next: Contacts) async throws -> FBSimulatorHIDSessionReceipt {
    try enter()
    defer { inFlight = false }
    try requireToken(candidate)
    let started = ProcessInfo.processInfo.systemUptime
    let before = sentCount
    state = .executing
    do {
      do {
        try validate(next)
        switch (contacts, next) {
        case (.single?, .single), (.pair?, .pair): break
        default: throw FBSimulatorHIDSessionError.invalidEvent("Cannot change contact count while retained")
        }
      } catch {
        throw FBSimulatorHIDSessionError.interrupted(reason: .invalidRetainedInput(String(describing: error)), cleanup: .notNeeded)
      }
      try await checkFreshness()
      try await dispatch(Self.event(next, direction: .down))
      try Task.checkCancellation()
      state = .retainedContacts
      return receipt(.moved, started: started, before: before)
    } catch { throw await interrupt(error) }
  }

  private var hasOwnedInput: Bool { contacts != nil || !heldKeys.isEmpty || !heldButtons.isEmpty }

  /// Observe only the existing local feed while owned input is idle. The task does not
  /// retain the session across sleeps. Actor admission keeps cleanup separate from caller input.
  private func startRetainedMonitor() {
    guard liveProvider != nil, hasOwnedInput, usesOwnedParts || token != nil, retainedMonitor == nil else { return }
    let monitorID = UUID()
    retainedMonitorID = monitorID
    retainedMonitor = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(nanoseconds: 50_000_000) }
        catch { return }
        guard !Task.isCancelled,
              await self?.maintainRetainedInput(monitorID) == true else { return }
      }
    }
  }

  private func stopRetainedMonitor() {
    retainedMonitorID = nil
    retainedMonitor?.cancel()
    retainedMonitor = nil
  }

  private func maintainRetainedInput(_ monitorID: UUID) async -> Bool {
    guard retainedMonitorID == monitorID, hasOwnedInput, usesOwnedParts || token != nil,
          let liveProvider else { return false }
    // A caller that owns admission continues to use its normal freshness checks.
    guard !inFlight else { return true }
    do {
      try liveProvider.validateCurrentRevision(expected: observation)
      return true
    } catch {
      inFlight = true
      idleCleanupInProgress = true
      _ = await interrupt(error)
      // Finish bounded cleanup and wake close() before cancelling this monitor's own task.
      idleCleanupInProgress = false
      inFlight = false
      let waiters = idleCleanupWaiters
      idleCleanupWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
      stopRetainedMonitor()
      return false
    }
  }

  private func enter() throws {
    guard !inFlight else { throw FBSimulatorHIDSessionError.busy }
    guard state != .closed else { throw FBSimulatorHIDSessionError.closed }
    guard state != .invalidated else { throw FBSimulatorHIDSessionError.invalidated }
    inFlight = true
  }

  private func requireToken(_ candidate: FBSimulatorHIDContactToken) throws {
    guard token == candidate, candidate.sessionID == sessionID, contacts != nil else {
      throw FBSimulatorHIDSessionError.invalidToken
    }
  }

  private func checkFreshness(authoritative: Bool = false) async throws {
    try Task.checkCancellation()
    if !authoritative, let liveProvider {
      try liveProvider.validateCurrentRevision(expected: observation)
      return
    }
    let current: FBSimulatorHIDSessionObservation
    do { current = try await freshnessProvider.observation() }
    catch is CancellationError { throw CancellationError() }
    catch where Task.isCancelled { throw CancellationError() }
    catch let error as FBSimulatorHIDSessionError { throw error }
    catch { throw FBSimulatorHIDSessionError.interrupted(reason: .observationUnavailable(String(describing: error)), cleanup: .notNeeded) }
    try Task.checkCancellation()
    guard current == observation else {
      throw FBSimulatorHIDSessionError.interrupted(reason: .staleContext, cleanup: .notNeeded)
    }
  }

  private func completeDrain() async throws {
    state = .draining
    // A transport owner lives in a long-running broker. Its DTUHID connection either stays open
    // for reuse or is cancelled only after the drain window following the last dispatch, so the
    // keepalive needs no wait here. Callers without an owner may exit the process right away.
    if transportLease != nil {
      try Task.checkCancellation()
      return
    }
    // Unstructured task is not cancelled with the caller. Cancellation is checked after keepalive.
    let transport = self.transport
    try await Task { try await transport.flush() }.value
    try Task.checkCancellation()
  }

  private func waitWithFreshness(_ seconds: TimeInterval) async throws {
    guard liveProvider != nil else {
      try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
      return
    }
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    while true {
      try await checkFreshness()
      let remaining = deadline - ProcessInfo.processInfo.systemUptime
      guard remaining > 0 else { return }
      // Read the existing local feed. Do not spawn full context reads during a hold.
      try await Task.sleep(nanoseconds: UInt64(min(remaining, 0.05) * 1_000_000_000))
    }
  }

  private func interrupt(_ error: Error) async -> FBSimulatorHIDSessionError {
    if !idleCleanupInProgress { stopRetainedMonitor() }
    let reason: FBSimulatorHIDInterruption
    if error is CancellationError { reason = .cancelled }
    else if case let FBSimulatorHIDSessionError.interrupted(value, _) = error { reason = value }
    else { reason = .transportFailure(String(describing: error)) }
    let changed: Bool
    switch reason {
    case .staleContext, .observationUnavailable, .transportFailure: changed = true
    case .cancelled, .invalidRetainedInput, .inputAdmissionRejected: changed = false
    }
    let cleanup = await cleanupContacts(uncertain: changed, trigger: String(describing: reason))
    // An admission rejection before this session sent any event leaves its connection exactly as
    // it was borrowed. Return it to the owner, which reuses it only for an identical observation;
    // closing it would make the next action open a new guest connection. Any other interruption
    // closes the connection and requires a fresh observation and connection.
    var untouched = false
    if case .inputAdmissionRejected = reason {
      untouched = sentCount == 0 && cleanup == .notNeeded && !hasOwnedInput
    }
    if untouched, let transportLease, await transportLease.transport.acceptsInput() {
      await transportLease.finish(reusable: true)
    } else {
      transport.disconnect()
      await transportLease?.finish(reusable: false)
    }
    liveProvider?.close()
    state = .invalidated
    return .interrupted(reason: reason, cleanup: cleanup)
  }

  private func cleanupContacts(uncertain: Bool, trigger: String) async -> FBSimulatorHIDCleanupOutcome {
    let transport = self.transport
    var releases: [FBSimulatorHIDEvent] = []
    if let contacts { releases.append(Self.event(contacts, direction: .up)) }
    releases += heldKeys.sorted().map { .keyboard(direction: .up, keyCode: $0) }
    releases += heldButtons.sorted { $0.rawValue < $1.rawValue }.map { .button(direction: .up, button: $0) }
    let started = ProcessInfo.processInfo.systemUptime
    var evidence = FBSimulatorHIDCleanupEvidence(boundSimulatorUDID: observation.simulatorUDID,
      boundBootIdentity: observation.bootIdentity, boundScreenID: observation.screenID,
      boundScreenUUID: observation.screenUniqueID,
      boundNativeWidth: observation.displayContext.nativePixelSize.width,
      boundNativeHeight: observation.displayContext.nativePixelSize.height,
      boundScale: observation.displayContext.scale,
      boundRotation: Int(observation.displayContext.rotation.rawValue), boundPoseRevision: observation.poseRevision,
      startedUptime: started, trigger: trigger,
      contextValidation: uncertain ? "notRecheckedAfterInterruption" : "pending",
      releases: [], timedOut: false)
    guard !releases.isEmpty else {
      lastCleanup = .notNeeded
      evidence.contextValidation = "noOwnedInput"
      evidence.finishedUptime = ProcessInfo.processInfo.systemUptime
      evidence.outcome = FBSimulatorHIDCleanupOutcome.notNeeded.rawValue
      lastCleanupEvidence = evidence
      return .notNeeded
    }
    state = .draining
    let race = FBSimulatorHIDCleanupRace(evidence: evidence)
    let provider = freshnessProvider
    let live = liveProvider
    let expected = observation
    let identityProvider = provider as? any FBSimulatorHIDCleanupIdentityProvider
    let cleanupTask = Task {
      do {
        var matches = false
        if let identityProvider {
          do {
            let identity = try await Self.readCleanupIdentity(identityProvider)
            matches = identity.matches(expected)
            await race.identity(identity, before: true)
            await race.context(matches ? "releaseIdentityMatchedBefore" : "releaseIdentityMismatchBefore")
          } catch {
            await race.identityFailure("before: \(error)")
            await race.context("releaseIdentityUnavailableBefore")
          }
          // A failed or slow identity read cannot suppress release on the original connection.
        } else if !uncertain {
          do {
            if let live { try live.validateCurrentRevision(expected: expected); matches = true }
            else { matches = try await provider.observation() == expected }
            await race.context(matches ? "matched" : "different")
          } catch {
            matches = false
            await race.context("unavailable", error: String(describing: error))
          }
        }
        try Task.checkCancellation()
        for (index, release) in releases.enumerated() {
          try Task.checkCancellation()
          await race.startRelease(index: index, primitive: String(describing: release))
          do {
            try await Self.sendOwnedRelease(release, transport: transport)
            let sendEvidence = await (transport as? any FBSimulatorHIDCleanupTransportDiagnostics)?.lastSendEvidence()
            await race.finishRelease(index: index, transport: sendEvidence, error: nil)
          } catch {
            let sendEvidence = await (transport as? any FBSimulatorHIDCleanupTransportDiagnostics)?.lastSendEvidence()
            await race.finishRelease(index: index, transport: sendEvidence, error: String(describing: error))
            throw error
          }
        }
        await race.startDrain()
        try await transport.flush()
        await race.finishDrain()
        if let identityProvider {
          do {
            let identity = try await Self.readCleanupIdentity(identityProvider)
            await race.identity(identity, before: false)
            matches = matches && identity.matches(expected)
            await race.context(matches ? "releaseIdentityMatchedBeforeAndAfter" : "releaseIdentityUnconfirmed")
          } catch {
            matches = false
            await race.identityFailure("after: \(error)")
            await race.context("releaseIdentityUnavailableAfter")
          }
        }
        await race.finish(matches ? .releaseEnqueuedAndDrained : .uncertain)
      } catch { await race.finish(.uncertain, error: String(describing: error)) }
    }
    let timeoutTask = Task {
      do { try await Task.sleep(nanoseconds: 2_000_000_000) }
      catch { return }
      await race.finish(.uncertain, timedOut: true)
    }
    let result = await race.wait()
    timeoutTask.cancel()
    if result == .uncertain { transport.disconnect(); cleanupTask.cancel() }
    lastCleanupEvidence = await race.snapshot()
    contacts = nil
    token = nil
    heldKeys.removeAll()
    heldButtons.removeAll()
    lastCleanup = result
    return result
  }

  /// The 100 ms read budget reserves cleanup time for the owned release. It is not a delay or
  /// freshness relaxation. Timeout cancels the read and forces uncertain classification.
  private static func readCleanupIdentity(_ provider: any FBSimulatorHIDCleanupIdentityProvider) async throws -> FBSimulatorHIDCleanupIdentity {
    let result = FBSimulatorBoundedResult<FBSimulatorHIDCleanupIdentity>()
    let read = Task {
      do { result.finish(.success(try await provider.cleanupIdentity())) }
      catch { result.finish(.failure(error)) }
    }
    defer { read.cancel() }
    return try await result.value(timeout: 0.1, operation: "Cleanup identity read") { _ in }
  }

  private func dispatch(_ event: FBSimulatorHIDEvent) async throws {
    // Store possible active state before enqueue so a send error cannot omit cleanup.
    switch event {
    case let .touch(.down, x, y): contacts = .single(CGPoint(x: x, y: y))
    case let .twoFingerTouch(.down, first, second): contacts = .pair(first, second)
    case let .keyboard(.down, code): heldKeys.insert(code)
    case let .button(.down, button): heldButtons.insert(button)
    default: break
    }
    try await Self.send(event, transport: transport)
    sentCount += 1
    switch event {
    case .touch(.up, _, _), .twoFingerTouch(.up, _, _): contacts = nil
    case let .keyboard(.up, code): heldKeys.remove(code)
    case let .button(.up, button): heldButtons.remove(button)
    default: break
    }
  }

  private static func sendOwnedRelease(_ event: FBSimulatorHIDEvent,
                                       transport: any FBSimulatorHIDTransport) async throws {
    guard let cleanupTransport = transport as? any FBSimulatorHIDOwnedCleanupTransport else {
      // Existing legacy transports retain their existing release path.
      try await send(event, transport: transport)
      return
    }
    let release: FBSimulatorHIDOwnedRelease
    switch event {
    case let .touch(.up, x, y): release = .touch(CGPoint(x: x, y: y))
    case let .twoFingerTouch(.up, first, second): release = .pair(first, second)
    case let .keyboard(.up, code): release = .key(code)
    case let .button(.up, button): release = .button(button)
    default: throw FBSimulatorHIDSessionError.invalidEvent("Cleanup accepts only owned UP events")
    }
    try await cleanupTransport.releaseOwnedInput(release)
  }

  private static func send(_ event: FBSimulatorHIDEvent, transport: any FBSimulatorHIDTransport) async throws {
    switch event {
    case let .touch(direction, x, y): try await transport.sendTouch(direction: direction, x: x, y: y)
    case let .twoFingerTouch(direction, first, second): try await transport.sendTwoFingerTouch(direction: direction, finger1: first, finger2: second)
    case let .keyboard(direction, code): try await transport.sendKeyboard(direction: direction, keyCode: code)
    case let .button(direction, button): try await transport.sendButton(direction: direction, button: button)
    default: throw FBSimulatorHIDSessionError.invalidEvent("Only prepared input primitives can be sent")
    }
  }

  private func validate(_ contacts: Contacts) throws {
    switch contacts {
    case let .single(point): try Self.validatePoint(point, context: observation.displayContext)
    case let .pair(first, second):
      try Self.validatePoint(first, context: observation.displayContext)
      try Self.validatePoint(second, context: observation.displayContext)
    }
  }

  private static func validatePoint(_ point: CGPoint, context: FBSimulatorHIDDisplayContext) throws {
    do { _ = try context.normalizedPoint(from: point) }
    catch { throw FBSimulatorHIDSessionError.invalidEvent(String(describing: error)) }
  }

  private static func event(_ contacts: Contacts, direction: FBSimulatorHIDDirection) -> FBSimulatorHIDEvent {
    switch contacts {
    case let .single(point): return .touch(direction: direction, x: point.x, y: point.y)
    case let .pair(first, second): return .twoFingerTouch(direction: direction, finger1: first, finger2: second)
    }
  }

  private func receipt(_ outcome: FBSimulatorHIDSessionOutcome, started: TimeInterval, before: Int,
                       cleanup: FBSimulatorHIDCleanupOutcome = .notNeeded) -> FBSimulatorHIDSessionReceipt {
    FBSimulatorHIDSessionReceipt(outcome: outcome, token: token,
      enqueuedEventCount: sentCount - before, elapsedSeconds: ProcessInfo.processInfo.systemUptime - started, cleanup: cleanup)
  }

  private static func prepare(_ event: FBSimulatorHIDEvent, context: FBSimulatorHIDDisplayContext,
                              ownedState: OwnedInputState? = nil, legacyBatch: Bool = false) throws -> [FBSimulatorHIDEvent] {
    var flattened: [FBSimulatorHIDEvent] = []
    func flatten(_ item: FBSimulatorHIDEvent) {
      if case let .composite(items) = item { for child in items { flatten(child) } }
      else { flattened.append(item) }
    }
    flatten(event.event(for: .dtuhid))
    var contactCount = ownedState?.contactCount ?? 0
    var keys = ownedState?.keys ?? Set<UInt32>()
    var buttons = ownedState?.buttons ?? Set<FBSimulatorHIDButton>()
    var keyCredits: [UInt32: Int] = legacyBatch ? Dictionary(uniqueKeysWithValues: keys.map { ($0, 1) }) : [:]
    for item in flattened {
      switch item {
      case let .touch(direction, x, y):
        try validatePoint(CGPoint(x: x, y: y), context: context)
        guard contactCount == 0 || contactCount == 1 else { throw FBSimulatorHIDSessionError.invalidEvent("Mixed contact counts") }
        if direction == .up && contactCount == 0 { throw FBSimulatorHIDSessionError.invalidEvent("Touch release without begin") }
        contactCount = direction == .down ? 1 : 0
      case let .twoFingerTouch(direction, first, second):
        guard ownedState == nil else { throw FBSimulatorHIDSessionError.invalidEvent("Owned parts support one touch contact only") }
        try validatePoint(first, context: context); try validatePoint(second, context: context)
        guard contactCount == 0 || contactCount == 2 else { throw FBSimulatorHIDSessionError.invalidEvent("Mixed contact counts") }
        if direction == .up && contactCount == 0 { throw FBSimulatorHIDSessionError.invalidEvent("Touch release without begin") }
        contactCount = direction == .down ? 2 : 0
      case let .delay(seconds):
        guard seconds.isFinite, seconds >= 0, seconds < Double(UInt64.max) / 1_000_000_000 else {
          throw FBSimulatorHIDSessionError.invalidEvent("Invalid delay")
        }
      case let .keyboard(direction, code):
        if legacyBatch {
          if direction == .down {
            keyCredits[code, default: 0] += 1
            keys.insert(code)
          } else {
            guard let credit = keyCredits[code], credit > 0 else {
              throw FBSimulatorHIDSessionError.invalidEvent("Key release without begin")
            }
            keyCredits[code] = credit - 1
            keys.remove(code)
          }
        } else {
          if direction == .down { keys.insert(code) }
          else if keys.remove(code) == nil { throw FBSimulatorHIDSessionError.invalidEvent("Key release without begin") }
        }
      case let .button(direction, button):
        guard button != .applePay else { throw FBSimulatorHIDSessionError.invalidEvent("Unadapted Apple Pay event") }
        if direction == .down { buttons.insert(button) }
        else if buttons.remove(button) == nil { throw FBSimulatorHIDSessionError.invalidEvent("Button release without begin") }
      default: throw FBSimulatorHIDSessionError.invalidEvent("Session does not execute pose or system-state events")
      }
    }
    if legacyBatch {
      for (code, credit) in keyCredits {
        guard credit == (keys.contains(code) ? 1 : 0) else {
          throw FBSimulatorHIDSessionError.invalidEvent("Repeated keyboard downs must balance within one legacy batch part")
        }
      }
    }
    guard ownedState != nil || (contactCount == 0 && keys.isEmpty && buttons.isEmpty) else {
      throw FBSimulatorHIDSessionError.invalidEvent("Complete gesture must release all inputs; use retained contact API")
    }
    return flattened
  }
}

/// One-shot race avoids waiting forever for a failed connection barrier during cleanup.
/// A timeout closes the original connection and reports uncertain delivery, never release success.
private actor FBSimulatorHIDCleanupRace {
  private var result: FBSimulatorHIDCleanupOutcome?
  private var continuation: CheckedContinuation<FBSimulatorHIDCleanupOutcome, Never>?
  private var evidence: FBSimulatorHIDCleanupEvidence
  init(evidence: FBSimulatorHIDCleanupEvidence) { self.evidence = evidence }
  func context(_ value: String, error: String? = nil) {
    guard result == nil else { return }
    evidence.contextValidation = value; evidence.contextValidationError = error
  }
  func identity(_ value: FBSimulatorHIDCleanupIdentity, before: Bool) {
    guard result == nil else { return }
    if before { evidence.identityBefore = value } else { evidence.identityAfter = value }
  }
  func identityFailure(_ message: String) {
    guard result == nil else { return }
    evidence.identityReadError = [evidence.identityReadError, message].compactMap { $0 }.joined(separator: "; ")
  }
  func startRelease(index: Int, primitive: String) {
    guard result == nil else { return }
    evidence.releases.append(FBSimulatorHIDCleanupReleaseEvidence(index: index, primitive: primitive,
      startedUptime: ProcessInfo.processInfo.systemUptime, returnedSuccessfully: false))
  }
  func finishRelease(index: Int, transport: FBSimulatorHIDSendEvidence?, error: String?) {
    guard result == nil, evidence.releases.indices.contains(index) else { return }
    evidence.releases[index].finishedUptime = ProcessInfo.processInfo.systemUptime
    evidence.releases[index].returnedSuccessfully = error == nil
    evidence.releases[index].errorDescription = error
    evidence.releases[index].transport = transport
  }
  func startDrain() { guard result == nil else { return }; evidence.drainStartedUptime = ProcessInfo.processInfo.systemUptime }
  func finishDrain() { guard result == nil else { return }; evidence.drainCompletedUptime = ProcessInfo.processInfo.systemUptime }
  func finish(_ result: FBSimulatorHIDCleanupOutcome, timedOut: Bool = false, error: String? = nil) {
    guard self.result == nil else { return }
    self.result = result
    evidence.timedOut = timedOut; evidence.errorDescription = error
    evidence.finishedUptime = ProcessInfo.processInfo.systemUptime; evidence.outcome = result.rawValue
    continuation?.resume(returning: result)
    continuation = nil
  }
  func snapshot() -> FBSimulatorHIDCleanupEvidence { evidence }
  func wait() async -> FBSimulatorHIDCleanupOutcome {
    if let result { return result }
    return await withCheckedContinuation { continuation = $0 }
  }
}
