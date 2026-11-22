import SwiftUI
import UIKit

/// A pointer for the simulator, moved from a trackpad instead of by touching the picture. It is
/// for when the picture is out of reach or awkward to touch: an iPhone Duo standing on a table has
/// the picture on its upright half and the trackpad on the half lying flat.
///
/// The pointer is drawn by this app over the picture; the simulator knows nothing of it. A click
/// is a touch at the pointer, a drag is a touch that moves with it, and a two-finger scroll is a
/// swipe that starts at it. So it works on any simulator, iPhone or iPad, and through any host,
/// because all the Mac ever sees are the touches it already understands. What it does not do is
/// what only a real pointer can: hover effects, and the pointer shapes iPadOS draws itself.
@MainActor
final class SimulatorPointer {
    /// Where the pointer is, as a share of the picture; nil while it is hidden.
    private(set) var position: CGPoint?
    private var pressed = false
    private var scrollPoint: CGPoint?

    /// Shows the pointer, or hides it: where, and whether a touch is down at it.
    var onChange: ((CGPoint?, Bool) -> Void)?
    /// Sends a touch: 1 down, 2 up, 4 move, at a share of the picture, at this time.
    var send: ((UInt8, CGPoint, TimeInterval) -> Void)?
    /// The picture's size on this screen in points, so that a finger's travel on the trackpad is
    /// the pointer's travel on the picture.
    var pictureSize: () -> CGSize = { .zero }

    /// How much further the pointer travels than the finger. The trackpad is smaller than the picture.
    private static let gain: CGFloat = 1.7

    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func share(of travel: CGPoint, gain: CGFloat) -> CGPoint {
        let size = pictureSize()
        guard size.width > 0, size.height > 0 else { return .zero }
        return CGPoint(x: travel.x * gain / size.width, y: travel.y * gain / size.height)
    }

    private func moved(_ point: CGPoint, by change: CGPoint) -> CGPoint {
        CGPoint(x: min(1, max(0, point.x + change.x)), y: min(1, max(0, point.y + change.y)))
    }

    /// The finger moved this far on the trackpad. A pointer that was hidden appears in the middle.
    func move(by travel: CGPoint) {
        let place = moved(position ?? CGPoint(x: 0.5, y: 0.5), by: share(of: travel, gain: Self.gain))
        position = place
        if pressed { send?(4, place, Self.now()) }
        onChange?(place, pressed)
    }

    /// A tap on the trackpad: a touch down and up where the pointer is.
    func click() {
        guard !pressed, scrollPoint == nil, let place = position else { return }
        send?(1, place, Self.now())
        onChange?(place, true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self else { return }
            self.send?(2, place, Self.now())
            if !self.pressed { self.onChange?(self.position, false) }
        }
    }

    /// The finger has rested on the trackpad: a touch goes down at the pointer and moves with it,
    /// for dragging and for whatever a long press brings up.
    func press() {
        guard !pressed, scrollPoint == nil else { return }
        let place = position ?? CGPoint(x: 0.5, y: 0.5)
        position = place
        pressed = true
        send?(1, place, Self.now())
        onChange?(place, true)
    }

    func release() {
        guard pressed, let place = position else { return }
        pressed = false
        send?(2, place, Self.now())
        onChange?(place, false)
    }

    /// Two fingers on the trackpad: a swipe that starts at the pointer and follows the fingers, so
    /// the content moves the way they do. The pointer stays where it is.
    func scrollBegan() {
        guard !pressed, scrollPoint == nil else { return }
        let place = position ?? CGPoint(x: 0.5, y: 0.5)
        position = place
        scrollPoint = place
        send?(1, place, Self.now())
        onChange?(place, false)
    }

    func scroll(by travel: CGPoint) {
        guard let from = scrollPoint else { return }
        let place = moved(from, by: share(of: travel, gain: 1))
        scrollPoint = place
        send?(4, place, Self.now())
    }

    func scrollEnded() {
        guard let place = scrollPoint else { return }
        scrollPoint = nil
        send?(2, place, Self.now())
    }

    /// Takes the pointer off the picture, lifting a touch it has down.
    func hide() {
        release()
        scrollEnded()
        position = nil
        onChange?(nil, false)
    }
}

/// The trackpad itself, placed in SwiftUI.
struct Trackpad: UIViewRepresentable {
    let pointer: SimulatorPointer

    func makeUIView(context: Context) -> TrackpadView {
        let view = TrackpadView()
        view.pointer = pointer
        return view
    }

    func updateUIView(_ view: TrackpadView, context: Context) {
        view.pointer = pointer
    }
}

/// Reads fingers as a Mac's trackpad does. One finger moves the pointer. A short touch that goes
/// nowhere is a click. A finger that rests before it moves picks up what is under the pointer and
/// drags it. Two fingers scroll.
final class TrackpadView: UIView {
    var pointer: SimulatorPointer?

    private enum Mode { case idle, undecided, moving, dragging, scrolling }
    private var mode = Mode.idle
    private var tracked: [UITouch] = []
    private var began: TimeInterval = 0
    private var travelled: CGFloat = 0
    private var hold: DispatchWorkItem?

    /// How far a finger may wander and still be a tap or a rest.
    private static let slop: CGFloat = 7
    /// How long a finger rests before it starts a drag.
    private static let holdTime: TimeInterval = 0.4
    /// The longest touch that still counts as a tap.
    private static let tapTime: TimeInterval = 0.3

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityLabel = "Trackpad"
        accessibilityHint = "Moves a pointer over the simulator. Tap to click, rest a finger to drag, use two fingers to scroll."
        accessibilityTraits = .allowsDirectInteraction
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// How far the tracked fingers moved since the last event, on average.
    private func travel(of touches: Set<UITouch>) -> CGPoint {
        let moving = tracked.filter(touches.contains)
        guard !moving.isEmpty else { return .zero }
        var sum = CGPoint.zero
        for touch in moving {
            let now = touch.location(in: self), before = touch.previousLocation(in: self)
            sum.x += now.x - before.x
            sum.y += now.y - before.y
        }
        return CGPoint(x: sum.x / CGFloat(tracked.count), y: sum.y / CGFloat(tracked.count))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let before = tracked.count
        for touch in touches where tracked.count < 2 { tracked.append(touch) }
        guard tracked.count > before else { return }
        if tracked.count == 1 {
            mode = .undecided
            began = touches.first?.timestamp ?? ProcessInfo.processInfo.systemUptime
            travelled = 0
            let rest = DispatchWorkItem { [weak self] in
                guard let self, self.mode == .undecided else { return }
                self.mode = .dragging
                self.pointer?.press()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            hold = rest
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdTime, execute: rest)
        } else {
            // A second finger turns whatever the first was doing into a scroll.
            hold?.cancel()
            if mode == .dragging { pointer?.release() }
            mode = .scrolling
            pointer?.scrollBegan()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let step = travel(of: touches)
        guard step != .zero else { return }
        travelled += hypot(step.x, step.y)
        switch mode {
        case .undecided:
            guard travelled > Self.slop else { return }
            hold?.cancel()
            mode = .moving
            pointer?.move(by: step)
        case .moving, .dragging:
            pointer?.move(by: step)
        case .scrolling:
            pointer?.scroll(by: step)
        case .idle:
            break
        }
    }

    private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
        guard touches.contains(where: tracked.contains) else { return }
        let time = touches.first?.timestamp ?? ProcessInfo.processInfo.systemUptime
        tracked.removeAll { touches.contains($0) }
        if mode == .scrolling {
            pointer?.scrollEnded()
            // A finger left behind goes back to moving the pointer; it cannot become a tap.
            mode = tracked.isEmpty ? .idle : .moving
            return
        }
        guard tracked.isEmpty else { return }
        hold?.cancel()
        switch mode {
        case .undecided where !cancelled && time - began < Self.tapTime: pointer?.click()
        case .dragging: pointer?.release()
        default: break
        }
        mode = .idle
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, cancelled: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, cancelled: true) }
}
