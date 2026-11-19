import AVFoundation
import SwiftUI
import UIKit

/// The live simulator: the picture, with the app's own controls beside it or above and below it,
/// whichever leaves the picture bigger (see `MirrorViewerLayout`). The controls never cover the
/// picture, so every touch on the picture is a touch on the simulator.
struct StreamScreen: View {
    let destination: StreamDestination
    let model: AppModel
    var onPairAgain: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var session = StreamSession()
    @State private var showsInfo = false
    @State private var infoTimer: Task<Void, Never>?

    var body: some View {
        GeometryReader { proxy in
            let side = MirrorViewerLayout.controlsAtSide(pane: proxy.size, video: session.videoSize)
            // One layout value, so the picture keeps its place in the view tree when the controls move.
            let layout = side ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                if !side { topBar }
                ZStack {
                    Color.black
                    StreamSurface(session: session)
                        .opacity(session.hasPicture ? 1 : 0)
                    overlay
                    if side, showsInfo, session.hasPicture { infoCard }
                    if side, session.hasPicture, session.stats.framesPerSecond > 0 { frameRate }
                }
                if side { sideBar } else { bottomBar }
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
            if phase == .active { session.client?.enteredForeground() }
        }
    }

    private var closeButton: some View {
        Button {
            dismiss()
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
            Text(destination.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(statusLine).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
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

    private func flashInfo() {
        infoTimer?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { showsInfo = true }
        infoTimer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.4)) { showsInfo = false }
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
                .accessibilityHint("Shows the Mac's name and the frame rate")
            }
            Spacer(minLength: 0)
            if !destination.isDemo {
                Group {
                    controlButton("Home", systemImage: "house.fill") { session.client?.pressButton(2) }
                    controlButton("App switcher", systemImage: "square.on.square") { session.client?.pressButton(2, count: 2) }
                    controlButton("Lock", systemImage: "lock.fill") { session.client?.pressButton(3) }
                }
                .disabled(session.state != .connected)
            }
        }
        .foregroundStyle(.white)
        .padding(.vertical, 10)
        .frame(width: MirrorViewerLayout.sideBar)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            closeButton
            VStack(alignment: .leading, spacing: 1) {
                Text(destination.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(statusLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
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
            guard session.hasPicture else { return "Waiting for the picture" }
            // A still screen sends no frames, so the rate is shown only while the picture moves.
            return session.stats.framesPerSecond > 0 ? "Live, \(session.stats.framesPerSecond) frames a second" : "Live"
        case .reconnecting: return "Reconnecting"
        case .unreachable, .refused: return "Not connected"
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        if destination.isDemo {
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
            .disabled(session.state != .connected)
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
            notice(progress: true, title: "Connecting to \(destination.title)", detail: nil)
        case .connected:
            if !session.hasPicture { notice(progress: true, title: "Waiting for the picture", detail: nil) }
        case .reconnecting:
            notice(progress: true, title: "Reconnecting", detail: nil)
        case .unreachable(let reason, let retrying):
            unreachable(reason, retrying: retrying)
        case .refused(.notPaired):
            notice(progress: false, title: "This device is no longer paired",
                   detail: "On your Mac, run axe mirror pair, then pair again here.") {
                Button("Pair again") { dismiss(); onPairAgain() }.buttonStyle(.borderedProminent)
            }
        case .refused(.busy):
            notice(progress: false, title: "The demo is in use",
                   detail: "Someone else is trying it right now. It frees up within three minutes.") {
                Button("Try again") { session.client?.retry() }.buttonStyle(.borderedProminent)
            }
        }
    }

    /// What is wrong and what to do about it, with a way to try again. While the app is still
    /// trying by itself it says so; after two minutes it stops and says that instead.
    private func unreachable(_ reason: MirrorUnreachable, retrying: Bool) -> some View {
        VStack(spacing: 14) {
            Image(systemName: reason == .offline ? "wifi.slash" : reason == .relay ? "network.slash" : "desktopcomputer.trianglebadge.exclamationmark")
                .font(.system(size: 34)).foregroundStyle(.secondary)
            Text(unreachableTitle(reason)).font(.headline).multilineTextAlignment(.center)
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
                    "2. In a terminal on it, host a booted simulator:",
                    "$ axe mirror --udid <UDID>",
                    "axe list-simulators shows the UDIDs. This screen connects by itself once the host is running."]
        }
    }

    private func notice(progress: Bool, title: String, detail: String?, @ViewBuilder actions: () -> some View = { EmptyView() }) -> some View {
        VStack(spacing: 14) {
            if progress { ProgressView().controlSize(.large).tint(.white) }
            Text(title).font(.headline).multilineTextAlignment(.center)
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

    /// True once a frame has been decoded since the last connection.
    var hasPicture: Bool { state == .connected && pictureSeen }
    private var pictureSeen = false

    func start(destination: StreamDestination, identity: Data, ownRelays: [String]) {
        guard client == nil else { return }
        let client = MirrorClient(target: destination.target, identity: identity, ownRelays: ownRelays,
                                  renderer: surface.display.displayLayer.sampleBufferRenderer)
        client.onState = { [weak self] state in
            guard let self else { return }
            self.state = state
            if state != .connected { self.pictureSeen = false }
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
        }
        surface.onTouch = { [weak client] kind, points, size, time in client?.touch(kind: kind, points: points, in: size, at: time) }
        surface.onPane = { [weak client] size, hertz in client?.setPane(size, displayHertz: hertz) }
        self.client = client
        client.start()
    }

    func stop() {
        client?.stop()
        client = nil
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

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        display.displayLayer.videoGravity = .resizeAspect
        addSubview(display)
        addSubview(touches)
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
        // The Mac is told the whole area in pixels, so it can size the video to what can be shown.
        let scale = window?.screen.nativeScale ?? traitCollection.displayScale
        let hertz = window?.screen.maximumFramesPerSecond ?? 60
        onPane?(CGSize(width: bounds.width * scale, height: bounds.height * scale), hertz)
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
