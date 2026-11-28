import ArgumentParser
import Darwin
import Foundation
import Security
#if AXE_MIRROR
@preconcurrency import FBControlCore
import FBSimulatorControl
#endif

/// Serves this Mac to the AXe Mirror app on paired devices: its simulators, live and with touch,
/// and its builds, to install. `axe remote` starts the host, `axe remote mirror --udid <UDID>`
/// starts it on one simulator, and the other subcommands pair a device, list the paired devices,
/// remove one, and publish and manage builds.
///
/// The host is a default subcommand that nobody types, and the argument parser answers
/// `axe remote --help` with that subcommand's help, not this command's. So the host's help is
/// written as the help for all of `axe remote` (see `MirrorHelp`), and the subcommand itself is
/// left out of the list this command prints for `axe help remote`. Giving this command the host's
/// options instead does not work: the parser reads a parent's options first, so `--relay-url`
/// after `pair` went to the host and `pair` never saw it.
struct RemoteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remote",
        abstract: MirrorHelp.abstract,
        usage: MirrorHelp.usage,
        discussion: MirrorHelp.discussion + "\n\n" + MirrorHelp.hostOptions,
        subcommands: [MirrorStartCommand.self, RemoteMirrorCommand.self, MirrorPairCommand.self, RemoteDevicesCommand.self,
                      MirrorUnpairCommand.self, MirrorBuildCommand.self, MirrorPublishCommand.self, MirrorBuildsCommand.self,
                      MirrorTestPairCommand.self],
        defaultSubcommand: MirrorStartCommand.self
    )
}

/// `axe mirror`, the name all of this had in AXe 2.1, when mirroring was all it did. Every command
/// released under it still runs, so nobody's script breaks; help and documentation name only
/// `axe remote`.
// Named MirrorCommand because `Mirror` is the standard library's reflection type, which AXe uses.
struct MirrorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mirror",
        abstract: MirrorHelp.abstract,
        usage: MirrorHelp.usage,
        discussion: MirrorHelp.discussion + "\n\n" + MirrorHelp.hostOptions,
        shouldDisplay: false,
        subcommands: [MirrorStartCommand.self, MirrorPairCommand.self, MirrorViewersCommand.self, MirrorUnpairCommand.self,
                      MirrorBuildCommand.self, MirrorPublishCommand.self, MirrorBuildsCommand.self, MirrorTestPairCommand.self],
        defaultSubcommand: MirrorStartCommand.self
    )
}

/// The help for `axe remote` as a whole. `axe remote --help` prints it with the host's options
/// below it; `axe help remote` prints it with the list of subcommands below it.
enum MirrorHelp {
    /// Refuses a relay address that is not one. A host given an address it could not use went on
    /// with iroh's public relays, though --relay-url promises "this relay and no other", so a
    /// slip of the finger sent the session through somebody else's relay without a word.
    static func checkRelay(_ address: String?) throws {
        guard let address else { return }
        guard let url = URL(string: address), url.scheme == "https" || url.scheme == "http", url.host?.isEmpty == false else {
            throw ValidationError("--relay-url takes a relay's address, such as https://relay.example.com: \"\(address)\" is not one.")
        }
    }

    static let abstract = "Serve this Mac's simulators and builds to the AXe Mirror app on an iPhone or iPad."

    /// One line per thing a person can type. `MirrorHelpTests` checks that every subcommand shown
    /// to users is here, so a new one cannot be left out.
    static let commands: [(usage: String, summary: String)] = [
        ("axe remote", "Start the host: simulators and builds."),
        ("axe remote mirror --udid <UDID>", "Start the host on one booted simulator."),
        ("axe remote pair", "Pair a device with a code or QR code."),
        ("axe remote devices", "List the paired devices."),
        ("axe remote unpair <device>", "Remove a paired device by name or ID."),
        ("axe remote build", "Build an app and offer it to install."),
        ("axe remote publish <ipa>", "Offer a signed IPA to install."),
        ("axe remote builds", "List the builds on offer, and manage them."),
    ]

    static let usage = """
    axe remote [--relay-url <relay-url>] [--no-builds]
    axe remote mirror --udid <udid> [--relay-url <relay-url>] [--demo --demo-app <demo-app>]
    axe remote pair [--name <name>] [--json] [--relay-url <relay-url>]
    axe remote devices [--json]
    axe remote unpair <device>
    axe remote build (--project <project> | --workspace <workspace>) --scheme <scheme> [--notes <notes>]
    axe remote publish <ipa> [--notes <notes>]
    axe remote builds [--json] [--remove <build-id>] [--keep <n>] [--notes <build-id> <text>] [--clean]
    """

    static let discussion: String = {
        let width = (commands.map(\.usage.count).max() ?? 0) + 3
        let table = commands.map { "  " + $0.usage.padding(toLength: width, withPad: " ", startingAt: 0) + $0.summary }
        return """
        Pair a device once, then start the host. A paired device chooses one of this Mac's simulators in the AXe Mirror app, which the host boots if it is shut down, or has a new one created, and installs the builds this Mac offers. axe remote mirror --udid shows one booted simulator instead. Only paired devices can connect. Needs an Apple silicon Mac.

        Commands:
        \(table.joined(separator: "\n"))

        The host prints one JSON line per event, starting with the host ID. Logs go to standard error. Stop it with Ctrl+C, SIGTERM or SIGHUP.

        Each command has its own help, for example axe remote pair --help. The commands were under axe mirror before AXe 2.2, and still run from there.
        """
    }()

    /// Where the host's own options are listed, for the screen that does not list them itself.
    static let hostOptions = "The host's options are listed by axe remote --help."
}

/// Which simulator the host shows, for `axe remote mirror`. The plain host takes the same options
/// without listing them, so that `axe mirror --udid`, as released in AXe 2.1, still runs.
struct MirrorSimulatorOptions: ParsableArguments {
    @Option(name: .customLong("udid"), help: "UDID of the booted simulator to host. Without it the paired device chooses, boots or creates a simulator.")
    var simulatorUDID: String?

    @Flag(name: .long, help: "Run as a public demo: any viewer may connect without pairing, one at a time, and is kept inside the app named by --demo-app. Uses its own key.")
    var demo = false

    @Option(name: .customLong("demo-app"), help: "With --demo, which needs it: the bundle ID of the app kept in front.")
    var demoApp: String?

    func validate() throws {
        if let simulatorUDID {
            guard !simulatorUDID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError("--udid must not be empty.")
            }
            guard !AutomationTarget.isPhysicalInputUDID(simulatorUDID) else {
                throw ValidationError("axe remote mirror runs against simulators only.")
            }
        }
        // A demo's visitors are strangers: they are shown one simulator and may not start others.
        guard !demo || simulatorUDID != nil else {
            throw ValidationError("--demo needs --udid.")
        }
        guard demoApp == nil || demo else {
            throw ValidationError("--demo-app needs --demo.")
        }
        // Without an app to keep in front, a stranger would have the whole simulator: its Safari
        // reaches this Mac's own network.
        guard !demo || demoApp?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw ValidationError("--demo needs --demo-app: the bundle ID of the one app its visitors are kept inside.")
        }
    }
}

/// The host's own options, and the host itself. The viewer finds this Mac by its host ID, a public
/// key, over iroh: directly when the two can reach each other, through a relay when they cannot.
/// Only paired devices are let in.
struct MirrorHostOptions: ParsableArguments {
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

    @Flag(name: .customLong("relay-only"),
        help: ArgumentHelp("Listen on loopback only, so every viewer goes through the relay.", visibility: .hidden))
    var relayOnly = false

    @Flag(name: .customLong("assume-local-network-blocked"),
        help: ArgumentHelp("Behave as if macOS kept this process off the local network. For tests.", visibility: .hidden))
    var assumeLocalNetworkBlocked = false

    @Option(name: .customLong("builds"),
            help: "Offer the builds in this folder instead of AXe's own store. Defaults to AXE_MIRROR_BUILDS.")
    var buildsFolder: String?

    @Flag(name: .customLong("no-builds"), help: "Offer paired devices no builds to install.")
    var noBuilds = false

    @OptionGroup var deviceSet: SimulatorDeviceSetOptions

    @Option(name: .customLong("install-identity"), help: ArgumentHelp("Keep the certificate viewers install builds with in this folder. For tests.", visibility: .hidden))
    var installIdentityFolder: String?

    @Option(name: .customLong("delay-rule"),
        help: ArgumentHelp("How the touch replay delay is chosen: gestures, steady or fixed.", visibility: .hidden))
    var delayRule = "gestures"

    func validate() throws {
        try MirrorHelp.checkRelay(relayURL)
    }

    func run(mirror: MirrorSimulatorOptions, logger: AxeLogger) async throws {
        #if AXE_MIRROR
        // Without --udid no simulator is opened yet: the viewer chooses one (see `MirrorSimulatorList`).
        var simulator: FBSimulator?
        if let simulatorUDID = mirror.simulatorUDID { simulator = try await DeviceState.bootedSimulator(udid: simulatorUDID, logger: logger) }
        // A demo host has its own identity, so that being a demo never opens this Mac's own host.
        let demo = mirror.demo
        let defaultKey = demo ? MirrorIdentity.keyURL.deletingLastPathComponent().appendingPathComponent("demo.key") : MirrorIdentity.keyURL
        let secret = try MirrorIdentity.secret(at: keyFile.map { URL(fileURLWithPath: $0) } ?? defaultKey)
        var settings = MirrorSession.Settings()
        settings.demo = demo
        settings.demoApp = mirror.demoApp
        if demo { settings.mbps = MirrorDemo.megabits }
        settings.relaySeed = MirrorRelays.seed(for: secret)
        settings.relayRecord = relayList
        if let installIdentityFolder {
            settings.installIdentity = MirrorInstallIdentityStore(folder: URL(fileURLWithPath: (installIdentityFolder as NSString).expandingTildeInPath, isDirectory: true))
        }
        if !demo, !noBuilds {
            // The viewer is offered the builds in AXe's store, or in the folder given. Each one
            // goes to the viewer over the connection it is paired on, when it asks for it.
            var folder = MirrorBuildStore.standard.root
            if let given = buildsFolder ?? ProcessInfo.processInfo.environment["AXE_MIRROR_BUILDS"].flatMap({ $0.isEmpty ? nil : $0 }) {
                folder = URL(fileURLWithPath: (given as NSString).expandingTildeInPath, isDirectory: true)
                var isFolder: ObjCBool = false
                guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
                    throw CLIError(errorDescription: "The builds folder \(folder.path) does not exist.", code: .invalidArguments)
                }
            }
            settings.builds = MirrorBuildCatalogue(folder: folder)
        }
        settings.watchRelays = relayURL == nil
        let relays = await MirrorRelays.choose(explicit: relayURL, seed: settings.relaySeed, record: relayList)
        settings.relayURLs = relays.relays
        MirrorHost.emit(relays.event)
        settings.relayOnly = relayOnly
        // A host that macOS keeps off the local network still hears a viewer on that network but
        // cannot answer it. Direct paths then open, are chosen for the picture and die, over and
        // over, and touches go unanswered for seconds at a time (measured 19 November 2026). Such a
        // host says why, and moves to the relay alone while a viewer on its own network is connected.
        // It asks macOS again each time such a viewer arrives, so it recovers once it is allowed.
        if !relayOnly, assumeLocalNetworkBlocked || MirrorLocalNetwork.check() == .blocked {
            settings.avoidLocalNetwork = true
            settings.assumeLocalNetworkBlocked = assumeLocalNetworkBlocked
            MirrorHost.emit(["event": "warning", "code": "localNetworkBlocked", "message": MirrorLocalNetwork.advice])
            mirrorNote("Warning: " + MirrorLocalNetwork.advice)
        }
        settings.viewers = allowUnpaired || demo ? nil : MirrorViewers(url: viewersFile.map { URL(fileURLWithPath: $0) } ?? MirrorViewers.defaultURL)
        settings.delayRule = delayRule
        settings.choosesSimulator = simulator == nil
        try await MirrorHost.run(simulator: simulator, secret: secret, settings: settings)
        #else
        throw CLIError(errorDescription: "axe remote needs an Apple silicon Mac.", code: .commandFailed)
        #endif
    }
}

/// `axe remote`: runs the host, for paired devices to choose a simulator and install builds.
struct MirrorStartCommand: AsyncParsableCommand {
    // `axe remote --help` prints this command's help, so it is the help for all of `axe remote`.
    // The name "start" is never needed and is not shown anywhere.
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: MirrorHelp.abstract,
        usage: MirrorHelp.usage,
        discussion: MirrorHelp.discussion,
        shouldDisplay: false
    )

    @OptionGroup var host: MirrorHostOptions

    // Taken and not listed: these belong to `axe remote mirror`, and are here for `axe mirror --udid`.
    @OptionGroup(visibility: .hidden) var simulator: MirrorSimulatorOptions

    var simulatorUDID: String? { simulator.simulatorUDID }
    var relayURL: String? { host.relayURL }
    var demo: Bool { simulator.demo }
    var demoApp: String? { simulator.demoApp }

    func run() async throws {
        let logger = AxeLogger()
        try await setup(logger: logger)
        try await host.run(mirror: simulator, logger: logger)
    }
}

/// `axe remote mirror`: runs the host on one simulator, which its viewers are shown and cannot change.
struct RemoteMirrorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mirror",
        abstract: "Start the host on one booted simulator, shown live in the AXe Mirror app with touch.",
        usage: "axe remote mirror --udid <udid> [--relay-url <relay-url>] [--demo --demo-app <demo-app>]",
        discussion: """
        Paired devices are shown this simulator and no other, and may still install the builds this Mac offers (--no-builds stops that). To let them choose, boot or create a simulator, start the host with axe remote alone.
        """
    )

    @OptionGroup var simulator: MirrorSimulatorOptions

    @OptionGroup var host: MirrorHostOptions

    func validate() throws {
        guard simulator.simulatorUDID != nil else {
            throw ValidationError("axe remote mirror needs --udid: the booted simulator to show. axe remote alone lets the paired device choose one.")
        }
    }

    func run() async throws {
        let logger = AxeLogger()
        try await setup(logger: logger)
        try await host.run(mirror: simulator, logger: logger)
    }
}

/// Pairs one viewer with this Mac. The host does not have to be running, and may be.
struct MirrorPairCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pair",
        abstract: "Show a one-time code for the AXe Mirror app to scan or type, and pair with the device that uses it.",
        discussion: """
        The code works once and for ten minutes. The paired device may connect to this Mac from then on; remove it with axe remote unpair.
        """
    )

    @Option(name: .long, help: "The name the app shows for this Mac. Defaults to the Mac's own name.")
    var name: String?

    @Flag(name: .long, help: "Print JSON lines instead of the QR code: one with the code, one when a device has paired.")
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

    func validate() throws {
        try MirrorHelp.checkRelay(relayURL)
    }

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
                print("Scan this with the AXe Mirror app, or type the code. It works once, for ten minutes.\n")
                for line in MirrorQRCode.lines(for: shown.link) ?? [] { print("  " + line) }
                print("\n  Code: \(MirrorPairingCode.display(shown.code))\n")
                // A relay named here is on no list the app has: only the QR code can tell it where to look.
                if relays.isNamed { print("This Mac is on a relay of its own (\(shown.relay)): scan the QR code. The code typed by hand will not find it.\n") }
                print("Waiting for the device. Press Ctrl+C to cancel.")
            }
        }
        if json {
            MirrorHost.emit(["event": "paired", "viewer": viewer.id, "name": viewer.name])
        } else {
            print("Paired with \(viewer.name).")
        }
        #else
        throw CLIError(errorDescription: "axe remote needs an Apple silicon Mac.", code: .commandFailed)
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
        switch await MirrorPairClient.pair(code: code, name: name, viewerSecret: secret, relays: relays.pairingRelays(public: MirrorPairClient.publicRelays)) {
        case .success(let reply):
            MirrorHost.emit(["event": "paired", "hostId": reply.hostId, "name": reply.name, "homeRelay": reply.homeRelay,
                             "relays": reply.relays.joined(separator: " "), "seconds": String(format: "%.1f", Date().timeIntervalSince(start))])
        case .failure(let failure):
            MirrorHost.emit(["event": "failed", "reason": String(describing: failure), "seconds": String(format: "%.1f", Date().timeIntervalSince(start))])
            throw ExitCode.failure
        }
        #else
        throw CLIError(errorDescription: "axe remote needs an Apple silicon Mac.", code: .commandFailed)
        #endif
    }
}

/// Lists the devices this Mac is paired with.
struct RemoteDevicesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devices",
        abstract: "List the devices paired with this Mac."
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
            // "viewers" is the name this list had in AXe 2.1, and scripts read it.
            let list = viewers.map { ["id": $0.id, "name": $0.name, "paired": dates.string(from: $0.paired)] }
            let data = try JSONSerialization.data(withJSONObject: ["viewers": list], options: [.sortedKeys, .withoutEscapingSlashes])
            print(String(decoding: data, as: UTF8.self))
        } else if viewers.isEmpty {
            print("No devices are paired with this Mac.")
        } else {
            for viewer in viewers { print("\(viewer.name)\t\(dates.string(from: viewer.paired))\t\(viewer.id)") }
        }
    }
}

/// `axe mirror viewers`, the name `axe remote devices` had in AXe 2.1.
struct MirrorViewersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "viewers", abstract: "List the devices paired with this Mac.")

    @OptionGroup var devices: RemoteDevicesCommand

    func run() async throws { try await devices.run() }
}

/// Removes a paired viewer. It can no longer connect, and a running host closes the session it
/// has open within a second.
struct MirrorUnpairCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unpair",
        abstract: "Remove a paired device by its name or ID."
    )

    @Argument(help: "The device's name, its ID, or the first characters of its ID, as shown by axe remote devices.")
    var viewer: String

    @Option(name: .customLong("viewers-file"),
        help: ArgumentHelp("Read the list of paired viewers from this file instead of AXe's own.", visibility: .hidden))
    var viewersFile: String?

    func run() async throws {
        let removed = try MirrorViewers(url: viewersFile.map { URL(fileURLWithPath: $0) } ?? MirrorViewers.defaultURL).remove(matching: viewer)
        guard let gone = removed.first else {
            throw CLIError(errorDescription: "No paired device matches \"\(viewer)\".", code: .commandFailed)
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
/// Runs the mirror host until the command is stopped, printing each event as a JSON line.
enum MirrorHost {
    /// The screen of a booted simulator, for the session to read.
    static func framebuffer(of simulator: FBSimulator) throws -> FBFramebuffer {
        do {
            return try FBFramebuffer.mainScreenSurface(for: simulator, logger: FBControlCoreLoggerFactory.systemLoggerWriting(toStderr: false, withDebugLogging: false))
        } catch {
            throw CLIError(errorDescription: "The simulator's screen could not be read: \(error.localizedDescription)", code: .captureFailed)
        }
    }

    /// The simulator a viewer chose, and its screen. It was booted, or created, a moment ago by
    /// simctl, and this process may hear of that a little later, so the lookup is tried for a few
    /// seconds before its failure is believed.
    static func open(udid: String) async throws -> (FBSimulator, FBFramebuffer) {
        let logger = AxeLogger()
        var attempt = 0
        while true {
            do {
                let simulator = try await DeviceState.bootedSimulator(udid: udid, logger: logger)
                return (simulator, try framebuffer(of: simulator))
            } catch let failure as CLIOutputFailure where ["notBooted", "targetNotFound"].contains(failure.code) && attempt < 20 {
                attempt += 1
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    /// `simulator` is nil on a host that lets its viewers choose one.
    static func run(simulator: FBSimulator?, secret: Data, settings: MirrorSession.Settings) async throws {
        // Each viewer's session reads the screen itself; this only finds out now, and not when the
        // first viewer connects, that it cannot be read.
        _ = try simulator.map { try framebuffer(of: $0) }
        let session = MirrorHostSessions(simulator: simulator, secret: secret, settings: settings)
        session.onEvent = { emit($0) }
        let stop = AsyncStream<Void>.makeStream()
        let fatal = MirrorLastValue()
        session.onFatal = { message in
            _ = fatal.changed(to: [message])
            emit(["event": "error", "message": message])
            stop.continuation.yield()
        }
        // SIGHUP is a closed terminal: the viewer is told the host stopped, rather than finding out
        // half a minute later.
        let observer = SignalObserver(signals: [SIGINT, SIGTERM, SIGHUP]) { stop.continuation.yield() }
        defer { observer.invalidate() }
        session.start()
        for await _ in stop.stream { break }
        for line in session.stop() { mirrorNote(line) }
        emit(["event": "stopped"])
        if let message = fatal.current?.first { throw CLIError(errorDescription: message, code: .commandFailed) }
    }

    /// Prints one event as a line. Events come from several threads, one for each viewer's session
    /// and more, and a line longer than a pipe takes in one piece (512 bytes) could be written in
    /// two, with another thread's line between them: whoever reads the events would then be given
    /// two lines that are not JSON. One line is written at a time.
    static func emit(_ event: [String: String], to output: FileHandle = .standardOutput) {
        guard var line = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        line.append(0x0A)
        emitLock.withLock { try? output.write(contentsOf: line) }
    }
    private static let emitLock = NSLock()
}
#endif

#if AXE_MIRROR
/// A build's description, as the fields of a JSON object. The identifiers of the devices it is
/// signed for are not printed; which of this Mac's devices they are is, by name.
private func fields(of build: MirrorPublishedBuild, known: [MirrorKnownDevices.Device]) throws -> [String: Any] {
    var fields = (try JSONSerialization.jsonObject(with: JSONEncoder().encode(build)) as? [String: Any]) ?? [:]
    fields["devices"] = nil
    if let devices = build.devices, !known.isEmpty {
        let coverage = MirrorKnownDevices.coverage(of: devices, among: known)
        fields["devices_covered"] = coverage.covered
        fields["devices_not_covered"] = coverage.notCovered
    }
    return fields
}

/// What the publishing commands print: one JSON object, or a few lines for a person.
private func report(_ build: MirrorPublishedBuild, store: MirrorBuildStore, json: Bool, extra: [String: String] = [:]) throws {
    let known = MirrorKnownDevices.list()
    if json {
        var fields = try fields(of: build, known: known)
        fields["store"] = store.root.path
        for (key, value) in extra { fields[key] = value }
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: data, as: UTF8.self))
    } else {
        print("Published \(build.name) \(build.versionText), build ID \(build.buildID).")
        print("It is signed for \(build.deviceCount) registered device\(build.deviceCount == 1 ? "" : "s").")
        if let devices = build.devices, !known.isEmpty {
            let coverage = MirrorKnownDevices.coverage(of: devices, among: known)
            if !coverage.covered.isEmpty { print("It will install on: \(coverage.covered.joined(separator: ", ")).") }
            if !coverage.notCovered.isEmpty { print("It will not install on: \(coverage.notCovered.joined(separator: ", ")). Register the device with your developer account, then build with --allow-provisioning-updates.") }
        }
        print("A running axe remote host offers it to paired devices within a few seconds: Apps, on the Mac's menu in the AXe Mirror app.")
    }
}

private func megabytes(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

private func store(at folder: String?) -> MirrorBuildStore {
    let given = folder ?? ProcessInfo.processInfo.environment["AXE_MIRROR_BUILDS"].flatMap { $0.isEmpty ? nil : $0 }
    return given.map { MirrorBuildStore(root: URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)) } ?? .standard
}
#endif

/// Adds a signed IPA to the builds this Mac offers its viewers.
struct MirrorPublishCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "publish",
        abstract: "Offer a signed IPA to paired devices to install.",
        discussion: """
        The IPA must be exported for Ad Hoc (Release Testing) distribution, with the viewer's device in its provisioning profile. It is checked, copied into AXe's store, and offered by a running axe remote host: the AXe Mirror app lists it under Builds, and says so at once when it is connected. The build goes to the app over the connection it is paired on, and iOS installs it from the device itself.
        """
    )

    @Argument(help: "The IPA to publish.")
    var ipa: String

    @Option(name: .long, help: "A line or two for the person installing it: what changed.")
    var notes = ""

    @Option(name: .customLong("device"), help: "Refuse the IPA unless this device's UDID is in its provisioning profile. Repeat for more.")
    var devices: [String] = []

    @Option(name: .customLong("builds"), help: "Publish into this folder instead of AXe's own store. Defaults to AXE_MIRROR_BUILDS.")
    var buildsFolder: String?

    @Flag(name: .long, help: "Print the build as one JSON object.")
    var json = false

    func run() async throws {
        #if AXE_MIRROR
        let store = store(at: buildsFolder)
        let build = try store.publish(ipa: URL(fileURLWithPath: (ipa as NSString).expandingTildeInPath), notes: notes, requiredDevices: devices)
        try report(build, store: store, json: json)
        #else
        throw CLIError(errorDescription: "axe remote needs an Apple silicon Mac.", code: .commandFailed)
        #endif
    }
}

/// Archives an app, exports it for registered devices and publishes it.
struct MirrorBuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Build an app for registered devices and offer it to paired devices to install.",
        discussion: """
        Archives the scheme with xcodebuild, exports it for Ad Hoc (Release Testing) distribution, checks the IPA and publishes it, as axe remote publish does. Signing is the project's own: with automatic signing Xcode uses the team's Ad Hoc profile for the app, which holds the devices registered with the developer account when the profile was made, and --allow-provisioning-updates lets Xcode make it again. The result says which of this Mac's devices the build will install on. The archive and logs are removed once the build is published (--keep-archive keeps them, for the debug symbols); a build that fails keeps them, and says where.
        """
    )

    @Option(name: .long, help: "The Xcode project to build.")
    var project: String?

    @Option(name: .long, help: "The Xcode workspace to build.")
    var workspace: String?

    @Option(name: .long, help: "The scheme to archive.")
    var scheme: String

    @Option(name: .long, help: "The build configuration.")
    var configuration = "Release"

    @Option(name: .customLong("team-id"), help: "The development team to sign with.")
    var teamID: String?

    @Option(name: .customLong("export-options"), help: "An export options plist to use instead of AXe's: its method must be release-testing.")
    var exportOptions: String?

    @Flag(name: .customLong("allow-provisioning-updates"), help: "Let Xcode register devices and create or update provisioning profiles.")
    var allowProvisioningUpdates = false

    @Option(name: .long, help: "A line or two for the person installing it: what changed.")
    var notes = ""

    @Option(name: .customLong("device"), help: "Refuse the build unless this device's UDID is in its provisioning profile. Repeat for more.")
    var devices: [String] = []

    @Option(name: .customLong("builds"), help: "Publish into this folder instead of AXe's own store. Defaults to AXE_MIRROR_BUILDS.")
    var buildsFolder: String?

    @Flag(name: .customLong("keep-archive"), help: "Keep the Xcode archive and the logs after publishing, and print where.")
    var keepArchive = false

    @Flag(name: .long, help: "Print the build as one JSON object.")
    var json = false

    func validate() throws {
        guard (project == nil) != (workspace == nil) else { throw ValidationError("Give --project or --workspace, one of them.") }
    }

    func run() async throws {
        #if AXE_MIRROR
        let store = store(at: buildsFolder)
        // What earlier builds that failed left behind, once it is too old to be worth reading.
        store.clean(olderThan: Date().addingTimeInterval(-MirrorBuildJob.keepFailedFor))
        let job = try MirrorBuildJob(store: store, project: project, workspace: workspace, scheme: scheme, configuration: configuration,
                                     teamID: teamID, exportOptions: exportOptions, allowProvisioningUpdates: allowProvisioningUpdates)
        if !json { mirrorNote("Archiving \(scheme). Logs are in \(job.folder.path)") }
        let ipa = try job.run()
        let build = try store.publish(ipa: ipa, notes: notes, requiredDevices: devices)
        // Published: the store has its own copy of the IPA, and the archive is hundreds of megabytes.
        if keepArchive {
            try job.keep()
            try report(build, store: store, json: json, extra: ["job": job.folder.path])
            if !json { print("The archive and logs are kept in \(job.folder.path) until axe remote builds --clean removes them.") }
        } else {
            job.discard()
            try report(build, store: store, json: json)
        }
        #else
        throw CLIError(errorDescription: "axe remote needs an Apple silicon Mac.", code: .commandFailed)
        #endif
    }
}

/// Lists the builds this Mac offers, and looks after them: removes some, keeps only the newest,
/// corrects notes, and clears what building left behind.
struct MirrorBuildsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "builds",
        abstract: "List the builds this Mac offers paired devices, and manage them.",
        discussion: """
        With no option, lists the builds, newest first. --remove takes one build ID or the start of one, and can be repeated; --keep removes all but the newest few of each app; --notes replaces a build's notes; --clean removes the archives and logs that builds which failed, or were built with --keep-archive, left behind. Removing a build stops it being offered. It does not take it off a device that has installed it: nothing can.
        """
    )

    @Flag(name: .long, help: "Print the result as JSON.")
    var json = false

    @Option(name: .long, help: "Remove the build whose ID starts with this. Repeat for more.")
    var remove: [String] = []

    @Option(name: .long, help: "Keep the newest of each app, this many, and remove the rest.")
    var keep: Int?

    @Option(name: .long, parsing: .upToNextOption, help: "Replace a build's notes: the build's ID, then the notes.")
    var notes: [String] = []

    @Flag(name: .long, help: "Remove the archives and logs that building left behind.")
    var clean = false

    @Option(name: .customLong("builds"), help: "Look in this folder instead of AXe's own store. Defaults to AXE_MIRROR_BUILDS.")
    var buildsFolder: String?

    func validate() throws {
        guard notes.isEmpty || notes.count == 2 else { throw ValidationError("--notes takes the build's ID and the notes: --notes 0a1b \"What changed\".") }
        if let keep, keep < 1 { throw ValidationError("--keep takes a number of builds, 1 or more.") }
    }

    func run() async throws {
        #if AXE_MIRROR
        let store = store(at: buildsFolder)
        var removed: [MirrorPublishedBuild] = []
        if !remove.isEmpty { removed += try store.remove(matching: remove) }
        if let keep { removed += try store.keep(newest: keep) }
        var edited: MirrorPublishedBuild?
        if notes.count == 2 { edited = try store.setNotes(notes[1], matching: notes[0]) }
        let cleaned = clean ? store.clean() : nil
        let builds = store.list()
        let left = store.leftovers()
        if json {
            let known = MirrorKnownDevices.list()
            var result: [String: Any] = ["builds": try builds.map { try fields(of: $0, known: known) }, "store": store.root.path,
                                         "leftovers": ["count": left.count, "bytes": left.bytes]]
            if !remove.isEmpty || keep != nil { result["removed"] = removed.map(\.buildID) }
            if let edited { result["edited"] = edited.buildID }
            if let cleaned { result["cleaned"] = ["count": cleaned.count, "bytes": cleaned.bytes] }
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes])
            print(String(decoding: data, as: UTF8.self))
            return
        }
        for build in removed { print("Removed \(build.name) \(build.versionText), build ID \(build.buildID).") }
        if (!remove.isEmpty || keep != nil), removed.isEmpty { print("Nothing to remove.") }
        if let edited { print("Changed the notes of \(edited.name) \(edited.versionText), build ID \(edited.buildID).") }
        if let cleaned { print(cleaned.count == 0 ? "Nothing was left behind." : "Removed what \(cleaned.count) build\(cleaned.count == 1 ? "" : "s") left behind: \(megabytes(cleaned.bytes)).") }
        if builds.isEmpty {
            print("No builds are published. Publish one with axe remote build or axe remote publish.")
        } else {
            // One line for each build, whatever its notes hold: the first line of them, and that cut short.
            for build in builds {
                let first = build.notes.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                let notes = first.count > 80 ? String(first.prefix(80)) + "…" : first
                print("\(build.name) \(build.versionText)\t\(build.publishedAt)\t\(build.buildID)\(notes.isEmpty ? "" : "\t" + notes)")
            }
        }
        if left.count > 0, cleaned == nil {
            mirrorNote("\(left.count) build folder\(left.count == 1 ? "" : "s") left behind, \(megabytes(left.bytes)). axe remote builds --clean removes them.")
        }
        #else
        throw CLIError(errorDescription: "axe remote needs an Apple silicon Mac.", code: .commandFailed)
        #endif
    }
}
