import ArgumentParser
import Darwin
import Foundation
import Security
#if AXE_MIRROR
@preconcurrency import FBControlCore
import FBSimulatorControl
#endif

/// Hosts a live view of one simulator for a viewer app on another device, and manages which
/// viewers may connect. `axe mirror --udid <UDID>` runs the host; the other subcommands pair a
/// viewer, list the paired viewers and remove one.
///
/// The host is a default subcommand that nobody types, and the argument parser answers
/// `axe mirror --help` with that subcommand's help, not this command's. So the host's help is
/// written as the help for all of `axe mirror` (see `MirrorHelp`), and the subcommand itself is
/// left out of the list this command prints for `axe help mirror`. Giving this command the host's
/// options instead does not work: the parser reads a parent's options first, so `--relay-url`
/// after `pair` went to the host and `pair` never saw it.
// Named MirrorCommand because `Mirror` is the standard library's reflection type, which AXe uses.
struct MirrorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mirror",
        abstract: MirrorHelp.abstract,
        usage: MirrorHelp.usage,
        discussion: MirrorHelp.discussion + "\n\n" + MirrorHelp.hostOptions,
        subcommands: [MirrorStartCommand.self, MirrorPairCommand.self, MirrorViewersCommand.self, MirrorUnpairCommand.self, MirrorTestPairCommand.self],
        defaultSubcommand: MirrorStartCommand.self
    )
}

/// The help for `axe mirror` as a whole. `axe mirror --help` prints it with the host's options
/// below it; `axe help mirror` prints it with the list of subcommands below it.
enum MirrorHelp {
    static let abstract = "Show one simulator live in the AXe Mirror app on an iPhone or iPad, with touch."

    /// One line per thing a person can type. `MirrorHelpTests` checks that every subcommand shown
    /// to users is here, so a new one cannot be left out.
    static let commands: [(usage: String, summary: String)] = [
        ("axe mirror --udid <UDID>", "Host a booted simulator for paired viewers."),
        ("axe mirror pair", "Pair a viewer with a one-time code or QR code."),
        ("axe mirror viewers", "List the paired viewers."),
        ("axe mirror unpair <viewer>", "Remove a paired viewer by its name or ID."),
    ]

    static let usage = """
    axe mirror --udid <udid> [--relay-url <relay-url>] [--demo] [--demo-app <demo-app>]
    axe mirror pair [--name <name>] [--json] [--relay-url <relay-url>]
    axe mirror viewers [--json]
    axe mirror unpair <viewer>
    """

    static let discussion: String = {
        let width = (commands.map(\.usage.count).max() ?? 0) + 3
        let table = commands.map { "  " + $0.usage.padding(toLength: width, withPad: " ", startingAt: 0) + $0.summary }
        return """
        Pair a device once, then host a booted simulator. Only paired devices can connect. Needs an Apple silicon Mac.

        Commands:
        \(table.joined(separator: "\n"))

        The host prints one JSON line per event, starting with the host ID. Logs go to standard error. Stop it with Ctrl+C or SIGTERM.

        Each command has its own help, for example axe mirror pair --help.
        """
    }()

    /// Where the host's own options are listed, for the screen that does not list them itself.
    static let hostOptions = "The host's options are listed by axe mirror --help."
}

/// Runs the host. The viewer finds this Mac by its host ID, a public key, over iroh: directly when
/// the two can reach each other, through a relay when they cannot. Only paired viewers are let in.
struct MirrorStartCommand: AsyncParsableCommand {
    // `axe mirror --help` prints this command's help, so it is the help for all of `axe mirror`.
    // The name "start" is never needed and is not shown anywhere.
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: MirrorHelp.abstract,
        usage: MirrorHelp.usage,
        discussion: MirrorHelp.discussion,
        shouldDisplay: false
    )

    @Option(name: .customLong("udid"), help: "UDID of the booted simulator to host.")
    var simulatorUDID: String

    @Option(name: .customLong("relay-url"), help: "Use this iroh relay and no other; by default AXe picks from its published list.")
    var relayURL: String?

    @Option(
        name: .customLong("relay-list"),
        help: ArgumentHelp("Use this text in place of the published relay list.", visibility: .hidden))
    var relayList: String?

    @Option(name: .customLong("key-file"),
        help: ArgumentHelp("Read the host key from this file instead of AXe's own.", visibility: .hidden))
    var keyFile: String?

    @Option(name: .customLong("viewers-file"),
        help: ArgumentHelp("Read the list of paired viewers from this file instead of AXe's own.", visibility: .hidden))
    var viewersFile: String?

    @Flag(name: .customLong("allow-unpaired"),
        help: ArgumentHelp("Let any viewer that knows the host ID connect. For tests only.", visibility: .hidden))
    var allowUnpaired = false

    @Flag(name: .long, help: "Run as a public demo: any viewer may connect without pairing, one at a time, and is kept inside one app. Uses its own key.")
    var demo = false

    @Option(name: .customLong("demo-app"), help: "With --demo: the bundle ID of the app kept in front.")
    var demoApp: String?

    @Flag(name: .customLong("relay-only"),
        help: ArgumentHelp("Listen on loopback only, so every viewer goes through the relay.", visibility: .hidden))
    var relayOnly = false

    @Option(name: .customLong("delay-rule"),
        help: ArgumentHelp("How the touch replay delay is chosen: gestures, steady or fixed.", visibility: .hidden))
    var delayRule = "gestures"

    func validate() throws {
        guard !simulatorUDID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("--udid must not be empty.")
        }
        guard !AutomationTarget.isPhysicalInputUDID(simulatorUDID) else {
            throw ValidationError("axe mirror runs against simulators only.")
        }
        guard demoApp == nil || demo else {
            throw ValidationError("--demo-app needs --demo.")
        }
    }

    func run() async throws {
        #if AXE_MIRROR
        let logger = AxeLogger()
        try await setup(logger: logger)
        let simulator = try await DeviceState.bootedSimulator(udid: simulatorUDID, logger: logger)
        // A demo host has its own identity, so that being a demo never opens this Mac's own host.
        let defaultKey = demo ? MirrorIdentity.keyURL.deletingLastPathComponent().appendingPathComponent("demo.key") : MirrorIdentity.keyURL
        let secret = try MirrorIdentity.secret(at: keyFile.map { URL(fileURLWithPath: $0) } ?? defaultKey)
        var settings = MirrorSession.Settings()
        settings.demo = demo
        settings.demoApp = demoApp
        if demo { settings.mbps = MirrorDemo.megabits }
        settings.relaySeed = MirrorRelays.seed(for: secret)
        settings.relayRecord = relayList
        settings.watchRelays = relayURL == nil
        let relays = await MirrorRelays.choose(explicit: relayURL, seed: settings.relaySeed, record: relayList)
        settings.relayURLs = relays.relays
        MirrorHost.emit(relays.event)
        settings.relayOnly = relayOnly
        settings.viewers = allowUnpaired || demo ? nil : MirrorViewers(url: viewersFile.map { URL(fileURLWithPath: $0) } ?? MirrorViewers.defaultURL)
        settings.delayRule = delayRule
        try await MirrorHost.run(simulator: simulator, secret: secret, settings: settings)
        #else
        throw CLIError(errorDescription: "axe mirror needs an Apple silicon Mac.", code: .commandFailed)
        #endif
    }
}

/// Pairs one viewer with this Mac. The host does not have to be running, and may be.
struct MirrorPairCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pair",
        abstract: "Show a one-time code for a viewer app to scan or type, and pair with the viewer that uses it.",
        discussion: """
        The code works once and for ten minutes. The paired viewer may connect to this Mac from then on; remove it with axe mirror unpair.
        """
    )

    @Option(name: .long, help: "The name the viewer shows for this Mac. Defaults to the Mac's own name.")
    var name: String?

    @Flag(name: .long, help: "Print JSON lines instead of the QR code: one with the code, one when a viewer has paired.")
    var json = false

    @Option(name: .customLong("relay-url"), help: "Pair through this iroh relay; by default AXe picks from its published list.")
    var relayURL: String?

    @Option(name: .customLong("relay-list"),
        help: ArgumentHelp("Use this text in place of the published relay list.", visibility: .hidden))
    var relayList: String?

    @Option(name: .customLong("key-file"),
        help: ArgumentHelp("Read the host key from this file instead of AXe's own.", visibility: .hidden))
    var keyFile: String?

    @Option(name: .customLong("viewers-file"),
        help: ArgumentHelp("Read the list of paired viewers from this file instead of AXe's own.", visibility: .hidden))
    var viewersFile: String?

    @Option(name: .long, help: ArgumentHelp("Seconds the code stays valid. For tests.", visibility: .hidden))
    var lifetime: Double = MirrorPairingCode.lifetime

    func run() async throws {
        #if AXE_MIRROR
        let secret = try MirrorIdentity.secret(at: keyFile.map { URL(fileURLWithPath: $0) } ?? MirrorIdentity.keyURL)
        let viewers = MirrorViewers(url: viewersFile.map { URL(fileURLWithPath: $0) } ?? MirrorViewers.defaultURL)
        _ = try viewers.all()       // a list that cannot be read is reported now, not after the user has scanned
        // The same choice the host makes, so the viewer is told the relay the host listens on.
        let relays = await MirrorRelays.choose(explicit: relayURL, seed: MirrorRelays.seed(for: secret), record: relayList)
        let json = json
        let dates = ISO8601DateFormatter()
        let viewer = try await MirrorPairHost.run(hostSecret: secret, relays: relays, viewers: viewers,
                                                  hostName: name ?? Host.current().localizedName ?? "Mac", lifetime: lifetime) { shown in
            if json {
                MirrorHost.emit(["event": "code", "code": MirrorPairingCode.display(shown.code), "link": shown.link,
                                 "expires": dates.string(from: shown.expires), "relay": shown.relay])
            } else {
                print("Scan this with the viewer app, or type the code. It works once, for ten minutes.\n")
                for line in MirrorQRCode.lines(for: shown.link) ?? [] { print("  " + line) }
                print("\n  Code: \(MirrorPairingCode.display(shown.code))\n\nWaiting for the viewer. Press Ctrl+C to cancel.")
            }
        }
        if json {
            MirrorHost.emit(["event": "paired", "viewer": viewer.id, "name": viewer.name])
        } else {
            print("Paired with \(viewer.name).")
        }
        #else
        throw CLIError(errorDescription: "axe mirror needs an Apple silicon Mac.", code: .commandFailed)
        #endif
    }
}

/// Plays the viewer's part in pairing, for tests: presents a code as a viewer with the given key.
struct MirrorTestPairCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test-pair",
        abstract: "Present a pairing code as a viewer would. For tests.",
        shouldDisplay: false
    )

    @Option(name: .long, help: "The code, or the link from the QR code.")
    var code: String

    @Option(name: .long, help: "The viewer's name.")
    var name = "Test viewer"

    @Option(name: .customLong("key-file"), help: "The viewer's key file; created if absent.")
    var keyFile: String

    @Option(name: .customLong("relay-url"), help: "Dial through this relay only.")
    var relayURL: String?

    @Option(name: .customLong("relay-list"), help: "Use this text in place of the published relay list.")
    var relayList: String?

    func run() async throws {
        #if AXE_MIRROR
        let secret = try MirrorIdentity.secret(at: URL(fileURLWithPath: keyFile))
        let relays = await MirrorRelays.choose(explicit: relayURL, record: relayList)
        let start = Date()
        switch await MirrorPairClient.pair(code: code, name: name, viewerSecret: secret, relays: relays.relays) {
        case .success(let reply):
            MirrorHost.emit(["event": "paired", "hostId": reply.hostId, "name": reply.name, "homeRelay": reply.homeRelay,
                             "relays": reply.relays.joined(separator: " "), "seconds": String(format: "%.1f", Date().timeIntervalSince(start))])
        case .failure(let failure):
            MirrorHost.emit(["event": "failed", "reason": String(describing: failure), "seconds": String(format: "%.1f", Date().timeIntervalSince(start))])
            throw ExitCode.failure
        }
        #else
        throw CLIError(errorDescription: "axe mirror needs an Apple silicon Mac.", code: .commandFailed)
        #endif
    }
}

/// Lists the viewers this Mac is paired with.
struct MirrorViewersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "viewers",
        abstract: "List the viewers paired with this Mac."
    )

    @Flag(name: .long, help: "Print the list as JSON.")
    var json = false

    @Option(name: .customLong("viewers-file"),
        help: ArgumentHelp("Read the list of paired viewers from this file instead of AXe's own.", visibility: .hidden))
    var viewersFile: String?

    func run() async throws {
        let viewers = try MirrorViewers(url: viewersFile.map { URL(fileURLWithPath: $0) } ?? MirrorViewers.defaultURL).all()
        let dates = ISO8601DateFormatter()
        if json {
            let list = viewers.map { ["id": $0.id, "name": $0.name, "paired": dates.string(from: $0.paired)] }
            let data = try JSONSerialization.data(withJSONObject: ["viewers": list], options: [.sortedKeys, .withoutEscapingSlashes])
            print(String(decoding: data, as: UTF8.self))
        } else if viewers.isEmpty {
            print("No viewers are paired with this Mac.")
        } else {
            for viewer in viewers { print("\(viewer.name)\t\(dates.string(from: viewer.paired))\t\(viewer.id)") }
        }
    }
}

/// Removes a paired viewer. It can no longer connect, and a session it has open is not affected
/// until it reconnects.
struct MirrorUnpairCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unpair",
        abstract: "Remove a paired viewer by its name or ID."
    )

    @Argument(help: "The viewer's name, its ID, or the first characters of its ID, as shown by axe mirror viewers.")
    var viewer: String

    @Option(name: .customLong("viewers-file"),
        help: ArgumentHelp("Read the list of paired viewers from this file instead of AXe's own.", visibility: .hidden))
    var viewersFile: String?

    func run() async throws {
        let removed = try MirrorViewers(url: viewersFile.map { URL(fileURLWithPath: $0) } ?? MirrorViewers.defaultURL).remove(matching: viewer)
        guard let gone = removed.first else {
            throw CLIError(errorDescription: "No paired viewer matches \"\(viewer)\".", code: .commandFailed)
        }
        print("Removed \(gone.name) (\(gone.id)).")
    }
}

/// The host's long-lived identity: 32 secret bytes kept in the user's Application Support folder,
/// readable by the user alone. The host ID viewers use is the public half.
enum MirrorIdentity {
    static var keyURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AXe/mirror/host.key")
    }

    /// Reads the key, or creates it on first use. A key that exists is never replaced: not when it
    /// has the wrong size, not when it cannot be read, and not when another command creates it at
    /// the same moment (the file is created only if absent, and the loser of that race reads the
    /// winner's key). Replacing it would silently unpair every viewer.
    static func secret(at url: URL = keyURL) throws -> Data {
        if let existing = try read(url) { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CLIError(errorDescription: "Could not create a mirror host key.", code: .commandFailed)
        }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // Written under another name and linked into place: the key appears whole or not at all,
        // and `link` fails if a key is already there.
        let temporary = url.path + ".\(UUID().uuidString).new"
        let descriptor = open(temporary, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw CLIError(errorDescription: "Could not write the mirror host key to \(url.path).", code: .outputFailed)
        }
        let written = write(descriptor, bytes, bytes.count)
        fsync(descriptor)
        close(descriptor)
        defer { unlink(temporary) }
        guard written == bytes.count else {
            throw CLIError(errorDescription: "Could not write the mirror host key to \(url.path).", code: .outputFailed)
        }
        if link(temporary, url.path) == 0 { return Data(bytes) }
        guard errno == EEXIST, let existing = try read(url) else {
            throw CLIError(errorDescription: "Could not write the mirror host key to \(url.path).", code: .outputFailed)
        }
        return existing
    }

    /// The key in the file, nil when there is no file. Any other trouble is an error.
    private static func read(_ url: URL) throws -> Data? {
        do {
            let existing = try Data(contentsOf: url)
            guard existing.count == 32 else {
                throw CLIError(errorDescription: "The mirror host key at \(url.path) is not 32 bytes. Move it away to create a new one.", code: .readFailed)
            }
            return existing
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError(errorDescription: "The mirror host key at \(url.path) cannot be read: \(error.localizedDescription)", code: .readFailed)
        }
    }
}

#if AXE_MIRROR
/// Runs one mirror session until the command is stopped, printing each event as a JSON line.
enum MirrorHost {
    static func run(simulator: FBSimulator, secret: Data, settings: MirrorSession.Settings) async throws {
        let framebuffer: FBFramebuffer
        do {
            framebuffer = try FBFramebuffer.mainScreenSurface(for: simulator, logger: FBControlCoreLoggerFactory.systemLoggerWriting(toStderr: false, withDebugLogging: false))
        } catch {
            throw CLIError(errorDescription: "The simulator's screen could not be read: \(error.localizedDescription)", code: .captureFailed)
        }
        let session = MirrorSession(simulator: simulator, framebuffer: framebuffer, secret: secret, settings: settings)
        session.onEvent = { emit($0) }
        let stop = AsyncStream<Void>.makeStream()
        let observer = SignalObserver(signals: [SIGINT, SIGTERM]) { stop.continuation.yield() }
        defer { observer.invalidate() }
        session.start()
        for await _ in stop.stream { break }
        for line in session.stop() { FileHandle.standardError.write(Data((line + "\n").utf8)) }
        emit(["event": "stopped"])
    }

    static func emit(_ event: [String: String]) {
        guard var line = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        line.append(0x0A)
        try? FileHandle.standardOutput.write(contentsOf: line)
    }
}
#endif
