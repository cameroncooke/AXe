import AppKit
import Darwin
import Dispatch
import Foundation
@preconcurrency import FBControlCore
@preconcurrency import FBSimulatorControl

private final class SliderProbeReporter: NSObject, FBEventReporter {
  var metadata: [String: String] = [:]
  func report(_ event: FBEventReporterSubject) {}
  func addMetadata(_ metadata: [String: String]) {}
}

private enum SliderProbeError: Error {
  case invalid(String)
  case cancelled
  case deadline
}

private struct SliderProbeArguments: Encodable {
  let udid: UUID
  let boot: String
  let screenID: UInt32
  let screenUUID: UUID
  let pid: Int32
  let identifier: String
  let label: String
  let percent: Double
  let deadlineUptime: Double
  let helper: String
  let output: String

  init(_ args: [String]) throws {
    let names: Set<String> = ["--udid", "--boot", "--screen-id", "--screen-uuid", "--pid",
      "--id", "--label", "--percent", "--deadline-uptime", "--helper", "--output"]
    guard args.count == names.count * 2 else {
      throw SliderProbeError.invalid("Supply each of: " + names.sorted().joined(separator: " "))
    }
    var values: [String: String] = [:]
    for index in stride(from: 0, to: args.count, by: 2) {
      let name = args[index]
      guard names.contains(name), values[name] == nil else {
        throw SliderProbeError.invalid("Unknown or repeated argument: " + name)
      }
      values[name] = args[index + 1]
    }
    guard let udid = values["--udid"].flatMap(UUID.init(uuidString:)),
          let boot = values["--boot"], !boot.isEmpty,
          let screenID = values["--screen-id"].flatMap(UInt32.init),
          let screenUUID = values["--screen-uuid"].flatMap(UUID.init(uuidString:)),
          let pid = values["--pid"].flatMap(Int32.init), pid > 0,
          let identifier = values["--id"], !identifier.isEmpty, identifier.utf8.count <= 4096,
          let label = values["--label"], !label.isEmpty, label.utf8.count <= 4096,
          let percent = values["--percent"].flatMap(Double.init), percent.isFinite, (0...100).contains(percent),
          let deadline = values["--deadline-uptime"].flatMap(Double.init), deadline.isFinite,
          let helper = values["--helper"], helper.hasPrefix("/"),
          let output = values["--output"], output.hasPrefix("/") else {
      throw SliderProbeError.invalid("Invalid explicit device, target, percentage, deadline or absolute file path")
    }
    let remaining = deadline - ProcessInfo.processInfo.systemUptime
    guard remaining > 0, remaining <= 30 else {
      throw SliderProbeError.invalid("Deadline must be in the next 30 seconds")
    }
    self.udid = udid; self.boot = boot; self.screenID = screenID; self.screenUUID = screenUUID
    self.pid = pid; self.identifier = identifier; self.label = label; self.percent = percent
    self.deadlineUptime = deadline; self.helper = helper; self.output = output
  }
}

/// The signal callback only marks cancellation. It never touches an AX object.
private final class SliderProbeCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var requested = false
  func request() { lock.lock(); requested = true; lock.unlock() }
  func check() throws {
    lock.lock(); let value = requested; lock.unlock()
    if value || Task.isCancelled { throw SliderProbeError.cancelled }
  }
}

private struct SliderProbeContext: Encodable {
  let simulatorUDID: String
  let bootIdentity: String
  let screenID: UInt32
  let screenUUID: String
  let axDisplayID: UInt32
  let rotation: Int
  let poseRevision: String
  init(_ value: FBSimulatorHIDSessionObservation) {
    simulatorUDID = value.simulatorUDID; bootIdentity = value.bootIdentity
    screenID = value.screenID; screenUUID = value.screenUniqueID
    axDisplayID = value.axDisplayID; rotation = value.displayContext.rotation.rawValue
    poseRevision = value.poseRevision
  }
}

private struct SliderProbeSample: Encodable {
  let phase: String
  let capturedUptime: Double
  let capabilities: FBSimulatorSliderCapabilities
}

private struct SliderProbeEvidence: Encodable {
  let schemaVersion = 1
  let source = "isolatedPublicFacadeSingleNumericSetter"
  let productionReady = false
  let sameHandleDomainNotExposedByPublicFacade = true
  let nativeSettable = "unobserved; public facade does not expose the native settable query"
  let acquisitionRemediation = "public frontmost acquisition has bounded SpringBoard remediation; probe does not replay a setter"
  let appAcknowledgement = "unobserved; root must inspect independent UIKit value and callbacks"
  let exclusion = "root must keep the explicit guest exclusive; backend lease is process-local"
  let args: SliderProbeArguments
  let frameworkPath: String
  let startedUptime: Double
  var finishedUptime: Double?
  var outcome = "beforeInput"
  var error: String?
  var phase = "argumentsAccepted"
  var context: SliderProbeContext?
  var nativeTarget: Double?
  var writeAttempts = 0
  var callStartedUptime: Double?
  var callReturnedUptime: Double?
  var backendFinished = false
  var feedClosed = false
  var samples: [SliderProbeSample] = []
  var readOnlyIdentifierSearchRoots: [FBSimulatorAXNode]?
  var readOnlyIdentifierSearchReturnedUptime: Double?
  var ownedRootBefore: FBSimulatorAXNode?
  var ownedRootFinal: FBSimulatorAXNode?
}

/// LAB ONLY. Public serialization cannot read this owned handle's min/max or
/// settable state. A separate backend sample supplies the constant fixture domain.
/// This experiment can prove one setter effect; it cannot prove production admission.
@main private struct DuoSliderSetterProbe {
  @MainActor static func main() async {
    do {
      let args = try SliderProbeArguments(Array(CommandLine.arguments.dropFirst()))
      let cancellation = SliderProbeCancellation()
      signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
      let signals = [SIGINT, SIGTERM].map { number in
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .utility))
        source.setEventHandler { cancellation.request() }
        source.resume()
        return source
      }
      let code = await run(args, cancellation: cancellation)
      for source in signals { source.cancel() }
      exit(code)
    } catch {
      FileHandle.standardError.write(Data((String(reflecting: error) + "\n").utf8))
      exit(2)
    }
  }

  @MainActor private static func run(_ args: SliderProbeArguments,
    cancellation: SliderProbeCancellation) async -> Int32 {
    let output = URL(fileURLWithPath: args.output)
    var evidence = SliderProbeEvidence(args: args,
      frameworkPath: Bundle(for: FBSimulator.self).bundleURL.path,
      startedUptime: ProcessInfo.processInfo.systemUptime)
    var feed: FBSimulatorHIDNativeFreshnessProvider?
    var backend: FBSimulatorSliderBackend?
    var root: FBAccessibilityElement?
    var selected: FBAccessibilityElement?
    let operationID = UUID()
    var outputOwned = false
    var code: Int32 = 2
    do {
      try persist(evidence, to: output, first: true)
      outputOwned = true
      try check(args, cancellation)
      let logger = FBControlCoreLoggerFactory.systemLoggerWriting(toStderr: true, withDebugLogging: false)
      FBControlCoreGlobalConfiguration.defaultLogger = logger
      try FBSimulatorControlFrameworkLoader.xcodeFrameworks.loadPrivateFrameworks(logger)
      let control = try FBSimulatorControl.withConfiguration(FBSimulatorControlConfiguration(
        deviceSetPath: nil, logger: logger, reporter: SliderProbeReporter()))
      guard let simulator = control.set.allSimulators.first(where: {
        UUID(uuidString: $0.udid) == args.udid
      }), simulator.state == .booted else { throw SliderProbeError.invalid("Explicit device is not booted") }
      try check(args, cancellation)
      let live = try await FBSimulatorHIDNativeFreshnessProvider.start(for: simulator,
        helperURL: URL(fileURLWithPath: args.helper), screenID: args.screenID, screenUniqueID: args.screenUUID)
      feed = live
      let observation = live.initialObservation
      guard observation.bootIdentity == args.boot, UUID(uuidString: observation.simulatorUDID) == args.udid,
            observation.screenID == args.screenID,
            UUID(uuidString: observation.screenUniqueID) == args.screenUUID else {
        throw SliderProbeError.invalid("Explicit boot or screen identity changed")
      }
      evidence.context = SliderProbeContext(observation)
      let native = FBSimulatorSliderBackend(simulator: simulator, observation: observation,
        freshnessProvider: live, label: args.label, expectedPID: args.pid, elementType: "Slider")
      backend = native
      evidence.phase = "nativeBackendPrepareStart"
      try persist(evidence, to: output)
      try await native.prepare(operationID: operationID, deadline: args.deadlineUptime)
      try check(args, cancellation)
      evidence.phase = "initialNativeReadStart"
      try persist(evidence, to: output)
      let initial = try await native.read(deadline: args.deadlineUptime)
      let domain = try initial.requireDomain()
      try requireNode(initial.node, args: args, expected: initial)
      let target = try domain.nativeValue(percent: args.percent)
      guard abs(try initial.requireValue() - target) > domain.tolerance else {
        throw SliderProbeError.invalid("Choose a target outside the initial value tolerance for this setter experiment")
      }
      evidence.nativeTarget = target
      evidence.samples.append(sample("initial", initial))
      try check(args, cancellation)
      try live.validateCurrentRevision(expected: observation)

      // Read-only diagnosis of the public substring ID search. This handle is
      // never used for a setter, even when it is the requested control.
      evidence.phase = "readOnlyIdentifierSearchAcquireStart"
      try persist(evidence, to: output)
      let idApp = try await simulator.accessibilityElementForFrontmostApplication(
        displayID: observation.axDisplayID, displayContext: observation.displayContext)
      root = idApp
      try requireUnique(nodes(idApp), args: args, expected: initial)
      try check(args, cancellation)
      let idHandle = try idApp.findElement(withValue: args.identifier, forKey: .uniqueID, depth: 64)
      selected = idHandle
      root = nil
      evidence.readOnlyIdentifierSearchRoots = try nodes(idHandle)
      evidence.readOnlyIdentifierSearchReturnedUptime = ProcessInfo.processInfo.systemUptime
      idHandle.close()
      selected = nil
      evidence.phase = "readOnlyIdentifierSearchCompleteNoWrite"
      try persist(evidence, to: output)
      try check(args, cancellation)
      try live.validateCurrentRevision(expected: observation)

      evidence.phase = "labelHandleAcquireStart"
      try persist(evidence, to: output)
      let app = try await simulator.accessibilityElementForFrontmostApplication(
        displayID: observation.axDisplayID, displayContext: observation.displayContext)
      root = app
      let tree = try nodes(app)
      guard !tree.isEmpty, tree.allSatisfy({ $0.pid == args.pid }) else {
        throw SliderProbeError.invalid("Public application roots have an unexpected PID")
      }
      try requireUnique(tree, args: args, expected: initial)
      let handle = try app.findElement(withValue: args.label, forKey: .label, depth: 64)
      selected = handle
      root = nil // findElement transferred the request token; close() is idempotent.
      try requireOwnedRoot(nodes(handle), args: args, expected: initial)
      evidence.phase = "beforeWriteNativeReadStart"
      try persist(evidence, to: output)
      let before = try await native.read(deadline: args.deadlineUptime)
      try before.requireSameTarget(as: initial, includeValue: true)
      evidence.samples.append(sample("beforeWrite", before))
      guard try await live.observation() == observation else {
        throw SliderProbeError.invalid("Complete context changed before the one write")
      }
      try check(args, cancellation)
      let owned = try nodes(handle)
      try requireOwnedRoot(owned, args: args, expected: before)
      evidence.ownedRootBefore = owned.first
      evidence.phase = "oneWritePreparedWithKnownPublicFacadeDomainGap"
      try persist(evidence, to: output)
      // There is no await between the final local checks and the one native call.
      try check(args, cancellation)
      try live.validateCurrentRevision(expected: observation)
      evidence.writeAttempts = 1
      evidence.phase = "nativeWriteMayStart"
      evidence.outcome = "singleWriteIntentPersistedOutcomeUnknown"
      // This is the start of the possible-write interval, including the intent
      // flush. A killed native call must leave a conservative persisted record.
      evidence.callStartedUptime = ProcessInfo.processInfo.systemUptime
      try persist(evidence, to: output)
      try check(args, cancellation)
      try live.validateCurrentRevision(expected: observation)
      try handle.setValue(NSNumber(value: target))
      evidence.callReturnedUptime = ProcessInfo.processInfo.systemUptime
      evidence.phase = "setterReturnedWithoutAppAcknowledgement"
      try persist(evidence, to: output)
      try check(args, cancellation)
      try live.validateCurrentRevision(expected: observation)

      let returnedAt = ProcessInfo.processInfo.systemUptime
      for delay in [0.0, 0.6, 2.0] {
        try await wait(until: returnedAt + delay, args: args, cancellation: cancellation)
        let after = try await native.readFinal(deadline: args.deadlineUptime)
        try check(args, cancellation)
        try after.requireSameTarget(as: initial, includeValue: false)
        evidence.samples.append(sample("afterWrite-\(delay)", after))
        try persist(evidence, to: output)
      }
      let finalOwned = try nodes(handle)
      guard let last = evidence.samples.last else { throw SliderProbeError.invalid("Missing final sample") }
      try requireOwnedRoot(finalOwned, args: args, expected: last.capabilities)
      evidence.ownedRootFinal = finalOwned.first
      let observed = try last.capabilities.requireValue()
      evidence.outcome = abs(observed - target) <= domain.tolerance
        ? "nativeValueObservedNoAppAcknowledgement" : "setterReturnedTargetNotObserved"
      evidence.phase = "boundedReadbackComplete"
      code = abs(observed - target) <= domain.tolerance ? 0 : 1
    } catch {
      evidence.error = String(reflecting: error)
      evidence.outcome = evidence.writeAttempts == 0 ? "failedBeforeInput" : "failedAfterSingleWriteNoReplay"
      FileHandle.standardError.write(Data((String(reflecting: error) + "\n").utf8))
    }
    selected?.close(); root?.close()
    if let backend { await backend.finish(operationID: operationID); evidence.backendFinished = true }
    if let feed { await feed.closeAndWait(); evidence.feedClosed = true }
    evidence.finishedUptime = ProcessInfo.processInfo.systemUptime
    if outputOwned {
      do { try persist(evidence, to: output) }
      catch {
        FileHandle.standardError.write(Data(("Evidence write failed: " + String(reflecting: error) + "\n").utf8))
        return 2
      }
    }
    return code
  }

  private static func check(_ args: SliderProbeArguments, _ cancellation: SliderProbeCancellation) throws {
    try cancellation.check()
    guard ProcessInfo.processInfo.systemUptime < args.deadlineUptime else { throw SliderProbeError.deadline }
  }

  private static func wait(until uptime: Double, args: SliderProbeArguments,
    cancellation: SliderProbeCancellation) async throws {
    guard uptime < args.deadlineUptime else { throw SliderProbeError.deadline }
    while ProcessInfo.processInfo.systemUptime < uptime {
      try check(args, cancellation)
      let remaining = uptime - ProcessInfo.processInfo.systemUptime
      if remaining > 0 { try await Task.sleep(for: .seconds(min(0.05, remaining))) }
    }
    try check(args, cancellation)
  }

  private static func sample(_ phase: String, _ value: FBSimulatorSliderCapabilities) -> SliderProbeSample {
    SliderProbeSample(phase: phase, capturedUptime: ProcessInfo.processInfo.systemUptime, capabilities: value)
  }

  private static func nodes(_ handle: FBAccessibilityElement) throws -> [FBSimulatorAXNode] {
    let response = try handle.serialize(with: FBAccessibilityRequestOptions(nestedFormat: true))
    let data = try JSONSerialization.data(withJSONObject: response.elements)
    guard data.count <= 1024 * 1024 else { throw SliderProbeError.invalid("Public tree exceeds one MiB") }
    let decoder = JSONDecoder()
    if let array = try? decoder.decode([FBSimulatorAXNode].self, from: data) { return array }
    return [try decoder.decode(FBSimulatorAXNode.self, from: data)]
  }

  private static func matching(_ roots: [FBSimulatorAXNode], identifier: String) throws -> [FBSimulatorAXNode] {
    var matches: [FBSimulatorAXNode] = []
    var count = 0
    func walk(_ nodes: [FBSimulatorAXNode], depth: Int) throws {
      guard depth <= 32 else { throw SliderProbeError.invalid("Public tree depth exceeds 32") }
      for node in nodes {
        count += 1
        guard count <= 1024 else { throw SliderProbeError.invalid("Public tree exceeds 1024 nodes") }
        if node.identifier == identifier { matches.append(node) }
        try walk(node.children, depth: depth + 1)
      }
    }
    try walk(roots, depth: 0)
    return matches
  }

  private static func requireUnique(_ roots: [FBSimulatorAXNode], args: SliderProbeArguments,
    expected: FBSimulatorSliderCapabilities) throws {
    let matches = try matching(roots, identifier: args.identifier)
    guard matches.count == 1, let node = matches.first else {
      throw SliderProbeError.invalid("Exact slider ID is absent or duplicated")
    }
    try requireNode(node, args: args, expected: expected)
  }

  private static func requireOwnedRoot(_ roots: [FBSimulatorAXNode], args: SliderProbeArguments,
    expected: FBSimulatorSliderCapabilities) throws {
    guard roots.count == 1, let root = roots.first else {
      throw SliderProbeError.invalid("Public owned handle does not have exactly one root")
    }
    try requireNode(root, args: args, expected: expected)
    try requireUnique(roots, args: args, expected: expected)
  }

  private static func requireNode(_ node: FBSimulatorAXNode, args: SliderProbeArguments,
    expected: FBSimulatorSliderCapabilities) throws {
    let domain = try expected.requireDomain()
    let value = try expected.requireValue()
    guard node.identifier == args.identifier, node.label == args.label,
          node.pid == args.pid, node.type == "Slider",
          node.frame == expected.node.frame, let frame = node.frame,
          [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
          frame.width > 0, frame.height > 0, case .number(let actual)? = node.value,
          actual == value, domain.contains(actual) else {
      throw SliderProbeError.invalid("Owned root ID, PID, Slider role, frame or numeric value changed")
    }
  }

  private static func persist(_ evidence: SliderProbeEvidence, to output: URL, first: Bool = false) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(evidence)
    guard data.count <= 4 * 1024 * 1024 else { throw SliderProbeError.invalid("Evidence exceeds four MiB") }
    try data.write(to: output, options: first ? .withoutOverwriting : .atomic)
  }
}
