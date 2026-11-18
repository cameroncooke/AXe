import AVFoundation
import SwiftUI
import UIKit

/// The live simulator: the picture in the middle, the app's own controls above and below it.
/// The controls never cover the picture, so every touch on the picture is a touch on the simulator.
struct StreamScreen: View {
    let destination: StreamDestination
    let model: AppModel
    var onPairAgain: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var session = StreamSession()

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ZStack {
                Color.black
                StreamSurface(session: session)
                    .opacity(session.hasPicture ? 1 : 0)
                overlay
            }
            bottomBar
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
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { session.client?.enteredBackground() }
            if phase == .active { session.client?.enteredForeground() }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
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
        case .refused: return "Not connected"
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
                .frame(width: 56, height: 40)
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
        case .reconnecting(let attempts):
            notice(progress: true, title: attempts > 2 ? "Can't reach \(destination.title)" : "Reconnecting",
                   detail: attempts > 2 ? unreachableHelp : nil)
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

    private var unreachableHelp: String {
        destination.isDemo
            ? "The demo simulator is not answering. Check your internet connection; still trying."
            : "Check that your Mac is awake and online, and that axe mirror is running on it. Still trying."
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
