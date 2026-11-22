import Foundation
// Shared with the AXe Mirror app: this file is compiled into the Mac's `axe` and into the viewer.

/// Decisions the viewer app makes that need no device to judge, kept here so that the Mac's tests
/// cover them: the app has no tests of its own.
enum MirrorViewerRules {
    /// Whether a list of simulators from the Mac takes the screen.
    ///
    /// A list can arrive after a simulator has been opened: the answer to a refresh, or to shutting
    /// another simulator down, asked for a moment before. The Mac is still showing the simulator
    /// then, and going back to the list would hide it. So a list takes the screen only when this
    /// device is choosing, when no simulator is shown, or when the Mac has let its simulator go
    /// (`expected`): on a new connection, or because another device took it away.
    static func listTakesScreen(choosing: Bool, expected: Bool, showingSimulator: Bool) -> Bool {
        choosing || expected || !showingSimulator
    }

    /// What to say when none of the names that should lead back to this device reached its own
    /// server. A certificate that is not trusted yet is the usual reason and needs no saying: the
    /// steps are on the screen. When instead none of the names could be found or connected to, the
    /// network is not leading them back to this device, as some company and hotel networks do
    /// not, and no amount of trusting helps.
    static func setupHint(for failures: [URLError.Code]) -> String? {
        let network: Set<URLError.Code> = [.cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .timedOut, .notConnectedToInternet, .networkConnectionLost]
        guard !failures.isEmpty, failures.allSatisfy(network.contains) else { return nil }
        return "This network is in the way: it does not lead back to this device. Try another Wi-Fi, or mobile data."
    }

    /// The round trip and the clock offset one pong gives, or nil for a pong to drop. The Mac
    /// echoes the time this device sent (`sent`) and adds its own (`hostTime`). Numbers that are
    /// not numbers, or a round trip no connection has, are dropped: turned into whole
    /// milliseconds for the figures on screen, one of them stopped the app.
    static func clockSample(sent: Double, hostTime: Double, received: Double) -> (roundTrip: Double, offset: Double)? {
        guard sent.isFinite, hostTime.isFinite, received.isFinite, (0...60).contains(received - sent) else { return nil }
        return (received - sent, hostTime - (sent + received) / 2)
    }

    /// Removes the builds this device has kept in `folder`, all but those whose IDs are in
    /// `keeping`. Each install left its build in the caches folder for good; iOS empties that
    /// folder only when the device is short of room. Returns how many went.
    @discardableResult
    static func tidyBuilds(keeping: Set<String>, in folder: URL) -> Int {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return 0 }
        var removed = 0
        for file in files where file.pathExtension == "ipa" && file.lastPathComponent.hasPrefix("build-") {
            let id = String(file.deletingPathExtension().lastPathComponent.dropFirst("build-".count))
            if !keeping.contains(id), (try? FileManager.default.removeItem(at: file)) != nil { removed += 1 }
        }
        return removed
    }

    /// Whether a caller of the app's own build server is the device itself: its address is a
    /// loopback one, 127.x.x.x or ::1, as text, with or without an interface after a "%". Anything
    /// else, and no address at all, is somebody else.
    static func isThisDevice(_ address: String?) -> Bool {
        guard var address = address?.lowercased(), !address.isEmpty else { return false }
        if let scope = address.firstIndex(of: "%") { address = String(address[..<scope]) }
        if address.hasPrefix("::ffff:") { address = String(address.dropFirst("::ffff:".count)) }     // an IPv4 caller on an IPv6 socket
        if address == "::1" { return true }
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil } && parts[0] == "127"
    }

    /// How long the app waits for the Mac to say it has started on a choice, in seconds. The Mac
    /// first reads its list of simulators and allows itself `macListSeconds` for that before it
    /// says the Mac was slow: the app must wait longer, so that the Mac's own word comes first.
    static let choiceAnswerSeconds: UInt64 = 35
    static let macListSeconds: Double = 30
}
