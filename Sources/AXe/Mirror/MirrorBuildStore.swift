#if AXE_MIRROR
import CryptoKit
import Foundation

/// What an IPA says about itself, once it has been checked: see `MirrorBuildInspector`.
struct MirrorBuildInspection: Equatable, Sendable {
    var bundleID: String
    var name: String
    var version: String
    var build: String
    var minimumOS: String
    var expires: Date
    /// The devices every profile in the package allows.
    var devices: Set<String>
}

/// Checks that an IPA is one iOS will install over the air on a registered device: a device app,
/// signed for Ad Hoc distribution, whose profiles have not expired and allow the signing certificate
/// and the bundle. A build that fails here would be offered to a viewer and then refused by iOS
/// with no reason given, so it is refused here, with the reason.
enum MirrorBuildInspector {
    static let largestPackage: Int64 = 4 * 1024 * 1024 * 1024

    static func inspect(ipa: URL, requiredDevices: [String] = []) throws -> MirrorBuildInspection {
        let size = (try? FileManager.default.attributesOfItem(atPath: ipa.path)[.size] as? NSNumber)?.int64Value
        guard let size, size > 0 else { throw refused("There is no IPA at \(ipa.path).") }
        guard size <= largestPackage else { throw refused("The IPA is larger than 4 GB.") }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("axe-build-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let package = scratch.appendingPathComponent("package", isDirectory: true)
        try unpack(ipa, into: package)

        let payload = package.appendingPathComponent("Payload", isDirectory: true)
        let apps = ((try? FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "app" }
        guard apps.count == 1, let app = apps.first else { throw refused("The IPA must hold exactly one app in its Payload folder.") }
        let info = try plist(at: app.appendingPathComponent("Info.plist"))
        guard (info["CFBundleSupportedPlatforms"] as? [String])?.contains("iPhoneOS") == true else {
            throw refused("The IPA is not a build for iPhone or iPad devices. A simulator build cannot be installed on a device.")
        }
        _ = try tool("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], saying: "The app's signature is not valid.")

        // The app and everything signed inside it: extensions and embedded apps.
        var bundles = [app]
        if let walker = FileManager.default.enumerator(at: app, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let item as URL in walker where ["appex", "app"].contains(item.pathExtension) {
                if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { bundles.append(item) }
            }
        }
        var devices: Set<String>?
        var expires: Date?
        for bundle in bundles {
            let profile = try self.profile(of: bundle, info: bundle == app ? info : plist(at: bundle.appendingPathComponent("Info.plist")), scratch: scratch)
            devices = devices.map { $0.intersection(profile.devices) } ?? profile.devices
            expires = expires.map { min($0, profile.expires) } ?? profile.expires
        }
        guard let devices, !devices.isEmpty, let expires else { throw refused("The app's profiles have no registered device in common.") }
        let missing = Set(requiredDevices).subtracting(devices)
        guard missing.isEmpty else {
            throw refused("\(missing.count == 1 ? "A required device is" : "\(missing.count) required devices are") not in the app's provisioning profile. Register the device and build again.")
        }
        func text(_ key: String) -> String { (info[key] as? String) ?? "" }
        let bundleID = text("CFBundleIdentifier")
        let name = [text("CFBundleDisplayName"), text("CFBundleName"), bundleID].first { !$0.isEmpty } ?? bundleID
        let inspection = MirrorBuildInspection(bundleID: bundleID, name: name, version: text("CFBundleShortVersionString"), build: text("CFBundleVersion"),
                                               minimumOS: text("MinimumOSVersion"), expires: expires, devices: devices)
        guard !inspection.version.isEmpty, !inspection.build.isEmpty, !inspection.minimumOS.isEmpty else {
            throw refused("The app has no version, build number or minimum iOS version.")
        }
        return inspection
    }

    /// A bundle ID as iOS allows it; also what keeps one from being a path.
    static func isBundleID(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]{0,254}$"#, options: .regularExpression) != nil
    }

    private static func refused(_ message: String) -> CLIError {
        CLIError(errorDescription: message, code: .invalidArguments)
    }

    /// Unpacks the IPA, refusing one that would write outside the folder or that holds links: an
    /// app bundle for a device has neither.
    private static func unpack(_ ipa: URL, into folder: URL) throws {
        let listing = String(decoding: try tool("/usr/bin/unzip", ["-Z1", ipa.path], saying: "The file is not an IPA."), as: UTF8.self)
        let names = listing.split(separator: "\n", omittingEmptySubsequences: true)
        guard !names.isEmpty, names.count <= 50_000 else { throw refused("The IPA has no files, or too many.") }
        for name in names {
            let parts = name.split(separator: "/", omittingEmptySubsequences: false).dropLast(name.hasSuffix("/") ? 1 : 0)
            guard !name.hasPrefix("/"), !name.contains("\\"), !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                throw refused("The IPA holds a file with an unsafe path.")
            }
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try tool("/usr/bin/unzip", ["-q", "-o", ipa.path, "-d", folder.path], saying: "The IPA could not be unpacked.")
        if let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let item as URL in walker where (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw refused("The IPA holds a symbolic link.")
            }
        }
    }

    private static func plist(at file: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: file),
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw refused("\(file.lastPathComponent) in the app cannot be read.")
        }
        return value
    }

    /// One signed bundle's profile, checked against the bundle: Ad Hoc, not expired, for this
    /// bundle ID and team, and allowing the certificate the bundle was signed with.
    private static func profile(of bundle: URL, info: [String: Any], scratch: URL) throws -> (devices: Set<String>, expires: Date) {
        let embedded = bundle.appendingPathComponent("embedded.mobileprovision")
        guard FileManager.default.fileExists(atPath: embedded.path) else {
            throw refused("\(bundle.lastPathComponent) has no provisioning profile. Export the app for Ad Hoc (Release Testing) distribution.")
        }
        let decoded = try tool("/usr/bin/security", ["cms", "-D", "-i", embedded.path], saying: "The provisioning profile cannot be read.")
        guard let profile = try? PropertyListSerialization.propertyList(from: decoded, format: nil) as? [String: Any],
              let entitlements = profile["Entitlements"] as? [String: Any], let expires = profile["ExpirationDate"] as? Date,
              let certificates = profile["DeveloperCertificates"] as? [Data], !certificates.isEmpty else {
            throw refused("The provisioning profile is not a valid Ad Hoc profile.")
        }
        guard let devices = profile["ProvisionedDevices"] as? [String], !devices.isEmpty, profile["ProvisionsAllDevices"] as? Bool != true,
              entitlements["get-task-allow"] as? Bool == false else {
            throw refused("The app is not signed for Ad Hoc (Release Testing) distribution. A development or App Store build cannot be installed this way.")
        }
        guard expires > Date() else { throw refused("The app's provisioning profile has expired.") }
        guard let identifier = info["CFBundleIdentifier"] as? String, isBundleID(identifier) else {
            throw refused("\(bundle.lastPathComponent) has no valid bundle identifier.")
        }
        let allowed = (profile["ApplicationIdentifierPrefix"] as? [String] ?? []).map { $0 + "." + identifier }
        let granted = entitlements["application-identifier"] as? String ?? ""
        let matches = granted.hasSuffix(".*") ? allowed.contains { $0.hasPrefix(granted.dropLast()) } : allowed.contains(granted)
        guard matches else { throw refused("The provisioning profile is not for \(identifier).") }

        let signedData = try tool("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", bundle.path], saying: "The app's signed entitlements cannot be read.")
        guard let signed = try? PropertyListSerialization.propertyList(from: signedData, format: nil) as? [String: Any] else {
            throw refused("The app's signed entitlements cannot be read.")
        }
        guard let signedID = signed["application-identifier"] as? String, allowed.contains(signedID) else {
            throw refused("The app was signed for another bundle identifier than its profile's.")
        }
        guard signed["get-task-allow"] as? Bool != true else { throw refused("The app is signed for debugging. Export it for Ad Hoc (Release Testing) distribution.") }
        guard let team = signed["com.apple.developer.team-identifier"] as? String, (profile["TeamIdentifier"] as? [String] ?? []).contains(team) else {
            throw refused("The app was signed by another team than its profile's.")
        }
        let prefix = scratch.appendingPathComponent(UUID().uuidString + "-cert-").path
        _ = try tool("/usr/bin/codesign", ["-d", "--extract-certificates=" + prefix, bundle.path], saying: "The app's signing certificate cannot be read.")
        guard let leaf = try? Data(contentsOf: URL(fileURLWithPath: prefix + "0")), certificates.contains(leaf) else {
            throw refused("The app was signed with a certificate its profile does not allow.")
        }
        return (Set(devices), expires)
    }

    /// Runs one of the system's signing tools. Its own words are not passed on: they can hold
    /// device and signing details, and `saying` is what the person needs.
    private static func tool(_ path: String, _ arguments: [String], saying: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw CLIError(errorDescription: "\(path) could not be run: \(error.localizedDescription)", code: .commandFailed) }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw refused(saying) }
        return data
    }
}

/// A build in AXe's store, as its `metadata.json` describes it.
struct MirrorPublishedBuild: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var buildID: String
    var bundleID: String
    var name: String
    var version: String
    var buildNumber: String
    var minimumOS: String
    var expiresAt: String
    var deviceCount: Int
    var publishedAt: String
    var sha256: String
    var sizeBytes: Int
    var notes: String
    /// The identifiers of the devices the build is signed for. Kept in the store, on this Mac, to
    /// say by name which devices can install it; never printed. Nil for a build published before
    /// they were kept.
    var devices: [String]?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", buildID = "build_id", bundleID = "bundle_id", name, version
        case buildNumber = "build_number", minimumOS = "minimum_os", expiresAt = "expires_at", deviceCount = "device_count"
        case publishedAt = "published_at", sha256, sizeBytes = "size_bytes", notes, devices
    }

    var versionText: String { "\(version) (\(buildNumber))" }
}

/// The builds AXe keeps for its viewers to install: one folder for each, `<bundle ID>/<build ID>`,
/// holding `app.ipa` and `metadata.json`. `axe mirror publish` and `axe mirror build` put builds
/// here, and a host offers them (`MirrorBuildCatalogue`) and sends one to a viewer that asks for
/// it. A build's app is never changed once it is here: publishing again makes another. Its notes
/// can be corrected.
///
/// `.jobs` beside the builds holds what `axe mirror build` needed to make one: an Xcode archive of
/// some hundreds of megabytes, and logs. A build that succeeds removes its own; one that fails
/// leaves it to be read, and it is removed a few days later or by `clean()`. One kept on purpose
/// (`--keep-archive`) is marked, and only `clean()` asked for by name removes it. A job that is
/// still running is never removed.
struct MirrorBuildStore: Equatable, Sendable {
    let root: URL

    static var standard: MirrorBuildStore {
        MirrorBuildStore(root: MirrorIdentity.keyURL.deletingLastPathComponent().appendingPathComponent("builds", isDirectory: true))
    }

    static func isBuildID(_ text: String) -> Bool {
        text.range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression) != nil
    }

    func folder(bundleID: String, buildID: String) -> URL {
        root.appendingPathComponent(bundleID, isDirectory: true).appendingPathComponent(buildID, isDirectory: true)
    }

    /// Checks an IPA and adds it to the store. The file is copied first and the copy is what is
    /// checked, so what is published is exactly what was checked, whatever happens to the original.
    func publish(ipa: URL, notes: String = "", requiredDevices: [String] = [], now: Date = Date()) throws -> MirrorPublishedBuild {
        let buildID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let staging = root.appendingPathComponent(".staging", isDirectory: true).appendingPathComponent(buildID, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        let staged = staging.appendingPathComponent("app.ipa")
        let (digest, size) = try Self.copy(ipa, to: staged)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: staged.path)
        let inspection = try MirrorBuildInspector.inspect(ipa: staged, requiredDevices: requiredDevices)
        let times = ISO8601DateFormatter()
        times.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let build = MirrorPublishedBuild(buildID: buildID, bundleID: inspection.bundleID, name: inspection.name, version: inspection.version,
                                         buildNumber: inspection.build, minimumOS: inspection.minimumOS, expiresAt: times.string(from: inspection.expires),
                                         deviceCount: inspection.devices.count, publishedAt: times.string(from: now), sha256: digest, sizeBytes: size, notes: notes,
                                         devices: inspection.devices.sorted())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(build).write(to: staging.appendingPathComponent("metadata.json"))
        let destination = folder(bundleID: build.bundleID, buildID: buildID)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.moveItem(at: staging, to: destination)
        return build
    }

    /// Every complete build in the store, newest first.
    func list() -> [MirrorPublishedBuild] {
        var found: [MirrorPublishedBuild] = []
        for app in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] {
            guard MirrorBuildInspector.isBundleID(app.lastPathComponent) else { continue }
            for folder in (try? FileManager.default.contentsOfDirectory(at: app, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] {
                if let build = build(bundleID: app.lastPathComponent, buildID: folder.lastPathComponent) { found.append(build) }
            }
        }
        return found.sorted { ($0.publishedAt, $0.buildID) > ($1.publishedAt, $1.buildID) }
    }

    /// One build, if the store holds it whole: its description names this folder and its IPA is there.
    func build(bundleID: String, buildID: String) -> MirrorPublishedBuild? {
        guard MirrorBuildInspector.isBundleID(bundleID), Self.isBuildID(buildID) else { return nil }
        let folder = folder(bundleID: bundleID, buildID: buildID)
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("metadata.json")),
              let build = try? JSONDecoder().decode(MirrorPublishedBuild.self, from: data),
              build.bundleID == bundleID, build.buildID == buildID,
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("app.ipa").path) else { return nil }
        return build
    }

    /// The one build whose ID is `text` or starts with it.
    func find(matching text: String) throws -> MirrorPublishedBuild {
        let wanted = list().filter { $0.buildID.hasPrefix(text.lowercased()) }
        guard !text.isEmpty, wanted.count == 1, let build = wanted.first else {
            throw CLIError(errorDescription: wanted.isEmpty ? "No build's ID starts with \"\(text)\". Run axe mirror builds to see them." : "\(wanted.count) builds' IDs start with \"\(text)\". Give more of the ID.", code: .invalidArguments)
        }
        return build
    }

    /// Removes builds, each by its ID or the first characters of it. Every one is found before any
    /// is removed, so a mistyped ID removes nothing. Returns the ones removed.
    func remove(matching texts: [String]) throws -> [MirrorPublishedBuild] {
        var wanted: [MirrorPublishedBuild] = []
        for text in texts {
            let build = try find(matching: text)
            if !wanted.contains(build) { wanted.append(build) }
        }
        for build in wanted { try delete(build) }
        return wanted
    }

    func remove(matching text: String) throws -> [MirrorPublishedBuild] { try remove(matching: [text]) }

    /// Keeps the newest `count` builds of each app and removes the rest. Returns the ones removed.
    func keep(newest count: Int) throws -> [MirrorPublishedBuild] {
        guard count >= 1 else { throw CLIError(errorDescription: "--keep takes a number of builds, 1 or more.", code: .invalidArguments) }
        var seen: [String: Int] = [:]
        var removed: [MirrorPublishedBuild] = []
        for build in list() {       // newest first
            seen[build.bundleID, default: 0] += 1
            if seen[build.bundleID, default: 0] > count { removed.append(build) }
        }
        for build in removed { try delete(build) }
        return removed
    }

    /// Replaces a build's notes. Nothing else about it changes: the app is the one that was checked.
    func setNotes(_ notes: String, matching text: String) throws -> MirrorPublishedBuild {
        var build = try find(matching: text)
        build.notes = notes
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(build).write(to: folder(bundleID: build.bundleID, buildID: build.buildID).appendingPathComponent("metadata.json"), options: .atomic)
        return build
    }

    private func delete(_ build: MirrorPublishedBuild) throws {
        let folder = folder(bundleID: build.bundleID, buildID: build.buildID)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: folder.appendingPathComponent("app.ipa").path)
        try FileManager.default.removeItem(at: folder)
    }

    // MARK: What building leaves behind

    var jobs: URL { root.appendingPathComponent(".jobs", isDirectory: true) }

    /// The folders builds were made in that are still here, and how much room they take.
    func leftovers() -> (count: Int, bytes: Int64) {
        let folders = ((try? FileManager.default.contentsOfDirectory(at: jobs, includingPropertiesForKeys: nil)) ?? []).filter { !Self.isRunning(job: $0) }
        return (folders.count, folders.reduce(0) { $0 + Self.size(of: $1) })
    }

    /// The file in a job's folder that says its archive was kept on purpose.
    static let keptMarker = ".kept"
    /// The file in a job's folder that holds the ID of the process making the build.
    static let runningMarker = ".running"

    /// Whether the process that is making this job's build is still there.
    static func isRunning(job folder: URL) -> Bool {
        guard let text = try? String(contentsOf: folder.appendingPathComponent(runningMarker), encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// Removes the folders builds were made in. With a `date`, which is how each new build tidies
    /// up after old failures, only those last touched before it and not kept on purpose. Without,
    /// which is `axe mirror builds --clean`, the kept ones too. A job that is still running is
    /// left alone either way. Returns how many went and how much room that gave back.
    @discardableResult
    func clean(olderThan date: Date? = nil) -> (count: Int, bytes: Int64) {
        var count = 0
        var bytes: Int64 = 0
        for folder in (try? FileManager.default.contentsOfDirectory(at: jobs, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if Self.isRunning(job: folder) { continue }
            if let date {
                if FileManager.default.fileExists(atPath: folder.appendingPathComponent(Self.keptMarker).path) { continue }
                if let touched = try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, touched >= date { continue }
            }
            let size = Self.size(of: folder)
            if (try? FileManager.default.removeItem(at: folder)) != nil {
                count += 1
                bytes += size
            }
        }
        return (count, bytes)
    }

    private static func size(of folder: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    /// Copies a file a megabyte at a time, hashing it as it goes.
    private static func copy(_ source: URL, to destination: URL) throws -> (sha256: String, size: Int) {
        guard let input = try? FileHandle(forReadingFrom: source) else {
            throw CLIError(errorDescription: "There is no IPA at \(source.path).", code: .invalidArguments)
        }
        defer { try? input.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var hash = SHA256()
        var size = 0
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            size += chunk.count
            guard Int64(size) <= MirrorBuildInspector.largestPackage else {
                throw CLIError(errorDescription: "The IPA is larger than 4 GB.", code: .invalidArguments)
            }
            hash.update(data: chunk)
            try output.write(contentsOf: chunk)
        }
        try output.synchronize()
        return (hash.finalize().map { String(format: "%02x", $0) }.joined(), size)
    }
}
#endif
