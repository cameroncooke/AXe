import CoreGraphics
import Foundation

/// Where the viewer app puts its own controls around the picture. The controls never cover the
/// picture, so they cost it room: bars above and below cost height, a column at the side costs
/// width, and one bar on top, wide enough for the simulator's buttons too, costs less height than
/// two. The app works out each and uses whichever leaves the biggest picture.
enum MirrorViewerLayout {
    static let topBar: CGFloat = 52
    static let bottomBar: CGFloat = 56
    static let sideBar: CGFloat = 64
    /// The narrowest pane whose one top bar has room for the simulator's buttons as well.
    static let singleBarWidth: CGFloat = 600

    /// The shape of a phone's screen, used until the first frame says what is really being shown.
    static let usualVideo = CGSize(width: 9, height: 19.5)

    enum Placement: Equatable { case bars, side, singleBar }

    /// The room the picture has with the controls placed so.
    static func room(pane: CGSize, placement: Placement) -> CGSize {
        switch placement {
        case .bars: return CGSize(width: pane.width, height: pane.height - topBar - bottomBar)
        case .side: return CGSize(width: pane.width - sideBar, height: pane.height)
        case .singleBar: return CGSize(width: pane.width, height: pane.height - topBar)
        }
    }

    /// The width the picture gets in `room`, keeping the video's shape.
    static func pictureWidth(room: CGSize, video: CGSize) -> CGFloat {
        let shape = video.width > 0 && video.height > 0 ? video : usualVideo
        guard room.width > 0, room.height > 0 else { return 0 }
        return min(room.width, room.height * shape.width / shape.height)
    }

    /// The width the picture gets in a pane of this size, with the controls at the side or in bars
    /// above and below.
    static func pictureWidth(pane: CGSize, video: CGSize, controlsAtSide: Bool) -> CGFloat {
        pictureWidth(room: room(pane: pane, placement: controlsAtSide ? .side : .bars), video: video)
    }

    /// The placement that leaves the biggest picture. Within half a percent of each other the
    /// earlier of bars, side, single bar wins, so the layout does not swap for a pixel and the
    /// bars, which have room for the Mac's name and the frame rate, are kept when nothing is lost.
    static func placement(pane: CGSize, video: CGSize) -> Placement {
        var candidates: [Placement] = [.bars, .side]
        if pane.width >= singleBarWidth { candidates.append(.singleBar) }
        var best = Placement.bars
        var bestWidth = pictureWidth(room: room(pane: pane, placement: .bars), video: video)
        for candidate in candidates.dropFirst() {
            let width = pictureWidth(room: room(pane: pane, placement: candidate), video: video)
            if width > bestWidth * 1.005 { best = candidate; bestWidth = width }
        }
        return best
    }

    /// Whether the top bar has room for the badge that says how the Mac is reached ("Direct" or
    /// "Relay") beside the simulator's name. `buttons` is how many round buttons the bar holds, and
    /// `withKeys` whether Home, App Switcher and Lock are in it too. The name keeps `leastName`
    /// points; when the badge would leave it less, the badge goes, and the simulator's Info screen
    /// says how the Mac is reached. It depends on the screen and the simulator alone, so the
    /// badge does not come and go while a simulator is on screen.
    static func topBarShowsRoute(width: CGFloat, buttons: Int, withKeys: Bool) -> Bool {
        // Margins, Close, the gaps either side of the name, each button with its gap, and the keys.
        let taken = 28 + 36 + 24 + CGFloat(buttons) * 48 + (withKeys ? 196 : 0)
        return width - taken - routeBadge >= leastName
    }
    static let routeBadge: CGFloat = 76
    static let leastName: CGFloat = 90

    /// Whether a column at the side leaves a bigger picture than bars above and below. Equal
    /// sizes keep the bars, which have room for the Mac's name and the frame rate.
    static func controlsAtSide(pane: CGSize, video: CGSize) -> Bool {
        pictureWidth(pane: pane, video: video, controlsAtSide: true) > pictureWidth(pane: pane, video: video, controlsAtSide: false)
    }

    /// Whether, on an iPhone Duo opened flat, the picture should take one page of the screen and
    /// the controls the other: when on one page it keeps at least nine tenths of the size it would
    /// have with the whole screen and the best placement of the bars. `sideBySide` says the pages
    /// are left and right (the Duo open in landscape) rather than top and bottom; `padding` is the
    /// margin each page keeps.
    static func usesPages(pane: CGSize, video: CGSize, sideBySide: Bool, padding: CGFloat = 16) -> Bool {
        guard video.width > 0, video.height > 0 else { return false }
        let page = sideBySide ? CGSize(width: pane.width / 2 - padding, height: pane.height - padding)
                              : CGSize(width: pane.width - padding, height: pane.height / 2 - padding)
        let whole = pictureWidth(room: room(pane: pane, placement: placement(pane: pane, video: video)), video: video)
        return pictureWidth(room: page, video: video) >= 0.9 * whole
    }
}
