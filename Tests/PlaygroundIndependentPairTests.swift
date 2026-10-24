import Foundation
import Testing

enum PlaygroundIndependentPairVariant: String, Sendable { case asymmetric, stationaryFirst, bounds, coincidentStart, crossing, batch }

@Suite("Playground Independent Two Finger Paths E2E", .serialized, .enabled(if: isE2EEnabled))
struct PlaygroundIndependentPairTests {
    @Test("Each finger follows its own path with distinct contact identity", arguments: [
        PlaygroundIndependentPairVariant.asymmetric, .stationaryFirst, .bounds, .coincidentStart, .crossing, .batch,
    ])
    func twoFingerPaths(_ variant: PlaygroundIndependentPairVariant) async throws {
        let session = try await PlaygroundAgentFeatureSession.open(caseName: "independent-pair-" + variant.rawValue,
            position: isDuoPlaygroundE2EEnabled ? .inner270 : .outer0)
        try await session.show("feature.showPad")
        let state = try await session.core.state()
        let frame = try session.core.frame(of: session.core.element("feature.pad", in: state))
        try #require(frame.width > 180 && frame.height > 80)
        let cx = frame.x + frame.width / 2
        let cy = frame.y + frame.height / 2
        let a = (x: cx - 50, y: cy - 15)
        var b = (x: cx + 45, y: cy + 15)
        var endA = (x: cx - 30, y: cy + 15)
        var endB = (x: cx + 65, y: cy - 15)
        switch variant {
        case .stationaryFirst: endA = a
        case .bounds: endA.x = 10000
        case .coincidentStart: b = a
        case .crossing: endA = b; endB = a
        default: break
        }
        var arguments = ["gesture", "two-finger-swipe", "-x", String(a.x), "-y", String(a.y),
            "--x2", String(b.x), "--y2", String(b.y), "--end-x", String(endA.x), "--end-y", String(endA.y),
            "--end-x2", String(endB.x), "--end-y2", String(endB.y), "--duration", "0.7", "--delta", "2"]
        if variant == .batch { arguments = ["batch", "--step", arguments.joined(separator: " ")] + session.selectedFlags }
        else { arguments += session.selectedFlags }
        let before = try session.document.read()
        let rejected = ![.asymmetric, .stationaryFirst].contains(variant)
        let output = try await session.command(arguments, allowFailure: rejected)
        if variant == .batch {
            try session.requireRefusal(output, before: before, message: "Two-finger-swipe is not supported in batch steps")
        } else if rejected {
            try #require(output.exitCode != 0)
            let receipt = try session.rawReceipt(output.output)
            try #require(receipt.outcome == "failedNoReplay" && receipt.enqueuedEventCount == 0
                && receipt.cleanup == "notNeeded" && receipt.quarantine == nil)
            try #require(receipt.error?.contains(variant == .bounds ? "pointOutsideDisplay" : "coincidentContacts") == true)
            let after = try session.document.read()
            try #require(after.inputState == before.inputState)
        } else {
            try #require(output.exitCode == 0)
            let receipt = try session.rawReceipt(output.output)
            try receipt.requireCompleted()
            let after = try await session.document.waitFor("both independent contacts ended") { $0.activeWindowTouches == 0 }
            let groups = try session.contacts(after: before, in: after, count: 2).sorted { ($0.first?.x ?? 0) < ($1.first?.x ?? 0) }
            for (index, rows) in groups.enumerated() {
                let first = try #require(rows.first)
                let last = try #require(rows.last)
                let start = index == 0 ? a : b
                let end = index == 0 ? endA : endB
                try #require(hypot(first.x - start.x, first.y - start.y) <= 2 && hypot(last.x - end.x, last.y - end.y) <= 2)
                if variant == .stationaryFirst && index == 0 {
                    try #require(rows.allSatisfy { hypot($0.x - start.x, $0.y - start.y) <= 2 })
                } else { try #require(rows.contains { $0.phase == "windowTouchMoved" && hypot($0.x - first.x, $0.y - first.y) > 2 }) }
            }
            try #require(after.text == before.text && after.slider == before.slider && after.switchOn == before.switchOn)
        }
    }
}
