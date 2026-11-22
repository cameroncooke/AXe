import AVKit
import SwiftUI

/// A short looping video that shows where to tap in Settings, which goes on playing in Picture in
/// Picture when the app is left: the person follows it in Settings itself, with the steps floating
/// over what they are doing.
///
/// iOS starts Picture in Picture by itself, when the app goes to the background, only for a video
/// that is playing in view with the audio session set for playback. The video has no sound, and
/// the session is given back as soon as the video stops.
///
/// The player owns the one view the video is drawn in, and the one Picture in Picture controller
/// for it, for as long as the setup screen is up. The screen lays itself out again when the app
/// goes to the background (iOS takes its pictures of it at other sizes then), and a layout that
/// made a new video view each time would take the floating video down with the old one a moment
/// after it appeared. So the layout only ever borrows this view (`TutorialVideo`).
@MainActor
final class TutorialPlayer: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {
    final class Surface: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    let player = AVQueuePlayer()
    /// The view the video is drawn in. There is one, whatever the screen's layout does.
    let surface = Surface()
    private var looper: AVPlayerLooper?
    private var controller: AVPictureInPictureController?
    private var returned: NSObjectProtocol?
    /// The video's shape, width over height, for the view that shows it.
    @Published private(set) var aspect: CGFloat = 0.75
    @Published private(set) var available = false

    /// `name` is a video in the app's bundle. A build without it shows no video and loses nothing else.
    init(resource name: String) {
        super.init()
        guard let url = Bundle.main.url(forResource: name, withExtension: "mp4") else { return }
        let item = AVPlayerItem(url: url)
        looper = AVPlayerLooper(player: player, templateItem: item)
        player.isMuted = true
        player.allowsExternalPlayback = false
        surface.playerLayer.player = player
        surface.playerLayer.videoGravity = .resizeAspect
        surface.backgroundColor = .black
        available = true
        if AVPictureInPictureController.isPictureInPictureSupported() {
            let made = AVPictureInPictureController(playerLayer: surface.playerLayer)
            made?.canStartPictureInPictureAutomaticallyFromInline = true
            made?.requiresLinearPlayback = true     // a loop to follow: no skipping about in it
            made?.delegate = self
            controller = made
        }
        // Back in the app, the video goes back to its place on the screen: left floating, it
        // would lie over the very buttons the person has come back for.
        returned = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller?.stopPictureInPicture() }
        }
        Task { [weak self] in
            guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
                  let size = try? await track.load(.naturalSize), size.height > 0 else { return }
            self?.aspect = size.width / size.height
        }
    }

    deinit {
        if let returned { NotificationCenter.default.removeObserver(returned) }
    }

    func play() {
        guard available else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
    }

    /// Stops the video, in view and in Picture in Picture, and gives the audio session back.
    func stop() {
        guard available else { return }
        controller?.stopPictureInPicture()
        player.pause()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // Coming back to the app from Picture in Picture needs nothing restored: the video is still in view.
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}

/// The tutorial in view: a place in the layout that the player's own view is put into. When the
/// layout makes this place again somewhere else, the same view moves there, and Picture in Picture
/// goes on.
struct TutorialVideo: UIViewRepresentable {
    let tutorial: TutorialPlayer

    func makeUIView(context: Context) -> UIView {
        let place = UIView()
        place.backgroundColor = .black
        adopt(into: place)
        return place
    }

    func updateUIView(_ place: UIView, context: Context) {
        // Another place may have had the view since this one was made, and gone.
        if tutorial.surface.superview == nil { adopt(into: place) }
    }

    private func adopt(into place: UIView) {
        let surface = tutorial.surface
        surface.frame = place.bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        place.addSubview(surface)
    }
}
