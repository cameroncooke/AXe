import CoreGraphics
import Foundation

/// Where the viewer app puts its own controls around the picture. The controls never cover the
/// picture, so they cost it room: bars above and below cost height, a column at the side costs
/// width. A phone's screen is tall and narrow, so in most places the app runs, a whole iPhone
/// screen or half of an iPad's, height is what the picture is short of and the side is the cheaper
/// place. The app works out both and uses whichever leaves the bigger picture.
enum MirrorViewerLayout {
    static let topBar: CGFloat = 52
    static let bottomBar: CGFloat = 56
    static let sideBar: CGFloat = 64

    /// The shape of a phone's screen, used until the first frame says what is really being shown.
    static let usualVideo = CGSize(width: 9, height: 19.5)

    /// The width the picture gets in a pane of this size, with the controls at the side or in bars
    /// above and below.
    static func pictureWidth(pane: CGSize, video: CGSize, controlsAtSide: Bool) -> CGFloat {
        let shape = video.width > 0 && video.height > 0 ? video : usualVideo
        let room = controlsAtSide
            ? CGSize(width: pane.width - sideBar, height: pane.height)
            : CGSize(width: pane.width, height: pane.height - topBar - bottomBar)
        guard room.width > 0, room.height > 0 else { return 0 }
        return min(room.width, room.height * shape.width / shape.height)
    }

    /// Whether a column at the side leaves a bigger picture than bars above and below. Equal
    /// sizes keep the bars, which have room for the Mac's name and the frame rate.
    static func controlsAtSide(pane: CGSize, video: CGSize) -> Bool {
        pictureWidth(pane: pane, video: video, controlsAtSide: true) > pictureWidth(pane: pane, video: video, controlsAtSide: false)
    }
}
