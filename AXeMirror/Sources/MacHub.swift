import SwiftUI

/// Where a person can go on a Mac they have connected to.
enum HubPlace: Hashable {
    case simulators
    /// Every simulator on the Mac, one row away from the Simulators screen.
    case allSimulators
    /// An app's builds, by its bundle ID.
    case app(String)
    /// One build, by its ID.
    case build(String)
    /// The one-time setup that lets this device install builds.
    case setup
}

/// The first screen on a Mac that lets its viewer choose: what the Mac offers, Simulators and
/// Apps, under the Mac's name and how this device reaches it.
///
/// Where the screen has the width (an unfolded iPhone Duo or an iPad held sideways), the two are
/// down one side and what the chosen one holds is beside them: the Mac's simulators, or its apps.
/// Nothing unfolds and nothing moves. An app opens on a screen of its own (`BuildsPlace`).
///
/// Where it has not, Simulators is a door to a screen of its own, and Apps is a heading: tapping
/// it brings the Mac's apps out under it and folds them away again. They are folded away to begin
/// with.
struct MacHub: View {
    let session: StreamSession
    let macName: String
    @Binding var path: [HubPlace]
    /// Leaves this Mac.
    let close: () -> Void
    /// Whether the apps are shown: under their heading on a narrow screen, or as what is beside
    /// the menu on a wide one, where Simulators is shown otherwise. Kept from one visit to the next.
    @AppStorage(MacHub.appsOpenKey) private var appsOpen = false
    static let appsOpenKey = "hub.apps.open"

    var body: some View {
        NavigationStack(path: $path) {
            SideBySide {
                ScrollView {
                    VStack(spacing: 14) {
                        header
                            .padding(.top, 8)
                            .padding(.bottom, 10)
                        door(apps: false, chooses: true)
                        door(apps: true, chooses: true)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            } main: {
                if appsOpen {
                    ScrollView {
                        HubApps(session: session, macName: macName, path: $path)
                            // No wider than reads well, in the middle of the room it has.
                            .frame(maxWidth: 560)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                    }
                } else {
                    SimulatorChooser(session: session, macName: macName, beside: true)
                }
            } narrow: {
                ScrollView {
                    VStack(spacing: 14) {
                        header
                            .padding(.top, 8)
                            .padding(.bottom, 10)
                        door(apps: false, chooses: false)
                        door(apps: true, chooses: false)
                        if appsOpen { HubApps(session: session, macName: macName, path: $path) }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
                .screenColumn()
            }
            .background(Color.black)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", systemImage: "xmark", action: close)
                        .accessibilityIdentifier("stream.close")
                }
            }
            .navigationDestination(for: HubPlace.self) { place in
                switch place {
                case .simulators: SimulatorChooser(session: session, macName: macName)
                case .allSimulators: AllSimulators(session: session, macName: macName)
                case .app(let bundleID): BuildsPlace(session: session, macName: macName, app: bundleID, build: nil)
                case .build(let id): BuildsPlace(session: session, macName: macName, app: nil, build: id)
                case .setup: LocalInstallSetup(session: session, macName: macName)
                }
            }
        }
        .installToast(session)
        // What the Mac could not do is said at the top of the Simulators screen: a failure after
        // choosing from the long list of all of them comes back there, where it can be read.
        .onChange(of: session.choiceProblem != nil) { _, failed in
            if failed, path.last == .allSimulators { path.removeLast() }
        }
        // Likewise a simulator opened from that list: leaving it comes back to the Simulators
        // screen, where it now heads the running ones.
        .onChange(of: session.progress != nil) { _, starting in
            if starting, path.last == .allSimulators { path.removeLast() }
        }
        // Over the whole stack, so the place the person came from is still there if the Mac fails.
        .overlay {
            if let progress = session.progress {
                SimulatorProgress(session: session, progress: progress)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "macbook")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: 92, height: 92)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            Text(macName)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                // A long name takes a second line; it is never cut short to save one.
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("hub.name")
            ConnectionChip(route: session.stats.route)
        }
        .frame(maxWidth: .infinity)
    }

    /// Simulators or Apps, as a row. With `chooses`, beside what it holds on a wide screen, it
    /// chooses which of the two is shown there and is marked when it is the one. Without,
    /// Simulators is a door to a screen of its own and Apps a heading over the list under it.
    @ViewBuilder
    private func door(apps: Bool, chooses: Bool) -> some View {
        let simulators = !apps
        let icon = simulators ? "iphone" : "shippingbox.fill"
        let tint: Color = simulators ? .blue : .orange
        let title = simulators ? "Simulators" : "Apps"
        let detail = simulators ? simulatorsLine : buildsLine
        let badge = simulators ? runningBadge : buildsBadge
        let chosen = chooses && apps == appsOpen
        Button {
            if chooses {
                appsOpen = apps
            } else if simulators {
                path.append(.simulators)
            } else {
                withAnimation(.easeOut(duration: 0.2)) { appsOpen.toggle() }
            }
        } label: {
            HStack(spacing: chooses ? 12 : 16) {
                tile(icon, tint, size: chooses ? 44 : 58)
                VStack(alignment: .leading, spacing: 3) {
                    if chooses {
                        // A narrower row, beside what it holds: the name on a line of its own, and
                        // one fact under it. The rest is on the other side of the screen.
                        Text(title).font(.headline).foregroundStyle(.white).lineLimit(1)
                        if let badge { chip(badge, tint) } else { Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
                    } else {
                        HStack(spacing: 8) {
                            Text(title).font(.title3.weight(.semibold)).foregroundStyle(.white)
                            if let badge { chip(badge, tint) }
                        }
                        Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                    }
                }
                // All the width there is: a Spacer beside it would take half and wrap the line early.
                .frame(maxWidth: .infinity, alignment: .leading)
                if !chooses {
                    // A door goes somewhere; a heading says which way its list will go.
                    Image(systemName: simulators ? "chevron.right" : "chevron.down")
                        .font(.footnote.weight(.bold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(apps && appsOpen ? 180 : 0))
                }
            }
            .padding(chooses ? 12 : 16)
            .background(chosen ? Color.accentColor.opacity(0.3) : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: chooses ? 20 : 24, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: chooses ? 20 : 24, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityValue(chooses ? "" : apps ? (appsOpen ? "Shown" : "Hidden") : "")
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier(simulators ? "hub.simulators" : "hub.builds")
    }

    private func tile(_ icon: String, _ tint: Color, size: CGFloat) -> some View {
        Image(systemName: icon)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }

    private func chip(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(tint.opacity(0.28), in: Capsule())
            .foregroundStyle(tint)
    }

    private var simulatorsLine: String {
        guard let list = session.list else {
            return session.choiceProblem == nil ? "Open one and use it from here" : "The Mac could not list them"
        }
        let running = list.simulators.filter(\.booted).count
        if list.simulators.isEmpty { return "None yet. Make one here" }
        return running == 0 ? "Nothing running · \(list.simulators.count) to start" : "Open one and use it from here"
    }

    private var runningBadge: String? {
        let running = session.list?.simulators.filter(\.booted).count ?? 0
        return running > 0 ? "\(running) RUNNING" : nil
    }

    private var buildsLine: String {
        guard let newest = session.builds.first else { return "Nothing published yet" }
        var line = "\(newest.name) \(newest.versionText)"
        if let published = newest.published {
            line += " · " + Date(timeIntervalSince1970: published).formatted(.relative(presentation: .named))
        }
        return line
    }

    private var buildsBadge: String? {
        if session.builds.contains(where: StreamSession.updatesThisApp) { return "UPDATE" }
        guard !session.builds.isEmpty else { return nil }
        return session.builds.count == 1 ? "1 BUILD" : "\(session.builds.count) BUILDS"
    }
}

/// How this device reaches the Mac: straight to it, or through a relay. It is there from the
/// start, saying only "Connected" for the moment it takes to learn which, so that nothing on the
/// screen moves down when it is known.
struct ConnectionChip: View {
    let route: String

    var body: some View {
        let direct = route == "Direct"
        HStack(spacing: 6) {
            Circle().fill(route.isEmpty ? Color.gray : direct ? Color.green : Color.orange).frame(width: 7, height: 7)
            Text(route.isEmpty ? "Connected" : direct ? "Connected directly" : "Connected through a relay")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(Color.white.opacity(0.08), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("hub.connection")
    }
}
