import AppKit
import CryptoKit
import Darwin
import Foundation
import FBSimulatorControl

/// One owned six-phase pickup. Each short-lived read process closes its native owners.
/// Raw scrubber coordinates select a search point only; exact native identity admits DOWN.
@MainActor
final class SliderPickupHelper {
    private struct Prepared {
        let initial: FBSimulatorSliderCapabilities
        let target: SliderPickupReadEvidence
        let point: SliderPickupReadEvidence
        let window: UInt64
        let centre: CGPoint
    }
    private let observation: FBSimulatorHIDSessionObservation
    private let live: FBSimulatorHIDNativeFreshnessProvider
    private let selectorKind: SelectedAXRequest.SelectorKind
    private let selectorValue: String
    private let expectedPID: Int32
    private let deadline: Double
    private let readID = UUID()
    private let child = SliderPickupReadChild()
    private var directory: URL?
    private var prepared: Prepared?
    private(set) var readPhases = 0
    private(set) var pickup = CGPoint.zero

    init(observation: FBSimulatorHIDSessionObservation, live: FBSimulatorHIDNativeFreshnessProvider,
         selectorKind: SelectedAXRequest.SelectorKind, selectorValue: String,
         expectedPID: Int32, deadline: Double) {
        self.observation = observation; self.live = live
        self.selectorKind = selectorKind; self.selectorValue = selectorValue
        self.expectedPID = expectedPID; self.deadline = deadline
    }

    private func check() throws {
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw SliderValueFailure.rejected("Slider value action deadline expired")
        }
        try live.validateCurrentRevision(expected: observation)
    }

    private func workingDirectory() throws -> URL {
        if let directory { return directory }
        var template = Array(FileManager.default.temporaryDirectory
            .appendingPathComponent("axe-slider-XXXXXX").path.utf8CString)
        guard let created = mkdtemp(&template) else {
            throw SliderValueFailure.rejected("Cannot create a private Slider read directory")
        }
        let value = URL(fileURLWithPath: String(cString: created), isDirectory: true)
        directory = value
        return value
    }

    private func readPhase(_ phase: String, point: CGPoint, binding: URL? = nil) async throws
        -> (SliderPickupReadEvidence, URL) {
        try check()
        guard readPhases < 6, let executable = Bundle.main.executableURL else {
            throw SliderValueFailure.rejected("Slider pickup read limit or executable is unavailable")
        }
        let directory = try workingDirectory()
        readPhases += 1
        let name = String(format: "read-%02d-%@", readPhases, phase)
        let file = directory.appendingPathComponent(name + ".json")
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        var arguments = ["slider-read-worker", "--phase", phase, "--read-id", readID.uuidString,
            "--remaining-budget-seconds", String(remaining), "--udid", observation.simulatorUDID,
            "--boot", observation.bootIdentity, "--screen-id", String(observation.screenID),
            "--screen-uuid", observation.screenUniqueID, "--pid", String(expectedPID),
            "--selector-kind", selectorKind.rawValue, "--selector-value", selectorValue,
            "--point-x", String(Double(point.x)), "--point-y", String(Double(point.y)),
            "--out", file.path]
        if let binding {
            let bytes = try Data(contentsOf: binding)
            guard bytes.count <= 1_048_576 else { throw SliderValueFailure.rejected("Slider binding exceeds its bound") }
            arguments += ["--binding", binding.path, "--binding-sha256",
                SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()]
        }
        let bytes = try await child.run(executable: executable, arguments: arguments,
            directory: directory, name: name, environment: ProcessInfo.processInfo.environment, deadline: deadline)
        let saved = try Data(contentsOf: file)
        guard saved.count <= 1_048_576 else { throw SliderValueFailure.rejected("Slider read exceeds its bound") }
        let result = try JSONDecoder().decode(SliderPickupReadEvidence.self, from: bytes)
        let disk = try JSONDecoder().decode(SliderPickupReadEvidence.self, from: saved)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard try encoder.encode(result) == encoder.encode(disk), result.sealed,
              result.verifiedAfterRead, result.error == nil, result.source == "axeSliderPickupReadV1",
              result.readID == readID.uuidString, result.readPhase == phase,
              result.expectedPID == expectedPID, result.selectorKind == selectorKind.rawValue,
              result.selectorValue == selectorValue, result.simulatorUDID == observation.simulatorUDID,
              result.inputEvents == 0, result.valueWrites == 0,
              let first = result.context, let last = result.finalContext,
              try first.observation.sessionObservation() == observation,
              try last.observation.sessionObservation() == observation,
              let elapsed = result.elapsedSeconds, elapsed >= 0, elapsed <= remaining,
              result.remainingBudgetSeconds == remaining else {
            throw SliderValueFailure.rejected("Slider read did not return a complete current zero-input result")
        }
        try check()
        return (result, file)
    }

    private func requireIdentity(_ value: SliderPickupReadEvidence, as expected: SliderPickupReadEvidence) throws {
        guard value.selectedToken == expected.selectedToken, value.selectedFrame == expected.selectedFrame,
              value.actualIdentifier == expected.actualIdentifier,
              value.genericAttributes.map({ $0.rawJSON }) == expected.genericAttributes.map({ $0.rawJSON }),
              value.finalSelectedToken == value.selectedToken, value.finalSelectedFrame == value.selectedFrame else {
            throw SliderValueFailure.rejected("Slider token, frame or value/domain changed during pickup")
        }
    }

    func prepare(before: FBSimulatorSliderCapabilities) async throws
        -> (pickup: CGPoint, minimum: CGPoint, maximum: CGPoint, hitFrame: CGRect) {
        let (target, targetFile) = try await readPhase("target", point: .zero)
        guard target.status == "TARGET_PHASE_COMPLETE", target.initialRootClosed,
              let selectedFrame = target.selectedFrame, let token = target.selectedToken,
              token.pid == expectedPID, target.actualIdentifier == before.node.identifier,
              before.node.frame == CGRect(x: selectedFrame.x, y: selectedFrame.y,
                  width: selectedFrame.width, height: selectedFrame.height) else {
            throw SliderValueFailure.rejected("Pickup target differs from the native Slider")
        }
        func number(_ name: String) throws -> Double {
            guard let attribute = target.genericAttributes.first(where: { $0.name == name }),
                  attribute.state == "returned", let json = attribute.rawJSON,
                  let fields = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: NSNumber],
                  let value = fields["value"]?.doubleValue, value.isFinite else {
                throw SliderValueFailure.rejected("Slider value/domain is unavailable")
            }
            return value
        }
        let domain = try before.requireDomain()
        // The child's values cross a JSON round trip, which can return a nearby double: 0.0009009009227156639
        // comes back as 0.0009009009227156636. Equal means equal within a few units in the last place.
        func same(_ value: Double, _ native: Double) -> Bool {
            value == native || abs(value - native) <= max(abs(value), abs(native)) * 1e-12
        }
        guard same(try number("AXValue"), try before.requireValue()), same(try number("AXMinValue"), domain.minimum),
              same(try number("AXMaxValue"), domain.maximum) else {
            throw SliderValueFailure.rejected("Native and pickup target values differ")
        }
        let (geometry, _) = try await readPhase("geometry", point: .zero, binding: targetFile)
        try requireIdentity(geometry, as: target)
        guard geometry.status == "GEOMETRY_PHASE_COMPLETE", geometry.axpOwnerClosed,
              geometry.nativeAXRole == NSAccessibility.Role.slider.rawValue, geometry.nativeToken == token,
              let window = geometry.windowContextID, window > 0 else {
            throw SliderValueFailure.rejected("Scrubber geometry lacks an independent native Slider")
        }
        func rawValue(_ symbol: String) throws -> NSObject {
            guard let attribute = geometry.attributes.first(where: { $0.symbol == symbol }),
                  attribute.state == "returned", let json = attribute.rawJSON,
                  let fields = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: NSObject],
                  let value = fields["value"] else { throw SliderValueFailure.rejected("Raw scrubber geometry is unavailable") }
            return value
        }
        func rawPoint(_ symbol: String) throws -> CGPoint {
            guard let fields = try rawValue(symbol) as? [String: NSNumber],
                  let x = fields["X"]?.doubleValue, let y = fields["Y"]?.doubleValue,
                  x.isFinite, y.isFinite else { throw SliderValueFailure.rejected("Raw scrubber point has an unsupported representation") }
            return CGPoint(x: x, y: y)
        }
        guard let fraction = try rawValue("kAXXCAttributeAbsoluteValue") as? NSNumber,
              fraction.doubleValue.isFinite, (0...1).contains(fraction.doubleValue) else {
            throw SliderValueFailure.rejected("Raw value cannot form a bounded search candidate")
        }
        let minimum = try rawPoint("kAXXCAttributeMinScrubberPosition")
        let maximum = try rawPoint("kAXXCAttributeMaxScrubberPosition")
        let raw = CGPoint(x: minimum.x + (maximum.x - minimum.x) * CGFloat(fraction.doubleValue),
            y: minimum.y + (maximum.y - minimum.y) * CGFloat(fraction.doubleValue))
        guard let frame = before.node.frame, minimum.x < maximum.x, minimum.y == maximum.y,
              [raw.x, raw.y, minimum.x, maximum.x].allSatisfy({ $0.isFinite }),
              minimum.x >= frame.minX, maximum.x <= frame.maxX,
              minimum.y >= frame.minY, minimum.y < frame.maxY else {
            throw SliderValueFailure.rejected("Slider value input requires contained horizontal scrubber geometry")
        }
        // A raw endpoint may equal maxX, which is outside CGRect's half-open bounds. Clamp to the
        // first and last native pixels inside the frame: the owned path snaps every point to that
        // pixel grid, so a half-pixel candidate next to maxX would round onto maxX itself.
        // The candidate is only a search point. It never admits DOWN.
        let scale = CGFloat(observation.displayContext.scale)
        guard scale.isFinite, scale > 0 else { throw SliderValueFailure.rejected("Display pixel scale is invalid") }
        let low = ceil(frame.minX * scale) / scale
        let high = (ceil(frame.maxX * scale) - 1) / scale
        guard scale.isFinite, scale > 0, low <= high else { throw SliderValueFailure.rejected("Slider has no contained pixel search point") }
        let candidate = CGPoint(x: min(max(raw.x, low), high), y: raw.y)
        guard frame.contains(candidate) else { throw SliderValueFailure.rejected("Scrubber search candidate is outside the Slider") }
        let (point, pointFile) = try await readPhase("point", point: candidate)
        try requireIdentity(point, as: target)
        let (parent, _) = try await readPhase("native", point: candidate, binding: pointFile)
        try requireIdentity(parent, as: target)
        guard point.status == "POINT_PHASE_COMPLETE", point.initialRootClosed, parent.axpOwnerClosed,
              parent.windowContextID == window, parent.nativeToken == token,
              parent.pointToken == point.pointToken, parent.pointFrame == point.pointFrame,
              let hit = point.pointFrame else { throw SliderValueFailure.rejected("Search point has no exact native Slider proof") }
        let hitFrame = CGRect(x: hit.x, y: hit.y, width: hit.width, height: hit.height)
        let centre: CGPoint
        if point.pointKind == "directSlider" {
            guard parent.status == "NATIVE_DIRECT_SLIDER_PHASE_COMPLETE_MATCHED", parent.directSliderVerified,
                  !parent.parentVerified, point.pointToken == token, point.pointFrame == target.selectedFrame else {
                throw SliderValueFailure.rejected("Direct Slider point proof differs")
            }
            // Preserve the admitted search point; a full Slider frame has no thumb-centre meaning.
            centre = candidate
        } else {
            guard point.pointKind == "distinctGroup", parent.status == "NATIVE_PARENT_PHASE_COMPLETE_MATCHED",
                  parent.parentVerified, !parent.directSliderVerified else { throw SliderValueFailure.rejected("Group parent proof unavailable") }
            centre = CGPoint(x: hitFrame.midX, y: hitFrame.midY)
        }
        guard frame.contains(hitFrame), hitFrame.contains(centre), frame.contains(centre) else {
            throw SliderValueFailure.rejected("Admitted native hit has no contained pickup point")
        }
        prepared = Prepared(initial: before, target: target, point: point, window: window, centre: centre)
        pickup = centre
        return (centre, minimum, maximum, hitFrame)
    }

    func confirm(backend: FBSimulatorSliderBackend) async throws {
        guard let prepared, readPhases == 4, prepared.centre == pickup else {
            throw SliderValueFailure.rejected("Prepared Slider pickup is unavailable or changed")
        }
        try check()
        let current = try await backend.read(deadline: deadline)
        try current.requireSameTarget(as: prepared.initial, includeValue: true)
        guard current.node.enabled == true, current.node.hidden == false,
              try current.observation.sessionObservation() == observation else {
            throw SliderValueFailure.rejected("Current native Slider is unavailable inside the input guard")
        }
        let (point, pointFile) = try await readPhase("point", point: pickup)
        try requireIdentity(point, as: prepared.target)
        let (parent, _) = try await readPhase("native", point: pickup, binding: pointFile)
        try requireIdentity(parent, as: prepared.target)
        guard point.status == "POINT_PHASE_COMPLETE", point.initialRootClosed,
              point.pointToken == prepared.point.pointToken, point.pointFrame == prepared.point.pointFrame,
              point.pointKind == prepared.point.pointKind,
              parent.axpOwnerClosed, parent.windowContextID == prepared.window,
              (prepared.point.pointKind == "directSlider"
                ? parent.status == "NATIVE_DIRECT_SLIDER_PHASE_COMPLETE_MATCHED" && parent.directSliderVerified && !parent.parentVerified
                : parent.status == "NATIVE_PARENT_PHASE_COMPLETE_MATCHED" && parent.parentVerified && !parent.directSliderVerified),
              parent.pointToken == prepared.point.pointToken, parent.pointFrame == prepared.point.pointFrame else {
            throw SliderValueFailure.rejected("Pickup point and exact native parent did not repeat inside the input guard")
        }
        try check()
        guard readPhases == 6, deadline - ProcessInfo.processInfo.systemUptime > 3 else {
            throw SliderValueFailure.rejected("Slider pickup has no release/readback reserve")
        }
        self.prepared = nil
    }

    func close() async -> Bool {
        guard await child.close() else { return false }
        guard let directory else { return true }
        do {
            try FileManager.default.removeItem(at: directory)
            self.directory = nil
            return true
        } catch { return false }
    }
}
