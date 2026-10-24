import UIKit

/// A public, non-recognizing observer for real contacts inside this normal page.
final class DuoControlsTouchObserver: UIGestureRecognizer {
    var onContact: ((DuoControlsContact) -> Void)?
    private var contacts: [ObjectIdentifier: Int] = [:]
    private var nextID = 0
    var activeCount: Int { contacts.count }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches.sorted(by: { $0.location(in: view?.window).x < $1.location(in: view?.window).x }) {
            nextID += 1
            contacts[ObjectIdentifier(touch)] = nextID
            record(touch, phase: "windowTouchBegan")
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches { record(touch, phase: "windowTouchMoved") }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(touches, phase: "windowTouchEnded")
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(touches, phase: "windowTouchCancelled")
    }

    private func finish(_ touches: Set<UITouch>, phase: String) {
        for touch in touches {
            guard let contactID = contacts.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            record(touch, phase: phase, contactID: contactID)
        }
        if contacts.isEmpty { state = .failed }
    }

    private func record(_ touch: UITouch, phase: String, contactID: Int? = nil) {
        guard let identity = contactID ?? contacts[ObjectIdentifier(touch)] else { return }
        let point = touch.location(in: view?.window)
        let hit = touch.view.map { $0.accessibilityIdentifier ?? String(describing: type(of: $0)) } ?? "(none)"
        onContact?(DuoControlsContact(contactID: identity, phase: phase, x: Double(point.x), y: Double(point.y),
            timestamp: touch.timestamp, activeTouches: contacts.count, hitView: hit))
    }
}

final class DuoControlsPad: UIView {
    var onTouches: ((String, Set<UITouch>) -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        onTouches?("touchBegan", touches)
        super.touchesBegan(touches, with: event)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        onTouches?("touchMoved", touches)
        super.touchesMoved(touches, with: event)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        onTouches?("touchEnded", touches)
        super.touchesEnded(touches, with: event)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        onTouches?("touchCancelled", touches)
        super.touchesCancelled(touches, with: event)
    }
}
