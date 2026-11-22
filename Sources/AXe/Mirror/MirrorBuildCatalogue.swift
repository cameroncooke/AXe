#if AXE_MIRROR
import Foundation

/// The builds a host offers its viewers to install: every build in a store laid out as AXe's own
/// is (`MirrorBuildStore`), newest first. `axe mirror publish` and `axe mirror build` put them
/// there.
///
/// A build has no address. The viewer asks for it over the connection it is paired on, the host
/// sends the file in pieces, and the viewer hands it to iOS from the device itself. So only a
/// build whose file is here is offered.
struct MirrorBuildCatalogue: Sendable {
    let folder: URL

    /// The most builds sent to a viewer: the newest ones.
    static let limit = 40

    /// The builds now in the folder whose profiles have not expired. A file that is not a build's
    /// description, or a build that is not where the store would have put it, is passed over.
    func read(now: Date = Date()) -> [MirrorBuild] {
        var found: [MirrorBuild] = []
        func look(in folder: URL, depth: Int) {
            guard let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
            for entry in entries {
                if entry.lastPathComponent == "metadata.json" {
                    guard let data = try? Data(contentsOf: entry), let build = Self.build(from: data, fallbackID: folder.lastPathComponent),
                          FileManager.default.fileExists(atPath: folder.appendingPathComponent("app.ipa").path),
                          folder.lastPathComponent == build.id, folder.deletingLastPathComponent().lastPathComponent == build.bundleID,
                          folder.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == self.folder.standardizedFileURL,
                          !build.isExpired(at: now) else { continue }
                    found.append(build)
                } else if depth > 0, (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    look(in: entry, depth: depth - 1)
                }
            }
        }
        look(in: folder, depth: 2)
        return Array(found.sorted { ($0.published ?? 0, $0.id) > ($1.published ?? 0, $1.id) }.prefix(Self.limit))
    }

    /// One build from its `metadata.json`, or nil when the file does not describe one.
    static func build(from data: Data, fallbackID: String) -> MirrorBuild? {
        guard let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func text(_ key: String) -> String? { (fields[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        guard let bundleID = text("bundle_id"), let version = text("version") else { return nil }
        // The app shows the start of the notes in its list and all of them on the build's own
        // screen. Something far longer than release notes is cut, so the list stays small to send.
        let notes = text("notes").map { $0.count > 4000 ? String($0.prefix(4000)) + "…" : $0 }
        return MirrorBuild(id: text("build_id") ?? fallbackID, name: text("name") ?? bundleID, bundleID: bundleID, version: version,
                           build: text("build_number") ?? "", notes: notes, published: text("published_at").flatMap(seconds(of:)),
                           expires: text("expires_at").flatMap(seconds(of:)), size: fields["size_bytes"] as? Int,
                           minimumOS: text("minimum_os"), sha256: text("sha256"), devices: fields["device_count"] as? Int)
    }

    /// An ISO 8601 time, with or without fractions of a second, as seconds since 1970.
    static func seconds(of time: String) -> Double? {
        let whole = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return (fractional.date(from: time) ?? whole.date(from: time))?.timeIntervalSince1970
    }
}
#endif
