import Foundation
import Security
import Testing
@testable import AXe

/// App builds the host offers a viewer to install on its own device.
@Suite("Mirror: builds to install")
struct MirrorBuildsTests {
    private func metadata(_ changes: [String: Any?] = [:]) -> Data {
        var fields: [String: Any] = [
            "build_id": "76b42eb3", "bundle_id": "com.example.app", "name": "Example", "version": "1.2", "build_number": "7",
            "minimum_os": "17.5", "published_at": "2026-11-21T13:56:52.352649Z", "expires_at": "2027-10-28T09:14:13Z",
            "size_bytes": 8_712_176, "notes": "Fixes things.", "sha256": String(repeating: "b", count: 64),
        ]
        for (key, value) in changes { fields[key] = value }
        return try! JSONSerialization.data(withJSONObject: fields.compactMapValues { $0 })
    }

    @Test("A build is read from its metadata.json")
    func reads() throws {
        let build = try #require(MirrorBuildCatalogue.build(from: metadata(), fallbackID: "folder"))
        #expect(build.id == "76b42eb3" && build.name == "Example" && build.bundleID == "com.example.app")
        #expect(build.versionText == "1.2 (7)" && build.size == 8_712_176 && build.notes == "Fixes things." && build.minimumOS == "17.5")
        #expect(build.sha256 == String(repeating: "b", count: 64))
        // Times with and without fractions of a second.
        #expect(abs((build.published ?? 0) - 1795269412.35) < 0.01)
        #expect(build.expires == MirrorBuildCatalogue.seconds(of: "2027-10-28T09:14:13Z"))
        #expect(!build.isExpired(at: Date(timeIntervalSince1970: 1795269412)))
        #expect(build.isExpired(at: Date(timeIntervalSince1970: (build.expires ?? 0) + 1)))
    }

    @Test("Without a build ID the folder's name stands in, and without a name the bundle ID")
    func bare() throws {
        let bare = try #require(MirrorBuildCatalogue.build(from: metadata(["build_id": nil, "name": nil, "build_number": nil]), fallbackID: "folder"))
        #expect(bare.id == "folder" && bare.name == "com.example.app" && bare.versionText == "1.2")
    }

    @Test("The link iOS installs from carries the manifest's address, escaped")
    func link() {
        #expect(MirrorBuild.installURL(manifest: "https://local.axe-cli.com:50123/b/a b/manifest.plist?x=1&y=2")
                == "itms-services://?action=download-manifest&url=https%3A%2F%2Flocal.axe-cli.com%3A50123%2Fb%2Fa%20b%2Fmanifest.plist%3Fx%3D1%26y%3D2")
    }

    @Test("A file that is not a build's description is passed over")
    func notABuild() {
        #expect(MirrorBuildCatalogue.build(from: Data("not json".utf8), fallbackID: "x") == nil)
        #expect(MirrorBuildCatalogue.build(from: metadata(["bundle_id": nil]), fallbackID: "x") == nil)
        // Release notes are sent whole; something far longer is cut.
        let notes = MirrorBuildCatalogue.build(from: metadata(["notes": String(repeating: "x", count: 900)]), fallbackID: "x")
        #expect(notes?.notes?.count == 900)
        let long = MirrorBuildCatalogue.build(from: metadata(["notes": String(repeating: "x", count: 9000)]), fallbackID: "x")
        #expect(long?.notes?.count == 4001)
    }

    @Test("A store's builds are offered newest first: only whole ones, in their place, not expired")
    func folder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axe-builds-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ path: String, _ data: Data) throws {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        func build(_ folder: String, _ changes: [String: Any?], package: Bool = true) throws {
            try write(folder + "/metadata.json", metadata(changes))
            if package { try write(folder + "/app.ipa", Data([1, 2, 3])) }
        }
        try build("com.example.app/old", ["build_id": "old", "published_at": "2026-11-20T10:00:00Z"])
        try build("com.example.app/new", ["build_id": "new", "published_at": "2026-11-21T10:00:00Z"])
        try build("com.example.app/expired", ["build_id": "expired", "expires_at": "2026-01-01T00:00:00Z"])
        // Described, with no file to send: nothing a viewer could install.
        try build("com.example.app/empty", ["build_id": "empty"], package: false)
        // Not where the store would have put it: under another name, another app, or deeper.
        try build("com.example.app/renamed", ["build_id": "moved"])
        try build("com.other.app/stray", ["build_id": "stray"])
        try build("a/com.example.app/deep", ["build_id": "deep"])
        try write("com.example.app/other/notes.json", metadata(["build_id": "other"]))
        let builds = MirrorBuildCatalogue(folder: root).read(now: Date(timeIntervalSince1970: 1795269412))
        #expect(builds.map(\.id) == ["new", "old"])
        #expect(MirrorBuildCatalogue(folder: root.appendingPathComponent("missing")).read().isEmpty)
    }

    @Test("The list survives the trip to the viewer")
    func wire() throws {
        let build = try #require(MirrorBuildCatalogue.build(from: metadata(), fallbackID: "x"))
        let sent = try JSONEncoder().encode(MirrorBuildList(builds: [build]))
        #expect(try JSONDecoder().decode(MirrorBuildList.self, from: sent).builds == [build])
        #expect(MirrorMessage.builds == 47 && MirrorMessage.listBuilds == 48 && MirrorMessage.installing == 49)
    }

    // MARK: AXe's own store

    private let buildID = "0123456789abcdef0123456789abcdef"

    /// A store holding one build of `com.example.app`, put there as `publish` leaves it.
    private func store(expires: String = "2099-01-01T00:00:00Z", package: Data = Data((0..<1000).map { UInt8($0 % 251) })) throws -> MirrorBuildStore {
        let store = MirrorBuildStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("axe-store-\(UUID().uuidString)"))
        let folder = store.folder(bundleID: "com.example.app", buildID: buildID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let build = MirrorPublishedBuild(buildID: buildID, bundleID: "com.example.app", name: "Example", version: "1.2", buildNumber: "7", minimumOS: "17.5",
                                         expiresAt: expires, deviceCount: 3, publishedAt: "2026-11-21T10:00:00.000Z", sha256: String(repeating: "a", count: 64), sizeBytes: package.count, notes: "Fixes things.")
        try JSONEncoder().encode(build).write(to: folder.appendingPathComponent("metadata.json"))
        try package.write(to: folder.appendingPathComponent("app.ipa"))
        return store
    }

    @Test("The store lists whole builds and finds one by its place; a name that is not an ID finds nothing")
    func storeLists() throws {
        let store = try store()
        defer { try? FileManager.default.removeItem(at: store.root) }
        #expect(store.list().map(\.versionText) == ["1.2 (7)"])
        #expect(store.build(bundleID: "com.example.app", buildID: buildID)?.name == "Example")
        #expect(store.build(bundleID: "com.example.app", buildID: "../../etc") == nil)
        #expect(store.build(bundleID: "../other", buildID: buildID) == nil)
        try FileManager.default.removeItem(at: store.folder(bundleID: "com.example.app", buildID: buildID).appendingPathComponent("app.ipa"))
        #expect(store.list().isEmpty)
    }

    @Test("A build is removed by the start of its ID, and only when that names one build")
    func storeRemoves() throws {
        let store = try store()
        defer { try? FileManager.default.removeItem(at: store.root) }
        #expect(throws: CLIError.self) { try store.remove(matching: "ffff") }
        #expect(throws: CLIError.self) { try store.remove(matching: "") }
        #expect(try store.remove(matching: "0123").map(\.buildID) == [buildID])
        #expect(store.list().isEmpty)
    }

    /// A store with three builds of one app and one of another, oldest to newest by the letter.
    private func stocked() throws -> (store: MirrorBuildStore, ids: [String: String]) {
        let store = MirrorBuildStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("axe-store-\(UUID().uuidString)"))
        var ids: [String: String] = [:]
        for (index, (name, bundle)) in [("a", "com.example.app"), ("b", "com.example.app"), ("c", "com.example.app"), ("z", "com.example.other")].enumerated() {
            let id = String(repeating: String(index + 1), count: 32)
            ids[name] = id
            let folder = store.folder(bundleID: bundle, buildID: id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let build = MirrorPublishedBuild(buildID: id, bundleID: bundle, name: name, version: "1.0", buildNumber: String(index + 1), minimumOS: "17.5",
                                             expiresAt: "2099-01-01T00:00:00Z", deviceCount: 2, publishedAt: "2026-11-2\(index)T10:00:00.000Z",
                                             sha256: String(repeating: "a", count: 64), sizeBytes: 3, notes: "first", devices: ["AAAA", "BBBB"])
            try JSONEncoder().encode(build).write(to: folder.appendingPathComponent("metadata.json"))
            try Data([1, 2, 3]).write(to: folder.appendingPathComponent("app.ipa"))
        }
        return (store, ids)
    }

    @Test("Several builds are removed at once, and none when one of the IDs is wrong")
    func removesSeveral() throws {
        let (store, ids) = try stocked()
        defer { try? FileManager.default.removeItem(at: store.root) }
        #expect(throws: CLIError.self) { try store.remove(matching: [ids["a"]!, "ffff"]) }
        #expect(store.list().count == 4)
        #expect(try store.remove(matching: [ids["a"]!, String(ids["z"]!.prefix(6)), ids["a"]!]).map(\.name) == ["a", "z"])
        #expect(store.list().map(\.name) == ["c", "b"])
    }

    @Test("Keeping the newest builds keeps that many of each app")
    func keepsNewest() throws {
        let (store, _) = try stocked()
        defer { try? FileManager.default.removeItem(at: store.root) }
        #expect(throws: CLIError.self) { try store.keep(newest: 0) }
        #expect(try store.keep(newest: 2).map(\.name) == ["a"])
        #expect(store.list().map(\.name) == ["z", "c", "b"])
        #expect(try store.keep(newest: 1).map(\.name) == ["b"])
        #expect(try store.keep(newest: 5).isEmpty)
    }

    @Test("A build's notes can be corrected, and nothing else about it changes")
    func editsNotes() throws {
        let (store, ids) = try stocked()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let before = try #require(store.build(bundleID: "com.example.app", buildID: ids["b"]!))
        #expect(try store.setNotes("Second thoughts.\nTwo lines.", matching: String(ids["b"]!.prefix(8))).notes == "Second thoughts.\nTwo lines.")
        var after = try #require(store.build(bundleID: "com.example.app", buildID: ids["b"]!))
        #expect(after.notes == "Second thoughts.\nTwo lines.")
        after.notes = before.notes
        #expect(after == before)
        #expect(throws: CLIError.self) { try store.setNotes("x", matching: "ffff") }
    }

    @Test("What building left behind is counted and cleared, old folders alone when a date is given")
    func cleans() throws {
        let (store, _) = try stocked()
        defer { try? FileManager.default.removeItem(at: store.root) }
        #expect(store.leftovers().count == 0 && store.clean().count == 0)
        for (name, age) in [("old", -5.0 * 86_400), ("new", -60.0)] {
            let folder = store.jobs.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("App.xcarchive"), withIntermediateDirectories: true)
            try Data(count: 20_000).write(to: folder.appendingPathComponent("App.xcarchive/binary"))
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(age)], ofItemAtPath: folder.path)
        }
        #expect(store.leftovers().count == 2 && store.leftovers().bytes >= 40_000)
        let aged = store.clean(olderThan: Date().addingTimeInterval(-MirrorBuildJob.keepFailedFor))
        #expect(aged.count == 1 && aged.bytes >= 20_000)
        #expect(FileManager.default.fileExists(atPath: store.jobs.appendingPathComponent("new").path))
        #expect(store.clean().count == 1 && store.leftovers().count == 0)
        // The builds themselves are untouched.
        #expect(store.list().count == 4)
    }

    @Test("An archive kept on purpose outlives later builds' tidying, and a job still running is never removed")
    func keepsWhatWasAskedFor() throws {
        let (store, _) = try stocked()
        defer { try? FileManager.default.removeItem(at: store.root) }
        func job(_ name: String, marker: String? = nil, holding text: String = "") throws {
            let folder = store.jobs.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("App.xcarchive"), withIntermediateDirectories: true)
            try Data(count: 20_000).write(to: folder.appendingPathComponent("App.xcarchive/binary"))
            if let marker { try text.write(to: folder.appendingPathComponent(marker), atomically: true, encoding: .utf8) }
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-5 * 86_400)], ofItemAtPath: folder.path)
        }
        func there(_ name: String) -> Bool { FileManager.default.fileExists(atPath: store.jobs.appendingPathComponent(name).path) }
        try job("failed")
        try job("kept", marker: ".kept")
        try job("running", marker: ".running", holding: String(getpid()))
        try job("crashed", marker: ".running", holding: "999999")       // its process is gone
        // What every later `axe mirror build` does: five-day-old failures go, the kept archive stays.
        let tidied = store.clean(olderThan: Date().addingTimeInterval(-MirrorBuildJob.keepFailedFor))
        #expect(tidied.count == 2 && !there("failed") && !there("crashed"))
        #expect(there("kept") && there("running"))
        // A job being made is not something left behind.
        #expect(store.leftovers().count == 1)
        // `axe mirror builds --clean` removes the kept archive, and still not the job that is running.
        #expect(store.clean().count == 1 && !there("kept") && there("running"))
    }

    @Test("This Mac's devices are read from devicectl's listing, without simulators, and matched to a build by name")
    func knownDevices() throws {
        let listing = Data(#"""
        {"result":{"devices":[
          {"hardwareProperties":{"reality":"physical","udid":"00008160-AAAA"},"deviceProperties":{"name":"Sam's iPhone"}},
          {"hardwareProperties":{"reality":"simulated","udid":"1111-2222"},"deviceProperties":{"name":"iPhone 17"}},
          {"hardwareProperties":{"udid":"00008103-bbbb"},"deviceProperties":{"name":"An iPad"}},
          {"hardwareProperties":{"reality":"physical"},"deviceProperties":{"name":"No identifier"}}
        ]}}
        """#.utf8)
        let known = MirrorKnownDevices.parse(listing)
        #expect(known.map(\.name) == ["An iPad", "Sam's iPhone"])
        let coverage = MirrorKnownDevices.coverage(of: ["00008103-BBBB", "0000-OTHER"], among: known)
        #expect(coverage.covered == ["An iPad"] && coverage.notCovered == ["Sam's iPhone"])
        #expect(MirrorKnownDevices.parse(Data("nonsense".utf8)).isEmpty)
    }

    @Test("A file that is not a signed device app is refused with the reason")
    func inspects() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("axe-ipa-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let notZip = scratch.appendingPathComponent("not.ipa")
        try Data("hello".utf8).write(to: notZip)
        #expect(throws: CLIError.self) { try MirrorBuildInspector.inspect(ipa: notZip) }
        #expect(throws: CLIError.self) { try MirrorBuildInspector.inspect(ipa: scratch.appendingPathComponent("missing.ipa")) }
        #expect(MirrorBuildInspector.isBundleID("com.example.app") && !MirrorBuildInspector.isBundleID("../etc") && !MirrorBuildInspector.isBundleID(""))
        #expect(MirrorBuildStore.isBuildID("0123456789abcdef0123456789abcdef") && !MirrorBuildStore.isBuildID("0123"))
    }

    // MARK: Installing from the viewer's own device

    @Test("A piece of a build survives the trip: its ID, its place and its bytes")
    func pieces() throws {
        let piece = MirrorBuildPiece(id: buildID, offset: 5_000_000_000, bytes: Data([1, 2, 3, 255]))
        #expect(MirrorBuildPiece(piece.encoded) == piece)
        #expect(MirrorBuildPiece(MirrorBuildPiece(id: "a", offset: 0, bytes: Data()).encoded)?.bytes.isEmpty == true)
        #expect(MirrorBuildPiece(Data()) == nil)
        #expect(MirrorBuildPiece(Data([40, 1, 2])) == nil)
        #expect(MirrorMessage.installIdentityRequest == 50 && MirrorMessage.installIdentity == 51 && MirrorMessage.fetchBuild == 52
                && MirrorMessage.buildPiece == 53 && MirrorMessage.fetchFailed == 54)
    }

    @Test("A published build is offered with the digest the viewer checks what it fetched against")
    func offered() throws {
        let store = try store()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let offered = MirrorBuildCatalogue(folder: store.root).read()
        #expect(offered.count == 1 && offered.first?.id == buildID && offered.first?.sha256 == String(repeating: "a", count: 64))
        // How many devices it is signed for goes to the app; which ones stays on the Mac.
        #expect(offered.first?.devices == 3)
        #expect(!String(decoding: try JSONEncoder().encode(offered), as: UTF8.self).contains("udid"))
    }

    @Test("The host makes one certificate for the names that point at the device, and keeps it")
    func identity() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("axe-identity-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MirrorInstallIdentityStore(folder: folder)
        let made = try store.load(macName: "Test Mac; rm -rf")
        #expect(made.names == MirrorInstallIdentity.loopbackNames && made.authorityName == "AXe Mirror installs from Test Mac rm -rf")
        #expect(made.expires > Date().timeIntervalSince1970 + 800 * 86_400)
        // Kept: asked again, it is the same one, so a viewer set up once stays set up.
        #expect(try store.load() == made)
        // The authority is a certificate that may sign, and the identity opens with its password to one that names the device.
        let authority = try #require(SecCertificateCreateWithData(nil, made.authority as CFData))
        #expect((SecCertificateCopySubjectSummary(authority) as String?) == "AXe Mirror installs from Test Mac rm -rf")
        var items: CFArray?
        #expect(SecPKCS12Import(made.identity as CFData, [kSecImportExportPassphrase as String: made.password] as CFDictionary, &items) == errSecSuccess)
        let first = try #require((items as? [[String: Any]])?.first)
        let chain = try #require(first[kSecImportItemCertChain as String] as? [SecCertificate])
        #expect((SecCertificateCopySubjectSummary(chain[0]) as String?) == "local.axe-cli.com")
        // Only the two files a viewer needs are kept: nothing that could sign anything else.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["identity.json"])
        // One nearly expired is made again.
        #expect(try store.load(now: Date(timeIntervalSince1970: made.expires - 86_400)) != made)
    }
}
