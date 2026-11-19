import Foundation
import Testing
@testable import AXe

@Suite("Mirror: why a host cannot be reached, and when the viewer stops trying")
struct MirrorReachabilityTests {
    @Test("The reason comes from what the viewer can check: its own network, then the relays")
    func reason() {
        let offline = MirrorUnreachable.reason(hasNetwork: false, relays: 1, answering: 0)
        let blocked = MirrorUnreachable.reason(hasNetwork: true, relays: 2, answering: 0)
        let hostDown = MirrorUnreachable.reason(hasNetwork: true, relays: 2, answering: 1)
        // A host with no relays of ours is dialled through public ones, which cannot be asked.
        let publicOnly = MirrorUnreachable.reason(hasNetwork: true, relays: 0, answering: 0)
        #expect(offline == .offline)
        #expect(blocked == .relay)
        #expect(hostDown == .host)
        #expect(publicOnly == .host)
    }

    @Test("Ten quiet seconds, then the reason with the app still trying, then it stops at two minutes")
    func phases() {
        let start = MirrorRetry.phase(elapsed: 0)
        let almost = MirrorRetry.phase(elapsed: 9.9)
        let explained = MirrorRetry.phase(elapsed: 10)
        let late = MirrorRetry.phase(elapsed: 119.9)
        let stopped = MirrorRetry.phase(elapsed: 120)
        #expect(start == .quiet)
        #expect(almost == .quiet)
        #expect(explained == .explaining)
        #expect(late == .explaining)
        #expect(stopped == .stopped)
    }

    @Test("The first retry comes after a second, later ones five seconds apart")
    func pacing() {
        let first = MirrorRetry.pause(afterFailures: 1)
        let later = MirrorRetry.pause(afterFailures: 2)
        #expect(first == 1)
        #expect(later == 5)
    }
}

@Suite("Mirror: where the viewer app puts its controls")
struct MirrorViewerLayoutTests {
    private let phone = CGSize(width: 1056, height: 2296)

    @Test("On a whole iPhone screen and on half an iPad the side column leaves the bigger picture")
    func sideWins() {
        let iphone = CGSize(width: 440, height: 860)
        let half = CGSize(width: 590, height: 800)
        let phoneSide = MirrorViewerLayout.pictureWidth(pane: iphone, video: phone, controlsAtSide: true)
        let phoneBars = MirrorViewerLayout.pictureWidth(pane: iphone, video: phone, controlsAtSide: false)
        let atSide = MirrorViewerLayout.controlsAtSide(pane: iphone, video: phone)
        let halfAtSide = MirrorViewerLayout.controlsAtSide(pane: half, video: phone)
        #expect(phoneSide > phoneBars)
        #expect(atSide)
        #expect(halfAtSide)
    }

    @Test("In a pane too narrow to spare a column the bars stay")
    func barsWin() {
        let narrow = CGSize(width: 300, height: 900)
        let bars = MirrorViewerLayout.controlsAtSide(pane: narrow, video: phone)
        let nothing = MirrorViewerLayout.pictureWidth(pane: CGSize(width: 40, height: 40), video: phone, controlsAtSide: true)
        #expect(!bars)
        #expect(nothing == 0)
    }

    @Test("Before the first frame the picture is taken to be a phone's shape")
    func beforeTheFirstFrame() {
        let pane = CGSize(width: 440, height: 860)
        let unknown = MirrorViewerLayout.controlsAtSide(pane: pane, video: .zero)
        let known = MirrorViewerLayout.controlsAtSide(pane: pane, video: MirrorViewerLayout.usualVideo)
        #expect(unknown == known)
    }
}

