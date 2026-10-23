import AppKit
import CryptoKit
import Darwin
import Foundation
import ObjectiveC
@preconcurrency import AccessibilityPlatformTranslation
@preconcurrency import FBControlCore
@preconcurrency import FBSimulatorControl

private final class SliderPickupReadReporter: NSObject, FBEventReporter {
    var metadata: [String: String] = [:]
    func report(_ event: FBEventReporterSubject) {}
    func addMetadata(_ metadata: [String: String]) {}
}
private enum SliderPickupReadError: Error { case rejected(String) }
struct SliderPickupReadRect: Codable, Equatable {
    let x: Double, y: Double, width: Double, height: Double
    init(_ frame: CGRect) { x = frame.minX; y = frame.minY; width = frame.width; height = frame.height }
}
struct SliderPickupReadToken: Codable, Equatable, Hashable {
    let pid: Int32, element: UInt64, elementID: UInt64
    init(pid: Int32, element: UInt64, elementID: UInt64) throws {
        guard pid > 0, element > 0, elementID > 0 else { throw SliderPickupReadError.rejected("SliderPickupReadNative token unavailable") }
        self.pid = pid; self.element = element; self.elementID = elementID
    }
    init(_ data: Data, pid expected: Int32) throws {
        guard data.count == 20 else { throw SliderPickupReadError.rejected("Unsupported simulator token length") }
        pid = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int32.self) }.littleEndian
        element = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt64.self) }.littleEndian
        elementID = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt64.self) }.littleEndian
        guard pid == expected, pid > 0, element > 0, elementID > 0 else { throw SliderPickupReadError.rejected("Simulator token identity differs") }
    }
}
struct SliderPickupReadAttribute: Codable {
    let source: String, name: String, symbol: String?, state: String
    let objectType: String?, rawJSON: String?, error: String?
    let objectiveCType: String?, rawDescription: String?
}
struct SliderPickupReadPoint: Codable, Equatable { let x: Double, y: Double }
struct SliderPickupParentNode: Codable, Equatable {
    let token: SliderPickupReadToken
    let identifier: String?
    let frame: SliderPickupReadRect
    let displayID: UInt32
    let windowContextID: UInt64
    let equalsSelectedTarget: Bool
}
struct SliderPickupParentWalk: Codable {
    let state: String
    let reason: String
    let nodes: [SliderPickupParentNode]
}
struct SliderPickupReadEvidence: Codable {
    var source = "axeSliderPickupReadV1"
    var readPhase = ""
    var readID = ""
    var simulatorUDID = ""
    var startedUptime = ProcessInfo.processInfo.systemUptime
    var finishedUptime: Double?
    var remainingBudgetSeconds: Double?
    var localDeadlineUptime: Double?
    var elapsedSeconds: Double?
    var sealed = false
    var bindingSHA256: String?
    var finalNativeToken: SliderPickupReadToken?
    var inputEvents = 0
    var valueWrites = 0
    let geometryUnits = "raw search candidates only; pickup requires exact current native parent identity"
    var point: SliderPickupReadPoint?
    var nativePoint: SliderPickupReadPoint?
    var pointToken: SliderPickupReadToken?
    var pointFrame: SliderPickupReadRect?
    var pointRole: String?
    var pointElementEqualsTarget: Bool?
    var parentWalk: SliderPickupParentWalk?
    var parentVerified = false
    var status = "FAILED"
    var phase = "arguments"
    var error: String?
    var context: FBSimulatorContextReadback?
    var finalContext: FBSimulatorContextReadback?
    var finalSelectedFrame: SliderPickupReadRect?
    var finalSelectedToken: SliderPickupReadToken?
    var initialRootClosed = false
    var finalRootClosed = false
    var expectedPID: Int32?
    var selectorKind = ""
    var selectorValue = ""
    var identifier: String?
    var actualIdentifier: String?
    var selectedFrame: SliderPickupReadRect?
    var selectedToken: SliderPickupReadToken?
    var nativeToken: SliderPickupReadToken?
    var nativeRole: UInt64?
    var windowContextID: UInt64?
    var attributes: [SliderPickupReadAttribute] = []
    var genericAttributes: [SliderPickupReadAttribute] = []
    var verifiedAfterRead = false
    var nativeSessionClosed = false
}

/// Only the existing source-verified Objective-C calls are used. No action selector exists here.
@MainActor private enum SliderPickupReadNative {
    typealias Factory = @convention(c) (AnyClass, Selector, NSObject) -> Unmanaged<NSObject>?
    typealias PIDFactory = @convention(c) (AnyClass, Selector, Int32) -> Unmanaged<NSObject>?
    typealias BoolFactory = @convention(c) (AnyClass, Selector, Bool) -> Unmanaged<NSObject>?
    typealias ObjectGet = @convention(c) (NSObject, Selector) -> Unmanaged<NSObject>?
    typealias UIntGet = @convention(c) (NSObject, Selector) -> UInt64
    typealias PIDGet = @convention(c) (NSObject, Selector) -> Int32
    typealias SnapshotCall = @convention(c) (NSObject, Selector, NSObject, NSArray, NSObject, AutoreleasingUnsafeMutablePointer<NSError?>) -> Unmanaged<NSObject>?
    typealias AttributeCall = @convention(c) (NSObject, Selector, NSObject, NSArray, AutoreleasingUnsafeMutablePointer<NSError?>) -> Unmanaged<NSObject>?
    typealias AXPAttributeCall = @convention(c) (NSObject, Selector, NSString) -> Unmanaged<NSObject>?
    typealias VoidCall = @convention(c) (NSObject, Selector) -> Void
    typealias Allocate = @convention(c) (AnyClass, Selector) -> Unmanaged<NSObject>
    typealias ElementInit = @convention(c) (NSObject, Selector, NSObject?, UInt64, UInt64, Int32, UInt64, UInt64) -> Unmanaged<NSObject>?
    static func method(_ cls: AnyClass, _ name: String, _ abi: String, factory: Bool = false) throws -> IMP {
        let sel = NSSelectorFromString(name)
        let item = factory ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel)
        guard let item, method_getTypeEncoding(item).map({ String(cString: $0) }) == abi else {
            throw SliderPickupReadError.rejected("Unavailable verified selector/ABI: " + name)
        }
        return method_getImplementation(item)
    }
    static func method(_ receiver: NSObject, _ name: String, _ abi: String) throws -> IMP {
        try method(type(of: receiver), name, abi)
    }
    static func object(_ receiver: NSObject, _ name: String) throws -> NSObject {
        let call = unsafeBitCast(try method(receiver, name, "@16@0:8"), to: ObjectGet.self)
        guard let value = call(receiver, NSSelectorFromString(name))?.takeUnretainedValue() else { throw SliderPickupReadError.rejected("Nil native object: " + name) }
        return value
    }
    static func number(_ receiver: NSObject, _ name: String) throws -> UInt64 {
        unsafeBitCast(try method(receiver, name, "Q16@0:8"), to: UIntGet.self)(receiver, NSSelectorFromString(name))
    }
    static func pid(_ receiver: NSObject) throws -> Int32 {
        unsafeBitCast(try method(receiver, "processIdentifier", "i16@0:8"), to: PIDGet.self)(receiver, NSSelectorFromString("processIdentifier"))
    }
    static func constant(_ symbol: String) throws -> NSString {
        guard let address = dlsym(UnsafeMutableRawPointer(bitPattern: -2), symbol),
              let value = address.assumingMemoryBound(to: NSString?.self).pointee else { throw SliderPickupReadError.rejected("Export unavailable: " + symbol) }
        return value
    }
    static func attributes(_ client: NSObject, _ element: NSObject, _ names: [NSString]) throws -> NSDictionary {
        var error: NSError?
        let call = unsafeBitCast(try method(client, "attributesForElement:attributes:error:", "@40@0:8@16@24^@32"), to: AttributeCall.self)
        guard let value = call(client, NSSelectorFromString("attributesForElement:attributes:error:"), element, names as NSArray, &error)?.takeUnretainedValue() as? NSDictionary,
              error == nil else { throw SliderPickupReadError.rejected("SliderPickupReadNative attribute read failed: " + String(describing: error)) }
        return value
    }
    static func generic(_ target: AXPMacPlatformElement, _ name: String) throws -> NSObject? {
        let call = unsafeBitCast(try method(target, "accessibilityAttributeValue:", "@24@0:8@16"), to: AXPAttributeCall.self)
        return call(target, NSSelectorFromString("accessibilityAttributeValue:"), name as NSString)?.takeUnretainedValue()
    }
    static func capture(source: String, name: String, symbol: String? = nil, value: NSObject?, error: String? = nil) -> SliderPickupReadAttribute {
        guard let value else { return .init(source: source, name: name, symbol: symbol, state: error == nil ? "missing" : "readError", objectType: nil, rawJSON: nil, error: error, objectiveCType: nil, rawDescription: nil) }
        let nativeValue = value as? NSValue
        let objectiveCType = nativeValue.map { String(cString: $0.objCType) }
        let rawDescription = nativeValue.map { String($0.description.prefix(1024)) }
        do {
            // Raw Objective-C attributes require Foundation serialization; no value semantics are inferred.
            let data = try JSONSerialization.data(withJSONObject: ["value": value], options: [.sortedKeys])
            guard data.count <= 65536 else { throw SliderPickupReadError.rejected("Raw attribute exceeds 64 KiB") }
            return .init(source: source, name: name, symbol: symbol, state: "returned", objectType: String(describing: type(of: value)), rawJSON: String(decoding: data, as: UTF8.self), error: nil, objectiveCType: objectiveCType, rawDescription: rawDescription)
        } catch {
            return .init(source: source, name: name, symbol: symbol, state: "unsupportedRepresentation", objectType: String(describing: type(of: value)), rawJSON: nil, error: String(describing: error), objectiveCType: objectiveCType, rawDescription: rawDescription)
        }
    }
    static func validate(_ values: NSDictionary, names: [NSString], id: String?, frame: CGRect, display: UInt32, window: UInt64?) throws -> UInt64 {
        guard values[names[0]] as? String == id,
              let rect = values[names[1]] as? [String: NSNumber],
              let x = rect["X"], let y = rect["Y"], let w = rect["Width"], let h = rect["Height"],
              CGRect(x: x.doubleValue, y: y.doubleValue, width: w.doubleValue, height: h.doubleValue) == frame,
              (values[names[2]] as? NSNumber)?.uint32Value == display,
              let context = values[names[3]] as? NSNumber, context.uint64Value > 0,
              window == nil || context.uint64Value == window else { throw SliderPickupReadError.rejected("SliderPickupReadNative identifier/frame/display/window differs") }
        return context.uint64Value
    }
    static func close(_ session: NSObject) throws {
        let call = unsafeBitCast(try method(session, "invalidate", "v16@0:8"), to: VoidCall.self)
        call(session, NSSelectorFromString("invalidate"))
    }
}


@MainActor private final class SliderPickupReadOwner {
    private let device: NSObject
    private let session: NSObject
    private var objects: [NSObject] = []
    private(set) var closed = false

    init(device: NSObject, session: NSObject) {
        self.device = device
        self.session = session
    }
    func keep(_ object: NSObject) { objects.append(object) }
    func close() throws {
        guard !closed else { return }
        try SliderPickupReadNative.close(session)
        closed = true
        withExtendedLifetime((device, objects)) {}
    }
}
private struct SliderPickupGenericRead {
    let root: AXPMacPlatformElement
    let target: AXPMacPlatformElement
    let bridge: String
    let frame: CGRect
    let token: SliderPickupReadToken
    let values: [SliderPickupReadAttribute]
}

enum SliderPickupReadPhase {
    @MainActor static func run(arguments args: [String]) async {
        var result = SliderPickupReadEvidence()
        var output: URL?
        var ownedOutput = false
        var root: FBAccessibilityElement?
        var nativeOwner: SliderPickupReadOwner?
        do {
            let required: Set<String> = ["--phase", "--read-id", "--remaining-budget-seconds", "--udid", "--boot", "--screen-id", "--screen-uuid", "--pid", "--selector-kind", "--selector-value", "--point-x", "--point-y", "--helper", "--out"]
            let optional: Set<String> = ["--binding", "--binding-sha256"]
            guard args.count % 2 == 0 else { throw SliderPickupReadError.rejected("Named arguments require values") }
            var fields: [String: String] = [:]
            for index in stride(from: 0, to: args.count, by: 2) {
                guard required.union(optional).contains(args[index]), fields[args[index]] == nil else {
                    throw SliderPickupReadError.rejected("Unknown/repeated argument")
                }
                fields[args[index]] = args[index + 1]
            }
            guard required.isSubset(of: Set(fields.keys)),
                  let phase = fields["--phase"], ["target", "geometry", "point", "native"].contains(phase),
                  let readID = fields["--read-id"].flatMap(UUID.init(uuidString:)),
                  let budget = fields["--remaining-budget-seconds"].flatMap(Double.init), budget.isFinite,
                  budget > 0, budget <= 30,
                  let udid = fields["--udid"].flatMap(UUID.init(uuidString:)),
                  let boot = fields["--boot"], !boot.isEmpty,
                  let screenID = fields["--screen-id"].flatMap(UInt32.init),
                  let screenUUID = fields["--screen-uuid"].flatMap(UUID.init(uuidString:)),
                  let pid = fields["--pid"].flatMap(Int32.init), pid > 0,
                  let selectorKind = fields["--selector-kind"], ["id", "label"].contains(selectorKind),
                  let selectorValue = fields["--selector-value"], !selectorValue.isEmpty, selectorValue.utf8.count <= 4096,
                  let pointX = fields["--point-x"].flatMap(Double.init), pointX.isFinite,
                  let pointY = fields["--point-y"].flatMap(Double.init), pointY.isFinite,
                  let helper = fields["--helper"], helper.hasPrefix("/"),
                  let out = fields["--out"], out.hasPrefix("/") else {
                throw SliderPickupReadError.rejected("Invalid explicit phase, identity, shared deadline or file path")
            }
            let localStart = ProcessInfo.processInfo.systemUptime
            let deadline = localStart + budget
            let destination = URL(fileURLWithPath: out)
            output = destination
            result.readPhase = phase; result.readID = readID.uuidString; result.simulatorUDID = udid.uuidString
            result.expectedPID = pid; result.selectorKind = selectorKind; result.selectorValue = selectorValue
            result.startedUptime = localStart; result.remainingBudgetSeconds = budget
            result.localDeadlineUptime = deadline
            try persist(result, destination, first: true)
            ownedOutput = true
            func check() throws {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw SliderPickupReadError.rejected("Shared read-only deadline exceeded")
                }
            }
            func mark(_ phase: String) throws { result.phase = phase; try persist(result, destination) }
            guard ["native", "geometry"].contains(phase) || fields["--binding"] == nil && fields["--binding-sha256"] == nil else {
                throw SliderPickupReadError.rejected("The point phase cannot use a previous binding")
            }
            let binding = try loadBinding(fields: fields, phase: phase)
            if let binding {
                guard binding.sealed, binding.verifiedAfterRead, binding.error == nil,
                      binding.readID == readID.uuidString, binding.simulatorUDID == udid.uuidString,
                      binding.expectedPID == pid, binding.selectorKind == selectorKind, binding.selectorValue == selectorValue,
                      binding.readPhase == (phase == "geometry" ? "target" : "point"),
                      binding.selectedFrame != nil, binding.selectedToken != nil else {
                    throw SliderPickupReadError.rejected("Prior sealed phase identity differs")
                }
                result.bindingSHA256 = fields["--binding-sha256"]
            }
            let logger = FBControlCoreLoggerFactory.systemLoggerWriting(toStderr: true, withDebugLogging: false)
            FBControlCoreGlobalConfiguration.defaultLogger = logger
            try FBSimulatorControlFrameworkLoader.xcodeFrameworks.loadPrivateFrameworks(logger)
            let control = try FBSimulatorControl.withConfiguration(FBSimulatorControlConfiguration(deviceSetPath: nil, logger: logger, reporter: SliderPickupReadReporter()))
            guard let simulator = control.set.allSimulators.first(where: { UUID(uuidString: $0.udid) == udid }),
                  simulator.state == .booted else { throw SliderPickupReadError.rejected("Explicit device is not booted") }
            let reader = FBSimulatorNativeContextReader(simulator: simulator, helperURL: URL(fileURLWithPath: helper), screenID: screenID, screenUniqueID: screenUUID)
            try check(); try mark("before-context")
            let before = try await reader.read()
            let observation = try before.observation.sessionObservation()
            guard observation.bootIdentity == boot else { throw SliderPickupReadError.rejected("Explicit boot changed") }
            if let binding {
                guard let previous = binding.finalContext,
                      try previous.observation.sessionObservation() == observation else {
                    throw SliderPickupReadError.rejected("Prior phase device context differs")
                }
            }
            result.context = before
            let point = CGPoint(x: pointX, y: pointY)
            let size = observation.displayContext.logicalSize
            guard observation.screenID == 1, observation.displayContext.rotation == .rot0,
                  pointX >= 0, pointY >= 0, pointX < size.width, pointY < size.height else {
                throw SliderPickupReadError.rejected("Slider pickup requires the active outer portrait display and an in-bounds point")
            }
            let normalized = try observation.displayContext.normalizedPoint(from: point)
            let nativePoint = CGPoint(x: normalized.x * observation.displayContext.nativePixelSize.width / observation.displayContext.scale,
                                      y: normalized.y * observation.displayContext.nativePixelSize.height / observation.displayContext.scale)
            result.point = SliderPickupReadPoint(x: pointX, y: pointY)
            result.nativePoint = SliderPickupReadPoint(x: nativePoint.x, y: nativePoint.y)
            try check()
            if phase == "target" {
                let commands = FBSimulatorAccessibilityCommands(simulator: simulator)
                let app = try await commands.accessibilityElementForFrontmostApplication(displayID: observation.axDisplayID, displayContext: observation.displayContext)
                root = app
                let generic = try readGeneric(app, pid: pid, selectorKind: selectorKind, selectorValue: selectorValue, prefix: "target", includeValues: true, check: check, mark: mark)
                result.actualIdentifier = generic.target.accessibilityIdentifier()
                result.selectedFrame = SliderPickupReadRect(generic.frame); result.selectedToken = generic.token
                result.finalSelectedFrame = result.selectedFrame; result.finalSelectedToken = generic.token
                result.genericAttributes = generic.values
                app.close(); root = nil; result.initialRootClosed = true
            } else if phase == "point" {
                // This process never creates an independent XCUI device/client.
                let commands = FBSimulatorAccessibilityCommands(simulator: simulator)
                try mark("before-AXP-root-acquire")
                let app = try await commands.accessibilityElementForFrontmostApplication(displayID: observation.axDisplayID, displayContext: observation.displayContext)
                root = app
                try mark("after-AXP-root-acquire")
                let generic = try readGeneric(app, pid: pid, selectorKind: selectorKind, selectorValue: selectorValue,
                    prefix: "AXP-only", includeValues: true, check: check, mark: mark)
                result.actualIdentifier = generic.target.accessibilityIdentifier()
                result.selectedFrame = SliderPickupReadRect(generic.frame)
                result.selectedToken = generic.token
                result.genericAttributes = generic.values
                guard generic.frame.contains(point) else { throw SliderPickupReadError.rejected("SliderPickupReadPoint outside current Slider frame") }
                try check(); try mark("before-fresh-point-token")
                let translator = unsafeBitCast(AXPTranslator.sharedInstance() as AnyObject, to: AXPTranslator.self)
                guard let hitTranslation = translator.object(at: nativePoint, displayId: observation.axDisplayID,
                    bridgeDelegateToken: generic.bridge), hitTranslation.pid == pid else {
                    throw SliderPickupReadError.rejected("Fresh point translation or PID differs")
                }
                hitTranslation.bridgeDelegateToken = generic.bridge
                guard let hit = translator.macPlatformElement(fromTranslation: hitTranslation) as? AXPMacPlatformElement,
                      hit.accessibilityRole()?.rawValue == NSAccessibility.Role.group.rawValue,
                      let hitToken = try simulatorToken(hit, pid: pid), hitToken != generic.token else {
                    throw SliderPickupReadError.rejected("Fresh point is not a distinct native Group token")
                }
                let hitFrame = hit.accessibilityFrame()
                guard [hitFrame.minX, hitFrame.minY, hitFrame.width, hitFrame.height].allSatisfy(\.isFinite),
                      hitFrame.width > 0, hitFrame.height > 0, hitFrame.contains(point), generic.frame.contains(hitFrame) else {
                    throw SliderPickupReadError.rejected("Fresh Group frame is not finite, contained and at the explicit point")
                }
                result.pointToken = hitToken; result.pointFrame = SliderPickupReadRect(hitFrame)
                result.pointRole = hit.accessibilityRole()?.rawValue
                result.pointElementEqualsTarget = hit.isEqual(generic.target)
                guard result.pointElementEqualsTarget == false,
                      translator.frontmostApplication(withDisplayId: observation.axDisplayID,
                        bridgeDelegateToken: generic.bridge)?.pid == pid else {
                    throw SliderPickupReadError.rejected("Fresh point identity or frontmost PID changed")
                }
                let final = try readGeneric(app, pid: pid, selectorKind: selectorKind, selectorValue: selectorValue,
                    prefix: "point-final-target", includeValues: true, check: check, mark: mark)
                guard final.frame == generic.frame, final.token == generic.token,
                      try attributeValues(final.values) == attributeValues(generic.values) else {
                    throw SliderPickupReadError.rejected("Selected Slider changed during point phase")
                }
                result.finalSelectedFrame = SliderPickupReadRect(final.frame); result.finalSelectedToken = final.token
                try mark("after-fresh-point-token")
                try mark("before-AXP-root-close")
                app.close(); root = nil
                result.initialRootClosed = true
                try mark("after-AXP-root-close")
            } else {
                // This process never acquires an AXP root, before or after native invalidate.
                guard let binding, binding.source == result.source,
                      binding.readPhase == (phase == "geometry" ? "target" : "point"),
                      binding.status == (phase == "geometry" ? "TARGET_PHASE_COMPLETE" : "POINT_PHASE_COMPLETE"),
                      binding.initialRootClosed, binding.inputEvents == 0, binding.valueWrites == 0,
                      let saved = binding.selectedFrame, let token = binding.selectedToken,
                      binding.finalSelectedFrame == saved, binding.finalSelectedToken == token else {
                    throw SliderPickupReadError.rejected("Native phase requires the sealed AXP target")
                }
                if phase == "native" {
                    guard binding.point == result.point, binding.nativePoint == result.nativePoint,
                          binding.pointRole == NSAccessibility.Role.group.rawValue,
                          binding.pointElementEqualsTarget == false,
                          let hitToken = binding.pointToken, hitToken != token, hitToken.pid == pid,
                          binding.pointFrame != nil else {
                        throw SliderPickupReadError.rejected("Native parent phase requires a fresh Group token")
                    }
                }
                let frame = CGRect(x: saved.x, y: saved.y, width: saved.width, height: saved.height)
                result.actualIdentifier = binding.actualIdentifier
                result.selectedFrame = saved; result.selectedToken = token
                result.finalSelectedFrame = binding.finalSelectedFrame; result.finalSelectedToken = binding.finalSelectedToken
                result.pointToken = binding.pointToken; result.pointFrame = binding.pointFrame
                result.pointRole = binding.pointRole; result.pointElementEqualsTarget = binding.pointElementEqualsTarget
                result.genericAttributes = binding.genericAttributes // Prior AXP measurements, not new native reads.
                try check(); try mark("before-native-framework-load")
                try FBSimulatorControlFrameworkLoader.accessibilityAutomationFrameworks.loadPrivateFrameworks(logger)
                try check(); try mark("after-native-framework-load")
                guard let deviceClass = NSClassFromString("XCUIDevice"), let elementClass = NSClassFromString("XCAccessibilityElement"),
                      let snapshotClass = NSClassFromString("XCElementSnapshot") else {
                    throw SliderPickupReadError.rejected("Verified native classes unavailable")
                }
                let makeDevice = unsafeBitCast(try SliderPickupReadNative.method(deviceClass, "iOSDeviceForSimulatorDevice:", "@24@0:8@16", factory: true), to: SliderPickupReadNative.Factory.self)
                guard let device = makeDevice(deviceClass, NSSelectorFromString("iOSDeviceForSimulatorDevice:"), simulator.device)?.takeUnretainedValue(),
                      try SliderPickupReadNative.object(device, "uniqueIdentifier").description.uppercased() == udid.uuidString else {
                    throw SliderPickupReadError.rejected("SliderPickupReadNative simulator identity differs")
                }
                try mark("before-native-session")
                let session = try SliderPickupReadNative.object(device, "remoteAutomationSession")
                let owner = SliderPickupReadOwner(device: device, session: session); nativeOwner = owner
                let client = try SliderPickupReadNative.object(device, "accessibilityInterface"); owner.keep(client)
                let makeApp = unsafeBitCast(try SliderPickupReadNative.method(elementClass, "elementWithProcessIdentifier:", "@20@0:8i16", factory: true), to: SliderPickupReadNative.PIDFactory.self)
                let makeAttributes = unsafeBitCast(try SliderPickupReadNative.method(snapshotClass, "requiredAXAttributesForElementSnapshotHierarchyOnMacOS:", "@20@0:8B16", factory: true), to: SliderPickupReadNative.BoolFactory.self)
                guard let application = makeApp(elementClass, NSSelectorFromString("elementWithProcessIdentifier:"), pid)?.takeUnretainedValue(),
                      let attributes = makeAttributes(snapshotClass, NSSelectorFromString("requiredAXAttributesForElementSnapshotHierarchyOnMacOS:"), false)?.takeUnretainedValue() as? NSSet else {
                    throw SliderPickupReadError.rejected("SliderPickupReadNative application/snapshot attributes unavailable")
                }
                owner.keep(application)
                var snapshotError: NSError?
                let snapshotCall = unsafeBitCast(try SliderPickupReadNative.method(client, "requestSnapshotForElement:attributes:parameters:error:", "@48@0:8@16@24@32^@40"), to: SliderPickupReadNative.SnapshotCall.self)
                let parameters = try SliderPickupReadNative.object(client, "defaultParameters")
                try check(); try mark("before-native-snapshot")
                guard let snapshot = snapshotCall(client, NSSelectorFromString("requestSnapshotForElement:attributes:parameters:error:"), application, attributes.allObjects as NSArray, parameters, &snapshotError)?.takeUnretainedValue(), snapshotError == nil,
                      try SliderPickupReadNative.number(SliderPickupReadNative.object(snapshot, "runtimeIssues"), "count") == 0 else {
                    throw SliderPickupReadError.rejected("SliderPickupReadNative snapshot failed: " + String(describing: snapshotError))
                }
                owner.keep(snapshot)
                var found: [NSObject] = []; var visited = 0
                func walk(_ node: NSObject, depth: Int) throws {
                    try check()
                    guard depth <= 32, visited < 512 else { throw SliderPickupReadError.rejected("SliderPickupReadNative tree bound exceeded") }
                    visited += 1
                    if try SliderPickupReadNative.number(node, "elementType") == 33 {
                        let element = try SliderPickupReadNative.object(node, "accessibilityElement")
                        if try nativeToken(element) == token { found.append(element) }
                    }
                    guard let children = try SliderPickupReadNative.object(node, "children") as? [NSObject] else { throw SliderPickupReadError.rejected("SliderPickupReadNative children unavailable") }
                    for child in children { try walk(child, depth: depth + 1) }
                }
                try walk(SliderPickupReadNative.object(snapshot, "rootElementSnapshot"), depth: 0)
                guard found.count == 1, let selected = found.first, try nativeToken(selected) == token else {
                    throw SliderPickupReadError.rejected("Independent native slider token differs")
                }
                owner.keep(selected); result.nativeRole = 33; result.nativeToken = token
                let symbols = ["XC_kAXXCAttributeIdentifier", "XC_kAXXCAttributeFrame", "XC_kAXXCAttributeWindowDisplayId", "XC_kAXXCAttributeWindowContextId"]
                let names = try symbols.map(SliderPickupReadNative.constant)
                let window = try SliderPickupReadNative.validate(SliderPickupReadNative.attributes(client, selected, names), names: names, id: binding.actualIdentifier, frame: frame, display: observation.axDisplayID, window: nil)
                result.windowContextID = window
                try check(); try mark("before-native-parent-walk")
                if phase == "geometry" {
                    for symbol in ["XC_kAXXCAttributeAbsoluteValue", "XC_kAXXCAttributeMinScrubberPosition", "XC_kAXXCAttributeMaxScrubberPosition"] {
                        try check()
                        let key = try SliderPickupReadNative.constant(symbol)
                        let value = try SliderPickupReadNative.attributes(client, selected, [key])[key] as? NSObject
                        result.attributes.append(SliderPickupReadNative.capture(source: "native read-only attribute", name: String(key), symbol: symbol, value: value))
                        try mark("geometry-" + symbol)
                    }
                } else {
                    guard let hitToken = binding.pointToken, let hitFrame = binding.pointFrame else {
                        throw SliderPickupReadError.rejected("Fresh native point binding is missing")
                    }
                    result.parentWalk = try readNativeParents(client: client, selected: selected, elementClass: elementClass,
                        hitToken: hitToken, hitFrame: hitFrame, point: point, expectedPID: pid, identifier: binding.actualIdentifier,
                        selectedFrame: frame, display: observation.axDisplayID, window: window, owner: owner, check: check)
                    result.parentVerified = result.parentWalk?.state == "matchedExactSliderNativeToken"
                }
                try mark("after-native-parent-walk")
                try check(); try mark("before-final-native-identity")
                _ = try SliderPickupReadNative.validate(SliderPickupReadNative.attributes(client, selected, names), names: names, id: binding.actualIdentifier, frame: frame, display: observation.axDisplayID, window: window)
                let finalToken = try nativeToken(selected)
                guard finalToken == token else { throw SliderPickupReadError.rejected("Final native token changed") }
                result.finalNativeToken = finalToken
                try mark("after-final-native-identity")
                try mark("before-native-local-close"); try owner.close()
                result.nativeSessionClosed = true
                try mark("after-native-local-close")
                // Return through sealing below. There is deliberately no legacy AXP rebootstrap here.
            }
            try check(); try mark("before-final-context")
            let after = try await reader.read(); result.finalContext = after
            guard try after.observation.sessionObservation() == observation else { throw SliderPickupReadError.rejected("Context changed during phase") }
            try check(); result.verifiedAfterRead = true
            switch phase {
            case "target": result.status = "TARGET_PHASE_COMPLETE"
            case "geometry": result.status = "GEOMETRY_PHASE_COMPLETE"
            case "point": result.status = "POINT_PHASE_COMPLETE"
            default: result.status = result.parentVerified ? "NATIVE_PARENT_PHASE_COMPLETE_MATCHED" : "NATIVE_PARENT_PHASE_COMPLETE_UNKNOWN"
            }
            result.phase = "complete"
        } catch { result.error = String(describing: error) }
        if let owner = nativeOwner, !owner.closed {
            do { try owner.close(); result.nativeSessionClosed = true }
            catch { result.error = result.error ?? String(describing: error) }
        }
        if let handle = root { handle.close(); result.initialRootClosed = true; root = nil }
        let finished = ProcessInfo.processInfo.systemUptime
        result.finishedUptime = finished
        result.elapsedSeconds = finished - result.startedUptime
        let withinBudget = result.remainingBudgetSeconds.map { budget in
            finished >= result.startedUptime && finished - result.startedUptime <= budget
        } ?? false
        if !withinBudget { result.error = result.error ?? "Local relative read budget expired" }
        let complete = result.verifiedAfterRead && result.error == nil && withinBudget &&
            (["target", "point"].contains(result.readPhase) ? result.initialRootClosed : result.nativeSessionClosed)
        if !complete { result.status = "FAILED" }
        result.sealed = complete
        do {
            if ownedOutput, let output { try persist(result, output) }
            let data = try JSONEncoder().encode(result)
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        } catch { FileHandle.standardError.write(Data((String(describing: error) + "\n").utf8)); exit(2) }
        exit(complete ? 0 : 2)
    }

    @MainActor private static func simulatorToken(_ target: AXPMacPlatformElement, pid: Int32) throws -> SliderPickupReadToken? {
        guard let value = try SliderPickupReadNative.generic(target, "AXDeviceElementToken") as? NSDictionary else { return nil }
        guard value["TokenType"] as? String == "AXElementTokenSimulator",
              let data = value["ElementData"] as? Data else { throw SliderPickupReadError.rejected("SliderPickupReadPoint simulator token unavailable") }
        return try SliderPickupReadToken(data, pid: pid)
    }

    /// Read-only adaptation of the existing native CheckBox parent transport.
    /// The selected target is independently proved Slider role33; the CheckBox client is unchanged.
    @MainActor private static func readNativeParents(client: NSObject, selected: NSObject, elementClass: AnyClass,
        hitToken: SliderPickupReadToken, hitFrame: SliderPickupReadRect, point: CGPoint, expectedPID: Int32, identifier: String?,
        selectedFrame: CGRect, display: UInt32, window: UInt64, owner: SliderPickupReadOwner,
        check: () throws -> Void) throws -> SliderPickupParentWalk {
        let selectedToken = try nativeToken(selected)
        guard selectedToken.pid == expectedPID, hitToken.pid == expectedPID, hitToken != selectedToken,
              selectedFrame.contains(point) else { throw SliderPickupReadError.rejected("SliderPickupReadNative point or Slider token differs") }
        // Exact initializer/ABI and metadata reads used by the accepted native Switch client.
        let identityKind = try SliderPickupReadNative.number(selected, "elementType")
        let origin = try SliderPickupReadNative.number(selected, "originPlatform")
        let allocate = unsafeBitCast(try SliderPickupReadNative.method(elementClass, "alloc", "@16@0:8", factory: true), to: SliderPickupReadNative.Allocate.self)
        let initialize = unsafeBitCast(try SliderPickupReadNative.method(elementClass,
            "initWithToken:elementOrHash:elementID:pid:elementType:originPlatform:", "@60@0:8@16Q24Q32i40Q44Q52"), to: SliderPickupReadNative.ElementInit.self)
        let allocated = allocate(elementClass, NSSelectorFromString("alloc"))
        guard let hit = initialize(allocated.takeUnretainedValue(),
            NSSelectorFromString("initWithToken:elementOrHash:elementID:pid:elementType:originPlatform:"), nil,
            hitToken.element, hitToken.elementID, hitToken.pid, identityKind, origin)?.takeRetainedValue() else {
            throw SliderPickupReadError.rejected("SliderPickupReadNative point identity unavailable")
        }
        owner.keep(hit)
        guard try nativeToken(hit) == hitToken else { throw SliderPickupReadError.rejected("Constructed native point token differs") }
        let symbols = ["XC_kAXXCAttributeIdentifier", "XC_kAXXCAttributeFrame", "XC_kAXXCAttributeWindowDisplayId",
                       "XC_kAXXCAttributeWindowContextId", "XC_kAXXCAttributeParent"]
        let names = try symbols.map(SliderPickupReadNative.constant)
        var current: NSObject? = hit
        var kept: [NSObject] = []
        var seenTokens = Set<SliderPickupReadToken>()
        var rows: [SliderPickupParentNode] = []
        for index in 0..<12 {
            try check()
            guard let element = current else { return SliderPickupParentWalk(state: "unknown", reason: "SliderPickupReadNative parent returned nil", nodes: rows) }
            let token = try nativeToken(element)
            guard token.pid == expectedPID else { throw SliderPickupReadError.rejected("SliderPickupReadNative ancestry PID differs") }
            guard seenTokens.insert(token).inserted, !kept.contains(where: { $0.isEqual(element) }) else {
                return SliderPickupParentWalk(state: "unknown", reason: "SliderPickupReadNative parent cycle detected", nodes: rows)
            }
            kept.append(element); owner.keep(element)
            let values = try SliderPickupReadNative.attributes(client, element, names)
            try check()
            guard (values[names[2]] as? NSNumber)?.uint32Value == display,
                  (values[names[3]] as? NSNumber)?.uint64Value == window,
                  let fields = values[names[1]] as? [String: NSNumber],
                  let x = fields["X"], let y = fields["Y"], let width = fields["Width"], let height = fields["Height"] else {
                throw SliderPickupReadError.rejected("SliderPickupReadNative parent frame, window or display differs")
            }
            let frame = CGRect(x: x.doubleValue, y: y.doubleValue, width: width.doubleValue, height: height.doubleValue)
            guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
                  frame.width > 0, frame.height > 0, frame.contains(point) else {
                throw SliderPickupReadError.rejected("SliderPickupReadNative parent has no finite positive frame at the explicit point")
            }
            if index == 0, SliderPickupReadRect(frame) != hitFrame { throw SliderPickupReadError.rejected("SliderPickupReadNative Group frame differs from the fresh point read") }
            let equalsSelected = element.isEqual(selected)
            rows.append(SliderPickupParentNode(token: token, identifier: values[names[0]] as? String, frame: SliderPickupReadRect(frame),
                displayID: display, windowContextID: window, equalsSelectedTarget: equalsSelected))
            if token == selectedToken || equalsSelected {
                guard token == selectedToken, equalsSelected, index > 0,
                      values[names[0]] as? String == identifier, frame == selectedFrame else {
                    throw SliderPickupReadError.rejected("SliderPickupReadNative target equality conflicts with exact Slider token or signature")
                }
                return SliderPickupParentWalk(state: "matchedExactSliderNativeToken", reason: "Current Group reaches the exact independent native Slider", nodes: rows)
            }
            let value = values[names[4]]
            guard value != nil, !(value is NSNull) else {
                return SliderPickupParentWalk(state: "unknown", reason: "SliderPickupReadNative parent returned nil", nodes: rows)
            }
            guard let parent = value as? NSObject else {
                return SliderPickupParentWalk(state: "unknown", reason: "SliderPickupReadNative parent did not return an object", nodes: rows)
            }
            current = parent
        }
        return SliderPickupParentWalk(state: "unknown", reason: "SliderPickupReadNative parent depth bound reached", nodes: rows)
    }

    @MainActor private static func nativeToken(_ target: NSObject) throws -> SliderPickupReadToken {
        try SliderPickupReadToken(pid: SliderPickupReadNative.pid(target), element: SliderPickupReadNative.number(target, "elementOrHash"), elementID: SliderPickupReadNative.number(target, "elementID"))
    }
    private static func attributeValues(_ values: [SliderPickupReadAttribute]) throws -> [String: String] {
        var result: [String: String] = [:]
        for value in values {
            guard result[value.name] == nil else { throw SliderPickupReadError.rejected("Duplicate prior attribute") }
            result[value.name] = value.rawJSON ?? value.state
        }
        return result
    }
    private static func loadBinding(fields: [String: String], phase: String) throws -> SliderPickupReadEvidence? {
        guard let file = fields["--binding"], let expected = fields["--binding-sha256"] else {
            guard ["target", "point"].contains(phase), fields["--binding"] == nil, fields["--binding-sha256"] == nil else {
                throw SliderPickupReadError.rejected("Binding file and hash are required together")
            }
            return nil
        }
        guard file.hasPrefix("/"), expected.count == 64 else { throw SliderPickupReadError.rejected("Invalid binding path/hash") }
        let data = try Data(contentsOf: URL(fileURLWithPath: file))
        guard data.count <= 1024 * 1024,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expected else {
            throw SliderPickupReadError.rejected("Binding receipt changed")
        }
        return try JSONDecoder().decode(SliderPickupReadEvidence.self, from: data)
    }

    // Keep the same trimmed, case-sensitive policy as FBSimulatorAXSelector.matchesLabel.
    // That helper is internal to the native module; no new native API is required.
    private static func matchesLabel(_ candidate: String?, query: String) -> Bool {
        let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return !wanted.isEmpty && candidate?.trimmingCharacters(in: .whitespacesAndNewlines) == wanted
    }

    @MainActor private static func readGeneric(_ app: FBAccessibilityElement, pid: Int32,
        selectorKind: String, selectorValue: String, prefix: String, includeValues: Bool,
        check: () throws -> Void, mark: (String) throws -> Void) throws -> SliderPickupGenericRead {
        try check()
        try mark(prefix + ":root-translation")
        guard let nativeRoot = Mirror(reflecting: app).children.first(where: { $0.label == "element" })?.value as? AXPMacPlatformElement,
              let bridge = nativeRoot.translation?.bridgeDelegateToken,
              nativeRoot.translation?.pid == pid else { throw SliderPickupReadError.rejected("Owned application wrapper or PID differs") }
        var visited = 0
        var found: [AXPMacPlatformElement] = []
        func walk(_ node: AXPMacPlatformElement, depth: Int) throws {
            try check()
            guard depth <= 32, visited < 512 else { throw SliderPickupReadError.rejected("Generic tree bound exceeded") }
            visited += 1
            let index = visited
            node.translation?.bridgeDelegateToken = bridge
            try mark(prefix + ":identifier-node-" + String(index))
            let matches = selectorKind == "id"
                ? node.accessibilityIdentifier() == selectorValue
                : matchesLabel(node.accessibilityLabel(), query: selectorValue)
            if matches { found.append(node) }
            try mark(prefix + ":children-node-" + String(index))
            guard let children = node.accessibilityChildren() as? [AXPMacPlatformElement] else { throw SliderPickupReadError.rejected("Generic children unavailable") }
            for child in children { try walk(child, depth: depth + 1) }
        }
        try walk(nativeRoot, depth: 0)
        guard found.count == 1, let target = found.first else { throw SliderPickupReadError.rejected("Generic target is not unique") }
        target.translation?.bridgeDelegateToken = bridge
        try mark(prefix + ":target-pid")
        guard target.translation?.pid == pid else { throw SliderPickupReadError.rejected("Generic target PID differs") }
        try mark(prefix + ":target-role")
        guard target.accessibilityRole()?.rawValue == NSAccessibility.Role.slider.rawValue,
              target.isAccessibilityEnabled(), !target.isAccessibilityHidden() else { throw SliderPickupReadError.rejected("Generic target is not an enabled visible Slider") }
        try check()
        try mark(prefix + ":target-frame")
        let frame = target.accessibilityFrame()
        guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
              frame.width > 0, frame.height > 0 else { throw SliderPickupReadError.rejected("Generic slider frame unavailable") }
        try check()
        try mark(prefix + ":target-token")
        guard let tokenValue = try SliderPickupReadNative.generic(target, "AXDeviceElementToken") as? NSDictionary,
              tokenValue["TokenType"] as? String == "AXElementTokenSimulator",
              let tokenData = tokenValue["ElementData"] as? Data else { throw SliderPickupReadError.rejected("Slider token unavailable") }
        let token = try SliderPickupReadToken(tokenData, pid: pid)
        try mark(prefix + ":target-token-returned")
        var values: [SliderPickupReadAttribute] = []
        if includeValues {
            for name in [NSAccessibility.Attribute.value.rawValue, NSAccessibility.Attribute.minValue.rawValue, NSAccessibility.Attribute.maxValue.rawValue] {
                try check()
                try mark(prefix + ":value-" + name)
                do { values.append(SliderPickupReadNative.capture(source: "AXP accessibilityAttributeValue", name: name, value: try SliderPickupReadNative.generic(target, name))) }
                catch { values.append(SliderPickupReadNative.capture(source: "AXP accessibilityAttributeValue", name: name, value: nil, error: String(describing: error))) }
                try mark(prefix + ":value-returned-" + name)
            }
        }
        try check()
        return SliderPickupGenericRead(root: nativeRoot, target: target, bridge: bridge, frame: frame, token: token, values: values)
    }

    private static func persist(_ result: SliderPickupReadEvidence, _ file: URL, first: Bool = false) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(result)
        guard data.count <= 1024 * 1024 else { throw SliderPickupReadError.rejected("SliderPickupReadEvidence exceeds 1 MiB") }
        try data.write(to: file, options: first ? .withoutOverwriting : .atomic)
    }
}
