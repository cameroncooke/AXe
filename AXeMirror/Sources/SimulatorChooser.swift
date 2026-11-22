import SwiftUI
import UIKit

/// The Mac's simulators, behind the Simulators door of `MacHub`: a Mac started with `axe mirror`
/// and no `--udid` waits for one to be chosen.
///
/// The screen is ordered by what a person most often comes for. First, the simulators that are
/// running: one tap and you are in. Then the few used most recently, which are the likeliest to be
/// started again. Everything else is one row away, under "All simulators", and making a new one is
/// a button in the bar. Shutting down and deleting are swipes and a long press, as in any list.
struct SimulatorChooser: View {
    let session: StreamSession
    let macName: String
    /// True beside the Mac's menu on a wide screen, where it is part of that screen and not one of
    /// its own: it then gives the bar no title and no search field, so that the bar is the same
    /// whichever of the menu's two is shown and nothing beside it moves.
    var beside = false
    @State private var creating = false
    @State private var search = ""
    @State private var deleting: MirrorSimulator?

    /// How many recently used simulators are offered before "All simulators".
    private static let recentCount = 5

    var body: some View {
        Group {
            if let list = session.list {
                simulators(list)
            } else if let problem = session.choiceProblem {
                // The Mac could not read its own simulators.
                VStack(spacing: 6) {
                    Artwork(scene: .trouble, width: 210)
                    ProblemCard(problem: problem, session: session)
                }
                .padding(24)
                .frame(maxWidth: 420)
            } else {
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text("Loading the simulators on \(macName)").font(.headline).multilineTextAlignment(.center)
                }
                .foregroundStyle(.white)
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .navigationTitle(beside ? "" : "Simulators")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $creating) {
            if let list = session.list {
                NewSimulatorView(runtimes: list.runtimes, macName: macName) { name, deviceType, runtime in
                    session.create(name: name, deviceType: deviceType, runtime: runtime)
                }
            }
        }
    }

    // MARK: The list

    private func simulators(_ list: MirrorSimulatorList) -> some View {
        let wanted = search.trimmingCharacters(in: .whitespaces)
        let running = list.simulators.filter(\.booted)
        let others = list.simulators.filter { !$0.booted }
        // ISO 8601 times in UTC sort as text.
        let recent = Array(others.filter { $0.lastUsed != nil }.sorted { ($0.lastUsed ?? "") > ($1.lastUsed ?? "") }.prefix(Self.recentCount))
        // With nothing running and nothing used before, the whole list is all there is to offer.
        let everythingHere = running.isEmpty && recent.isEmpty
        return GeometryReader { proxy in
          let balance = ScreenBalance(proxy)
          // A wide screen has room for the running simulators as tiles, beside the list of the
          // rest: nothing is drawn out across the width.
          let tiles = balance.wide && wanted.isEmpty && !running.isEmpty
          ScrollViewReader { scroll in
           HStack(alignment: .top, spacing: 0) {
            if tiles {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Running on \(macName)").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                            Spacer(minLength: 8)
                            if beside, !list.runtimes.isEmpty { newButton }
                        }
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                            ForEach(running) { SimulatorTile(simulator: $0, session: session) { deleting = $0 } }
                        }
                    }
                    .padding(.leading, 22)
                    .padding(.trailing, 6)
                    .padding(.top, 10)
                }
                .frame(width: 440)
            }
            List {
                if let problem = session.choiceProblem {
                    Section { ProblemCard(problem: problem, session: session) }
                        .id(Self.problemID)
                }
                if !wanted.isEmpty {
                    let found = list.simulators.filter { $0.matches(wanted) }
                    Section("Results") {
                        ForEach(found) { SimulatorRow(simulator: $0, session: session, prominent: $0.booted) { deleting = $0 } }
                        if found.isEmpty { Text("No simulator matches “\(wanted)”.").foregroundStyle(.secondary) }
                    }
                } else {
                    if !tiles {
                        Section {
                            if running.isEmpty {
                                NothingRunning(macName: macName, canCreate: !list.runtimes.isEmpty, any: !list.simulators.isEmpty) { creating = true }
                            } else {
                                ForEach(running) { SimulatorRow(simulator: $0, session: session, prominent: true) { deleting = $0 } }
                            }
                        } header: {
                            HStack {
                                Text("Running on \(macName)")
                                Spacer(minLength: 8)
                                if beside, !list.runtimes.isEmpty { newButton.textCase(nil) }
                            }
                        }
                    }
                    if !recent.isEmpty {
                        Section {
                            ForEach(recent) { SimulatorRow(simulator: $0, session: session) { deleting = $0 } }
                        } header: {
                            Text("Recent")
                        } footer: {
                            Text("Tap one to start it and connect.")
                        }
                    }
                    if everythingHere {
                        SimulatorSections(simulators: others, order: list.runtimes.map(\.name), session: session) { deleting = $0 }
                    } else if !others.isEmpty {
                        Section {
                            NavigationLink(value: HubPlace.allSimulators) {
                                LabeledContent("All simulators", value: "\(list.simulators.count)")
                            }
                            .accessibilityIdentifier("chooser.all")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.black)
            // What the Mac could not do is said at the top: the list goes there, wherever it was.
            .onChange(of: session.choiceProblem != nil) { _, failed in
                if failed { withAnimation { scroll.scrollTo(Self.problemID, anchor: .top) } }
            }
            .accessibilityIdentifier("chooser.list")
            .frame(maxWidth: tiles ? 400 : 520)
           }
           .frame(maxWidth: .infinity, maxHeight: .infinity)
           // Balanced against the side column, unless both halves need the room.
           .padding(.leading, tiles ? 0 : balance.leading)
           .padding(.trailing, tiles ? 0 : balance.trailing)
          }
        }
            .background(Color.black)
            .toolbar {
                // Beside the menu, New is with the list: a button in the bar would make the bar
                // taller for this half of the menu than for the other, and move the menu down.
                if !list.runtimes.isEmpty, !beside {
                    ToolbarItem(placement: .topBarTrailing) {
                        // A stack, not a Label: the toolbar draws a Label as its icon alone.
                        Button { creating = true } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "plus")
                                Text("New")
                            }
                            .font(.subheadline.weight(.semibold))
                        }
                        .accessibilityLabel("New simulator")
                        .accessibilityIdentifier("chooser.new")
                    }
                }
            }
            // With no simulators on the Mac there is nothing to search.
            .modifier(Searching(on: !beside && !list.simulators.isEmpty, text: $search))
            .refreshable { await session.refresh() }
            .confirmsDeleting($deleting, on: macName, with: session)
    }

    /// The search field, on the screen that is the simulators' own, while the Mac has simulators.
    /// All simulators has one too.
    private struct Searching: ViewModifier {
        let on: Bool
        @Binding var text: String

        func body(content: Content) -> some View {
            if on { content.searchable(text: $text, prompt: "Search simulators") } else { content }
        }
    }

    /// New, where the bar does not have it.
    private var newButton: some View {
        Button { creating = true } label: {
            Label("New", systemImage: "plus").font(.subheadline.weight(.semibold))
        }
        .accessibilityLabel("New simulator")
        .accessibilityIdentifier("chooser.new")
    }

    private static let problemID = "chooser.problem.section"

}

/// What the first section says when no simulator is running. With simulators to start, they are
/// right below and New is in the bar, so it only says so. With none on the Mac at all there is
/// nothing below to tap, and making one is the way on: then, and only then, it has the button.
private struct NothingRunning: View {
    let macName: String
    /// The Mac has an iOS version to make a simulator with.
    let canCreate: Bool
    /// The Mac has simulators, though none is running.
    let any: Bool
    let create: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Artwork(scene: .nothingRunning, width: 190)
            Text("Nothing is running").font(.title3.weight(.semibold))
            Text(any ? "Start a simulator below." : canCreate ? "\(macName) has no iOS simulators yet." : "\(macName) has no iOS simulators and no iOS runtime to make one with. Install one in Xcode.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if canCreate, !any {
                Button(action: create) {
                    // A stack, not a Label: in a list a Label keeps a column for its icon and tints
                    // it with the accent colour, which on this button left a gap where the plus
                    // was and the words off to the right of it.
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                        Text("New simulator")
                    }
                    .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 2)
                .accessibilityIdentifier("chooser.newFirst")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }
}

/// The Mac is creating, booting or opening a simulator: shown over whatever screen asked for it.
struct SimulatorProgress: View {
    let session: StreamSession
    let progress: MirrorSimulatorProgress

    /// The Mac is creating, booting or opening the simulator. The steps it goes through are shown
    /// with the one it is on, and the simulator's ID as soon as the Mac has one for it, because a
    /// boot can take a minute and the ID is already good to use.
    var body: some View {
        let name = progress.name.flatMap { $0.isEmpty ? nil : $0 } ?? "the simulator"
        let title: String
        switch progress.step {
        case "creating": title = "Creating \(name)"
        case "restarting": title = "Restarting \(name)"
        case "booting": title = "Starting \(name)"
        default: title = "Opening \(name)"
        }
        let plan = session.plan.contains(progress.step) ? session.plan : [progress.step]
        let at = plan.firstIndex(of: progress.step) ?? 0
        return VStack(spacing: 18) {
            Image(systemName: "iphone")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
                .frame(width: 96, height: 96)
                .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .symbolEffect(.pulse)
            Text(title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            HStack(spacing: 8) {
                ForEach(Array(plan.enumerated()), id: \.offset) { index, step in
                    stepChip(step, state: index < at ? .done : index == at ? .now : .later)
                }
            }
            if progress.step != "opening" {
                Text("A simulator that has not run before can take a minute to start.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if let udid = progress.udid, !udid.isEmpty {
                Button {
                    UIPasteboard.general.string = udid
                } label: {
                    Label(udid, systemImage: "doc.on.doc")
                        .font(.caption.monospaced())
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Copy simulator ID \(udid)")
            }
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: 400)
        .accessibilityIdentifier("chooser.progress")
    }

    private enum StepState { case done, now, later }

    private func stepChip(_ step: String, state: StepState) -> some View {
        let label = step == "creating" ? "Create" : step == "restarting" ? "Shut down" : step == "booting" ? "Boot" : "Open"
        return HStack(spacing: 6) {
            switch state {
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .now: ProgressView().controlSize(.mini).tint(.white)
            case .later: Image(systemName: "circle").foregroundStyle(.white.opacity(0.35))
            }
            Text(label).font(.footnote.weight(.semibold)).foregroundStyle(state == .later ? Color.white.opacity(0.45) : Color.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.white.opacity(state == .now ? 0.16 : 0.07), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(state == .done ? "done" : state == .now ? "in progress" : "to do")")
    }
}

/// The name, iOS version and device of a simulator for the Mac to create.
struct NewSimulatorView: View {
    let runtimes: [MirrorRuntime]
    let macName: String
    let create: (String, MirrorDeviceType, MirrorRuntime) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var runtimeID = ""
    @State private var deviceTypeID = ""

    private var runtime: MirrorRuntime? { runtimes.first { $0.id == runtimeID } ?? runtimes.first }
    private var deviceType: MirrorDeviceType? {
        guard let types = runtime?.deviceTypes else { return nil }
        return types.first { $0.id == deviceTypeID } ?? types.first
    }
    private var usableName: Bool { MirrorSimulatorChoice.usableName(name) != nil }
    private var shownName: String {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? (deviceType?.name ?? "New simulator") : typed
    }

    var body: some View {
        NavigationStack {
            Form {
                // What is about to be made, as it will appear in the list.
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: deviceType?.family == "iPad" ? "ipad" : "iphone")
                            .font(.title)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 56, height: 56)
                            .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(shownName).font(.headline).lineLimit(1)
                            Text([deviceType?.name, runtime?.name].compactMap { $0 }.joined(separator: " · "))
                                .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                            Text("Created on \(macName)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }
                Section {
                    TextField("Name", text: $name, prompt: Text(deviceType?.name ?? "Name"))
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("new.name")
                } header: {
                    Text("Name")
                } footer: {
                    Text(usableName ? "Left empty, the simulator takes its device's name."
                         : "One line of at most \(MirrorSimulatorChoice.nameLimit) characters that does not start with a hyphen.")
                }
                Section {
                    Picker("iOS version", selection: $runtimeID) {
                        ForEach(runtimes) { Text($0.name).tag($0.id) }
                    }
                    .accessibilityIdentifier("new.runtime")
                    Picker("Device", selection: $deviceTypeID) {
                        let types = runtime?.deviceTypes ?? []
                        ForEach(["iPhone", "iPad"], id: \.self) { family in
                            let ofFamily = types.filter { $0.family == family }
                            if !ofFamily.isEmpty {
                                Section(family) { ForEach(ofFamily) { Text($0.name).tag($0.id) } }
                            }
                        }
                    }
                    .pickerStyle(.navigationLink)
                    .accessibilityIdentifier("new.device")
                } footer: {
                    Text("The Mac creates the simulator, starts it and shows it here.")
                }
            }
            .navigationTitle("New simulator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        guard let deviceType, let runtime else { return }
                        create(name, deviceType, runtime)
                        dismiss()
                    }
                    .disabled(deviceType == nil || !usableName)
                    .accessibilityIdentifier("new.create")
                }
            }
            .onAppear {
                // The newest iOS version and its newest device, which is what simctl lists first.
                if runtimeID.isEmpty { runtimeID = runtimes.first?.id ?? "" }
                if deviceTypeID.isEmpty { deviceTypeID = runtime?.deviceTypes.first?.id ?? "" }
            }
            .onChange(of: runtimeID) {
                // A device the newly chosen version cannot run gives way to that version's newest.
                if runtime?.deviceTypes.contains(where: { $0.id == deviceTypeID }) != true {
                    deviceTypeID = runtime?.deviceTypes.first?.id ?? ""
                }
            }
        }
    }
}

// MARK: - Rows

extension MirrorSimulator {
    /// The device and the iOS version on one line. The model says nothing new when the simulator
    /// still has its device's name.
    var detail: String { name == model ? os : "\(model) · \(os)" }

    func matches(_ wanted: String) -> Bool {
        [name, model, os].contains { $0.localizedCaseInsensitiveContains(wanted) }
    }
}

/// One simulator in a list. Tapping it opens it; a swipe or a long press shuts it down, deletes it
/// or copies its ID. A running simulator is drawn larger, with an Open button: it is what most
/// people came for. While the Mac is shutting it down or deleting it, the row says so and takes no taps.
private struct SimulatorRow: View {
    let simulator: MirrorSimulator
    let session: StreamSession
    var prominent = false
    let askToDelete: (MirrorSimulator) -> Void

    var body: some View {
        let doing = session.busy[simulator.udid]
        Button {
            session.open(simulator)
        } label: {
            HStack(spacing: prominent ? 14 : 12) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(simulator.name)
                        .font(prominent ? .headline : .body)
                        .foregroundStyle(Color.primary)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    Text(doing == MirrorSimulatorAction.delete ? "Deleting" : doing == MirrorSimulatorAction.shutDown ? "Shutting down" : simulator.detail)
                        .font(.footnote)
                        .foregroundStyle(doing == nil ? Color.secondary : Color.orange)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if doing != nil {
                    ProgressView()
                } else if prominent {
                    Text("Open")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(Color.accentColor, in: Capsule())
                        .fixedSize()
                } else if simulator.booted {
                    Circle().fill(.green).frame(width: 8, height: 8).accessibilityLabel("Running")
                }
            }
            .padding(.vertical, prominent ? 6 : 1)
            .contentShape(Rectangle())
        }
        .disabled(doing != nil)
        .accessibilityIdentifier("chooser.simulator.\(simulator.udid)")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // No destructive role: the row stays until the question is answered and the Mac has done it.
            Button("Delete", systemImage: "trash") { askToDelete(simulator) }.tint(.red)
            if simulator.booted {
                Button("Shut Down", systemImage: "power") { session.shutDown(simulator) }.tint(.orange)
                Button("Restart", systemImage: "arrow.clockwise") { session.restart(simulator) }.tint(.indigo)
            }
        }
        .swipeActions(edge: .leading) {
            Button("Copy ID", systemImage: "doc.on.doc") { UIPasteboard.general.string = simulator.udid }.tint(.accentColor)
        }
        .contextMenu { SimulatorMenu(simulator: simulator, session: session, askToDelete: askToDelete) }
    }

    @ViewBuilder
    private var icon: some View {
        let symbol = simulator.model.hasPrefix("iPad") ? "ipad" : "iphone"
        if prominent {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.green)
                .frame(width: 46, height: 46)
                .background(Color.green.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            Image(systemName: symbol).font(.body).foregroundStyle(Color.secondary).frame(width: 26)
        }
    }
}

/// What can be done with a simulator, from a long press on its row or its tile.
private struct SimulatorMenu: View {
    let simulator: MirrorSimulator
    let session: StreamSession
    let askToDelete: (MirrorSimulator) -> Void

    var body: some View {
        Button(simulator.booted ? "Open" : "Start and open", systemImage: "play.fill") { session.open(simulator) }
        Button("Copy ID", systemImage: "doc.on.doc") { UIPasteboard.general.string = simulator.udid }
        if simulator.booted {
            Button("Shut down", systemImage: "power") { session.shutDown(simulator) }
            Button("Restart", systemImage: "arrow.clockwise") { session.restart(simulator) }
        }
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive) { askToDelete(simulator) }
    }
}

/// A running simulator as a tile, for a wide screen: what it is, and Open. A long press offers
/// the rest, as it does on a row.
private struct SimulatorTile: View {
    let simulator: MirrorSimulator
    let session: StreamSession
    let askToDelete: (MirrorSimulator) -> Void

    var body: some View {
        let doing = session.busy[simulator.udid]
        Button {
            session.open(simulator)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Image(systemName: simulator.model.hasPrefix("iPad") ? "ipad" : "iphone")
                        .font(.title2)
                        .foregroundStyle(.green)
                        .frame(width: 46, height: 46)
                        .background(Color.green.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Spacer(minLength: 6)
                    if doing != nil {
                        ProgressView()
                    } else {
                        Text("Open")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Color.accentColor, in: Capsule())
                    }
                }
                Spacer(minLength: 12)
                Text(simulator.name).font(.headline).foregroundStyle(Color.primary).lineLimit(2).multilineTextAlignment(.leading)
                Text(doing == MirrorSimulatorAction.delete ? "Deleting" : doing == MirrorSimulatorAction.shutDown ? "Shutting down" : simulator.detail)
                    .font(.footnote)
                    .foregroundStyle(doing == nil ? Color.secondary : Color.orange)
                    .lineLimit(1)
                    .padding(.top, 2)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: 138)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(doing != nil)
        .accessibilityIdentifier("chooser.simulator.\(simulator.udid)")
        .contextMenu { SimulatorMenu(simulator: simulator, session: session, askToDelete: askToDelete) }
    }
}

/// Simulators under their iOS versions, newest version first.
private struct SimulatorSections: View {
    let simulators: [MirrorSimulator]
    /// The iOS versions in the order to show them; a version found only on a simulator goes last.
    let order: [String]
    let session: StreamSession
    let askToDelete: (MirrorSimulator) -> Void

    var body: some View {
        let versions = (order + simulators.map(\.os)).uniqued().filter { version in simulators.contains { $0.os == version } }
        ForEach(versions, id: \.self) { version in
            Section(version) {
                ForEach(simulators.filter { $0.os == version }) { SimulatorRow(simulator: $0, session: session, askToDelete: askToDelete) }
            }
        }
    }
}

/// Every simulator on the Mac, by iOS version, one row away from the first screen so that the
/// first screen stays short.
struct AllSimulators: View {
    let session: StreamSession
    let macName: String
    @State private var search = ""
    @State private var deleting: MirrorSimulator?

    var body: some View {
        let wanted = search.trimmingCharacters(in: .whitespaces)
        let all = session.list?.simulators ?? []
        let shown = wanted.isEmpty ? all : all.filter { $0.matches(wanted) }
        List {
            SimulatorSections(simulators: shown, order: session.list?.runtimes.map(\.name) ?? [], session: session) { deleting = $0 }
            if shown.isEmpty {
                Text(wanted.isEmpty ? "\(macName) has no iOS simulators." : "No simulator matches “\(wanted)”.").foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .screenColumn()
        .background(Color.black)
        .navigationTitle("All simulators")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search simulators")
        .refreshable { await session.refresh() }
        .confirmsDeleting($deleting, on: macName, with: session)
        .accessibilityIdentifier("chooser.allList")
    }
}

private extension View {
    /// Asks before a simulator is deleted, and says what goes with it.
    func confirmsDeleting(_ deleting: Binding<MirrorSimulator?>, on macName: String, with session: StreamSession) -> some View {
        confirmationDialog(deleting.wrappedValue.map { "Delete \($0.name)?" } ?? "",
                           isPresented: Binding(get: { deleting.wrappedValue != nil }, set: { if !$0 { deleting.wrappedValue = nil } }),
                           titleVisibility: .visible, presenting: deleting.wrappedValue) { simulator in
            Button("Delete simulator", role: .destructive) { session.delete(simulator) }
            Button("Cancel", role: .cancel) {}
        } message: { simulator in
            Text("This removes \(simulator.name) and everything in it from \(macName). It cannot be undone.")
        }
    }
}

/// Something the Mac could not do, in plain words, with the one thing that can be done about it
/// from this device as a button. The Mac's own technical message waits behind Details: it is for
/// whoever looks after the Mac, not for the person holding the phone.
struct ProblemCard: View {
    let problem: MirrorProblem
    let session: StreamSession
    @State private var showsDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(problem.title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(.orange)
            Text(problem.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                if let action = session.problemAction {
                    Button(action.title, action: action.run)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("chooser.problem.action")
                }
                Button("Dismiss") { session.dismissProblem() }
                    .buttonStyle(.bordered)
                Spacer(minLength: 0)
                if let detail = problem.detail, !detail.isEmpty {
                    Button(showsDetail ? "Hide Details" : "Details") { withAnimation { showsDetail.toggle() } }
                        .font(.footnote)
                        .accessibilityIdentifier("chooser.problem.details")
                }
            }
            if showsDetail, let detail = problem.detail {
                Text(detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chooser.problem")
    }

    private var icon: String {
        switch problem.code {
        case MirrorProblem.macSetup: return "desktopcomputer.trianglebadge.exclamationmark"
        case MirrorProblem.timedOut: return "hourglass"
        case MirrorProblem.noSpace: return "externaldrive.badge.exclamationmark"
        default: return "exclamationmark.triangle.fill"
        }
    }
}
