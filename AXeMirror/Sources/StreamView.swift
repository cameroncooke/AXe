import AVFoundation
import SwiftUI
import UIKit

/// The live simulator: the picture, with the app's own controls beside it, above and below it, or
/// in one bar on top, whichever leaves the picture biggest (see `MirrorViewerLayout`). The controls
/// never cover the picture, so every touch on the picture is a touch on the simulator.
///
/// On an iPhone Duo folded part way, the fold decides instead. Stood on a table like a laptop, the
/// picture has the upright half and the half lying flat has the controls and a trackpad; folded like
/// a book, the picture has one page and the controls the other.
///
/// An iPhone Duo simulator is shown flat, as any simulator is. Fold turns the live picture into a
/// 3D Duo to fold (`DuoFoldView`), and it turns back into the flat picture when the folding is done.
struct StreamScreen: View {
    let destination: StreamDestination
    let model: AppModel
    var onPairAgain: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var session = StreamSession()
    @State private var showsInfo = false
    @State private var infoTimer: Task<Void, Never>?
    @State private var copiedID: String?
    @State private var copiedTimer: Task<Void, Never>?
    /// True while the app asks what to do with the simulator being left: Close goes back to the
    /// Mac's list of simulators, and the list's own Close leaves the Mac.
    @State private var leaving = false
    /// The Mac's builds to install, as a sheet over the picture: for a Mac with no menu to go to.
    @State private var showsBuilds = false
    /// Where the person is in the Mac's menu (`MacHub`). Kept here so that leaving a simulator
    /// comes back to the screen it was opened from.
    @State private var hubPath: [HubPlace] = []
    /// Whether the menu lists the Mac's apps under their heading (`MacHub`).
    @AppStorage(MacHub.appsOpenKey) private var appsOpen = false

    var body: some View {
        let live = session.state == .connected && !session.choosing
        GeometryReader { proxy in
            // A simulator on screen is split at the fold. The list of simulators and the notices
            // shown while there is no connection keep the whole screen: they are read, not touched.
            let fold = live ? Self.fold(in: proxy) : nil
            // The list of simulators has no picture to make room for, and the bar above it says
            // whose simulators they are.
            let placement = fold == nil && !session.choosing ? MirrorViewerLayout.placement(pane: proxy.size, video: session.videoSize) : .bars
            let side = placement == .side
            // One layout value, so the picture keeps its place in the view tree when the controls move.
            // At a fold the gap between the two is the fold itself, so nothing lies across it.
            let layout = fold.map { $0.sideBySide ? AnyLayout(HStackLayout(spacing: $0.gap)) : AnyLayout(VStackLayout(spacing: $0.gap)) }
                ?? (side ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0)))
            layout {
                // The Mac's menu and the screens behind it bring their own bar, with the way out.
                if fold == nil, !side, !session.showsHub { topBar(withKeys: placement == .singleBar) }
                ZStack {
                    Color.black
                    StreamSurface(session: session)
                        .opacity(session.hasPicture ? 1 : 0)
                    // With no picture, what is said is centred on the screen, not on the room
                    // the bar at the side leaves.
                    overlay
                        .offset(x: side && !session.hasPicture ? MirrorViewerLayout.sideBar / 2 : 0)
                    if side, showsInfo, session.hasPicture, !session.folding { infoCard }
                    if side, session.hasPicture, session.stats.framesPerSecond > 0, !session.folding { frameRate }
                    if let copiedID { copiedNotice(copiedID) }
                    if session.folding { foldHint }
                    statusNotice
                    // A build published for this device: one line at the foot of the picture or the menu.
                    // Not over the menu's own list of apps or the screens behind it, which have the build in them already.
                    if let build = session.announcedBuild, session.state == .connected, !session.folding, !showsBuilds,
                       !(session.choosing && (hubPath.isEmpty ? appsOpen : !hubPath.contains(.simulators))) {
                        VStack {
                            Spacer(minLength: 0)
                            BuildNotice(build: build, session: session, showAll: showBuilds)
                                .padding(.bottom, 10)
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                // The picture's side of the fold, exactly; nil leaves it the room the bars do not take.
                .frame(width: fold.flatMap { $0.sideBySide ? $0.first : nil }, height: fold.flatMap { $0.sideBySide ? nil : $0.first })
                if let fold { deck(trackpad: fold.trackpad) } else if side { sideBar } else if placement == .bars { bottomBar }
            }
            // The shape the picture has room for: one side of the fold, or the whole screen.
            .onChange(of: FitKey(roomIsWide: fold.map { $0.sideBySide ? $0.first > proxy.size.height : proxy.size.width > $0.first } ?? (proxy.size.width > proxy.size.height),
                                 pictureIsWide: session.videoSize.width > session.videoSize.height,
                                 simulator: session.showing?.udid ?? "", picture: session.hasPicture), initial: true) { _, key in
                session.roomIsWide = key.roomIsWide
                guard key.picture, !session.folding else { return }
                session.fit(roomIsWide: key.roomIsWide)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            session.start(destination: destination, identity: model.identity, ownRelays: model.relays)
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            session.stop()
        }
        .onChange(of: session.hasPicture) { _, live in
            if live { flashInfo() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { session.client?.enteredBackground() }
            if phase == .active {
                session.client?.enteredForeground()
                session.checkLocalInstall()     // back from Settings, perhaps with the certificate trusted
            }
        }
        .sheet(isPresented: $showsBuilds) { BuildsSheet(session: session, macName: destination.title) }
        .animation(.easeOut(duration: 0.25), value: session.announcedBuild?.id)
        // Leaving a simulator is a choice: it can go on running on the Mac, or be shut down.
        .confirmationDialog("Leave \(session.showing?.name ?? "the simulator")?", isPresented: $leaving, titleVisibility: .visible) {
            Button("Leave it running") { session.leave(shutDown: false) }
            Button("Shut it down") { session.leave(shutDown: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Left running, it stays booted on \(destination.title) and keeps its ID. Shut down, it stops; nothing in it is lost.")
        }
    }

    /// Shows the Mac's builds: on its menu when that is on screen, and over the picture otherwise.
    /// An Install tapped before this device is set up for it opens the setup.
    private func showBuilds() {
        if session.choosing {
            appsOpen = true
            hubPath = session.pendingInstall != nil ? [.setup] : []
        } else {
            showsBuilds = true
        }
    }

    /// Where the fold of a partly folded iPhone Duo crosses this screen: how much room there is
    /// before it, how wide the fold itself is, and whether the two parts are side by side (folded
    /// like a book) or one above the other (folded like a laptop).
    private struct Fold: Equatable {
        var first: CGFloat
        var gap: CGFloat
        var sideBySide: Bool
        /// Only a Duo stood on a table has the trackpad: its controls lie flat under the hands.
        var trackpad: Bool
    }

    /// The fold, read from the system's reserved regions, which is where Apple says a layout
    /// should take it from: the regions arrive with the layout pass, hinge angles do not. There is
    /// none when the device is flat, on a device that does not fold, and before iOS 27.1.
    private static func fold(in proxy: GeometryProxy) -> Fold? {
        guard #available(iOS 27.1, *), let division = proxy.reservedRegions(kind: .division).first else { return nil }
        let frame = division.frame
        let sideBySide = frame.height > frame.width
        let first = sideBySide ? frame.minX : frame.minY
        let rest = sideBySide ? proxy.size.width - frame.maxX : proxy.size.height - frame.maxY
        // A fold at the very edge of this view leaves nothing to put on one side of it.
        guard first >= 120, rest >= 120 else { return nil }
        return Fold(first: first, gap: sideBySide ? frame.width : frame.height, sideBySide: sideBySide, trackpad: !sideBySide)
    }

    // MARK: The control deck (partly folded iPhone Duo)

    /// Everything the bars hold, with room to spare: which simulator this is, how the stream is
    /// doing, the simulator's buttons at a size for a thumb, and the ways out. It has a whole half
    /// of the screen, so nothing in it is an icon alone.
    private func deck(trackpad withTrackpad: Bool) -> some View {
        GeometryReader { area in
            // On a table the deck is wide: the controls take the left of it and the trackpad the
            // rest. As a page of an open or book-folded Duo it is the controls alone.
            let wide = area.size.width > area.size.height * 1.15
            let layout = wide ? AnyLayout(HStackLayout(spacing: 14)) : AnyLayout(VStackLayout(spacing: 14))
            layout {
                deckControls(fills: wide || !withTrackpad)
                    .frame(width: wide && withTrackpad ? min(340, area.size.width * 0.46) : nil)
                if withTrackpad { trackpad }
            }
            .padding(16)
        }
        .foregroundStyle(.white)
        // A container: the controls in it keep their own identifiers.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stream.deck")
    }

    /// Which simulator this is, how the stream is doing, the simulator's buttons and the ways out.
    private func deckControls(fills: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                // The Mac names the simulator, not its kind; a picture as squat as an iPad's says which.
                Image(systemName: min(session.videoSize.width, session.videoSize.height) > 0.62 * max(session.videoSize.width, session.videoSize.height) ? "ipad" : "iphone")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).lineLimit(1).minimumScaleFactor(0.8)
                    if let screen = session.screenLine, session.state == .connected {
                        hingeLine(screen).font(.footnote)
                    } else {
                        Text(session.stats.route.isEmpty ? statusLine : "\(statusLine) · \(session.stats.route)")
                            .font(.footnote).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            deckStats
            deckButtons
            if fills { Spacer(minLength: 0) }
            HStack(spacing: 10) {
                if let showing = session.showing, !showing.udid.isEmpty {
                    deckKey("Copy ID", systemImage: "doc.on.doc", small: true, action: copyID)
                        .accessibilityIdentifier("stream.copyID")
                }
                if session.showing?.canRotate == true {
                    rotateMenu {
                        VStack(spacing: 4) {
                            Image(systemName: "rotate.left").font(.body)
                            Text("Rotate").font(Font.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    }
                }
                if session.showing?.hasHinge == true {
                    foldButton {
                        VStack(spacing: 4) {
                            Image(systemName: session.folding ? "checkmark" : "book.pages").font(.body)
                            Text(session.folding ? "Done" : "Fold").font(Font.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .foregroundStyle(session.folding ? Color.accentColor : Color.white)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    }
                }
                deckKey("Close", systemImage: "xmark", small: true) { close() }
                .accessibilityIdentifier("stream.close")
            }
        }
    }

    /// A trackpad for the simulator: it moves a pointer this app draws over the picture, and
    /// clicks, drags and scrolls with it (see `SimulatorPointer`).
    private var trackpad: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            Trackpad(pointer: session.pointer)
            VStack(spacing: 2) {
                Label("Trackpad", systemImage: "hand.point.up.left").font(.footnote.weight(.semibold))
                Text("Tap to click · rest a finger to drag · two fingers to scroll")
                    .font(.caption2).multilineTextAlignment(.center)
            }
            .foregroundStyle(.white.opacity(0.4))
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: 120)
        .onDisappear { session.pointer.hide() }
        .accessibilityIdentifier("stream.trackpad")
    }

    /// The simulator's own buttons. A demo has none: its visitor is kept inside one app.
    @ViewBuilder
    private var deckButtons: some View {
        if destination.isDemo {
            Text("Demo simulator. Touch the picture to use it.")
                .font(.footnote).foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if showsKeys {
            HStack(spacing: 10) {
                deckKey("Home", systemImage: "house.fill") { session.client?.pressButton(2) }
                deckKey("Switcher", systemImage: "square.on.square") { session.client?.pressButton(2, count: 2) }
                deckKey("Lock", systemImage: "lock.fill") { session.client?.pressButton(3) }
            }
        }
    }

    private var deckStats: some View {
        HStack(spacing: 10) {
            deckStat(session.stats.framesPerSecond > 0 ? "\(session.stats.framesPerSecond)" : "–", "fps")
            deckStat(String(format: "%.1f", session.stats.megabits), "Mbps")
            deckStat(session.stats.roundTripMs > 0 ? "\(session.stats.roundTripMs)" : "–", "ms")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(session.stats.framesPerSecond) frames a second, \(String(format: "%.1f", session.stats.megabits)) megabits a second, \(session.stats.roundTripMs) milliseconds round trip")
    }

    private func deckStat(_ number: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(number).font(.title3.weight(.bold).monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.white.opacity(0.6)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// A key of the deck: the simulator's own buttons at full size, the ways out a size smaller
    /// and quieter, so the eye goes to the simulator's first.
    private func deckKey(_ title: String, systemImage: String, small: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: small ? 4 : 6) {
                Image(systemName: systemImage).font(small ? .body : .title2)
                Text(title).font((small ? Font.caption2 : Font.caption).weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
            }
            // One height for a row of keys, whatever shape each one's symbol is.
            .frame(maxWidth: .infinity, minHeight: small ? 50 : 72)
            .background(.white.opacity(small ? 0.08 : 0.14), in: RoundedRectangle(cornerRadius: small ? 13 : 16, style: .continuous))
        }
        .accessibilityLabel(title == "Switcher" ? "App switcher" : title)
    }

    /// What decides whether the simulator should be turned to fit the room for its picture.
    private struct FitKey: Equatable {
        var roomIsWide: Bool
        var pictureIsWide: Bool
        var simulator: String
        var picture: Bool
    }

    /// Turns the simulator. A tap gives a quarter turn to the left, as Simulator.app's Rotate Left;
    /// a press and hold offers both directions and, for an iPad, turning it to fit the screen by
    /// itself.
    @ViewBuilder
    private func rotateMenu<Face: View>(@ViewBuilder label: () -> Face) -> some View {
        Menu {
            Button("Rotate Left", systemImage: "rotate.left") { session.rotate(MirrorRotationRequest.left) }
            Button("Rotate Right", systemImage: "rotate.right") { session.rotate(MirrorRotationRequest.right) }
            if session.showing?.isIPad == true || session.showing?.hasHinge == true {
                Divider()
                Toggle(isOn: Binding(get: { session.fitsToScreen }, set: { session.fitsToScreen = $0 })) {
                    Label("Fit to Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                }
            }
        } label: {
            label()
        } primaryAction: {
            session.rotate(MirrorRotationRequest.left)
        }
        .accessibilityLabel("Rotate")
        .accessibilityHint("Turns the simulator a quarter turn left. Touch and hold for more.")
        .accessibilityIdentifier("stream.rotate")
    }

    /// Fold turns the picture of an iPhone Duo simulator into a 3D Duo to fold; Done turns it back.
    private func foldButton<Face: View>(@ViewBuilder label: () -> Face) -> some View {
        Button { session.folding ? session.endFolding() : session.beginFolding() } label: { label() }
            .accessibilityLabel(session.folding ? "Done folding" : "Fold")
            .accessibilityValue(session.screenLine ?? "")
            .accessibilityHint(session.folding ? "Goes back to using the simulator." : "Shows the simulator as a Duo you fold by dragging its halves.")
            .accessibilityIdentifier("stream.fold")
    }

    /// How an iPhone Duo simulator is folded, in words.
    private func hingeLine(_ text: String) -> some View {
        Text(text).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            .accessibilityIdentifier("stream.screen")
    }

    /// The one notice over the picture, the most important there is, or none:
    ///  1. the simulator is not answering: a card in the middle, as touches would not work anyway,
    ///     saying whether the Mac is busy, which may be why, with Restart;
    ///  2. a fold that did not finish, then a busy Mac: one line at the top that takes no touches.
    /// The connection's own states (connecting, reconnecting, unreachable) cover the whole picture
    /// instead (`overlay`), and then this shows nothing.
    @ViewBuilder
    private var statusNotice: some View {
        if session.state == .connected, session.hasPicture {
            if let health = session.health, !health.responding {
                notAnswering(health)
            } else if let problem = session.foldProblem {
                noticeLine(problem, systemImage: "exclamationmark.triangle.fill", identifier: "stream.foldProblem")
            } else if session.hostLoad?.busy == true {
                noticeLine("Your Mac is very busy, so the simulator may lag.", systemImage: "gauge.with.dots.needle.100percent", identifier: "stream.macBusy")
            }
        }
    }

    private func noticeLine(_ text: String, systemImage: String, identifier: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.black.opacity(0.78), in: Capsule())
            .padding(12)
            .frame(maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
            .transition(.opacity)
            .accessibilityIdentifier(identifier)
    }

    /// The simulator has stopped answering the Mac. On a busy Mac that may only be the load, so the
    /// card says so and offers Restart after a minute; on a quiet Mac Restart is offered at once.
    private func notAnswering(_ health: MirrorSimulatorHealth) -> some View {
        let busy = session.hostLoad?.busy == true
        return TimelineView(.periodic(from: .now, by: 5)) { context in
            let waited = session.unansweredSince.map { context.date.timeIntervalSince($0) } ?? 0
            let offersRestart = session.canLeaveByChoice && (!busy || waited >= StreamSession.restartAfterOnBusyMac)
            VStack(spacing: 10) {
                Image(systemName: busy ? "gauge.with.dots.needle.100percent" : "exclamationmark.octagon.fill")
                    .font(.title2)
                    .foregroundStyle(busy ? Color.yellow : Color.orange)
                Text(busy ? "\(title) is slow to answer" : "\(title) is not responding")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Group {
                    if busy, let load = session.hostLoad {
                        Text("Your Mac is very busy (load \(String(format: "%.1f", load.load)) per core), which may be why. It may catch up by itself.")
                    } else {
                        Text(health.reason ?? "The Mac cannot reach it.")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                if offersRestart {
                    Button {
                        session.restartShowing()
                    } label: {
                        Label("Restart Simulator", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(busy ? .gray : .orange)
                    .accessibilityIdentifier("stream.restart")
                    Text("Restarting closes the apps running in it; nothing saved in it is lost.")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                } else if !session.canLeaveByChoice {
                    Text("Restart it on the Mac, or start the host without --udid to restart it from here.")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                }
            }
            .foregroundStyle(.white)
            .padding(18)
            .frame(maxWidth: 360)
            .background(.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stream.notResponding")
    }

    /// Under the 3D Duo while it is being folded: the three postures as buttons, and how to fold it
    /// by hand. The buttons are the plain way; dragging and pinching are the direct way.
    private var foldHint: some View {
        VStack(spacing: 10) {
            // Words and pictures where there is room for them, pictures alone where there is not.
            ViewThatFits(in: .horizontal) {
                foldChips(titled: true)
                foldChips(titled: false)
            }
            Text(session.foldNote)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.7))
                .accessibilityIdentifier("stream.foldHint")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .frame(height: StreamSession.foldControlsHeight, alignment: .bottom)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .transition(.opacity)
    }

    private func foldChips(titled: Bool) -> some View {
        HStack(spacing: 8) {
            foldChip("Closed", systemImage: "rectangle.portrait", degrees: 0, titled: titled)
            foldChip("Half open", systemImage: "book", degrees: 90, titled: titled)
            foldChip("Open", systemImage: "rectangle.split.2x1", degrees: 180, titled: titled)
        }
    }

    private func foldChip(_ title: String, systemImage: String, degrees: Double, titled: Bool) -> some View {
        Button { session.setFold(degrees) } label: {
            Group {
                if titled { Label(title, systemImage: systemImage) } else { Image(systemName: systemImage) }
            }
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.white.opacity(0.14), in: Capsule())
        }
        .foregroundStyle(.white)
        .accessibilityLabel(title)
        .accessibilityIdentifier("stream.fold.\(Int(degrees))")
    }

    /// Back to the Mac's list of simulators, asking first whether to leave the simulator running;
    /// out of the Mac when it offers no list.
    private func close() {
        if session.canLeaveByChoice { leaving = true } else { dismiss() }
    }

    private var closeButton: some View {
        Button {
            close()
        } label: {
            Label("Close", systemImage: "xmark")
                .labelStyle(.iconOnly)
                .font(.body.weight(.semibold))
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.14), in: Circle())
        }
        .accessibilityIdentifier("stream.close")
    }

    /// The Mac's name and the state of the stream, laid over the top of the picture for three
    /// seconds: when the picture arrives, and when the route badge is tapped. It takes no touches,
    /// so a touch that lands on it still goes to the simulator. A bar for it would cost the picture
    /// height all the time; a tap on the picture to bring it back would steal a tap from the simulator.
    private var infoCard: some View {
        VStack(spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(session.screenLine.map { "\(statusLine) · \($0)" } ?? statusLine).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
            if let udid = session.showing?.udid, !udid.isEmpty {
                Text(udid).font(.caption2.monospaced()).foregroundStyle(.white.opacity(0.75)).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.black.opacity(0.62), in: Capsule())
        .padding(.top, 10)
        .frame(maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .transition(.opacity)
        .accessibilityIdentifier("stream.info")
    }

    /// The frame rate, small, in the bottom left corner, while the picture is moving. A still
    /// screen sends no frames, so there is nothing to show then. It takes no touches.
    private var frameRate: some View {
        Text("\(session.stats.framesPerSecond) fps")
            .font(.caption2.weight(.medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.black.opacity(0.5), in: Capsule())
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .allowsHitTesting(false)
            .accessibilityIdentifier("stream.fps")
    }

    /// The simulator's name once the Mac has said which it shows, the Mac's name until then.
    private var title: String {
        guard let name = session.showing?.name, !name.isEmpty, !session.choosing else { return destination.title }
        return name
    }

    /// Says that the simulator's ID is on the clipboard, and shows it, for two seconds, over the
    /// top of the picture. It takes no touches.
    private func copiedNotice(_ udid: String) -> some View {
        VStack(spacing: 2) {
            Label("Simulator ID copied", systemImage: "checkmark.circle.fill").font(.subheadline.weight(.semibold))
            Text(udid).font(.caption2.monospaced()).foregroundStyle(.white.opacity(0.8)).lineLimit(1).minimumScaleFactor(0.6)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(12)
        // At the top, clear of the frame rate in the bottom corner.
        .frame(maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .transition(.opacity)
        .accessibilityIdentifier("stream.copied")
    }

    /// Puts the simulator's UDID on the clipboard, to paste where an agent or a command needs it.
    private func copyID() {
        guard let udid = session.showing?.udid, !udid.isEmpty else { return }
        UIPasteboard.general.string = udid
        copiedTimer?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { copiedID = udid }
        copiedTimer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.4)) { copiedID = nil }
        }
    }

    /// Copy the simulator's ID, and go back to the Mac's simulators when the Mac lets this viewer
    /// choose. Shown while a simulator is on screen.
    @ViewBuilder
    private var simulatorButtons: some View {
        if let showing = session.showing, !session.choosing, session.state == .connected {
            if !showing.udid.isEmpty {
                roundButton("Copy simulator ID", systemImage: "doc.on.doc", action: copyID)
                    .accessibilityIdentifier("stream.copyID")
            }
            if showing.canRotate {
                rotateMenu {
                    Image(systemName: "rotate.left")
                        .font(.footnote.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .background(.white.opacity(0.14), in: Circle())
                }
            }
            if showing.hasHinge {
                foldButton {
                    Image(systemName: session.folding ? "checkmark" : "book.pages")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(session.folding ? Color.black : Color.white)
                        .frame(width: 36, height: 36)
                        .background(session.folding ? Color.white : Color.white.opacity(0.14), in: Circle())
                }
            }
        }
    }

    private func roundButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.footnote.weight(.semibold))
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.14), in: Circle())
        }
    }

    private func flashInfo() {
        infoTimer?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { showsInfo = true }
        infoTimer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.4)) { showsInfo = false }
        }
    }

    /// In the side column, under the Fold button: which screen of an iPhone Duo simulator is lit and
    /// how far it is open, on two short lines, as the column is narrow. The top bar and the deck say
    /// the same in one line. A tap on it folds, as the button above it does.
    @ViewBuilder
    private var sideScreenLabel: some View {
        if let parts = session.screenParts, !session.choosing, session.state == .connected {
            Button { session.folding ? session.endFolding() : session.beginFolding() } label: {
                VStack(spacing: 1) {
                    Text(parts.screen).font(.caption2.weight(.semibold))
                    if !parts.position.isEmpty {
                        Text(parts.position).font(.caption2).foregroundStyle(.white.opacity(0.7))
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .padding(.horizontal, 6)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(session.screenLine ?? "")
            .accessibilityHint("Shows the simulator as a Duo you can fold.")
            .accessibilityIdentifier("stream.screen")
        }
    }

    /// Everything the bars hold, in one column beside the picture: Close at the top, the route
    /// under it (tap it to see the Mac's name and the frame rate), the simulator's buttons at the
    /// bottom where a thumb rests.
    private var sideBar: some View {
        VStack(spacing: 12) {
            closeButton
            if session.state == .connected, !session.stats.route.isEmpty {
                Button(action: flashInfo) {
                    Text(session.stats.route)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.white.opacity(0.14), in: Capsule())
                }
                .accessibilityLabel("Connection: \(session.stats.route)")
                .accessibilityHint("Shows the simulator's name and ID and the frame rate")
            }
            simulatorButtons
            sideScreenLabel
            Spacer(minLength: 0)
            if showsKeys {
                Group {
                    controlButton("Home", systemImage: "house.fill") { session.client?.pressButton(2) }
                    controlButton("App switcher", systemImage: "square.on.square") { session.client?.pressButton(2, count: 2) }
                    controlButton("Lock", systemImage: "lock.fill") { session.client?.pressButton(3) }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.vertical, 10)
        .frame(width: MirrorViewerLayout.sideBar)
    }

    /// Close, the simulator's name and state, and its buttons; with `withKeys`, Home, App Switcher
    /// and Lock as well, for a pane wide enough to need no bar below.
    private func topBar(withKeys: Bool) -> some View {
        HStack(spacing: 12) {
            closeButton
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let screen = session.screenLine, !session.choosing, session.state == .connected {
                    hingeLine(screen).font(.caption)
                } else {
                    Text(statusLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            simulatorButtons
            if withKeys, showsKeys {
                HStack(spacing: 8) {
                    controlButton("Home", systemImage: "house.fill") { session.client?.pressButton(2) }
                    controlButton("App switcher", systemImage: "square.on.square") { session.client?.pressButton(2, count: 2) }
                    controlButton("Lock", systemImage: "lock.fill") { session.client?.pressButton(3) }
                }
            }
            if session.state == .connected, !session.stats.route.isEmpty {
                Text(session.stats.route)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.14), in: Capsule())
                    .accessibilityLabel("Connection: \(session.stats.route)")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var statusLine: String {
        switch session.state {
        case .connecting: return "Connecting"
        case .connected:
            if session.choosing { return session.progress == nil ? "Choose a simulator" : "Starting the simulator" }
            // Until the Mac says what it has, there may be no picture coming: it may open on its menu.
            guard session.showing != nil else { return "Connecting" }
            guard session.hasPicture else { return "Waiting for the picture" }
            // A still screen sends no frames, so the rate is shown only while the picture moves.
            return session.stats.framesPerSecond > 0 ? "Live, \(session.stats.framesPerSecond) frames a second" : "Live"
        case .reconnecting: return "Reconnecting"
        case .unreachable, .refused: return "Not connected"
        }
    }

    /// Home, App Switcher and Lock are shown only while a simulator is on screen and the Mac is
    /// connected: with no simulator, or while the Mac cannot be reached, they would press nothing.
    private var showsKeys: Bool {
        !destination.isDemo && session.state == .connected && !session.choosing && session.showing != nil
    }

    @ViewBuilder
    private var bottomBar: some View {
        if session.choosing || (!destination.isDemo && !showsKeys) {
            // The simulator's buttons have nothing to press until one is chosen and the Mac answers.
            EmptyView()
        } else if destination.isDemo {
            Text("Demo simulator. Touch the picture to use it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
        } else {
            HStack(spacing: 28) {
                controlButton("Home", systemImage: "house.fill") { session.client?.pressButton(2) }
                controlButton("App switcher", systemImage: "square.on.square") { session.client?.pressButton(2, count: 2) }
                controlButton("Lock", systemImage: "lock.fill") { session.client?.pressButton(3) }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
        }
    }

    private func controlButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.title3)
                .frame(width: 52, height: 42)
                .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var overlay: some View {
        switch session.state {
        case .connecting:
            notice(art: .connecting, title: "Connecting to \(destination.title)", detail: nil)
        case .connected:
            if session.choosing {
                MacHub(session: session, macName: destination.title, path: $hubPath) { dismiss() }
            } else if session.showing == nil {
                // Connected, and the Mac has not yet said what it has: a simulator's picture, or
                // its menu, which has none. So nothing is said about a picture until one is coming.
                notice(art: .connecting, title: "Connecting to \(destination.title)", detail: nil)
            } else if !session.hasPicture {
                notice(art: .waiting, title: "Waiting for the picture", detail: nil)
            }
        case .reconnecting:
            notice(art: .reconnecting, title: "Reconnecting", detail: nil)
        case .unreachable(let reason, let retrying):
            unreachable(reason, retrying: retrying)
        case .refused(.notPaired):
            notice(art: .notPaired, title: "This device is no longer paired",
                   detail: "On your Mac, run axe mirror pair, then pair again here.") {
                Button("Pair again") { dismiss(); onPairAgain() }.buttonStyle(.borderedProminent)
            }
        case .refused(.busy):
            notice(art: .busy, title: "The demo is in use",
                   detail: "Someone else is trying it right now. It frees up within three minutes.") {
                Button("Try again") { session.client?.retry() }.buttonStyle(.borderedProminent)
            }
        }
    }

    /// What is wrong and what to do about it, with a way to try again. While the app is still
    /// trying by itself it says so; after two minutes it stops and says that instead.
    private func unreachable(_ reason: MirrorUnreachable, retrying: Bool) -> some View {
        VStack(spacing: 14) {
            Artwork(scene: reason == .offline ? .offline : reason == .relay ? .relayDown : .macAway, width: 210)
            Text(unreachableTitle(reason)).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                .accessibilityIdentifier("stream.problem")
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(unreachableSteps(reason).enumerated()), id: \.offset) { _, step in
                    if step.hasPrefix("$ ") {
                        Text(step.dropFirst(2))
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    } else {
                        Text(step).font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Button("Try again") { session.client?.retry() }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("stream.retry")
            HStack(spacing: 8) {
                if retrying { ProgressView().controlSize(.small).tint(.white) }
                Text(retrying ? "Still trying every few seconds." : "Stopped trying after two minutes.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("stream.retrying")
            }
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: 380)
    }

    private func unreachableTitle(_ reason: MirrorUnreachable) -> String {
        switch reason {
        case .offline: return "No internet connection"
        case .relay: return "Can't reach the AXe relay"
        case .host: return destination.isDemo ? "The demo isn't answering" : "\(destination.title) isn't answering"
        }
    }

    /// One line per step; a line that starts with "$ " is a command to run on the Mac.
    private func unreachableSteps(_ reason: MirrorUnreachable) -> [String] {
        switch reason {
        case .offline:
            return ["Connect this device to Wi-Fi or mobile data."]
        case .relay:
            return ["This network may be blocking it. Try another network, or mobile data.",
                    "Every connection starts through the relay, even to a Mac on the same Wi-Fi."]
        case .host where destination.isDemo:
            return ["The demo simulator may be restarting or offline. Try again in a minute."]
        case .host:
            return ["1. Check that the Mac is awake and online.",
                    "2. In a terminal on it, start the host:",
                    "$ axe mirror",
                    "You then choose a simulator here. This screen connects by itself once the host is running."]
        }
    }

    /// What is going on while there is no picture: a drawing of it, and the words. The drawing
    /// moves where something is under way, so no spinner is needed beside it.
    private func notice(art: Artwork.Scene, title: String, detail: String?, @ViewBuilder actions: () -> some View = { EmptyView() }) -> some View {
        VStack(spacing: 14) {
            Artwork(scene: art, width: 220)
            Text(title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            actions()
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: 360)
    }
}

/// Owns the connection for one showing of the stream screen and republishes its state for SwiftUI.
@MainActor
@Observable
final class StreamSession {
    private(set) var state: MirrorClient.State = .connecting
    private(set) var stats = MirrorClient.Stats()
    private(set) var videoSize = CGSize.zero
    private(set) var client: MirrorClient?
    @ObservationIgnored let surface = StreamSurfaceView()
    /// The pointer the deck's trackpad moves over the picture.
    @ObservationIgnored let pointer = SimulatorPointer()

    /// The simulator on screen, as the Mac named it when the stream started.
    private(set) var showing: MirrorClient.Showing?
    /// True while the Mac shows no simulator and waits for one to be chosen here.
    private(set) var choosing = false
    /// The Mac's simulators and what a new one can be made from; nil until the Mac has sent them.
    private(set) var list: MirrorSimulatorList?
    /// The choice the Mac is working on: creating, booting or opening a simulator.
    private(set) var progress: MirrorSimulatorProgress?
    /// What last went wrong on the Mac, said for the person holding this device, with what can be
    /// done about it from here.
    private(set) var choiceProblem: MirrorProblem?
    /// What was last asked of the Mac, to do again when a problem offers Try Again.
    private enum Asked {
        case list, open(MirrorSimulator), create(String, MirrorDeviceType, MirrorRuntime)
        case shutDown(MirrorSimulator), delete(MirrorSimulator), restart(MirrorSimulator)
    }
    @ObservationIgnored private var asked = Asked.list
    /// Whether the Mac has said anything about the choice under way; see `watchChoice`.
    @ObservationIgnored private var choiceAnswered = false
    @ObservationIgnored private var choiceWatch: Task<Void, Never>?
    /// How long the Mac may take to say it has started on a choice. It says so at once; a long
    /// boot is reported as it goes and does not count against this.
    static let choiceAnswerLimit: UInt64 = 20
    /// The steps the choice under way goes through, in order: some of creating, booting, opening.
    private(set) var plan: [String] = []
    /// Simulators the Mac is shutting down or deleting for this viewer, by UDID, with which of the two.
    private(set) var busy: [String: String] = [:]
    /// Whether the simulator on screen is answering the Mac; nil until the Mac says otherwise.
    private(set) var health: MirrorSimulatorHealth?
    /// How busy the Mac is; nil from a Mac that does not say.
    private(set) var hostLoad: MirrorHostLoad?

    // MARK: Builds to install

    /// The app builds the Mac offers to install on this device, newest first.
    private(set) var builds: [MirrorBuild] = []
    /// A build to tell the person about without their looking: one that arrived while they were
    /// connected, or a newer build of this app than the one running.
    var announcedBuild: MirrorBuild?
    /// Why the last Install did nothing, with the build it was for.
    var installProblem: (build: MirrorBuild, title: String, message: String)?
    /// The build the person asked for before this device was set up to install: the setup opens,
    /// and offers it again the moment it is done.
    var pendingInstall: MirrorBuild?
    /// The build iOS was asked to install a moment ago: said in passing (`InstallToast`), and then
    /// forgotten. iOS asks the person itself and tells this app nothing more, not that they agreed
    /// and not that they did not, so nothing here can go on saying that it is installing.
    private(set) var installStarted: MirrorBuild?
    static let installNoteLasts: TimeInterval = 5
    @ObservationIgnored private var buildsSeen = false
    @ObservationIgnored private var askedForBuilds = false

    /// This app's own build number, and whether a build is one of this app.
    static let ownBuild = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    static func isThisApp(_ build: MirrorBuild) -> Bool { build.bundleID == Bundle.main.bundleIdentifier }
    /// A build of this app that is newer than the one running.
    static func updatesThisApp(_ build: MirrorBuild) -> Bool { isThisApp(build) && (Int(build.build) ?? 0) > ownBuild }

    // MARK: Installing from this device

    /// Whether this device can serve builds to iOS itself: the Mac's certificate has not arrived
    /// or cannot be used, it is not installed and trusted yet, or it is ready under a name.
    enum LocalInstall: Equatable {
        case unavailable, notTrusted, ready(String)
    }
    private(set) var localInstall = LocalInstall.unavailable
    /// The build being fetched from the Mac over the connection, and how far it has got.
    private(set) var fetching: (id: String, received: Int, size: Int)?
    /// The build iOS's installer has taken from this device, and how much of it.
    private(set) var takenByIOS: (id: String, what: String)?
    @ObservationIgnored private var installIdentity: MirrorInstallIdentity?
    @ObservationIgnored private var installServer: LocalInstallServer?
    @ObservationIgnored private var askedForIdentity = false
    /// Why the Mac could not make its certificate, in its words, when it could not.
    @ObservationIgnored private var identityProblem: String?
    @ObservationIgnored private var fetch: (build: MirrorBuild, host: String, file: URL, handle: FileHandle)?
    @ObservationIgnored private var keepAwake = UIBackgroundTaskIdentifier.invalid

    /// The name the authority's certificate has under Certificate Trust Settings.
    var installAuthorityName: String { installIdentity?.authorityName ?? "AXe Mirror installs" }

    private func gotInstallIdentity(_ identity: MirrorInstallIdentity) {
        identityProblem = nil
        // The person is about to be asked to trust this authority fully. It is offered only if its
        // own certificate limits it to the names that point at this device: then nothing signed by
        // it for any other site is accepted by iOS, whoever holds its key, and that does not rest
        // on the Mac's word.
        guard MirrorCertificateLimits.isLimited(identity.authority, to: MirrorInstallIdentity.loopbackNames),
              Set(identity.names).isSubset(of: Set(MirrorInstallIdentity.loopbackNames)) else {
            identityProblem = "Its certificate is not limited to installs on this device. Update AXe on the Mac."
            installServer?.stop()
            installServer = nil
            installIdentity = nil
            localInstall = .unavailable
            return
        }
        guard identity != installIdentity || installServer == nil else { return }
        installIdentity = identity
        installServer?.stop()
        installServer = LocalInstallServer(identity: identity)
        installServer?.onFetched = { [weak self] id, what in self?.takenByIOS = (id, what) }
        localInstall = installServer == nil ? .unavailable : .notTrusted
        checkLocalInstall()
    }

    /// Finds out whether iOS trusts this device's own server yet: this app asks it over HTTPS under
    /// each name in turn, as iOS's installer will. Run when the certificate arrives and each time
    /// the app comes to the front, which is when the person returns from Settings.
    func checkLocalInstall() {
        guard let identity = installIdentity, let server = installServer else { return }
        Task { @MainActor [weak self] in
            // iOS may have suspended the app while the person was in Settings, and closed the
            // server with it: a new one, before asking whether it is trusted.
            if await !server.isAlive(), let self, self.installServer === server {
                server.stop()
                self.installServer = LocalInstallServer(identity: identity)
                self.installServer?.onFetched = { [weak self] id, what in self?.takenByIOS = (id, what) }
            }
            guard let port = self?.installServer?.securePort else { return }
            for name in identity.names {
                guard let url = URL(string: "https://\(name):\(port)/healthz") else { continue }
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 4)
                request.httpMethod = "GET"
                let session = URLSession(configuration: .ephemeral)
                let answered = ((try? await session.data(for: request))?.1 as? HTTPURLResponse)?.statusCode == 200
                session.finishTasksAndInvalidate()
                if answered {
                    self?.localInstall = .ready(name)
                    return
                }
            }
            if self?.installServer != nil { self?.localInstall = .notTrusted }
        }
    }

    /// Opens the authority's certificate in Safari, which is the only way iOS takes one. This app
    /// goes on serving it for the half minute iOS allows an app that is not in front.
    func installAuthority() {
        guard let port = installServer?.plainPort, let url = URL(string: "http://localhost:\(port)/authority.cer") else { return }
        stayAwake()
        UIApplication.shared.open(url)
    }

    private func stayAwake() {
        if keepAwake != .invalid { UIApplication.shared.endBackgroundTask(keepAwake) }
        keepAwake = UIApplication.shared.beginBackgroundTask { [weak self] in
            guard let self else { return }
            UIApplication.shared.endBackgroundTask(self.keepAwake)
            self.keepAwake = .invalid
        }
    }

    /// Fetches a build from the Mac over the connection, a piece at a time, then hands it to iOS
    /// from this device. A copy already fetched whole is used as it is.
    private func fetchAndInstall(_ build: MirrorBuild, host: String) {
        guard fetch == nil, let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let file = caches.appendingPathComponent("build-\(build.id).ipa")
        if let wanted = build.sha256, FileManager.default.fileExists(atPath: file.path), LocalInstallServer.digest(of: file) == wanted {
            hand(build, file: file, host: host)
            return
        }
        FileManager.default.createFile(atPath: file.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: file) else {
            installProblem = (build, "This device could not keep the build", "There may be no room for it.")
            return
        }
        fetch = (build, host, file, handle)
        fetching = (build.id, 0, build.size ?? 0)
        client?.fetchBuild(build.id, offset: 0)
    }

    private func gotPiece(_ piece: MirrorBuildPiece) {
        guard let fetch, let progress = fetching, piece.id == fetch.build.id, piece.offset == progress.received else { return }
        try? fetch.handle.write(contentsOf: piece.bytes)
        let received = progress.received + piece.bytes.count
        fetching = (progress.id, received, progress.size)
        let finished = piece.bytes.count < MirrorBuildFetch.largest || (progress.size > 0 && received >= progress.size)
        guard finished else { client?.fetchBuild(piece.id, offset: received); return }
        try? fetch.handle.close()
        self.fetch = nil
        fetching = nil
        let build = fetch.build, file = fetch.file, host = fetch.host
        Task.detached {
            let sound = build.sha256.map { $0 == LocalInstallServer.digest(of: file) } ?? true
            await MainActor.run { [weak self] in
                guard sound else {
                    try? FileManager.default.removeItem(at: file)
                    self?.installProblem = (build, "The build arrived damaged", "What this device received is not what the Mac published. Try again.")
                    return
                }
                self?.hand(build, file: file, host: host)
            }
        }
    }

    private func fetchFailed(_ failure: MirrorBuildFetchFailure) {
        guard let fetch, failure.id == fetch.build.id else { return }
        try? fetch.handle.close()
        try? FileManager.default.removeItem(at: fetch.file)
        self.fetch = nil
        fetching = nil
        installProblem = (fetch.build, "The Mac could not send the build", failure.message)
    }

    /// Hands iOS a build this device now holds: its manifest's address on this device's own server.
    private func hand(_ build: MirrorBuild, file: URL, host: String) {
        guard let server = installServer else { return }
        let manifest = server.serve(build.id, LocalInstallServer.Served(file: file, bundleID: build.bundleID, buildNumber: build.build, title: build.name, host: host))
        guard let text = MirrorBuild.installURL(manifest: manifest), let link = URL(string: text) else { return }
        takenByIOS = nil
        stayAwake()
        open(build, link)
    }

    /// A fetch cut short by the connection going is dropped; the next Install starts it again.
    private func dropFetch() {
        guard let fetch else { return }
        try? fetch.handle.close()
        try? FileManager.default.removeItem(at: fetch.file)
        self.fetch = nil
        fetching = nil
    }

    private func received(_ list: [MirrorBuild]) {
        // Builds come over the connection: ask once for the certificate this device will serve
        // them to iOS with.
        if !askedForIdentity, !list.isEmpty {
            askedForIdentity = true
            client?.requestInstallIdentity()
        }
        let known = Set(builds.map(\.id))
        let arrived = list.first { !known.contains($0.id) }
        builds = list
        if buildsSeen {
            // Published while this viewer was connected: somebody means it to be installed now.
            if let arrived { announcedBuild = arrived }
        } else {
            buildsSeen = true
            announcedBuild = list.first(where: Self.updatesThisApp)
        }
        if let announced = announcedBuild, !list.contains(where: { $0.id == announced.id }) { announcedBuild = nil }
    }

    /// Installs a build: it is fetched from the Mac over the connection and handed to iOS from
    /// this device. Before the device is set up for that, the build is kept as the one wanted and
    /// the Builds screen opens the setup, which offers it again when it is done.
    func install(_ build: MirrorBuild) {
        installProblem = nil
        guard !build.isExpired() else {
            installProblem = (build, "This build has expired", "Its signing profile is no longer valid. Publish it again on the Mac.")
            return
        }
        switch localInstall {
        case .ready(let host):
            pendingInstall = nil
            if announcedBuild?.id == build.id { announcedBuild = nil }
            fetchAndInstall(build, host: host)
        case .notTrusted:
            pendingInstall = build
        case .unavailable:
            // The certificate comes within a moment of the builds; ask again in case it was lost.
            client?.requestInstallIdentity()
            if let identityProblem {
                // The Mac has said it cannot make one: waiting will not help, and it says why.
                installProblem = (build, "Your Mac could not get ready to install", identityProblem)
            } else {
                installProblem = (build, "Not ready to install yet", "This device is still waiting for the Mac’s certificate. Try again in a moment.")
            }
        }
    }

    private func open(_ build: MirrorBuild, _ link: URL) {
        client?.reportInstall(build.id)
        installStarted = build
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.installNoteLasts * 1_000_000_000))
            if self?.installStarted?.id == build.id { self?.installStarted = nil }
        }
        UIApplication.shared.open(link) { [weak self] opened in
            guard !opened, let self else { return }
            self.installStarted = nil
            self.installProblem = (build, "iOS did not take the build", "This device would not open the install link.")
        }
    }

    /// When the simulator stopped answering; Restart is offered at once on a quiet Mac, and on a
    /// busy one only after `restartAfterOnBusyMac`, as it may yet catch up.
    private(set) var unansweredSince: Date?
    static let restartAfterOnBusyMac: TimeInterval = 60

    /// Why the last fold of an iPhone Duo simulator failed, in the Mac's words; shown for a while.
    private(set) var foldProblem: String?
    @ObservationIgnored private var foldProblemTimer: Task<Void, Never>?

    // MARK: Turning the simulator

    /// For an iPad simulator: turn it to the shape the screen has room for, landscape when the room
    /// is wide and portrait when it is tall. Kept between launches. Turning it by hand stops this
    /// for that simulator until it is opened again.
    var fitsToScreen: Bool = (UserDefaults.standard.object(forKey: "MirrorFitsToScreen") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(fitsToScreen, forKey: "MirrorFitsToScreen")
            if fitsToScreen { turnedByHand = nil; lastFit = nil }
        }
    }
    @ObservationIgnored private var turnedByHand: String?      // the simulator last turned by hand
    /// Whether the picture's room is wider than it is tall, as the layout last said.
    @ObservationIgnored var roomIsWide = false
    @ObservationIgnored private var lastFit: (simulator: String, wide: Bool)?

    func rotate(_ to: String) {
        turnedByHand = showing?.udid
        client?.rotate(to)
    }

    /// Turns an iPad simulator, or an iPhone Duo simulator lying flat, to the
    /// room's shape, once for each change of room or simulator, so an app that will not turn is not
    /// asked again and again. A half-open Duo is never turned: that would change tabletop into book.
    /// True when the simulator was asked to turn.
    @discardableResult
    func fit(roomIsWide: Bool) -> Bool {
        guard fitsToScreen, let showing, showing.canRotate, turnedByHand != showing.udid,
              videoSize.width > 0, videoSize.height > 0 else { return false }
        let flatDuo = showing.hasHinge && screen?.role == "inner" && screen?.isBent == false
        guard showing.isIPad || flatDuo else { return false }
        let pictureIsWide = videoSize.width > videoSize.height
        guard pictureIsWide != roomIsWide else { lastFit = (showing.udid, roomIsWide); return false }
        if let lastFit, lastFit.simulator == showing.udid, lastFit.wide == roomIsWide { return false }
        lastFit = (showing.udid, roomIsWide)
        client?.rotate(roomIsWide ? MirrorRotationRequest.landscape : MirrorRotationRequest.portrait)
        return true
    }

    // MARK: The iPhone Duo

    /// Which screen of an iPhone Duo simulator the picture is, and its hinge, as the Mac last said.
    private(set) var screen: MirrorScreenState?

    /// True while an iPhone Duo simulator is shown as a 3D device to fold. Touches then move the
    /// device, not the simulator. It goes back to the flat picture `foldReturnAfter` after the last
    /// drag, or when Done is tapped.
    private(set) var folding = false
    @ObservationIgnored private var foldReturn: Task<Void, Never>?
    @ObservationIgnored private var dragging = false
    static let foldReturnAfter: UInt64 = 1_500_000_000
    /// The strip at the bottom of the picture's room that the fold buttons and their line of words
    /// have; the 3D Duo keeps clear of it.
    static let foldControlsHeight: CGFloat = 96
    /// The angle last asked of the simulator and not yet seen on it; nil once it is there. While it
    /// is set the 3D Duo stays up: going back to the picture first would show the old screen.
    private(set) var foldWanted: Double?
    /// For a fold to open flat: the shape the inner screen was asked to have.
    @ObservationIgnored private var foldWide: Bool?
    @ObservationIgnored private var foldSent: (degrees: Double, at: Date)?
    /// How long the simulator has to get to the angle before the 3D Duo stops waiting for it. The
    /// hinge takes a third of a second (iOS 27.3 simulator, 21 November 2026); this is ten times that.
    static let foldWait: TimeInterval = 3
    @ObservationIgnored private var returning = false
    @ObservationIgnored private var modelSync: Task<Void, Never>?

    /// Which screen of an iPhone Duo simulator is lit and how far it is open, as two short words:
    /// "Inner" and "Open", "Inner" and "90°", "Outer" and "Closed". Nil for a simulator without a hinge.
    var screenParts: (screen: String, position: String)? {
        guard let screen, showing?.hasHinge == true else { return nil }
        let name = screen.role == "outer" ? "Outer" : "Inner"
        guard let degrees = screen.degrees else { return (name, "") }
        if degrees <= 5 { return (name, "Closed") }
        if degrees >= 175 { return (name, "Open") }
        return (name, "\(Int(degrees))°")
    }

    /// The same in one line: "Inner screen · Open", "Inner screen · Half open 90°", "Outer screen · Closed".
    var screenLine: String? {
        guard let parts = screenParts else { return nil }
        let position = parts.position.hasSuffix("°") ? "Half open \(parts.position)" : parts.position
        return position.isEmpty ? "\(parts.screen) screen" : "\(parts.screen) screen · \(position)"
    }

    private var outerLit: Bool { screen?.role == "outer" }

    /// Turns the flat picture into the 3D Duo. Its halves get the stream's frames first, so the
    /// picture on them is live from the moment they take over.
    func beginFolding() {
        guard !folding, !surface.isFolding, hasPicture, showing?.hasHinge == true, let client else { return }
        folding = true
        client.mirror(to: surface.foldView.renderers)
        surface.foldView.bottomReserve = Self.foldControlsHeight
        surface.foldView.onFold = { [weak self] degrees in self?.foldTo(degrees) }
        // While a finger is still folding, the simulator's hinge follows it: one message for each
        // few degrees, which the simulator takes as it does a slider being dragged.
        surface.foldView.onFolding = { [weak self] degrees in
            guard let self else { return }
            if let sent = self.foldSent, abs(sent.degrees - degrees) < 4 || Date().timeIntervalSince(sent.at) < 0.08 { return }
            self.foldTo(degrees, settled: false)
        }
        surface.foldView.onDragging = { [weak self] dragging in
            guard let self else { return }
            self.dragging = dragging
            if dragging { self.foldReturn?.cancel() } else { self.scheduleFoldReturn() }
        }
        Task { @MainActor [weak self] in
            // Time for the halves to show the frame on screen now; a still screen sends no new one.
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard let self, self.folding else { return }
            self.surface.beginFolding(at: self.screen?.degrees ?? (self.outerLit ? 0 : 180), outerLit: self.outerLit)
        }
    }

    /// Lays the Duo flat again and gives way to the flat picture, which must be the simulator's
    /// screen as it now is. So a fold still on its way is waited for first: until the Mac says the
    /// simulator is there and that screen's picture has arrived, a third of a second as a rule and
    /// `foldWait` at most. Then, if the room has changed shape while the Duo was being folded, the
    /// simulator is turned to it, so that nothing turns once the picture is back: a few hundredths
    /// of a second, and `turnWait` at most.
    func endFolding() {
        foldReturn?.cancel()
        guard folding, !returning else { return }
        guard surface.isFolding else { finishFolding(); return }
        returning = true
        Task { @MainActor [weak self] in
            while let self, self.returning, self.foldWanted != nil || !self.pictureIsOfScreen,
                  let sent = self.foldSent, Date().timeIntervalSince(sent.at) < Self.foldWait {
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
            if let self, self.returning, self.fit(roomIsWide: self.roomIsWide) {
                let asked = Date()
                while self.returning, Date().timeIntervalSince(asked) < Self.turnWait, (self.videoSize.width > self.videoSize.height) != self.roomIsWide {
                    try? await Task.sleep(nanoseconds: 30_000_000)
                }
            }
            guard let self, self.returning else { return }
            self.returning = false
            self.finishFolding()
        }
    }
    static let turnWait: TimeInterval = 0.8

    /// Stops folding at once, as when the simulator goes away.
    private func stopFolding() {
        returning = false
        finishFolding()
    }

    private func finishFolding() {
        foldReturn?.cancel()
        modelSync?.cancel()
        guard folding else { return }
        folding = false
        foldWanted = nil
        foldSent = nil
        guard surface.isFolding else { client?.mirror(to: []); return }
        surface.endFolding(outerLit: outerLit) { [weak self] in
            guard let self, !self.folding else { return }
            self.client?.mirror(to: [])
        }
    }

    /// Goes back to the flat picture a moment after the last drag.
    private func scheduleFoldReturn() {
        foldReturn?.cancel()
        foldReturn = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.foldReturnAfter)
            guard !Task.isCancelled, let self, !self.dragging else { return }
            self.endFolding()
        }
    }

    /// Folds the simulator to the angle the 3D Duo is at, held the way the Duo is shown: with its
    /// hinge upright, like a book, the outer screen is portrait and the inner one landscape; with the
    /// hinge across, like a laptop, the inner one is portrait. Closed, it is always held upright: the
    /// outer screen's home screen is upright only. The Mac decides how the device is held from the
    /// posture and the shape asked for.
    ///
    /// While a finger is still folding (`settled` false) only the hinge is moved. Closed or opened
    /// flat, the 3D Duo is told how the picture will be held, and turns to it once it has finished
    /// folding, before the picture arrives; the picture then comes up upright on it.
    private func foldTo(_ degrees: Double, settled: Bool = true) {
        let upright = surface.foldView.hingeIsUpright
        let request: MirrorFoldRequest
        foldWide = nil
        if !settled {
            request = MirrorFoldRequest(posture: MirrorFoldRequest.angle, degrees: degrees.rounded())
        } else if degrees <= 5 {
            request = MirrorFoldRequest(posture: MirrorFoldRequest.closed, orientation: MirrorRotationRequest.portrait)
            surface.foldView.turnWhenFolded(upright: true)
        } else if degrees >= 175 {
            // Open flat, it is held to fit the room when Fit to Screen is on: the room as it is now.
            let fits = fitsToScreen && showing?.canRotate == true && turnedByHand != showing?.udid
            let wide = fits ? roomIsWide : upright
            foldWide = wide
            if fits { lastFit = nil }
            request = MirrorFoldRequest(posture: MirrorFoldRequest.open, orientation: wide ? MirrorRotationRequest.landscape : MirrorRotationRequest.portrait)
            surface.foldView.turnWhenFolded(upright: wide)
        } else {
            request = MirrorFoldRequest(posture: upright ? MirrorFoldRequest.book : MirrorFoldRequest.tabletop, degrees: degrees.rounded())
        }
        foldSent = (degrees, Date())
        foldWanted = degrees
        client?.fold(request)
    }

    /// The line under the 3D Duo: how to fold it, or why the screen lit is not the one expected.
    var foldNote: String {
        if foldWanted == nil, let screen, let degrees = screen.degrees, screen.role == "outer", degrees > 20 {
            return "iOS lights the outer screen at this angle. Open it flat for the inner screen."
        }
        return "Drag a half, or pinch, to fold it. Tap Done to use the simulator again."
    }

    /// Folds the simulator to an angle chosen with a button, moving the 3D Duo there too.
    func setFold(_ degrees: Double) {
        guard folding else { return }
        surface.foldView.set(degrees)       // reports back through `onFold`
        scheduleFoldReturn()
    }

    /// Whether the simulator is where it was last asked to be.
    private func foldArrived(_ screen: MirrorScreenState) -> Bool {
        guard let wanted = foldWanted, let degrees = screen.degrees else { return true }
        if wanted <= 5 { return degrees <= 5 && screen.role == "outer" }
        if wanted >= 175 { return degrees >= 175 && screen.role == "inner" && foldWide.map { $0 == (screen.width > screen.height) } ?? true }
        return abs(degrees - wanted) <= 5
    }

    /// Whether the picture now decoded is of the screen the Mac last named. The Mac names the screen
    /// a moment before the first frame of it arrives; until then the picture is the other screen's,
    /// which has another shape.
    private var pictureIsOfScreen: Bool {
        guard let screen, screen.width > 0, screen.height > 0, videoSize.width > 0, videoSize.height > 0 else { return true }
        return abs(videoSize.width / videoSize.height - screen.width / screen.height) < 0.04
    }

    /// Moves the 3D Duo's picture to the screen the simulator now lights, and turns the Duo to the
    /// way that picture is held if it is not already, once that screen's picture is the one
    /// arriving, or after half a second whatever the picture.
    private func syncFoldModel() {
        modelSync?.cancel()
        guard folding, let screen else { return }
        // While a fold is on its way, the screen it is leaving is of no interest: as the simulator
        // shuts its inner screen may turn, and as it opens its outer one may, on the way out.
        if let wanted = foldWanted, (wanted <= 5) == (screen.role == "inner") { return }
        let show = { [weak self] in
            guard let self, self.folding, let screen = self.screen else { return }
            self.surface.foldView.show(outerLit: screen.role == "outer", pictureIsWide: screen.width > screen.height)
        }
        if pictureIsOfScreen { show(); return }
        modelSync = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            show()
        }
    }

    /// True while the Mac's menu, or a screen behind it, is what is on screen.
    var showsHub: Bool {
        state == .connected && choosing && progress == nil
    }

    /// True while a simulator this viewer may leave or shut down is on screen.
    var canLeaveByChoice: Bool {
        guard let showing else { return false }
        return state == .connected && !choosing && showing.canChoose && !showing.udid.isEmpty
    }

    /// True once a frame of the simulator now shown has been decoded.
    var hasPicture: Bool { state == .connected && pictureSeen && !choosing }
    private var pictureSeen = false

    func start(destination: StreamDestination, identity: Data, ownRelays: [String]) {
        guard client == nil else { return }
        let client = MirrorClient(target: destination.target, identity: identity, ownRelays: ownRelays,
                                  renderer: surface.display.displayLayer.sampleBufferRenderer)
        client.onState = { [weak self] state in
            guard let self else { return }
            self.state = state
            // Once for each connection: the Mac then sends the builds again whenever they change.
            if state == .connected, !self.askedForBuilds {
                self.askedForBuilds = true
                self.client?.requestBuilds()
            } else if state != .connected {
                self.askedForBuilds = false
                self.askedForIdentity = false
                self.dropFetch()
            }
            if state != .connected {
                self.stopFolding()
                self.pictureSeen = false
                if self.progress != nil {
                    self.choiceProblem = MirrorProblem(code: MirrorProblem.other, title: "The connection dropped",
                                                       message: "\(destination.title) stopped answering before it finished. It may still have done it.", action: MirrorProblem.retry)
                }
                self.progress = nil     // the Mac drops a choice when its viewer goes away
                self.busy = [:]
            }
        }
        client.onShowing = { [weak self] showing in
            guard let self else { return }
            self.showing = showing
            self.choosing = false
            self.choiceAnswered = true
            self.progress = nil
            self.choiceProblem = nil
            self.pictureSeen = false
            self.screen = nil
            self.health = nil
            self.unansweredSince = nil
            self.stopFolding()
        }
        client.onHealth = { [weak self] health in
            guard let self else { return }
            self.health = health.responding ? nil : health
            self.unansweredSince = health.responding ? nil : (self.unansweredSince ?? Date())
        }
        client.onHostLoad = { [weak self] load in self?.hostLoad = load }
        client.onBuilds = { [weak self] builds in self?.received(builds) }
        client.onInstallIdentity = { [weak self] identity in self?.gotInstallIdentity(identity) }
        client.onInstallIdentityFailed = { [weak self] message in self?.identityProblem = message }
        client.onBuildPiece = { [weak self] piece in self?.gotPiece(piece) }
        client.onFetchFailed = { [weak self] failure in self?.fetchFailed(failure) }
        client.onScreen = { [weak self] screen in
            guard let self else { return }
            self.screen = screen
            if self.foldArrived(screen) { self.foldWanted = nil }
            self.syncFoldModel()
        }
        client.onSimulators = { [weak self] list in
            guard let self else { return }
            self.list = list
            self.stopFolding()
            self.choosing = true
            self.pictureSeen = false
            self.busy = [:]         // the list is sent when a shut-down or a delete is done
        }
        client.onProgress = { [weak self] progress in
            guard let self else { return }
            if progress.step != "foldFailed" { self.choiceAnswered = true }
            if progress.step == "foldFailed" {
                self.foldWanted = nil
                self.syncFoldModel()        // whatever the simulator shows now is what the 3D Duo shows
                self.showFoldProblem("\(Self.problem(in: progress).title). Try again.")
            } else if progress.step == "failed" {
                // A failed choice may have changed what is running, so the list is read again. A
                // list that itself could not be read is not asked for again, or it would be for ever.
                let choiceFailed = self.progress != nil || !self.busy.isEmpty
                self.progress = nil
                self.busy = [:]
                self.choiceProblem = Self.problem(in: progress)
                if choiceFailed { self.client?.requestSimulators() }
            } else {
                self.progress = progress
            }
        }
        client.onStats = { [weak self] stats in
            guard let self else { return }
            self.stats = stats
            if stats.framesPerSecond > 0 { self.pictureSeen = true }
        }
        client.onVideoSize = { [weak self] size in
            guard let self else { return }
            self.videoSize = size
            self.surface.videoSize = size
            self.syncFoldModel()
        }
        surface.onTouch = { [weak client, weak self] kind, points, size, time in
            // A finger on the picture itself takes over from the trackpad's pointer.
            if kind == 1 { self?.pointer.hide() }
            client?.touch(kind: kind, points: points, in: size, at: time)
        }
        // The pointer's touches are shares of the picture, so they are sent as points in a view one point square.
        pointer.send = { [weak client] kind, share, time in client?.touch(kind: kind, points: [share], in: CGSize(width: 1, height: 1), at: time) }
        pointer.pictureSize = { [weak surface] in surface?.pictureSize ?? .zero }
        pointer.onChange = { [weak surface] place, pressed in surface?.showPointer(at: place, pressed: pressed) }
        surface.onPane = { [weak client] size, hertz in client?.setPane(size, displayHertz: hertz) }
        self.client = client
        client.start()
    }

    func stop() {
        client?.stop()
        client = nil
    }

    // MARK: Choosing a simulator

    /// Opens a simulator from the list. The Mac boots it first if it is shut down.
    func open(_ simulator: MirrorSimulator) {
        asked = .open(simulator)
        choiceProblem = nil
        pictureSeen = false
        plan = simulator.booted ? ["opening"] : ["booting", "opening"]
        progress = MirrorSimulatorProgress(step: simulator.booted ? "opening" : "booting", udid: simulator.udid, name: simulator.name)
        client?.choose(MirrorSimulatorChoice(udid: simulator.udid))
        watchChoice()
    }

    /// A choice the Mac never answers would leave its progress on screen for ever. If the Mac has
    /// said nothing about it within `choiceAnswerLimit` seconds, the list comes back with a message.
    private func watchChoice() {
        choiceAnswered = false
        choiceWatch?.cancel()
        choiceWatch = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.choiceAnswerLimit * 1_000_000_000)
            guard !Task.isCancelled, let self, !self.choiceAnswered, self.progress != nil, self.choosing else { return }
            self.progress = nil
            self.choiceProblem = MirrorProblem(code: MirrorProblem.other, title: "Your Mac did not answer",
                                               message: "It may be asleep, or AXe may have stopped on it.", action: MirrorProblem.retry)
            self.client?.requestSimulators()
        }
    }

    /// Has the Mac create a simulator, boot it and show it.
    func create(name: String, deviceType: MirrorDeviceType, runtime: MirrorRuntime) {
        asked = .create(name, deviceType, runtime)
        choiceProblem = nil
        pictureSeen = false
        let shown = name.trimmingCharacters(in: .whitespacesAndNewlines)
        plan = ["creating", "booting", "opening"]
        progress = MirrorSimulatorProgress(step: "creating", name: shown.isEmpty ? deviceType.name : shown)
        client?.choose(MirrorSimulatorChoice(name: shown, deviceType: deviceType.id, runtime: runtime.id))
        watchChoice()
    }

    /// Leaves the simulator on screen and goes back to the Mac's list. The simulator stays booted
    /// unless `shutDown` says otherwise.
    func leave(shutDown: Bool) {
        let udid = showing?.udid ?? ""
        choosing = true
        pictureSeen = false
        progress = nil
        if shutDown, !udid.isEmpty {
            busy[udid] = MirrorSimulatorAction.shutDown
            client?.manage(MirrorSimulatorAction(action: MirrorSimulatorAction.shutDown, udid: udid))
        } else {
            client?.leaveSimulator()
        }
    }

    private func showFoldProblem(_ message: String) {
        foldProblem = message
        foldProblemTimer?.cancel()
        foldProblemTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            self?.foldProblem = nil
        }
    }

    /// Restarts a simulator from the list: shut down, by force if it no longer answers, then booted
    /// and opened.
    func restart(_ simulator: MirrorSimulator) {
        asked = .restart(simulator)
        choiceProblem = nil
        pictureSeen = false
        plan = ["restarting", "booting", "opening"]
        progress = MirrorSimulatorProgress(step: "restarting", udid: simulator.udid, name: simulator.name)
        client?.manage(MirrorSimulatorAction(action: MirrorSimulatorAction.restart, udid: simulator.udid))
        watchChoice()
    }

    /// Restarts the simulator on screen, as `restart` does one in the list.
    func restartShowing() {
        guard canLeaveByChoice, let showing else { return }
        choosing = true
        health = nil
        restart(MirrorSimulator(udid: showing.udid, name: showing.name, booted: true, model: showing.model, os: ""))
    }

    /// Shuts a simulator in the list down. It stays on the Mac.
    func shutDown(_ simulator: MirrorSimulator) {
        asked = .shutDown(simulator)
        choiceProblem = nil
        busy[simulator.udid] = MirrorSimulatorAction.shutDown
        client?.manage(MirrorSimulatorAction(action: MirrorSimulatorAction.shutDown, udid: simulator.udid))
    }

    /// Deletes a simulator from the Mac, with everything in it. The caller has asked first.
    func delete(_ simulator: MirrorSimulator) {
        asked = .delete(simulator)
        choiceProblem = nil
        busy[simulator.udid] = MirrorSimulatorAction.delete
        client?.manage(MirrorSimulatorAction(action: MirrorSimulatorAction.delete, udid: simulator.udid))
    }

    func refreshSimulators() {
        asked = .list
        choiceProblem = nil
        client?.requestSimulators()
    }

    /// The problem a failure carries. A Mac from before problems were sent gives only its own
    /// words, which are worked out the same way here.
    private static func problem(in progress: MirrorSimulatorProgress) -> MirrorProblem {
        progress.problem ?? MirrorProblem.describe(doing: progress.doing ?? (progress.step == "foldFailed" ? "fold" : "open"), errorCode: "",
                                                   technical: progress.message ?? "", name: progress.name)
    }

    /// The button a problem offers, and what it does; nil when there is nothing to do from here.
    var problemAction: (title: String, run: () -> Void)? {
        guard let problem = choiceProblem, let action = problem.action else { return nil }
        switch action {
        case MirrorProblem.restart:
            let simulator: MirrorSimulator? = switch asked {
            case .open(let s), .restart(let s), .shutDown(let s), .delete(let s): s
            default: nil
            }
            guard let simulator else { return ("Try Again", { [weak self] in self?.askAgain() }) }
            return ("Restart Simulator", { [weak self] in self?.restart(simulator) })
        case MirrorProblem.refresh:
            return ("Update List", { [weak self] in self?.refreshSimulators() })
        default:
            return ("Try Again", { [weak self] in self?.askAgain() })
        }
    }

    func dismissProblem() { choiceProblem = nil }

    /// Asks the Mac again for what last failed.
    private func askAgain() {
        switch asked {
        case .list: refreshSimulators()
        case .open(let simulator): open(simulator)
        case .create(let name, let deviceType, let runtime): create(name: name, deviceType: deviceType, runtime: runtime)
        case .shutDown(let simulator): shutDown(simulator)
        case .delete(let simulator): delete(simulator)
        case .restart(let simulator): restart(simulator)
        }
    }
}

/// Places the UIKit surface in SwiftUI.
struct StreamSurface: UIViewRepresentable {
    let session: StreamSession
    func makeUIView(context: Context) -> StreamSurfaceView { session.surface }
    func updateUIView(_ view: StreamSurfaceView, context: Context) {}
}

/// The area the picture may use. Inside it the picture is laid out at the video's own shape, as
/// large as fits, with the touch layer exactly over it.
final class StreamSurfaceView: UIView {
    let display = DisplayView()
    private let touches = TouchView()
    var onTouch: ((UInt8, [CGPoint], CGSize, TimeInterval) -> Void)?
    var onPane: ((CGSize, Int) -> Void)?
    var videoSize = CGSize.zero { didSet { setNeedsLayout() } }
    /// The picture's size on screen, in points.
    var pictureSize: CGSize { display.bounds.size }

    /// The trackpad's pointer, drawn over the picture: a small translucent disc, as iPadOS draws its own.
    private let pointerView = UIView()
    private var pointerAt: CGPoint?

    /// The iPhone Duo simulator as a 3D device, while it is being folded; hidden the rest of the time.
    let foldView = DuoFoldView()
    var isFolding: Bool { !foldView.isHidden }

    /// Shows the pointer at a share of the picture, smaller while a touch is down at it; nil hides it.
    func showPointer(at place: CGPoint?, pressed: Bool) {
        pointerAt = place
        pointerView.isHidden = place == nil
        if let place {
            pointerView.center = CGPoint(x: display.frame.minX + place.x * display.frame.width, y: display.frame.minY + place.y * display.frame.height)
        }
        UIView.animate(withDuration: 0.08) {
            self.pointerView.transform = pressed ? CGAffineTransform(scaleX: 0.72, y: 0.72) : .identity
            self.pointerView.backgroundColor = UIColor(white: pressed ? 0.25 : 0.5, alpha: pressed ? 0.75 : 0.55)
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        display.displayLayer.videoGravity = .resizeAspect
        addSubview(display)
        addSubview(touches)
        // About the size of iPadOS's own pointer on a picture this size, not a fingertip.
        pointerView.bounds = CGRect(x: 0, y: 0, width: 13, height: 13)
        pointerView.layer.cornerRadius = 6.5
        pointerView.layer.borderWidth = 1
        pointerView.layer.borderColor = UIColor(white: 1, alpha: 0.9).cgColor
        pointerView.layer.shadowColor = UIColor.black.cgColor
        pointerView.layer.shadowOpacity = 0.35
        pointerView.layer.shadowRadius = 3
        pointerView.layer.shadowOffset = CGSize(width: 0, height: 1)
        pointerView.backgroundColor = UIColor(white: 0.5, alpha: 0.55)
        pointerView.isUserInteractionEnabled = false
        pointerView.isHidden = true
        addSubview(pointerView)
        foldView.isHidden = true
        addSubview(foldView)
        touches.onTouch = { [weak self] kind, points, time in
            guard let self else { return }
            self.onTouch?(kind, points, self.touches.bounds.size, time)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        var picture = bounds
        if videoSize.width > 0, videoSize.height > 0, bounds.width > 0, bounds.height > 0 {
            let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
            let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
            picture = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        }
        display.frame = picture
        touches.frame = picture
        foldView.frame = bounds
        if let pointerAt {
            pointerView.center = CGPoint(x: picture.minX + pointerAt.x * picture.width, y: picture.minY + pointerAt.y * picture.height)
        }
        // The Mac is told the whole area in pixels, so it can size the video to what can be shown.
        let scale = window?.screen.nativeScale ?? traitCollection.displayScale
        let hertz = window?.screen.maximumFramesPerSecond ?? 60
        onPane?(CGSize(width: bounds.width * scale, height: bounds.height * scale), hertz)
    }
}

extension StreamSurfaceView {
    /// Turns the flat picture into the 3D Duo, which takes its place exactly, then picks it up. The
    /// halves' renderers must already be getting frames. Touches go to the device until `endFolding`.
    func beginFolding(at degrees: Double, outerLit: Bool) {
        foldView.matchPicture(display.frame, outerLit: outerLit, innerIsWide: display.frame.width >= display.frame.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        foldView.isHidden = false
        display.isHidden = true
        pointerView.isHidden = true
        CATransaction.commit()
        touches.isUserInteractionEnabled = false
        foldView.pickUp(at: degrees)
    }

    /// Lays the Duo flat over the picture as it now is, then gives way to the flat picture.
    func endFolding(outerLit: Bool, done: @escaping () -> Void) {
        layoutIfNeeded()        // the picture's frame for the video as it is now
        foldView.layDown(over: display.frame, outerLit: outerLit, innerIsWide: display.frame.width >= display.frame.height) { [weak self] in
            guard let self else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.display.isHidden = false
            self.foldView.isHidden = true
            CATransaction.commit()
            self.touches.isUserInteractionEnabled = true
            done()
        }
    }
}

final class DisplayView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

/// Sits over the picture and passes one or two fingers on to the Mac. Kinds: 1 down, 2 up,
/// 3 cancel, 4 move, 5 a second finger joining one that is already down.
///
/// The simulator's input takes one contact or two, and a pair goes up together. So when one finger
/// of a pair lifts, the pair ends there. The finger that stays is not passed on unless it then moves
/// away, in which case it starts a new touch. Lifting it or starting it at once would read as a tap.
final class TouchView: UIView {
    var onTouch: ((UInt8, [CGPoint], TimeInterval) -> Void)?
    private var tracked: [UITouch] = []
    private var leftover: CGPoint?      // where the remaining finger was when its pair ended; nil when there is none
    private static let leftoverSlop: CGFloat = 10

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityLabel = "Simulator screen"
        accessibilityIdentifier = "stream.picture"
        accessibilityTraits = .allowsDirectInteraction
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private var points: [CGPoint] { tracked.map { $0.location(in: self) } }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let time = touches.first?.timestamp ?? ProcessInfo.processInfo.systemUptime
        let before = tracked.count
        for touch in touches where tracked.count < 2 { tracked.append(touch) }
        guard tracked.count > before else { return }        // a third finger: not passed on
        // A finger already down and passed on is joined; otherwise this is a fresh touch-down.
        let joining = before == 1 && leftover == nil
        leftover = nil
        onTouch?(joining ? 5 : 1, points, time)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard touches.contains(where: tracked.contains) else { return }
        let time = touches.first?.timestamp ?? ProcessInfo.processInfo.systemUptime
        if let origin = leftover {
            guard let point = points.first, hypot(point.x - origin.x, point.y - origin.y) > Self.leftoverSlop else { return }
            leftover = nil
            onTouch?(1, points, time)
            return
        }
        onTouch?(4, points, time)
    }

    private func finish(_ kind: UInt8, _ touches: Set<UITouch>) {
        guard touches.contains(where: tracked.contains) else { return }
        let time = touches.first?.timestamp ?? ProcessInfo.processInfo.systemUptime
        if leftover == nil { onTouch?(kind, points, time) }
        tracked.removeAll { touches.contains($0) }
        leftover = tracked.isEmpty ? nil : points.first
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(2, touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(3, touches) }
}
