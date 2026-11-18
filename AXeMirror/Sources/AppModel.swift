import Foundation
import IrohLib
import Observation
import Security
import UIKit

/// A Mac this device has been paired with.
struct PairedHost: Codable, Identifiable, Equatable {
    var id: String              // the Mac's iroh endpoint ID
    var name: String
    var homeRelay: String       // where the Mac listened when it was paired; empty for iroh's public relays
    var relays: [String]
    var paired: Date
}

/// What a stream connects to: one of the user's Macs, or the public demo.
struct StreamDestination: Identifiable, Equatable {
    var id: String { target.hostID }
    var title: String
    var target: MirrorClient.Target
    var isDemo: Bool
}

/// The app's state: this device's identity, the Macs it is paired with, and the settings read from
/// DNS when the app starts (the relay list and the configuration record).
@MainActor
@Observable
final class AppModel {
    private(set) var hosts: [PairedHost] = []
    private(set) var config = MirrorConfig.builtIn
    /// Our relays in order of preference; empty means iroh's public relays.
    private(set) var relays: [String] = MirrorRelays.builtIn.own
    private(set) var settingsLoaded = false

    let identity: Data
    let build = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    /// True when the published settings say this build is too old to connect.
    var needsUpdate: Bool { config.minimumBuild > build }

    var demo: StreamDestination? {
        guard let host = config.demoHost else { return nil }
        let candidates = ([config.demoRelay].compactMap { $0 } + relays + Self.publicRelays).uniqued()
        return StreamDestination(title: "Demo simulator", target: .init(hostID: host, relays: candidates), isDemo: true)
    }

    private static let publicRelays = RelayMode.defaultMode().relayMap().urls()
    private let store: URL

    init() {
        identity = Identity.load()
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = folder.appendingPathComponent("hosts.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: store), let saved = try? decoder.decode([PairedHost].self, from: data) { hosts = saved }
        applyLaunchArguments()
    }

    /// Reads the relay list and the configuration record. Both fall back to built-in values, so the
    /// app works when DNS does not.
    func loadSettings() async {
        guard !settingsLoaded || config == .builtIn else { return }
        let seed = MirrorRelays.seed(for: identity)
        async let chosen = MirrorRelays.choose(explicit: nil, seed: seed)
        async let published = Task.detached { MirrorConfig.load() }.value
        let (choice, loaded) = await (chosen, published)
        relays = choice.relays
        if overrides.config == nil { config = loaded }
        settingsLoaded = true
    }

    func destination(for host: PairedHost) -> StreamDestination {
        let candidates = ([host.homeRelay].filter { !$0.isEmpty } + host.relays + relays + Self.publicRelays).uniqued()
        return StreamDestination(title: host.name, target: .init(hostID: host.id, relays: candidates), isDemo: false)
    }

    enum PairFailure: Error, Equatable { case badCode, notFound, refused, badReply }

    /// Presents a typed code or a scanned link to the Mac showing it, and stores the Mac on success.
    func pair(code: String) async -> Result<PairedHost, PairFailure> {
        await loadSettings()
        let name = UIDevice.current.name
        let result = await MirrorPairClient.pair(code: code, name: name, viewerSecret: identity, relays: relays)
        switch result {
        case .success(let reply):
            let host = PairedHost(id: reply.hostId, name: reply.name, homeRelay: reply.homeRelay, relays: reply.relays, paired: Date())
            hosts.removeAll { $0.id == host.id }
            hosts.append(host)
            save()
            return .success(host)
        case .failure(.badCode): return .failure(.badCode)
        case .failure(.notFound): return .failure(.notFound)
        case .failure(.refused): return .failure(.refused)
        case .failure(.badReply): return .failure(.badReply)
        }
    }

    func remove(_ host: PairedHost) {
        hosts.removeAll { $0.id == host.id }
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(hosts) else { return }
        try? data.write(to: store, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: Launch arguments, for screenshots and tests

    private struct Overrides { var config: MirrorConfig? }
    private var overrides = Overrides()

    /// `-MirrorDemoHost <id>` and `-MirrorDemoRelay <url>` stand in for the published demo host, and
    /// `-MirrorSampleHosts YES` fills the list with example Macs. None of these is used in normal runs.
    private func applyLaunchArguments() {
        let defaults = UserDefaults.standard
        if let host = defaults.string(forKey: "MirrorDemoHost"), !host.isEmpty {
            var forced = MirrorConfig()
            forced.demoHost = host
            forced.demoRelay = defaults.string(forKey: "MirrorDemoRelay")
            overrides.config = forced
            config = forced
        }
        if defaults.bool(forKey: "MirrorSampleHosts") {
            hosts = [
                PairedHost(id: String(repeating: "a", count: 64), name: "Studio MacBook Pro", homeRelay: "", relays: [], paired: Date(timeIntervalSinceNow: -86_400 * 3)),
                PairedHost(id: String(repeating: "b", count: 64), name: "Office Mac mini", homeRelay: "", relays: [], paired: Date(timeIntervalSinceNow: -86_400 * 20)),
            ]
        }
    }
}

/// This device's lasting identity: 32 random bytes in the Keychain, readable only on this device.
/// The public half is the ID a Mac stores when it is paired with this device.
enum Identity {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.cameroncooke.axemirror.identity",
        kSecAttrAccount as String: "viewer-key",
    ]

    static func load() -> Data {
        var lookup = query
        lookup[kSecReturnData as String] = true
        var found: CFTypeRef?
        if SecItemCopyMatching(lookup as CFDictionary, &found) == errSecSuccess, let data = found as? Data, data.count == 32 { return data }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let key = Data(bytes)
        var item = query
        item[kSecValueData as String] = key
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemDelete(query as CFDictionary)
        SecItemAdd(item as CFDictionary, nil)
        return key
    }
}

extension Array where Element: Hashable {
    /// The elements in order, each once.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
