import ArgumentParser
import Foundation
import Testing
@testable import AXe

/// `axe remote --help` is answered with the host subcommand's help, because the host is the default
/// subcommand. These tests keep that one screen complete: it once named a `start` command nobody
/// types and said nothing of pairing.
@Suite("Mirror help")
struct MirrorHelpTests {
    private var shownSubcommands: [ParsableCommand.Type] {
        RemoteCommand.configuration.subcommands.filter { $0.configuration.shouldDisplay }
    }

    @Test("axe remote --help lists every command a user can type, and the host's options")
    func hostHelpIsTheWholeHelp() {
        let help = Axe.helpMessage(for: MirrorStartCommand.self)
        for command in shownSubcommands {
            let name = command._commandName
            let listed = help.contains("axe remote " + name)
            #expect(listed, "\(name) is missing from axe remote --help")
        }
        #expect(help.contains("axe remote mirror --udid <UDID>"))
        for option in ["--relay-url <relay-url>", "--no-builds", "--builds <builds>"] {
            #expect(help.contains(option), "\(option) is missing from axe remote --help")
        }
        #expect(!help.contains("remote start"))
        #expect(!help.contains("\n  start"))
    }

    @Test("Every subcommand shown to users has a line in the table and in the usage")
    func tableCoversSubcommands() {
        let tableLines = MirrorHelp.commands.map { $0.usage }
        var names: [String] = []
        for command in shownSubcommands {
            let name = command._commandName
            names.append(name)
            let prefix = "axe remote " + name
            let inTable = tableLines.contains { $0.hasPrefix(prefix) }
            let inUsage = MirrorHelp.usage.contains(prefix)
            #expect(inTable, "\(prefix) has no line in MirrorHelp.commands")
            #expect(inUsage, "\(prefix) is missing from MirrorHelp.usage")
        }
        #expect(names == ["mirror", "pair", "devices", "unpair", "build", "publish", "builds"])
    }

    @Test("The table fits an 80-column terminal, so no line of it is wrapped")
    func tableFits() {
        let table = MirrorHelp.discussion.split(separator: "\n").filter { $0.hasPrefix("  axe remote") }
        #expect(table.count == MirrorHelp.commands.count)
        for line in table { #expect(line.count <= 80, "\(line.count) columns: \(line)") }
    }

    @Test("axe help remote lists pair, devices and unpair, not the host's hidden name")
    func groupHelp() {
        let help = Axe.helpMessage(for: RemoteCommand.self)
        #expect(help.contains("SUBCOMMANDS:"))
        for name in ["mirror", "pair", "devices", "unpair"] { #expect(help.contains("\n  \(name) ")) }
        #expect(!help.contains("remote start"))
        #expect(!help.contains("\n  start"))
        #expect(!help.contains("test-pair"))
        #expect(help.contains("axe remote --help"))
    }

    @Test("Error text and the JSON command name do not mention the hidden name either")
    func hiddenNameIsNotPrinted() throws {
        let hidden = Axe.withoutHiddenDefaultNames("  See 'axe remote start --help' for more information.")
        #expect(hidden == "  See 'axe remote --help' for more information.")
        let pairLine = "  See 'axe remote pair --help' for more information."
        #expect(Axe.withoutHiddenDefaultNames(pairLine) == pairLine)
        let hingeLine = "  See 'axe hinge set --help' for more information."
        #expect(Axe.withoutHiddenDefaultNames(hingeLine) == hingeLine)

        let host = try Axe.parseAsRoot(["remote"])
        let hostPath = Axe.commandPath(of: host)
        #expect(host is MirrorStartCommand)
        #expect(hostPath == "remote")
        let devices = try Axe.parseAsRoot(["remote", "devices"])
        let devicesPath = Axe.commandPath(of: devices)
        #expect(devicesPath == "remote devices")
    }

    @Test("The host still runs with or without the hidden name, and pair keeps its own options")
    func parsing() throws {
        let named = try Axe.parseAsRoot(["remote", "start"])
        #expect(named is MirrorStartCommand)
        let parsed = try Axe.parseAsRoot(["remote", "pair", "--relay-url", "https://relay.example", "--json"])
        let pair = parsed as? MirrorPairCommand
        #expect(pair?.relayURL == "https://relay.example")
        #expect(pair?.json == true)
    }

    @Test("axe remote mirror hosts one simulator and needs --udid; its options are listed there, not by axe remote")
    func mirrorSubcommand() throws {
        let mirror = try #require(try Axe.parseAsRoot(["remote", "mirror", "--udid", "ABC", "--no-builds"]) as? RemoteMirrorCommand)
        #expect(mirror.simulator.simulatorUDID == "ABC")
        #expect(mirror.host.noBuilds)
        #expect(Axe.commandPath(of: mirror) == "remote mirror")
        #expect(throws: (any Error).self) { try Axe.parseAsRoot(["remote", "mirror"]) }
        #expect(throws: (any Error).self) { try Axe.parseAsRoot(["remote", "mirror", "--udid", "ABC", "--demo"]) }
        #expect(throws: (any Error).self) { try Axe.parseAsRoot(["remote", "mirror", "--udid", "ABC", "--relay-url", "nonsense"]) }
        let mirrorHelp = Axe.helpMessage(for: RemoteMirrorCommand.self)
        for option in ["--udid <udid>", "--demo ", "--demo-app <demo-app>", "--relay-url <relay-url>"] {
            #expect(mirrorHelp.contains(option), "\(option) is missing from axe remote mirror --help")
        }
        let hostHelp = Axe.helpMessage(for: MirrorStartCommand.self)
        #expect(!hostHelp.contains("--demo-app <demo-app>   "))
        #expect(!hostHelp.contains("--udid <udid>   "))
    }

    @Test("Every command released as axe mirror in AXe 2.1 still runs, and is kept out of help")
    func oldNamesStillRun() throws {
        let host = try #require(try Axe.parseAsRoot(["mirror", "--udid", "ABC"]) as? MirrorStartCommand)
        #expect(host.simulatorUDID == "ABC")
        #expect(try Axe.parseAsRoot(["mirror"]) is MirrorStartCommand)
        #expect(try Axe.parseAsRoot(["mirror", "start", "--udid", "ABC"]) is MirrorStartCommand)
        #expect(try Axe.parseAsRoot(["mirror", "pair", "--json"]) is MirrorPairCommand)
        #expect(try Axe.parseAsRoot(["mirror", "viewers", "--json"]) is MirrorViewersCommand)
        #expect(try Axe.parseAsRoot(["mirror", "unpair", "phone"]) is MirrorUnpairCommand)
        #expect(try Axe.parseAsRoot(["mirror", "publish", "app.ipa"]) is MirrorPublishCommand)
        #expect(try Axe.parseAsRoot(["mirror", "builds"]) is MirrorBuildsCommand)
        #expect(try Axe.parseAsRoot(["mirror", "build", "--project", "A.xcodeproj", "--scheme", "A"]) is MirrorBuildCommand)
        let top = Axe.helpMessage(for: Axe.self)
        #expect(top.contains("\n  remote "))
        #expect(!top.contains("\n  mirror "))
        #expect(Axe.withoutHiddenDefaultNames("See 'axe mirror start --help'") == "See 'axe mirror --help'")
    }
}
