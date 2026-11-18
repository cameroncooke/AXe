import Darwin
import Foundation

/// One viewer this Mac has been paired with. `id` is the viewer's iroh endpoint ID, the public half
/// of a key that never leaves the viewer; iroh proves it on every connection, so a viewer cannot
/// claim an ID that is not its own.
struct MirrorViewer: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var paired: Date
}

/// The list of paired viewers, kept in a file beside the host key and readable by the user alone.
///
/// The host reads the file again for every incoming connection, so a viewer paired or removed by
/// another `axe mirror` command takes effect at once, without restarting the host. Changes are made
/// under a lock file and written by replacing the file, so a reader never sees half a list and two
/// commands changing it at the same moment do not lose each other's change.
struct MirrorViewers: Sendable {
    let url: URL

    static var defaultURL: URL { MirrorIdentity.keyURL.deletingLastPathComponent().appendingPathComponent("viewers.json") }

    init(url: URL = MirrorViewers.defaultURL) { self.url = url }

    private struct File: Codable {
        var version = 1
        var viewers: [MirrorViewer]
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    /// The paired viewers, oldest first. A missing file is an empty list; a file that cannot be read
    /// as a list is an error, so that a damaged file never silently lets everyone in or out.
    func all() throws -> [MirrorViewer] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            return try Self.decoder.decode(File.self, from: Data(contentsOf: url)).viewers
        } catch {
            throw CLIError(errorDescription: "The list of paired viewers at \(url.path) cannot be read: \(error.localizedDescription)", code: .readFailed)
        }
    }

    /// Whether this viewer may connect. A list that cannot be read allows nobody.
    func allows(_ id: String) -> Bool {
        ((try? all()) ?? []).contains { $0.id == id }
    }

    /// Adds a viewer, or renames it and refreshes its date if it is already paired.
    @discardableResult
    func add(id: String, name: String, now: Date = Date()) throws -> MirrorViewer {
        let viewer = MirrorViewer(id: id, name: Self.clean(name), paired: now)
        try change { viewers in
            viewers.removeAll { $0.id == id }
            viewers.append(viewer)
        }
        return viewer
    }

    /// Removes the viewers matching `text`: a whole ID, the start of an ID (at least 6 characters), or
    /// a name, ignoring case. Returns what was removed. More than one match by name or prefix is an
    /// error, so a slip cannot remove several devices.
    func remove(matching text: String) throws -> [MirrorViewer] {
        let wanted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var removed: [MirrorViewer] = []
        try change { viewers in
            var matches = viewers.filter { $0.id == wanted }
            if matches.isEmpty {
                matches = viewers.filter { (wanted.count >= 6 && $0.id.hasPrefix(wanted.lowercased())) || $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
                guard matches.count <= 1 else {
                    throw CLIError(errorDescription: "\"\(wanted)\" matches \(matches.count) paired viewers. Use the ID shown by axe mirror viewers.", code: .commandFailed)
                }
            }
            removed = matches
            viewers.removeAll { viewer in matches.contains { $0.id == viewer.id } }
        }
        return removed
    }

    /// A name as it will be stored and shown: one line, no control characters, at most 60 characters.
    static func clean(_ name: String) -> String {
        let line = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) }
        let trimmed = String(String.UnicodeScalarView(line)).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Unnamed viewer" : String(trimmed.prefix(60))
    }

    private func change(_ edit: (inout [MirrorViewer]) throws -> Void) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = open(url.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX) == 0 else {
            if lock >= 0 { close(lock) }
            throw CLIError(errorDescription: "Could not lock the list of paired viewers at \(url.path).", code: .outputFailed)
        }
        defer { flock(lock, LOCK_UN); close(lock) }
        var viewers = try all()
        try edit(&viewers)
        let data = try Self.encoder.encode(File(viewers: viewers))
        // Written to a private file first and moved into place, so the list is never readable by
        // others and never half written.
        let temporary = url.path + ".new"
        unlink(temporary)
        let descriptor = open(temporary, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw CLIError(errorDescription: "Could not write the list of paired viewers to \(url.path).", code: .outputFailed)
        }
        let written = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        fsync(descriptor)
        close(descriptor)
        guard written == data.count, rename(temporary, url.path) == 0 else {
            unlink(temporary)
            throw CLIError(errorDescription: "Could not write the list of paired viewers to \(url.path).", code: .outputFailed)
        }
    }
}
