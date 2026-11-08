@preconcurrency import XPC
import Foundation

/// One read did not complete within its budget. Nothing was sent, so a caller may read again.
public struct FBSimulatorHingeReadTimeout: LocalizedError, CustomNSError, CustomStringConvertible, Sendable {
  public init() {}
  public var description: String { "Context hinge sample timed out" }
  public var errorDescription: String? { description }
  public static var errorDomain: String { "com.facebook.FBSimulatorControl" }
  public var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: errorDescription ?? ""] }
}

/// A fresh sample, its cancellation reply and the original request reply complete one read.
public enum FBSimulatorHingeReader {
  public static func read(for simulator: FBSimulator) async throws -> FBSimulatorHingeObservation {
    let channel = UUID()
    let request = try FBSimulatorHIDHingeWire.request(deviceID: simulator.udid, channel: channel, changeThreshold: 0)
    let connection = try FBSimulatorHIDHingeWire.connect(simulator)
    defer { xpc_connection_cancel(connection) }
    let queue = DispatchQueue(label: "com.facebook.FBSimulatorControl.context-hinge")
    xpc_connection_set_target_queue(connection, queue)
    let result = FBSimulatorBoundedResult<FBSimulatorHingeObservation>()
    return try await result.value(timeout: 3, operation: "Context hinge sample",
                                  timeoutError: { FBSimulatorHingeReadTimeout() }) { finish in
      let started = ProcessInfo.processInfo.systemUptime
      let completion = FBSimulatorHingeReadCompletion(deadline: started + 3, finish: finish)
      xpc_connection_set_event_handler(connection) { event in
        guard !completion.finished else { return }
        do {
          let samples = try FBSimulatorHIDHingeWire.samples(event, channel: channel, notBefore: started)
          let hasSample = completion.remember(samples.max { $0.timestampUptime < $1.timestampUptime })
          guard let reply = xpc_dictionary_create_reply(event) else {
            throw FBSimulatorHIDHingeWire.failure("Context motion sample has no reply channel")
          }
          xpc_dictionary_set_bool(reply, "CoreDevice.XPCMessageKey.cancellationRequested", hasSample)
          xpc_connection_send_message(connection, reply)
          if hasSample {
            let sequence = completion.cancellationReplyEnqueued()
            xpc_connection_send_barrier(connection) {
              queue.async { completion.cancellationReplyDrained(sequence) }
            }
          }
        } catch { completion.fail(error) }
      }
      xpc_connection_resume(connection)
      xpc_connection_send_message_with_reply(connection, request, queue) { reply in
        guard !completion.finished else { return }
        guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY,
              xpc_dictionary_get_value(reply, "CoreDevice.error") == nil,
              let output = xpc_dictionary_get_value(reply, "CoreDevice.output"),
              xpc_get_type(output) == XPC_TYPE_DICTIONARY,
              xpc_dictionary_get_count(output) == 0 else {
          completion.fail(FBSimulatorHIDHingeWire.failure("Context motion service rejected the request"))
          return
        }
        completion.originalReplyReceived()
      }
    }
  }
}

/// All mutable state and the finish callback belong to the read's existing serial XPC queue.
/// The send barrier returns to that queue before it changes completion state.
private final class FBSimulatorHingeReadCompletion: @unchecked Sendable {
  private let deadline: TimeInterval
  private let finish: @Sendable (Result<FBSimulatorHingeObservation, Error>) -> Void
  private var sample: FBSimulatorHingeObservation?
  private var enqueuedReplies = 0
  private var drainedReplies = 0
  private var receivedOriginalReply = false
  private(set) var finished = false

  init(deadline: TimeInterval,
       finish: @escaping @Sendable (Result<FBSimulatorHingeObservation, Error>) -> Void) {
    self.deadline = deadline
    self.finish = finish
  }

  func remember(_ candidate: FBSimulatorHingeObservation?) -> Bool {
    if sample == nil { sample = candidate }
    return sample != nil
  }

  func cancellationReplyEnqueued() -> Int {
    enqueuedReplies += 1
    return enqueuedReplies
  }

  func cancellationReplyDrained(_ sequence: Int) {
    guard !finished else { return }
    drainedReplies = max(drainedReplies, sequence)
    completeIfReady()
  }

  func originalReplyReceived() {
    guard !finished else { return }
    guard enqueuedReplies > 0 else {
      fail(FBSimulatorHIDHingeWire.failure("Context motion service replied before the sample cancellation reply"))
      return
    }
    receivedOriginalReply = true
    completeIfReady()
  }

  func fail(_ error: Error) {
    guard !finished else { return }
    finished = true
    finish(.failure(error))
  }

  private func completeIfReady() {
    guard !finished, receivedOriginalReply, enqueuedReplies > 0,
          drainedReplies == enqueuedReplies, let sample else { return }
    guard ProcessInfo.processInfo.systemUptime <= deadline else {
      fail(FBSimulatorHingeReadTimeout())
      return
    }
    finished = true
    finish(.success(sample))
  }
}
