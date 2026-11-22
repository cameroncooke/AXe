import SwiftUI

@main
struct AXeMirrorApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            HomeView(model: model)
                .task { await model.loadSettings() }
        }
    }
}

/// The first screen: a picture of what the app does, with the Macs this device is paired with, or
/// a welcome when there are none.
struct HomeView: View {
    let model: AppModel
    @State private var stream: StreamDestination?
    @State private var pairing = false
    @State private var showingAbout = false
    @State private var forgetting: PairedHost?

    var body: some View {
        NavigationStack {
            Group {
                if model.needsUpdate {
                    VStack(spacing: 14) {
                        Artwork(scene: .update, width: 230)
                        Text("Update needed").font(.title2.weight(.bold))
                        Text("This version of AXe Mirror is too old to connect. Update it from the App Store.")
                            .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(28)
                    .frame(maxWidth: 420)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemGroupedBackground))
                } else if model.hosts.isEmpty {
                    welcome
                } else {
                    list
                }
            }
            .navigationTitle("AXe Mirror")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("About", systemImage: "info.circle") { showingAbout = true }
                }
                if !model.hosts.isEmpty, !model.needsUpdate {
                    ToolbarItem(placement: .topBarTrailing) {
                        // Says what it does: a plus sign here was taken for "add" and nobody found pairing.
                        // A stack, not a Label: the toolbar draws a Label as its icon alone.
                        Button { pairing = true } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "qrcode.viewfinder")
                                Text("Pair")
                            }
                            .font(.subheadline.weight(.semibold))
                        }
                        .accessibilityLabel("Pair a Mac")
                        .accessibilityIdentifier("home.pairToolbar")
                    }
                }
            }
        }
        .fullScreenCover(item: $stream) { destination in
            StreamScreen(destination: destination, model: model) { pairing = true }
        }
        .sheet(isPresented: $pairing) { PairView(model: model) }
        .sheet(isPresented: $showingAbout) { AboutView(model: model) }
    }

    /// With no Mac paired yet: what the app does, the three things to do on the Mac, and the way
    /// in. On a wide screen the picture stands at one side and the steps at the other, so the
    /// button to pair is in view without scrolling, an iPhone on its side included.
    private var welcome: some View {
        GeometryReader { proxy in
            let balance = ScreenBalance(proxy)
            ScrollView {
                Group {
                    if balance.wide {
                        HStack(alignment: .center, spacing: 40) {
                            welcomeHero(width: balance.short ? 210 : 300).frame(width: 330)
                            welcomeSteps(tight: balance.short).frame(width: 380)
                        }
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height * 0.94)
                    } else {
                        VStack(spacing: 22) {
                            welcomeHero(width: 270).padding(.top, 12)
                            welcomeSteps(tight: false)
                        }
                        .padding(.horizontal, 22)
                        .padding(.bottom, 28)
                        .frame(maxWidth: 520)
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.leading, balance.leading)
                .padding(.trailing, balance.trailing)
            }
        }
        .background(Color(.systemGroupedBackground))
    }

    private func welcomeHero(width: CGFloat) -> some View {
        VStack(spacing: 8) {
            Artwork(scene: .mirroring, width: width)
            Text("Your simulator, in your hand")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            Text("See and touch the iOS Simulator running on your Mac, live, from this device.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func welcomeSteps(tight: Bool) -> some View {
        VStack(spacing: tight ? 10 : 18) {
            VStack(alignment: .leading, spacing: tight ? 8 : 14) {
                step(1, "Install AXe on your Mac.", detail: "axe-cli.com")
                step(2, "Run this in Terminal:", detail: "axe mirror pair")
                step(3, "Scan the code it shows, then start the host:", detail: "axe mirror")
            }
            .padding(tight ? 12 : 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            VStack(spacing: tight ? 8 : 12) {
                Button {
                    pairing = true
                } label: {
                    Label("Pair with your Mac", systemImage: "qrcode.viewfinder")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, tight ? 2 : 6)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("home.pair")
                if let demo = model.demo {
                    Button {
                        stream = demo
                    } label: {
                        Label("Try the demo", systemImage: "play.circle")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, tight ? 2 : 6)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("home.demo")
                    if !tight {
                        Text("No Mac needed. The demo is a simulator we keep running for you to try.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
            }
        }
    }

    private func step(_ number: Int, _ text: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Color.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(text).font(.subheadline)
                Text(detail).font(.subheadline.monospaced().weight(.semibold)).textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The Macs this device is paired with, under a picture of what the app does. Each Mac is a
    /// card with one action, Connect, the one filled button on the screen; pairing another and the
    /// demo are two quieter buttons beneath, and what to run on the Mac is one line under those.
    /// On a wide screen the picture stands at one side and the Macs at the other.
    private var list: some View {
        GeometryReader { proxy in
            let balance = ScreenBalance(proxy)
            ScrollView {
                Group {
                    if balance.wide {
                        HStack(alignment: .center, spacing: 44) {
                            hero(width: balance.short ? 220 : 300).frame(width: 330)
                            macs.frame(width: 390)
                        }
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height * 0.9)
                    } else {
                        VStack(spacing: 24) {
                            hero(width: 250)
                            macs
                        }
                        .padding(.horizontal, 18)
                        .padding(.bottom, 28)
                        .frame(maxWidth: 520)
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.leading, balance.leading)
                .padding(.trailing, balance.trailing)
            }
        }
        .background(Color(.systemGroupedBackground))
        .confirmationDialog(forgetting.map { "Forget \($0.name)?" } ?? "", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
                            titleVisibility: .visible, presenting: forgetting) { host in
            Button("Forget This Mac", role: .destructive) { model.remove(host) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This device will have to be paired again before it can connect. On the Mac, axe mirror unpair removes this device from its list.")
        }
    }

    private func hero(width: CGFloat) -> some View {
        VStack(spacing: 8) {
            Artwork(scene: .mirroring, width: width)
            Text("Your simulator, in your hand").font(.title2.weight(.bold)).multilineTextAlignment(.center)
            Text("Open a Mac to use its simulators and install its builds.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    private var macs: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your Macs").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 6)
            ForEach(model.hosts) { macCard($0) }
            HStack(spacing: 10) {
                Button { pairing = true } label: {
                    Label("Pair a Mac", systemImage: "qrcode.viewfinder").font(.subheadline.weight(.semibold)).lineLimit(1).frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("home.pairAnother")
                if let demo = model.demo {
                    Button { stream = demo } label: {
                        Label("Try the Demo", systemImage: "play.circle").font(.subheadline.weight(.semibold)).lineLimit(1).frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("home.demo")
                }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .padding(.top, 4)
            Text("Start the host on your Mac with **axe mirror**, then tap Connect.")
                .font(.footnote).foregroundStyle(.secondary).padding(.leading, 6).padding(.top, 2)
        }
    }

    /// One paired Mac. The card connects; forgetting the Mac is behind the three dots, or a press
    /// and hold.
    private func macCard(_ host: PairedHost) -> some View {
        HStack(spacing: 4) {
            Button {
                stream = model.destination(for: host)
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "macbook")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 50, height: 50)
                        .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(host.name).font(.headline).foregroundStyle(Color.primary).lineLimit(2).multilineTextAlignment(.leading)
                        Text("Paired \(host.paired.formatted(date: .abbreviated, time: .omitted))")
                            .font(.footnote).foregroundStyle(Color.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Connect")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.accentColor, in: Capsule())
                        .fixedSize()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Connect to \(host.name)")
            .accessibilityIdentifier("home.connect")
            Menu {
                Button("Forget This Mac", systemImage: "trash", role: .destructive) { forgetting = host }
            } label: {
                Image(systemName: "ellipsis").font(.body.weight(.semibold)).foregroundStyle(.secondary).frame(width: 34, height: 44)
            }
            .accessibilityLabel("More for \(host.name)")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contextMenu {
            Button("Connect", systemImage: "play.fill") { stream = model.destination(for: host) }
            Button("Forget This Mac", systemImage: "trash", role: .destructive) { forgetting = host }
        }
    }
}

/// Version, links and the short story of how the app works.
struct AboutView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("How it works") {
                    Text("AXe Mirror shows an iOS Simulator that runs on your own Mac. The picture and your touches travel between your devices, encrypted from end to end. They go directly when the two can reach each other, and through a relay when they cannot. A relay cannot see the picture or the touches.")
                        .font(.subheadline)
                }
                Section {
                    Link(destination: URL(string: "https://axe-cli.com/mirror/support")!) { Label("Help and support", systemImage: "questionmark.circle") }
                    Link(destination: URL(string: "https://axe-cli.com/mirror/privacy")!) { Label("Privacy policy", systemImage: "hand.raised") }
                    Link(destination: URL(string: "https://axe-cli.com")!) { Label("AXe for your Mac", systemImage: "terminal") }
                }
                Section("Privacy") {
                    Text("No account, no tracking, no analytics. This device keeps a random identity key and the list of Macs you paired with; nothing else is stored.")
                        .font(.subheadline)
                }
                Section {
                    LabeledContent("Version", value: "\(model.version) (\(model.build))")
                } footer: {
                    Text("Connections use iroh, an open-source library by n0, under the MIT and Apache 2.0 licences.")
                }
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
