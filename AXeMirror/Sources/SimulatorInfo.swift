import SwiftUI
import UIKit

/// What there is to know about the simulator on screen, as a sheet over its picture: its name, the
/// kind of device, its iOS version to the build, its screen and its ID, and under them how this
/// device reaches the Mac. The picture goes on behind it. Opened with the Info button.
///
/// A Mac with an older AXe names no iOS version or screen scale; those rows are then left out.
struct SimulatorInfoSheet: View {
    let session: StreamSession
    let macName: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var copiedTimer: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                if let showing = session.showing {
                    Section {
                        fact("Name", showing.name, id: "name")
                        fact("Device", showing.model, id: "device")
                        fact("Version", MirrorViewerRules.versionLine(os: showing.os, build: showing.osBuild), id: "version")
                        if let screen = session.screen {
                            fact("Screen", MirrorViewerRules.screenLine(width: screen.width, height: screen.height, scale: showing.scale) ?? "", id: "screen")
                        }
                        fact("Fold", session.screenLine ?? "", id: "fold")
                        if !showing.udid.isEmpty {
                            // On one line, however narrow the sheet: an ID broken in two is hard to read.
                            LabeledContent("ID") {
                                Text(showing.udid)
                                    .font(.footnote.monospaced())
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.5)
                                    .textSelection(.enabled)
                            }
                            .accessibilityIdentifier("info.udid")
                            Button(action: { copy(showing.udid) }) {
                                Label(copied ? "Copied" : "Copy ID", systemImage: copied ? "checkmark" : "doc.on.doc")
                            }
                            .accessibilityIdentifier("info.copyID")
                        }
                    }
                }
                Section("Connection") {
                    fact("Mac", macName, id: "mac")
                    fact("Route", route, id: "route")
                    fact("Picture", picture, id: "picture")
                }
            }
            .navigationTitle("Simulator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("info.done")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    /// One fact, or nothing when the Mac did not say.
    @ViewBuilder
    private func fact(_ label: String, _ value: String, id: String) -> some View {
        if !value.isEmpty {
            LabeledContent(label) {
                Text(value).textSelection(.enabled).multilineTextAlignment(.trailing)
            }
            .accessibilityIdentifier("info.\(id)")
        }
    }

    /// "Direct" or "Relay", with the round trip once it has been measured.
    private var route: String {
        let stats = session.stats
        guard !stats.route.isEmpty else { return "" }
        return stats.roundTripMs > 0 ? "\(stats.route), \(stats.roundTripMs) ms" : stats.route
    }

    /// The size of the video, in pixels, and its frame rate while the picture is moving.
    private var picture: String {
        let size = session.videoSize
        guard size.width > 0, size.height > 0 else { return "" }
        let pixels = "\(Int(size.width)) × \(Int(size.height)) pixels"
        return session.stats.framesPerSecond > 0 ? "\(pixels), \(session.stats.framesPerSecond) fps" : pixels
    }

    private func copy(_ udid: String) {
        UIPasteboard.general.string = udid
        copiedTimer?.cancel()
        copied = true
        copiedTimer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}
