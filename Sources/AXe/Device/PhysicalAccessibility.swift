import Foundation
import FBSimulatorControl

struct PhysicalAccessibilitySnapshot: Sendable {
    let json: Data
    let roots: [AccessibilityElement]
    let display: PhysicalDeviceDisplay
}

struct PhysicalSemanticPressReceipt: Codable, Sendable {
    let identifier: String
    let stateBefore: Bool
    let stateAfter: Bool
    let readbackCount: Int
    let outcome: String
    let delivery: String
}

enum PhysicalAccessibility {
    /// Upper bound for one tree read: the pushed tree pair plus any live translator lookups. A device takes
    /// about 0.9 s plus 44 ms per element (measured on an iPad Pro: 148 elements in 7.3 s, 188 in 9.1 s), so
    /// this allows about 330 elements; the 6 s it used to be failed every screen above about 115.
    static let readBudget: TimeInterval = 20

    static func projectionEntries(_ archive: PhysicalAXTreeArchive) -> [FBPhysicalAXTreeProjection.Entry] {
        archive.entries.map {
            FBPhysicalAXTreeProjection.Entry(requestType: $0.requestType, pid: $0.pid,
                                             objectID: $0.objectID, attribute: $0.attribute)
        }
    }

    static func project(_ archive: PhysicalAXTreeArchive, display: PhysicalDeviceDisplay,
                        forward: ((FBPhysicalAXTreeProjection.LiveRequest) throws -> Data)? = nil) throws -> PhysicalAccessibilitySnapshot {
        let json: Data
        let roots: [AccessibilityElement]
        do {
            json = try FBPhysicalAXTreeProjection.json(archive: archive.data, entries: projectionEntries(archive),
                                                         forward: forward)
            roots = try JSONDecoder().decode([AccessibilityElement].self, from: json)
        } catch let failure as CLIOutputFailure {
            // A live lookup that timed out or did not match keeps its own code and message.
            throw failure
        } catch {
            try Task.checkCancellation()
            throw Self.unavailable
        }
        guard roots.count == 1, roots[0].pid == archive.rootIdentity?.pid,
              roots[0].children?.isEmpty == false else {
            throw unavailable
        }
        return PhysicalAccessibilitySnapshot(json: json, roots: roots, display: display)
    }

    private static var unavailable: CLIOutputFailure {
        CLIOutputFailure(code: "treeUnavailable",
            message: "AXe could not read a complete accessibility tree. Close any blocking alert on the device and retry.")
    }
}
