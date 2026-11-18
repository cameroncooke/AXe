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

/// The first screen: the Macs this device is paired with, or a welcome when there are none.
struct HomeView: View {
    let model: AppModel
    @State private var stream: StreamDestination?
    @State private var pairing = false
    @State private var showingAbout = false

    var body: some View {
        NavigationStack {
            Group {
                if model.needsUpdate {
                    ContentUnavailableView("Update needed", systemImage: "arrow.down.circle",
                                           description: Text("This version of AXe Mirror is too old to connect. Update it from the App Store."))
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
                        Button("Pair with a Mac", systemImage: "plus") { pairing = true }
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

    private var welcome: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image("Glyph")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 132, height: 132)
                    .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
                    .accessibilityHidden(true)
                    .padding(.top, 28)
                VStack(spacing: 8) {
                    Text("Your simulator, in your hand")
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text("See and touch the iOS Simulator running on your Mac, live, from this device.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                VStack(alignment: .leading, spacing: 14) {
                    step(1, "Install AXe on your Mac.", detail: "axe-cli.com")
                    step(2, "Run this in Terminal:", detail: "axe mirror pair")
                    step(3, "Scan the code it shows, then start a simulator:", detail: "axe mirror --udid <UDID>")
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                VStack(spacing: 12) {
                    Button {
                        pairing = true
                    } label: {
                        Label("Pair with your Mac", systemImage: "qrcode.viewfinder")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
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
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("home.demo")
                        Text("No Mac needed. The demo is a simulator we keep running for you to try.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 28)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
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

    private var list: some View {
        List {
            Section {
                ForEach(model.hosts) { host in
                    Button {
                        stream = model.destination(for: host)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "macbook")
                                .font(.title2)
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 38)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(host.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                                Text("Paired \(host.paired.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "play.fill").foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                    }
                    .swipeActions {
                        Button("Remove", systemImage: "trash", role: .destructive) { model.remove(host) }
                    }
                }
            } header: {
                Text("Your Macs")
            } footer: {
                Text("Start a simulator on your Mac with axe mirror --udid <UDID>, then tap the Mac here.")
            }
            if let demo = model.demo {
                Section {
                    Button {
                        stream = demo
                    } label: {
                        Label("Try the demo", systemImage: "play.circle")
                    }
                    .accessibilityIdentifier("home.demo")
                } footer: {
                    Text("A simulator we keep running, for trying the app without a Mac.")
                }
            }
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
