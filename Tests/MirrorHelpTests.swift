import ArgumentParser
import Foundation
import Testing
@testable import AXe

/// `axe mirror --help` is answered with the host subcommand's help, because the host is the default
/// subcommand. These tests keep that one screen complete: it once named a `start` command nobody
/// types and said nothing of pairing.
@Suite("Mirror help")
struct MirrorHelpTests {
    private var shownSubcommands: [ParsableCommand.Type] {
        MirrorCommand.configuration.subcommands.filter { $0.configuration.shouldDisplay }
    }

    @Test("axe mirror --help lists every command a user can type, and the host's options")
    func hostHelpIsTheWholeHelp() {
        let help = Axe.helpMessage(for: MirrorStartCommand.self)
        for command in shownSubcommands {
            let name = command._commandName
            let listed = help.contains("axe mirror " + name)
            #expect(listed, "\(name) is missing from axe mirror --help")
        }
        #expect(help.contains("axe mirror --udid <UDID>"))
        for option in ["--udid <udid>", "--relay-url <relay-url>", "--demo ", "--demo-app <demo-app>"] {
            #expect(help.contains(option), "\(option) is missing from axe mirror --help")
        }
        #expect(!help.contains("mirror start"))
        #expect(!help.contains("\n  start"))
    }

    @Test("Every subcommand shown to users has a line in the table and in the usage")
    func tableCoversSubcommands() {
        let tableLines = MirrorHelp.commands.map { $0.usage }
        var names: [String] = []
        for command in shownSubcommands {
            let name = command._commandName
            names.append(name)
            let prefix = "axe mirror " + name
            let inTable = tableLines.contains { $0.hasPrefix(prefix) }
            let inUsage = MirrorHelp.usage.contains(prefix)
            #expect(inTable, "\(prefix) has no line in MirrorHelp.commands")
            #expect(inUsage, "\(prefix) is missing from MirrorHelp.usage")
        }
        #expect(names == ["pair", "viewers", "unpair", "build", "publish", "builds"])
    }

    @Test("The table fits an 80-column terminal, so no line of it is wrapped")
    func tableFits() {
        let table = MirrorHelp.discussion.split(separator: "\n").filter { $0.hasPrefix("  axe mirror") }
        #expect(table.count == MirrorHelp.commands.count)
        for line in table { #expect(line.count <= 80, "\(line.count) columns: \(line)") }
    }

    @Test("axe help mirror lists pair, viewers and unpair, not the host's hidden name")
    func groupHelp() {
        let help = Axe.helpMessage(for: MirrorCommand.self)
        #expect(help.contains("SUBCOMMANDS:"))
        for name in ["pair", "viewers", "unpair"] { #expect(help.contains("\n  \(name) ")) }
        #expect(!help.contains("mirror start"))
        #expect(!help.contains("\n  start"))
        #expect(!help.contains("test-pair"))
        #expect(help.contains("axe mirror --help"))
    }

    @Test("Error text and the JSON command name do not mention the hidden name either")
    func hiddenNameIsNotPrinted() throws {
        let hidden = Axe.withoutHiddenDefaultNames("  See 'axe mirror start --help' for more information.")
        #expect(hidden == "  See 'axe mirror --help' for more information.")
        let pairLine = "  See 'axe mirror pair --help' for more information."
        #expect(Axe.withoutHiddenDefaultNames(pairLine) == pairLine)
        let hingeLine = "  See 'axe hinge set --help' for more information."
        #expect(Axe.withoutHiddenDefaultNames(hingeLine) == hingeLine)

        let host = try Axe.parseAsRoot(["mirror", "--udid", "ABC"])
        let hostPath = Axe.commandPath(of: host)
        #expect(host is MirrorStartCommand)
        #expect(hostPath == "mirror")
        let viewers = try Axe.parseAsRoot(["mirror", "viewers"])
        let viewersPath = Axe.commandPath(of: viewers)
        #expect(viewersPath == "mirror viewers")
    }

    @Test("The host still runs with or without the hidden name, and pair keeps its own options")
    func parsing() throws {
        let named = try Axe.parseAsRoot(["mirror", "start", "--udid", "ABC"])
        #expect(named is MirrorStartCommand)
        let parsed = try Axe.parseAsRoot(["mirror", "pair", "--relay-url", "https://relay.example", "--json"])
        let pair = parsed as? MirrorPairCommand
        #expect(pair?.relayURL == "https://relay.example")
        #expect(pair?.json == true)
    }
}
