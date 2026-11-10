import Foundation

extension TestHelpers {
    /// A fresh app keeps loading its accessibility runtime for a few seconds after the first
    /// read. On iOS 27.2 the tree still changes then (scroll bars fill in, the navigation bar
    /// moves in the child order) and the app handles touches late, which breaks feedback input
    /// such as a slider value. Settled means two reads, 500 ms apart, describe the same tree.
    static func waitForSettledAccessibility(simulatorUDID: String, description: String,
                                            timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var previous: NSObject?
        var lastObserved = "No raw app state was read."
        repeat {
            do {
                let output = try await runAxeCommand("describe-ui", simulatorUDID: simulatorUDID).output
                lastObserved = output
                let json = output.firstIndex(where: { $0 == "[" || $0 == "{" }).map { output[$0...] } ?? ""
                // Parsed objects compare by content and child order; the raw text does not keep
                // a stable key order.
                let current = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSObject
                if let current, let previous, current.isEqual(previous) { return }
                previous = current
            } catch {
                previous = nil
                lastObserved = String(describing: error)
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        } while Date() < deadline
        throw TestError.unexpectedState("Timed out waiting for a settled accessibility tree on \(description).\n\(lastObserved)")
    }
}
