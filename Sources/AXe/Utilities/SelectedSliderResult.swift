import Foundation
import FBSimulatorControl

/// A fixed public scalar receipt. Raw AX attributes and tree labels are not part of this schema.
/// The controller is bounded to 20 actions and 23 samples. This keeps output capacity
/// independent of later application-supplied AX strings before the first action.
struct SelectedSliderResult: Codable, Sendable {
    enum ElementType: String, Codable, Sendable { case slider = "Slider" }
    struct Sample: Codable, Sendable {
        let phase: String
        let elapsedSeconds: Double
        let snapshotID: UUID
        let elementType: ElementType?
        let minimum: Double?
        let maximum: Double?
        let tolerance: Double?
        let value: Double?
        init(_ source: FBSimulatorSliderSample) {
            phase = source.phase; elapsedSeconds = source.elapsedSeconds
            snapshotID = source.capabilities.snapshotID
            elementType = source.capabilities.node.type.flatMap(ElementType.init(rawValue:))
            let domain = try? source.capabilities.requireDomain()
            minimum = domain?.minimum; maximum = domain?.maximum; tolerance = domain?.tolerance
            value = try? source.capabilities.requireValue()
        }
    }
    struct Action: Codable, Sendable {
        let action: FBSimulatorSliderAction
        let valueBeforeAction: Double?
        let elementType: ElementType?
        let callStartedUptime: Double
        let callReturnedUptime: Double
        let guestAcknowledged: Bool
        init(_ source: FBSimulatorSliderActionReceipt) {
            action = source.action; valueBeforeAction = try? source.verifiedBeforeAction.requireValue()
            elementType = source.verifiedBeforeAction.node.type.flatMap(ElementType.init(rawValue:))
            callStartedUptime = source.callStartedUptime; callReturnedUptime = source.callReturnedUptime
            guestAcknowledged = source.guestAcknowledged
        }
    }
    let outcome: String
    let reason: String?
    let reasonTruncated: Bool
    let delivery: String
    let endpoint: FBSimulatorSliderEndpoint
    let actionAttempts: Int
    let actionsReturned: Int
    let startedUptime: Double
    let deadlineUptime: Double
    let elapsedSeconds: Double
    let samples: [Sample]
    let actions: [Action]
    let physicalGeometry = "unknown"
    init(_ source: FBSimulatorSliderEndpointReceipt) {
        outcome = source.outcome; delivery = source.delivery; endpoint = source.endpoint
        reason = source.reason.map { String($0.prefix(1024)) }
        reasonTruncated = (source.reason?.count ?? 0) > 1024
        actionAttempts = source.actionAttempts; actionsReturned = source.actionsReturned
        startedUptime = source.startedUptime; deadlineUptime = source.deadlineUptime
        elapsedSeconds = source.elapsedSeconds
        samples = source.samples.map(Sample.init); actions = source.actionReceipts.map(Action.init)
    }

    static func validateCapacity(result: SelectedAXResult, context: SelectedHIDContext) throws {
        // A scalar sample/action encodes to less than 2 KiB: fixed keys, UUID,
        // bounded phase (at most 16 ASCII bytes), native type (Slider), finite IEEE numbers and booleans.
        // Reserve 8 KiB for scalar receipt fields and the bounded diagnostic reason.
        let fixed = try JSONEncoder().encode(result).count + JSONEncoder().encode(context).count
        guard fixed <= 64 * 1024,
              fixed + 23 * 2048 + 20 * 2048 + 8192 <= SelectedAXBounds.contentBytes else {
            throw SelectedHIDFailure.invalid("Selected slider receipt capacity is unavailable; no action")
        }
    }
}
