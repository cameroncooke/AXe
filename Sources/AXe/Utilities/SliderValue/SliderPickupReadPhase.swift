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
enum SliderPickupReadError: Error { case rejected(String) }
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
    let geometryUnits = "raw search candidates only; pickup requires exact current native Slider or parent identity"
    var point: SliderPickupReadPoint?
    var nativePoint: SliderPickupReadPoint?
    var pointToken: SliderPickupReadToken?
    var pointFrame: SliderPickupReadRect?
    var pointRole: String?
    var pointElementEqualsTarget: Bool?
    var parentWalk: SliderPickupParentWalk?
    var parentVerified = false
    var directSliderVerified = false
    var pointKind: String?
    var nativeAXRole: String?
    var axpOwnerClosed = false
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

/// Declared AXP reads only. No independent automation client or session is constructed.
@MainActor enum SliderPickupReadNative {
    typealias AXPAttributeCall = @convention(c) (NSObject, Selector, NSString) -> Unmanaged<NSObject>?
    typealias WindowCall = @convention(c) (NSObject, Selector) -> UInt32
    static func method(_ receiver: NSObject, _ name: String, _ abi: String) throws -> IMP {
        guard let method = class_getInstanceMethod(type(of: receiver), NSSelectorFromString(name)),
              method_getTypeEncoding(method).map({ String(cString: $0) }) == abi else {
            throw SliderPickupReadError.rejected("Declared native getter ABI unavailable: " + name)
        }
        return method_getImplementation(method)
    }
    static func window(_ target: AXPMacPlatformElement) throws -> UInt64 {
        let call = unsafeBitCast(try method(target, "_windowContextId", "I16@0:8"), to: WindowCall.self)
        let value = call(target, NSSelectorFromString("_windowContextId"))
        guard value > 0 else { throw SliderPickupReadError.rejected("Native window context unavailable") }
        return UInt64(value)
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
        do {
            let required: Set<String> = ["--phase", "--read-id", "--remaining-budget-seconds", "--udid", "--boot", "--screen-id", "--screen-uuid", "--pid", "--selector-kind", "--selector-value", "--point-x", "--point-y", "--out"]
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
            let reader = FBSimulatorNativeContextReader(simulator: simulator, screenID: screenID, screenUniqueID: screenUUID)
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
            guard pointX >= 0, pointY >= 0, pointX < size.width, pointY < size.height else {
                throw SliderPickupReadError.rejected("Slider pickup requires an in-bounds point on the current selected display")
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
                      let hitToken = try simulatorToken(hit, pid: pid) else {
                    throw SliderPickupReadError.rejected("Fresh point native identity unavailable")
                }
                let hitFrame = hit.accessibilityFrame()
                guard [hitFrame.minX, hitFrame.minY, hitFrame.width, hitFrame.height].allSatisfy(\.isFinite),
                      hitFrame.width > 0, hitFrame.height > 0, hitFrame.contains(point), generic.frame.contains(hitFrame) else {
                    throw SliderPickupReadError.rejected("Fresh Group frame is not finite, contained and at the explicit point")
                }
                result.pointToken = hitToken; result.pointFrame = SliderPickupReadRect(hitFrame)
                result.pointRole = hit.accessibilityRole()?.rawValue
                result.pointElementEqualsTarget = hit.isEqual(generic.target)
                if result.pointRole == NSAccessibility.Role.slider.rawValue {
                    guard hitToken == generic.token, result.pointElementEqualsTarget == true, hitFrame == generic.frame else {
                        throw SliderPickupReadError.rejected("Direct Slider point identity or frame differs")
                    }
                    result.pointKind = "directSlider"
                } else {
                    guard result.pointRole == NSAccessibility.Role.group.rawValue, hitToken != generic.token,
                          result.pointElementEqualsTarget == false else { throw SliderPickupReadError.rejected("Point is neither selected Slider nor distinct Group") }
                    result.pointKind = "distinctGroup"
                }
                guard translator.frontmostApplication(withDisplayId: observation.axDisplayID,
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
                guard let binding, binding.source == result.source,
                      binding.readPhase == (phase == "geometry" ? "target" : "point"),
                      binding.status == (phase == "geometry" ? "TARGET_PHASE_COMPLETE" : "POINT_PHASE_COMPLETE"),
                      binding.initialRootClosed, binding.inputEvents == 0, binding.valueWrites == 0,
                      let saved = binding.selectedFrame, let token = binding.selectedToken,
                      binding.finalSelectedFrame == saved, binding.finalSelectedToken == token else {
                    throw SliderPickupReadError.rejected("Read phase requires a sealed current target binding")
                }
                let commands = FBSimulatorAccessibilityCommands(simulator: simulator)
                let app = try await commands.accessibilityElementForFrontmostApplication(displayID: observation.axDisplayID, displayContext: observation.displayContext)
                root = app
                let generic = try readGeneric(app, pid: pid, selectorKind: selectorKind, selectorValue: selectorValue,
                    prefix: "current-native-AXP", includeValues: true, check: check, mark: mark)
                guard generic.token == token, SliderPickupReadRect(generic.frame) == saved,
                      generic.target.accessibilityIdentifier() == binding.actualIdentifier,
                      try attributeValues(generic.values) == attributeValues(binding.genericAttributes) else {
                    throw SliderPickupReadError.rejected("Fresh AXP target differs from sealed binding")
                }
                let translator = unsafeBitCast(AXPTranslator.sharedInstance() as AnyObject, to: AXPTranslator.self)
                func current() throws {
                    try check()
                    guard translator.frontmostApplication(withDisplayId: observation.axDisplayID,
                        bridgeDelegateToken: generic.bridge)?.pid == pid else {
                        throw SliderPickupReadError.rejected("Frontmost PID changed during native read")
                    }
                }
                try current()
                let window = try SliderPickupReadNative.window(generic.target)
                result.actualIdentifier = binding.actualIdentifier
                result.selectedFrame = saved; result.selectedToken = token
                result.nativeToken = token; result.nativeAXRole = generic.target.accessibilityRole()?.rawValue
                result.windowContextID = window; result.genericAttributes = generic.values
                if phase == "geometry" {
                    result.attributes = try SliderPickupRawAttributes.read(simulator: simulator, target: generic.target,
                        frame: generic.frame, deadline: deadline, check: current)
                } else {
                    guard binding.point == result.point, binding.nativePoint == result.nativePoint,
                          let expectedHit = binding.pointToken, let expectedFrame = binding.pointFrame,
                          let translation = translator.object(at: nativePoint, displayId: observation.axDisplayID,
                              bridgeDelegateToken: generic.bridge), translation.pid == pid else {
                        throw SliderPickupReadError.rejected("Fresh native point unavailable")
                    }
                    translation.bridgeDelegateToken = generic.bridge
                    guard let hit = translator.macPlatformElement(fromTranslation: translation) as? AXPMacPlatformElement else {
                        throw SliderPickupReadError.rejected("Fresh native point object unavailable")
                    }
                    guard try simulatorToken(hit, pid: pid) == expectedHit,
                          SliderPickupReadRect(hit.accessibilityFrame()) == expectedFrame,
                          hit.accessibilityRole()?.rawValue == binding.pointRole,
                          hit.isEqual(generic.target) == binding.pointElementEqualsTarget else {
                        throw SliderPickupReadError.rejected("Fresh native point differs from sealed point")
                    }
                    result.pointToken = expectedHit; result.pointFrame = expectedFrame
                    result.pointRole = binding.pointRole; result.pointElementEqualsTarget = binding.pointElementEqualsTarget
                    result.pointKind = binding.pointKind
                    if binding.pointKind == "directSlider" {
                        guard expectedHit == token, expectedFrame == saved, hit.isEqual(generic.target),
                              hit.accessibilityRole()?.rawValue == NSAccessibility.Role.slider.rawValue,
                              try SliderPickupReadNative.window(hit) == window else {
                            throw SliderPickupReadError.rejected("Native direct Slider identity/window differs")
                        }
                        result.directSliderVerified = true
                    } else {
                        guard binding.pointKind == "distinctGroup", expectedHit != token,
                              hit.accessibilityRole()?.rawValue == NSAccessibility.Role.group.rawValue else {
                            throw SliderPickupReadError.rejected("Native parent read requires a distinct Group")
                        }
                        result.parentWalk = try readAXPParents(hit: hit, selected: generic.target, bridge: generic.bridge,
                            expectedHit: expectedHit, hitFrame: expectedFrame, point: point, pid: pid,
                            selectedToken: token, selectedFrame: generic.frame, display: observation.axDisplayID,
                            window: window, check: current)
                        result.parentVerified = result.parentWalk?.state == "matchedExactSliderNativeToken"
                    }
                }
                try current()
                let final = try readGeneric(app, pid: pid, selectorKind: selectorKind, selectorValue: selectorValue,
                    prefix: "final-native-AXP", includeValues: true, check: check, mark: mark)
                guard final.token == token, final.frame == generic.frame,
                      try attributeValues(final.values) == attributeValues(generic.values),
                      try SliderPickupReadNative.window(final.target) == window else {
                    throw SliderPickupReadError.rejected("Native target/frame/value/window changed during phase")
                }
                result.finalSelectedFrame = SliderPickupReadRect(final.frame); result.finalSelectedToken = final.token
                result.finalNativeToken = final.token
                app.close(); root = nil; result.initialRootClosed = true; result.axpOwnerClosed = true
            }
            try check(); try mark("before-final-context")
            let after = try await reader.read(); result.finalContext = after
            guard try after.observation.sessionObservation() == observation else { throw SliderPickupReadError.rejected("Context changed during phase") }
            try check(); result.verifiedAfterRead = true
            switch phase {
            case "target": result.status = "TARGET_PHASE_COMPLETE"
            case "geometry": result.status = "GEOMETRY_PHASE_COMPLETE"
            case "point": result.status = "POINT_PHASE_COMPLETE"
            default: result.status = result.directSliderVerified ? "NATIVE_DIRECT_SLIDER_PHASE_COMPLETE_MATCHED" : (result.parentVerified ? "NATIVE_PARENT_PHASE_COMPLETE_MATCHED" : "NATIVE_PARENT_PHASE_COMPLETE_UNKNOWN")
            }
            result.phase = "complete"
        } catch { result.error = String(describing: error) }
        if let handle = root { handle.close(); result.initialRootClosed = true; root = nil }
        if result.initialRootClosed { result.axpOwnerClosed = true }
        let finished = ProcessInfo.processInfo.systemUptime
        result.finishedUptime = finished
        result.elapsedSeconds = finished - result.startedUptime
        let withinBudget = result.remainingBudgetSeconds.map { budget in
            finished >= result.startedUptime && finished - result.startedUptime <= budget
        } ?? false
        if !withinBudget { result.error = result.error ?? "Local relative read budget expired" }
        let complete = result.verifiedAfterRead && result.error == nil && withinBudget &&
            result.axpOwnerClosed
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

    /// Fresh AXP parent reads prove the exact selected native token; no SDK object is synthesized.
    @MainActor private static func readAXPParents(hit: AXPMacPlatformElement, selected: AXPMacPlatformElement,
        bridge: String, expectedHit: SliderPickupReadToken, hitFrame: SliderPickupReadRect, point: CGPoint,
        pid: Int32, selectedToken: SliderPickupReadToken, selectedFrame: CGRect, display: UInt32,
        window: UInt64, check: () throws -> Void) throws -> SliderPickupParentWalk {
        var current: AXPMacPlatformElement? = hit
        var kept: [AXPMacPlatformElement] = [], tokens = Set<SliderPickupReadToken>(), rows: [SliderPickupParentNode] = []
        for index in 0..<12 {
            try check()
            guard let node = current, let translation = node.translation, translation.pid == pid else {
                throw SliderPickupReadError.rejected("Native AXP parent unavailable or foreign")
            }
            translation.bridgeDelegateToken = bridge
            guard let token = try simulatorToken(node, pid: pid), tokens.insert(token).inserted,
                  !kept.contains(where: { $0.isEqual(node) }) else { throw SliderPickupReadError.rejected("Native AXP parent identity missing or cyclic") }
            kept.append(node)
            let frame = node.accessibilityFrame(), equalsSelected = node.isEqual(selected)
            guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
                  frame.width > 0, frame.height > 0, frame.contains(point),
                  try SliderPickupReadNative.window(node) == window else {
                throw SliderPickupReadError.rejected("Native AXP parent frame/window differs")
            }
            if index == 0, token != expectedHit || SliderPickupReadRect(frame) != hitFrame {
                throw SliderPickupReadError.rejected("Native AXP hit binding differs")
            }
            rows.append(SliderPickupParentNode(token: token, identifier: node.accessibilityIdentifier(),
                frame: SliderPickupReadRect(frame), displayID: display, windowContextID: window, equalsSelectedTarget: equalsSelected))
            if token == selectedToken || equalsSelected {
                guard index > 0, token == selectedToken, equalsSelected, frame == selectedFrame,
                      node.accessibilityIdentifier() == selected.accessibilityIdentifier() else {
                    throw SliderPickupReadError.rejected("Native AXP parent conflicts with exact selected Slider")
                }
                withExtendedLifetime(kept) {}
                return SliderPickupParentWalk(state: "matchedExactSliderNativeToken", reason: "Fresh selected-display AXP Group reaches exact Slider token/window", nodes: rows)
            }
            current = node.accessibilityParent() as? AXPMacPlatformElement
        }
        throw SliderPickupReadError.rejected("Native AXP parent depth exceeds bound")
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
