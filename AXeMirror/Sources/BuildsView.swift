import SwiftUI
import UIKit

/// The app builds the Mac offers to install on this device.
///
/// Install fetches the build from the Mac over the connection this device is on and hands it to
/// iOS from the device itself (`StreamSession.install`). That needs the Mac's certificate installed
/// and trusted, once: until it is, Install opens the setup for it, and the setup offers the build
/// again when it is done.
///
/// When the Mac has builds of one app, the list is that app's builds, newest first. When it has
/// builds of several, the list has one row for each app, however many builds of it there are:
/// tapping an app shows its builds (`AppBuilds`), or its one build, and holding it down offers to
/// install its newest. Tapping a build opens everything about it (`BuildDetail`); holding one down
/// offers Install. Nothing is said about the connection while it works; when the Mac cannot be
/// reached, that is said at the top. That iOS has been handed a build is said in passing
/// (`InstallToast`) and not kept on screen.
///
/// On a Mac's menu the apps are listed on the menu itself (`HubApps`), so `BuildsList` is a
/// screen only over a simulator's picture. Either way a row opens `BuildsPlace`, which on a wide
/// screen is an app's builds with the chosen one beside them.

/// The builds over the picture, for a Mac that shows one simulator and has no menu to go back to.
struct BuildsSheet: View {
    let session: StreamSession
    let macName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            BuildsList(session: session, macName: macName)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }.accessibilityIdentifier("builds.done")
                    }
                }
        }
        .installToast(session)
        .preferredColorScheme(.dark)
    }
}

/// The builds as a screen of their own, over a simulator's picture (`BuildsSheet`): the apps, or
/// the builds of the only app. A row opens what it names (`BuildsPlace`).
struct BuildsList: View {
    let session: StreamSession
    let macName: String
    /// The one-time setup, pushed when Install is tapped before it has been done.
    @State private var showsSetup = false
    @State private var appeared = false
    /// The build a row opened, and the app whose builds one opened, by its bundle ID.
    @State private var shown: MirrorBuild?
    @State private var shownApp: String?

    var body: some View {
        list(BuildApp.group(session.builds))
            .screenColumn()
            .background(Color.black)
            .navigationTitle("Builds")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $shown) { BuildsPlace(session: session, macName: macName, app: nil, build: $0.id) }
            .navigationDestination(item: $shownApp) { BuildsPlace(session: session, macName: macName, app: $0, build: nil) }
            .navigationDestination(isPresented: $showsSetup) { LocalInstallSetup(session: session, macName: macName) }
            .onAppear {
                // Only as the screen opens, for an Install tapped on the notice that led here: coming
                // back from the setup must not push it again.
                guard !appeared else { return }
                appeared = true
                showsSetup = session.pendingInstall != nil
            }
    }

    /// The apps as a list, or the builds of the only app. A row opens the app's builds or the
    /// build. Install is with the build, and behind holding a row down.
    private func list(_ apps: [BuildApp]) -> some View {
        List {
            BuildStatus(session: session, macName: macName, build: nil, inList: true)
            if case .notTrusted = session.localInstall, !session.builds.isEmpty {
                Section {
                    Button { showsSetup = true } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "lock.shield").font(.title3).foregroundStyle(.tint).frame(width: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Set Up Installs").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                Text("Once for \(macName), about a minute.").font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("builds.local.setup")
                }
            }
            if session.builds.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Artwork(scene: .noBuilds, width: 200)
                        Text("No builds yet").font(.title3.weight(.semibold))
                        Text("Builds published on \(macName) with axe mirror build show up here, ready to install.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                }
            } else if apps.count == 1 {
                // One app: nothing to choose between, so its builds are the list.
                Section {
                    ForEach(apps[0].builds) { build in
                        BuildRow(build: build, session: session, picked: nil, install: { install(build) }) { shown = build }
                    }
                } header: {
                    AppHeader(app: apps[0])
                } footer: {
                    Text(route)
                        .accessibilityIdentifier("builds.route")
                }
            } else {
                Section {
                    ForEach(apps) { app in
                        AppRow(app: app, session: session, installLatest: { install(app.newest) }) {
                            if app.builds.count == 1 {
                                shown = app.builds[0]       // nothing to choose between
                            } else {
                                shownApp = app.id
                            }
                        }
                    }
                } footer: {
                    Text(route)
                        .accessibilityIdentifier("builds.route")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.black)
    }

    private func install(_ build: MirrorBuild) {
        session.install(build)
        if session.pendingInstall != nil { showsSetup = true }
    }

    /// How the builds reach this device: said quietly, under the list.
    private var route: String {
        switch session.stats.route {
        case "Direct": return "Sent straight from \(macName) to this device."
        case "": return "Sent from \(macName) over the connection you are on."
        default: return "Sent from \(macName) through a relay, so a large build takes a little longer."
        }
    }
}

/// What has gone wrong, when something has: the Mac is out of reach, or an install failed. With
/// `build`, only what concerns that build. Nothing when all is well.
private struct BuildStatus: View {
    let session: StreamSession
    let macName: String
    let build: MirrorBuild?
    /// In a list each card is a section of it; elsewhere each is a card of its own.
    let inList: Bool
    /// False where the screen says for itself that the Mac is out of reach.
    var offline = true

    @ViewBuilder
    private func place(@ViewBuilder _ content: () -> some View) -> some View {
        if inList {
            Section { content() }
        } else {
            content()
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    var body: some View {
        if offline, session.state != .connected {
            place {
                card(icon: "wifi.slash", tint: .orange, title: "Not connected to \(macName)",
                     message: "Builds install again once the connection is back.")
                    .accessibilityIdentifier("builds.offline")
            }
        }
        if let problem = session.installProblem, build == nil || build?.id == problem.build.id {
            place {
                VStack(alignment: .leading, spacing: 10) {
                    card(icon: "exclamationmark.triangle.fill", tint: .orange, title: problem.title, message: problem.message)
                    HStack(spacing: 8) {
                        Button("Try Again") { session.install(problem.build) }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("builds.problem.retry")
                        Button("Dismiss") { session.installProblem = nil }.buttonStyle(.bordered)
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 2)
                // Its own element with the buttons inside it: an identifier on a plain stack is given to them all.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("builds.problem")
            }
        }
    }

    private func card(icon: String, tint: Color, title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(tint).frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(message).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Said in passing when iOS has been handed a build: a line at the foot of the screen that goes
/// by itself. iOS asks the person whether to install and tells this app nothing of the answer, so
/// a note that stayed would go on saying "installing" after they had said no.
private struct InstallToast: View {
    let session: StreamSession

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if let build = session.installStarted {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.app.fill").font(.title3).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(build.name) \(build.versionText)").font(.footnote.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                        Text(StreamSession.isThisApp(build) ? "Confirm when iOS asks. AXe Mirror closes while it updates." : "Confirm when iOS asks.")
                            .font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.18)))
                .frame(maxWidth: 420)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("builds.started")
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.25), value: session.installStarted?.id)
    }
}

extension View {
    /// Says in passing, at the foot of this view, that iOS has been handed a build.
    func installToast(_ session: StreamSession) -> some View {
        overlay { InstallToast(session: session) }
    }
}

/// The Mac's apps on its menu, under the Apps door: what `BuildsList` lists, without a screen of
/// its own to go to first. With builds of one app they are that app's builds; with builds of
/// several, a row for each app. A row opens what it names, and held down it installs.
struct HubApps: View {
    let session: StreamSession
    let macName: String
    @Binding var path: [HubPlace]

    var body: some View {
        let apps = BuildApp.group(session.builds)
        VStack(spacing: 10) {
            // The menu says for itself when the Mac is out of reach.
            BuildStatus(session: session, macName: macName, build: nil, inList: false, offline: false)
            VStack(spacing: 0) {
                if case .notTrusted = session.localInstall, !apps.isEmpty {
                    Button { path.append(.setup) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "lock.shield").font(.title3).foregroundStyle(.tint).frame(width: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Set Up Installs").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                Text("Once, about a minute.").font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("builds.local.setup")
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    line
                }
                if apps.isEmpty {
                    Text("No builds yet. Builds published on \(macName) with axe mirror build show up here.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .accessibilityIdentifier("builds.none")
                } else if apps.count == 1 {
                    // One app: nothing to choose between, so its builds are listed.
                    AppHeader(app: apps[0])
                        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 2)
                    ForEach(apps[0].builds) { build in
                        if build.id != apps[0].builds.first?.id { line }
                        BuildRow(build: build, session: session, picked: nil, install: { install(build) }) { path.append(.build(build.id)) }
                            .padding(.horizontal, 16).padding(.vertical, 6)
                    }
                } else {
                    ForEach(apps) { app in
                        if app.id != apps.first?.id { line }
                        AppRow(app: app, session: session, installLatest: { install(app.newest) }) {
                            // An app with one build has nothing to choose between.
                            path.append(app.builds.count == 1 ? .build(app.builds[0].id) : .app(app.id))
                        }
                        .padding(.horizontal, 16).padding(.vertical, 6)
                    }
                }
            }
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    private var line: some View {
        Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 16)
    }

    private func install(_ build: MirrorBuild) {
        session.install(build)
        if session.pendingInstall != nil { path.append(.setup) }
    }
}

/// What a row of apps or builds opens: an app's builds, or one build.
///
/// Where the screen has the width, it is the app's builds down one side, each with the start of
/// its notes, and everything about the chosen one beside them: the build that was asked for, or
/// the newest. Where it has not, it is the build alone, or the app's builds as a list that opens
/// each (`AppBuilds`).
struct BuildsPlace: View {
    let session: StreamSession
    let macName: String
    /// The app, by its bundle ID, when it is an app's builds that were asked for.
    let app: String?
    /// The build, by its ID, when it is one build.
    let build: String?
    /// Beside the list: the build chosen from it.
    @State private var chosen: String?
    @State private var showsSetup = false

    var body: some View {
        let asked = build.flatMap { id in session.builds.first { $0.id == id } }
        let bundleID = app ?? asked?.bundleID
        let builds = session.builds.filter { $0.bundleID == bundleID }
        let current = builds.first { $0.id == chosen } ?? asked ?? builds.first
        Group {
            if let current {
                SideBySide {
                    // A card of rows and not a list, so that its top is where the build's is:
                    // the two stand side by side, the same distance from everything around them.
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(builds) { build in
                                if build.id != builds.first?.id { Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 16) }
                                BuildRow(build: build, session: session, picked: build.id == current.id, install: {
                                    // What comes of it is said with the build, so the build is shown.
                                    chosen = build.id
                                    install(build)
                                }) {
                                    withAnimation(.easeOut(duration: 0.2)) { chosen = build.id }
                                }
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .background(build.id == current.id ? Color.accentColor.opacity(0.26) : Color.clear)
                            }
                        }
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                        .padding(.leading, Self.edge)
                        .padding(.trailing, Self.gap / 2)
                        .padding(.vertical, Self.edge)
                    }
                } main: {
                    BuildPane(build: current, session: session, macName: macName) { install(current) }
                        // No wider than reads well, in the middle of the room it has.
                        .frame(maxWidth: 640)
                        .frame(maxWidth: .infinity)
                        .padding(.leading, Self.gap / 2)
                        .padding(.trailing, Self.edge)
                        .padding(.vertical, Self.edge)
                } narrow: {
                    if let asked {
                        BuildDetail(build: asked, session: session, macName: macName)
                    } else {
                        AppBuilds(bundleID: bundleID ?? "", session: session, macName: macName)
                    }
                }
            } else {
                Text("\(macName) no longer has that build.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black)
        // No title of its own: side by side, the build says which app it is, and the narrow
        // screens bring their own.
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showsSetup) { LocalInstallSetup(session: session, macName: macName) }
    }

    /// Side by side: the room between the pair and the screen's edges, and between the two.
    private static let edge: CGFloat = 16
    private static let gap: CGFloat = 16

    private func install(_ build: MirrorBuild) {
        session.install(build)
        if session.pendingInstall != nil { showsSetup = true }
    }
}

/// An app the Mac has builds of, with them newest first.
struct BuildApp: Identifiable, Equatable {
    /// The app's bundle ID.
    let id: String
    let builds: [MirrorBuild]
    var newest: MirrorBuild { builds[0] }

    /// The builds by app, each app's newest first, and the apps in the order of their newest build.
    /// `builds` comes newest first from the Mac.
    static func group(_ builds: [MirrorBuild]) -> [BuildApp] {
        var order: [String] = []
        var byApp: [String: [MirrorBuild]] = [:]
        for build in builds {
            if byApp[build.bundleID] == nil { order.append(build.bundleID) }
            byApp[build.bundleID, default: []].append(build)
        }
        return order.map { BuildApp(id: $0, builds: byApp[$0] ?? []) }
    }
}

/// The only app's name over its builds, when the list is one app's builds.
private struct AppHeader: View {
    let app: BuildApp

    var body: some View {
        HStack(spacing: 8) {
            BuildIcon(build: app.newest, size: 24)
            Text(app.newest.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
            Spacer(minLength: 4)
            Text(app.builds.count == 1 ? "1 build" : "\(app.builds.count) builds").font(.footnote).foregroundStyle(.secondary)
        }
        .textCase(nil)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("builds.app.header")
    }
}

/// An app's place in the list: its name, its newest build and how many there are. It opens the
/// app's builds, and says so with a chevron. Held down, it offers to install the app's newest
/// build without opening anything.
private struct AppRow: View {
    let app: BuildApp
    let session: StreamSession
    let installLatest: () -> Void
    let open: () -> Void

    var body: some View {
        let newest = app.newest
        let update: MirrorBuild? = app.builds.first(where: StreamSession.updatesThisApp)
        let facts: String = BuildFacts.line(for: newest, size: false)
        let coming: Double? = Self.share(of: session.fetching, in: app)
        Button(action: open) {
            HStack(alignment: .center, spacing: 12) {
                BuildIcon(build: newest, size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(newest.name).font(.body.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                        if let update { BuildBadge(build: update) }
                    }
                    Text(facts).font(.footnote).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let coming {
                    // One of its builds is on its way from the Mac.
                    ProgressView(value: coming).progressViewStyle(.circular)
                }
                if app.builds.count > 1 {
                    Text("\(app.builds.count)")
                        .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.white.opacity(0.1), in: Capsule())
                        .accessibilityLabel("\(app.builds.count) builds")
                }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .contextMenu {
            Button(action: installLatest) {
                Text("Install Latest Build")
                Text(newest.versionText)
                Image(systemName: "arrow.down.app")
            }
            .disabled(session.fetching != nil || session.state != .connected)
        }
        .accessibilityLabel(app.builds.count == 1 ? "\(newest.name) \(newest.versionText)" : "\(newest.name), \(app.builds.count) builds")
        .accessibilityHint(app.builds.count == 1 ? "Shows this build, with Install" : "Shows this app's builds")
        .accessibilityIdentifier("builds.app.\(app.id)")
    }

    /// How much of one of the app's builds has come from the Mac, when one is coming.
    private static func share(of fetching: (id: String, received: Int, size: Int)?, in app: BuildApp) -> Double? {
        guard let fetching, app.builds.contains(where: { $0.id == fetching.id }) else { return nil }
        return fetching.size > 0 ? min(1, Double(fetching.received) / Double(fetching.size)) : 0
    }
}

/// One app's builds, newest first: behind the app's row on a narrow screen.
struct AppBuilds: View {
    let bundleID: String
    let session: StreamSession
    let macName: String
    @State private var shown: MirrorBuild?
    @State private var showsSetup = false

    var body: some View {
        let builds = session.builds.filter { $0.bundleID == bundleID }
        List {
            BuildStatus(session: session, macName: macName, build: nil, inList: true)
            if builds.isEmpty {
                Section { Text("\(macName) no longer has builds of this app.").foregroundStyle(.secondary) }
            } else {
                Section {
                    ForEach(builds) { build in
                        BuildRow(build: build, session: session, picked: nil, install: {
                            session.install(build)
                            if session.pendingInstall != nil { showsSetup = true }
                        }) { shown = build }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .screenColumn()
        .background(Color.black)
        .navigationTitle(builds.first?.name ?? "Builds")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $shown) { BuildDetail(build: $0, session: session, macName: macName) }
        .navigationDestination(isPresented: $showsSetup) { LocalInstallSetup(session: session, macName: macName) }
    }
}

/// A build's place in its app's list: its version, age and size, and the start of its notes. The
/// whole row opens the build, where Install is: one thing to tap, and the chevron says what it does.
/// Held down, it offers Install. Beside the build on a wide screen it chooses the build shown
/// there. The one shown is marked, and says nothing of its notes: they are beside it in full.
private struct BuildRow: View {
    let build: MirrorBuild
    let session: StreamSession
    /// Nil on a narrow screen; on a wide one, whether this is the build shown.
    let picked: Bool?
    let install: () -> Void
    let show: () -> Void

    var body: some View {
        let narrow = picked == nil
        let facts: String = BuildFacts.line(for: build, version: false)
        let notes: String? = picked == true ? nil : build.notes
        let coming: Double? = Self.share(of: session.fetching, for: build)
        let busy: Bool = session.fetching != nil || session.state != .connected
        Button(action: show) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(build.versionText).font(.body.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                        BuildBadge(build: build)
                    }
                    Text(facts).font(.footnote).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
                    if let notes {
                        Text(notes).font(.footnote).foregroundStyle(.tertiary).lineLimit(2).multilineTextAlignment(.leading).padding(.top, 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let coming {
                    // On its way from the Mac.
                    ProgressView(value: coming)
                        .progressViewStyle(.circular)
                        .accessibilityIdentifier("builds.fetching")
                }
                if narrow {
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .contextMenu {
            Button(action: install) { Label("Install", systemImage: "arrow.down.app") }
                .disabled(busy)
        }
        .accessibilityLabel("\(build.name) \(build.versionText)")
        .accessibilityHint("Shows this build, with Install")
        .accessibilityAddTraits(picked == true ? .isSelected : [])
        .accessibilityIdentifier("builds.row.\(build.id)")
    }

    /// How much of this build has come from the Mac, when it is the one coming.
    private static func share(of fetching: (id: String, received: Int, size: Int)?, for build: MirrorBuild) -> Double? {
        guard let fetching, fetching.id == build.id else { return nil }
        return fetching.size > 0 ? min(1, Double(fetching.received) / Double(fetching.size)) : 0
    }
}

/// Everything about one build, beside the list on a wide screen: what it is and Install in one
/// line across the top, its notes at a width that reads well, and its facts as a grid of small
/// tiles. The same content as `BuildDetail`, laid out for the room.
private struct BuildPane: View {
    let build: MirrorBuild
    let session: StreamSession
    let macName: String
    let install: () -> Void
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center, spacing: 16) {
                    BuildIcon(build: build, size: 76)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(build.name).font(.title2.weight(.bold)).lineLimit(2).minimumScaleFactor(0.8)
                        // Whether it is the build installed is said on its row, beside this.
                        Text("Version \(build.versionText)").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    InstallControl(build: build, session: session, style: .pane, install: install)
                }
                BuildStatus(session: session, macName: macName, build: build, inList: false)
                VStack(alignment: .leading, spacing: 8) {
                    Text("What’s New").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    if let notes = build.notes {
                        Text(notes).font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("builds.detail.notes")
                    } else {
                        Text("No notes were published with this build.").foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Details").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                        if let published = build.published {
                            tile("Published", Date(timeIntervalSince1970: published).formatted(date: .abbreviated, time: .shortened))
                        }
                        if let size = build.size { tile("Size", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
                        if let minimumOS = build.minimumOS { tile("Requires", "iOS \(minimumOS) or later") }
                        if let expires = build.expires {
                            tile("Installable until", Date(timeIntervalSince1970: expires).formatted(date: .abbreviated, time: .omitted))
                        }
                        if let devices = build.devices { tile("Signed for", devices == 1 ? "1 device" : "\(devices) devices") }
                        tile("Bundle ID", build.bundleID)
                        Button {
                            UIPasteboard.general.string = build.id
                            copied = true
                        } label: {
                            tile(copied ? "Build ID copied" : "Build ID · tap to copy", build.id, monospaced: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(26)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .onChange(of: build.id) { copied = false }
        .accessibilityIdentifier("builds.detail")
    }

    private func tile(_ name: String, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(monospaced ? .footnote.monospaced() : .subheadline.weight(.medium)).lineLimit(1).truncationMode(.middle).minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Install, or how far the build has come from the Mac.
private struct InstallControl: View {
    /// Across the top of a build's own screen, or at its own width in the pane.
    enum Style { case banner, pane }

    let build: MirrorBuild
    let session: StreamSession
    let style: Style
    let install: () -> Void

    var body: some View {
        if let fetching = session.fetching, fetching.id == build.id {
            let share = fetching.size > 0 ? min(1, Double(fetching.received) / Double(fetching.size)) : 0
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: share)
                Text("Fetching · \(Int((share * 100).rounded()))%").font(.footnote).foregroundStyle(.secondary)
            }
            .frame(width: style == .pane ? 150 : nil)
            .accessibilityIdentifier("builds.fetching")
        } else {
            Button(action: install) {
                Text("Install")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, style == .pane ? 18 : 0)
                    .frame(maxWidth: style == .banner ? .infinity : nil)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(style == .banner ? .roundedRectangle(radius: 14) : .capsule)
            .controlSize(.large)
            // Its own width whatever is beside it: a long name must not squeeze the word in two.
            .fixedSize(horizontal: style != .banner, vertical: false)
            .disabled(session.fetching != nil || session.state != .connected)
            .accessibilityLabel("Install \(build.name) \(build.versionText)")
            .accessibilityIdentifier("builds.detail.install")
        }
    }
}

/// Everything about one build: what it is, its notes in full, and the facts that tell one build
/// from another, with Install at the top.
struct BuildDetail: View {
    let build: MirrorBuild
    let session: StreamSession
    let macName: String
    @State private var showsSetup = false
    @State private var copied = false

    var body: some View {
        List {
            Section {
                VStack(spacing: 14) {
                    BuildIcon(build: build, size: 84)
                    VStack(spacing: 4) {
                        Text(build.name).font(.title2.weight(.bold)).multilineTextAlignment(.center)
                        HStack(spacing: 6) {
                            Text("Version \(build.versionText)").font(.subheadline).foregroundStyle(.secondary)
                            BuildBadge(build: build)
                        }
                    }
                    InstallControl(build: build, session: session, style: .banner) {
                        session.install(build)
                        if session.pendingInstall != nil { showsSetup = true }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
            }
            BuildStatus(session: session, macName: macName, build: build, inList: true)
            Section("What’s New") {
                if let notes = build.notes {
                    Text(notes).font(.body).textSelection(.enabled)
                        .accessibilityIdentifier("builds.detail.notes")
                } else {
                    Text("No notes were published with this build.").foregroundStyle(.secondary)
                }
            }
            Section("Details") {
                fact("Version", build.version)
                if !build.build.isEmpty { fact("Build", build.build) }
                if let published = build.published {
                    fact("Published", Date(timeIntervalSince1970: published).formatted(date: .abbreviated, time: .shortened))
                }
                if let size = build.size { fact("Size", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
                if let minimumOS = build.minimumOS { fact("Requires", "iOS \(minimumOS) or later") }
                if let expires = build.expires {
                    fact("Installable until", Date(timeIntervalSince1970: expires).formatted(date: .abbreviated, time: .omitted))
                }
                if let devices = build.devices { fact("Signed for", devices == 1 ? "1 device" : "\(devices) devices") }
                fact("From", macName)
            }
            Section {
                fact("Bundle ID", build.bundleID)
                Button {
                    UIPasteboard.general.string = build.id
                    copied = true
                } label: {
                    LabeledContent(copied ? "Build ID copied" : "Build ID") {
                        Text(build.id).font(.footnote.monospaced()).lineLimit(1).truncationMode(.middle)
                    }
                }
                .foregroundStyle(.primary)
            } footer: {
                Text("The build ID is what axe mirror builds lists on the Mac. Tap it to copy.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .screenColumn()
        .background(Color.black)
        .navigationTitle(build.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showsSetup) { LocalInstallSetup(session: session, macName: macName) }
        .accessibilityIdentifier("builds.detail")
    }

    private func fact(_ name: String, _ value: String) -> some View {
        LabeledContent(name) { Text(value).multilineTextAlignment(.trailing).textSelection(.enabled) }
    }
}

/// The facts a row has room for: "1.2 (7) · 5 minutes ago · 8.7 MB".
private enum BuildFacts {
    static func line(for build: MirrorBuild, version: Bool = true, size: Bool = true) -> String {
        var parts = version ? [build.versionText] : []
        if let published = build.published {
            parts.append(Date(timeIntervalSince1970: published).formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
        }
        if size, let bytes = build.size { parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) }
        return parts.joined(separator: " · ")
    }
}

/// For a build of this app: whether it is the one running, or newer.
private struct BuildBadge: View {
    let build: MirrorBuild

    var body: some View {
        if StreamSession.isThisApp(build) {
            if StreamSession.updatesThisApp(build) {
                badge("UPDATE", .green)
            } else if Int(build.build) == StreamSession.ownBuild {
                badge("INSTALLED", .gray)
            }
        }
    }

    private func badge(_ text: String, _ colour: Color) -> some View {
        Text(text).font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2)
            .background(colour.opacity(0.25), in: Capsule()).foregroundStyle(colour)
    }
}

/// A tile standing for the app: its first letter on a colour of its own, the same for every build
/// of the same app. The Mac does not send the app's icon.
private struct BuildIcon: View {
    let build: MirrorBuild
    let size: CGFloat

    private static let colours: [Color] = [.blue, .indigo, .purple, .pink, .orange, .teal, .green, .cyan]

    var body: some View {
        let colour = Self.colours[build.bundleID.unicodeScalars.reduce(0) { ($0 &+ Int($1.value)) % 9973 } % Self.colours.count]
        Text(String(build.name.first ?? "?").uppercased())
            .font(.system(size: size * 0.48, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(colour.gradient, in: RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// One line over the picture or the list: a build is ready, with Install and a way to see them all.
struct BuildNotice: View {
    let build: MirrorBuild
    let session: StreamSession
    let showAll: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.app.fill").foregroundStyle(.tint)
            Button(action: showAll) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(StreamSession.updatesThisApp(build) ? "Update ready" : "Build ready").font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                    Text("\(build.name) \(build.versionText)").font(.footnote.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("builds.notice.open")
            Spacer(minLength: 4)
            Button("Install") {
                session.install(build)
                showAll()       // what happens next is said there, or the setup opens there
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier("builds.notice.install")
            Button { session.announcedBuild = nil } label: {
                Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.7)).frame(width: 28, height: 28)
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 7)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.18)))
        .frame(maxWidth: 420)
        .padding(.horizontal, 12)
        // Its own element with the buttons inside it: an identifier on a plain stack is given to them all.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("builds.notice")
    }
}

/// The one-time setup that lets iOS install builds from this device: installing the certificate
/// the Mac made and switching it on. iOS gives no way to do either for the person, so this says
/// exactly where to tap, and checks by itself each time they come back.
struct LocalInstallSetup: View {
    let session: StreamSession
    let macName: String
    @Environment(\.dismiss) private var dismiss
    /// The steps as a video, which floats over Safari and Settings while the person follows them.
    @StateObject private var tutorial = TutorialPlayer(resource: "trust-tutorial")

    private var ready: Bool {
        if case .ready = session.localInstall { return true }
        return false
    }

    var body: some View {
        GeometryReader { proxy in
            if ScreenBalance(proxy).wide {
                wide(proxy)
            } else {
                narrow
                    .screenColumn()
                    .background(Color(uiColor: .systemGroupedBackground))
            }
        }
        .background(Color.black)
        .navigationTitle("Set Up Installs")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            session.checkLocalInstall()
            if !ready { tutorial.play() }
        }
        .onDisappear {
            tutorial.stop()
            session.pendingInstall = nil
        }
        .onChange(of: ready) { _, now in
            if now { tutorial.stop() }
        }
    }

    private var video: some View {
        TutorialVideo(tutorial: tutorial)
            .aspectRatio(tutorial.aspect, contentMode: .fit)
            // An element of its own, whatever the player's view offers.
            .accessibilityElement()
            .accessibilityLabel("A video of the steps")
            .accessibilityIdentifier("local.setup.video")
    }

    private func open() {
        tutorial.play()     // playing in view, so iOS floats it when this app is left
        session.installAuthority()
    }

    /// Installs the build that was asked for, now that it can be, or just goes back.
    private func finish() {
        let wanted = session.pendingInstall
        dismiss()
        if let wanted { session.install(wanted) }
    }

    private var finishTitle: String { session.pendingInstall.map { "Install \($0.name) \($0.versionText)" } ?? "Done" }

    private var explanation: String {
        "A one-time setup, so builds from \(macName) can be installed on this device."
    }

    private static let steps: [(title: String, detail: String)] = [
        ("Download it", "In Safari, tap Allow, then Close."),
        ("Install it", "Settings › Profile Downloaded › Install."),
        ("Switch it on", "Settings › General › About › Certificate Trust Settings."),
    ]

    /// A wide screen: the video stands at one side, as tall as the screen allows, and what to do
    /// is beside it at a width that reads well. Nothing runs the width of the screen.
    private func wide(_ proxy: GeometryProxy) -> some View {
        let balance = ScreenBalance(proxy)
        let column = VStack(alignment: .leading, spacing: 16) {
            if ready {
                Label("Ready", systemImage: "checkmark.seal.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.green)
                    .accessibilityIdentifier("local.setup.ready")
                Text("Installs are set up").font(.title.weight(.bold))
                Button(action: finish) { Text(finishTitle).font(.body.weight(.semibold)).padding(.horizontal, 10) }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
                    .accessibilityIdentifier("local.setup.done")
            } else {
                HStack(spacing: 14) {
                    Label("Not set up yet", systemImage: "hourglass").font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                    Button("Check Again") { session.checkLocalInstall() }
                        .font(.subheadline)
                        .accessibilityIdentifier("local.setup.check")
                }
                if let hint = session.setupHint {
                    Label(hint, systemImage: "wifi.exclamationmark").font(.footnote).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("local.setup.hint")
                }
                Text("Set up installs, once").font(.title.weight(.bold))
                Text(explanation)
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(action: open) { Text("Open the Certificate in Safari").font(.body.weight(.semibold)).padding(.horizontal, 10) }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
                    .accessibilityIdentifier("local.setup.open")
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(index + 1)").font(.footnote.weight(.bold)).foregroundStyle(.white)
                                .frame(width: 24, height: 24).background(Color.accentColor, in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.title).font(.subheadline.weight(.semibold))
                                Text(index == 2 ? step.detail + " Switch on “\(session.installAuthorityName)”." : step.detail)
                                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(.top, 4)
                Label("Works only for installs on this device", systemImage: "lock.fill")
                    .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 370, alignment: .leading)
        return HStack(alignment: .center, spacing: 40) {
            if ready {
                Artwork(scene: .ready, width: 280)
            } else if tutorial.available {
                video
                    // As tall as the screen allows, and no wider than leaves the steps their room.
                    .frame(maxWidth: max(180, proxy.size.width - 370 - 40 - 48), maxHeight: min(proxy.size.height - 36, 600))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            // Centred beside the video when it fits, as it does unless the type is very large.
            ViewThatFits(in: .vertical) {
                column
                ScrollView { column }
            }
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.leading, balance.leading)
        .padding(.trailing, balance.trailing)
    }

    private var narrow: some View {
        List {
            // First, so it is in view the moment the person comes back from Settings.
            Section {
                if ready {
                    Label("Ready to install", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        .accessibilityIdentifier("local.setup.ready")
                    Button(finishTitle, action: finish)
                        .font(.body.weight(.semibold))
                        .accessibilityIdentifier("local.setup.done")
                } else {
                    HStack {
                        Label("Not set up yet", systemImage: "hourglass").foregroundStyle(.orange)
                        Spacer()
                        Button("Check Again") { session.checkLocalInstall() }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("local.setup.check")
                    }
                    if let hint = session.setupHint {
                        Label(hint, systemImage: "wifi.exclamationmark").font(.footnote).foregroundStyle(.orange)
                            .accessibilityIdentifier("local.setup.hint")
                    }
                }
            }
            if !ready {
                // The video and the button that starts it all, both in view without scrolling.
                Section {
                    if tutorial.available {
                        video
                            .frame(maxHeight: 360)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    }
                    Button(action: open) {
                        Text("Open the Certificate in Safari").font(.body.weight(.semibold)).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    .accessibilityIdentifier("local.setup.open")
                } footer: {
                    Text(tutorial.available ? "The video follows you into Safari and Settings." : "")
                }
            }
            Section {
                Text(explanation).font(.subheadline)
            }
            Section("1 · Download it") {
                Text(Self.steps[0].detail).font(.subheadline)
            }
            Section("2 · Install it") {
                Text(Self.steps[1].detail).font(.subheadline)
            }
            Section("3 · Switch it on") {
                Text("Settings › General › About › Certificate Trust Settings. Switch on “\(session.installAuthorityName)”.").font(.subheadline)
            }
            // Said once, in a few words. Explaining how it is safe makes people wonder whether it is.
            Section {
                Label("Works only for installs on this device", systemImage: "lock.fill")
                    .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
        }
    }
}
