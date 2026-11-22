import Foundation
import Testing
@testable import AXe

@Suite("Mirror paired viewers")
struct MirrorViewersTests {
    private let phone = "41f3777e39562ad9d0770a658bab23851932a83ad682d66ac32f87976357e87c"
    private let tablet = "41f3aa0b9d1c2e3f405162738495a6b7c8d9e0f1a2b3c4d5e6f708192a3b4c5d"

    private func store() -> MirrorViewers {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("axe-mirror-tests-\(UUID().uuidString)")
        return MirrorViewers(url: folder.appendingPathComponent("viewers.json"))
    }

    @Test("With no file nobody is paired and nobody is allowed")
    func emptyByDefault() throws {
        let viewers = store()
        #expect(try viewers.all().isEmpty)
        #expect(!viewers.allows(phone))
    }

    @Test("A paired viewer is allowed and others are not")
    func pairedIsAllowed() throws {
        let viewers = store()
        try viewers.add(id: phone, name: "Test iPhone")
        #expect(viewers.allows(phone))
        #expect(!viewers.allows(tablet))
        #expect(try viewers.all().map(\.name) == ["Test iPhone"])
    }

    @Test("Pairing the same viewer again renames it instead of listing it twice")
    func pairingAgain() throws {
        let viewers = store()
        try viewers.add(id: phone, name: "Old name", now: Date(timeIntervalSince1970: 1_000))
        try viewers.add(id: tablet, name: "Tablet", now: Date(timeIntervalSince1970: 2_000))
        try viewers.add(id: phone, name: "New name", now: Date(timeIntervalSince1970: 3_000))
        let all = try viewers.all()
        #expect(all.map(\.name) == ["Tablet", "New name"])
        #expect(all.last?.paired == Date(timeIntervalSince1970: 3_000))
    }

    @Test("Two devices that give the same name are told apart, and each can be removed by its name")
    func sameName() throws {
        // What iOS lets an app say its device is called: "iPhone", on every iPhone.
        let viewers = store()
        let third = "41f3bb0b9d1c2e3f405162738495a6b7c8d9e0f1a2b3c4d5e6f708192a3b4c5d"
        #expect(try viewers.add(id: phone, name: "iPhone").name == "iPhone")
        #expect(try viewers.add(id: tablet, name: "iPhone").name == "iPhone 2")
        #expect(try viewers.add(id: third, name: "iphone").name == "iphone 3")
        #expect(try viewers.all().map(\.name) == ["iPhone", "iPhone 2", "iphone 3"])
        // Paired again, a device keeps the name it had, not a new number.
        #expect(try viewers.add(id: tablet, name: "iPhone").name == "iPhone 2")
        #expect(try viewers.remove(matching: "iPhone 2").map(\.id) == [tablet])
        #expect(try viewers.remove(matching: "iPhone").map(\.id) == [phone])
    }

    @Test("A second store on the same file sees a change at once, as the running host must")
    func sharedBetweenProcesses() throws {
        let viewers = store(), other = MirrorViewers(url: viewers.url)
        #expect(!other.allows(phone))
        try viewers.add(id: phone, name: "Phone")
        #expect(other.allows(phone))
        #expect(try viewers.remove(matching: phone).count == 1)
        #expect(!other.allows(phone))
    }

    @Test("A viewer is removed by ID, by the start of its ID or by its name")
    func removes() throws {
        for text in [phone, String(phone.prefix(8)), "my iphone"] {
            let viewers = store()
            try viewers.add(id: phone, name: "My iPhone")
            try viewers.add(id: "9" + tablet.dropFirst(), name: "Tablet")
            #expect(try viewers.remove(matching: text).map(\.id) == [phone])
            #expect(try viewers.all().map(\.name) == ["Tablet"])
        }
    }

    @Test("Removing what matches nothing removes nothing; an ID start shorter than six characters matches nothing")
    func removesNothing() throws {
        let viewers = store()
        try viewers.add(id: phone, name: "Phone")
        #expect(try viewers.remove(matching: "someone else").isEmpty)
        #expect(try viewers.remove(matching: String(phone.prefix(5))).isEmpty)
        #expect(viewers.allows(phone))
    }

    @Test("A name or ID start that matches two viewers removes neither")
    func ambiguousRemoval() throws {
        let viewers = store()
        // A list from before same-named devices were told apart: two called "Phone".
        let other = String(phone.prefix(10)) + String(repeating: "0", count: 54)
        try FileManager.default.createDirectory(at: viewers.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":1,"viewers":[{"id":"\#(phone)","name":"Phone","paired":"2026-11-01T10:00:00Z"},{"id":"\#(tablet)","name":"Phone","paired":"2026-11-02T10:00:00Z"},{"id":"\#(other)","name":"Other","paired":"2026-11-03T10:00:00Z"}]}"#.utf8)
            .write(to: viewers.url)
        #expect(throws: CLIError.self) { try viewers.remove(matching: "phone") }
        #expect(throws: CLIError.self) { try viewers.remove(matching: String(phone.prefix(8))) }
        #expect(try viewers.all().count == 3)
    }

    @Test("The file and its folder are readable by the user alone")
    func privateFile() throws {
        let viewers = store()
        try viewers.add(id: phone, name: "Phone")
        let file = try FileManager.default.attributesOfItem(atPath: viewers.url.path)[.posixPermissions] as? NSNumber
        let folder = try FileManager.default.attributesOfItem(atPath: viewers.url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        #expect(file?.intValue == 0o600)
        #expect(folder?.intValue == 0o700)
    }

    @Test("A host learns which of its connected viewers have been removed, and throws nobody out over a damaged file")
    func removedAmongConnected() throws {
        let viewers = store()
        #expect(viewers.changed == nil)
        try viewers.add(id: phone, name: "Phone")
        try viewers.add(id: tablet, name: "Tablet")
        let written = try #require(viewers.changed)
        #expect(viewers.removed(among: [phone, tablet]).isEmpty)
        // `axe mirror unpair` from another process: the file changes, and the phone is off the list.
        try FileManager.default.setAttributes([.modificationDate: written.addingTimeInterval(-10)], ofItemAtPath: viewers.url.path)
        let before = try #require(viewers.changed)
        #expect(try MirrorViewers(url: viewers.url).remove(matching: "Phone").count == 1)
        #expect(viewers.changed != before)
        #expect(viewers.removed(among: [phone, tablet]) == [phone])
        try Data("not a list".utf8).write(to: viewers.url)
        #expect(viewers.removed(among: [phone, tablet]).isEmpty)
    }

    @Test("A damaged file allows nobody and is reported, not replaced")
    func damagedFile() throws {
        let viewers = store()
        try viewers.add(id: phone, name: "Phone")
        try Data("not a list".utf8).write(to: viewers.url)
        #expect(!viewers.allows(phone))
        #expect(throws: CLIError.self) { try viewers.all() }
        #expect(throws: CLIError.self) { try viewers.add(id: tablet, name: "Tablet") }
        #expect(try Data(contentsOf: viewers.url) == Data("not a list".utf8))
    }

    @Test("Names are stored as one short line", arguments: [
        ("  My iPhone \n", "My iPhone"), ("a\u{0007}b\nc", "abc"), ("", "Unnamed viewer"), ("   ", "Unnamed viewer"),
        (String(repeating: "x", count: 200), String(repeating: "x", count: 60)),
    ])
    func cleansNames(_ given: String, _ stored: String) {
        #expect(MirrorViewers.clean(given) == stored)
    }

    @Test("Many additions at once all land")
    func concurrentAdds() async throws {
        let viewers = store()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask { _ = try? MirrorViewers(url: viewers.url).add(id: String(format: "%064x", index), name: "Viewer \(index)") }
            }
        }
        #expect(try viewers.all().count == 40)
    }
}
