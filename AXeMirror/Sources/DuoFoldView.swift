import AVFoundation
import UIKit

/// The iPhone Duo simulator as a 3D device, shown while it is being folded. The picture on it is the
/// live picture: the stream's frames are shown on its halves as well (`renderers`), so nothing stops
/// while the flat picture turns into the device and back.
///
/// The Duo opens like a book held in both hands: each half turns half the fold about the hinge. Short
/// of half open it also turns, more the further it closes, until closed it shows its outer screen,
/// which is on the back of the left half. Whatever the angle, the device is kept centred: it is slid
/// sideways by half of what its outline has moved. Laid flat and square on, at full size, the device
/// is exactly the flat picture, which is how it takes over from the picture and gives back to it
/// without a break.
///
/// Ways to fold it: drag a half away from the middle to open it and towards the middle to close it
/// (closed, a drag either way opens it); spread two fingers to open it and pinch to close it; tap it
/// when it is closed to open it flat. Dragging the space around it tilts it a little. The view reports
/// the angle as it changes (`onFolding`) and when the fingers lift (`onFold`); the caller folds the
/// simulator.
final class DuoFoldView: UIView {
    /// The angle chosen, when the finger lifts after folding.
    var onFold: ((Double) -> Void)?
    /// The angle while a finger is still folding, each time it changes.
    var onFolding: ((Double) -> Void)?
    /// A drag started or ended: the caller holds off returning to the flat picture while one is under way.
    var onDragging: ((Bool) -> Void)?

    /// The live picture on the inner screen's halves and on the outer screen.
    private let leftLive = AVSampleBufferDisplayLayer(), rightLive = AVSampleBufferDisplayLayer(), outerLive = AVSampleBufferDisplayLayer()
    var renderers: [AVSampleBufferVideoRenderer] { [leftLive.sampleBufferRenderer, rightLive.sampleBufferRenderer, outerLive.sampleBufferRenderer] }

    private let cam = CATransformLayer(), closer = CATransformLayer()
    private let leftHalf = CATransformLayer(), rightHalf = CATransformLayer()
    private let leftFront = CALayer(), rightFront = CALayer(), leftBack = CALayer(), rightBack = CALayer()
    private let leftShade = CALayer(), rightShade = CALayer(), outerShade = CALayer()
    /// The inner screen's glass on each half: the frame runs round its three outer sides and not
    /// along the hinge, where the one screen carries on from half to half.
    private let leftGlass = CALayer(), rightGlass = CALayer()
    /// Darkens a face as it turns away from the viewer, as light would.
    private let leftLight = CALayer(), rightLight = CALayer(), leftBackLight = CALayer(), rightBackLight = CALayer()
    /// The body between each half's faces: slices one behind another, which read as its edge.
    private var leftBody: [CALayer] = [], rightBody: [CALayer] = []
    private static let slices = 5
    /// How far the device is slid to stay centred, in its own points; the hinge is this far from the middle.
    private var centring: CGFloat = 0

    /// The angle shown, in degrees: 0 closed, 180 flat.
    private(set) var angle: Double = 180
    private var tiltX: Double = 0, tiltY: Double = 0
    private var scale: CGFloat = 1
    private var bezel: CGFloat = 0
    /// Which screen the live picture is: the outer one when the simulator is closed.
    private var outerLit = false
    /// The picture's frame in this view, which the flat device matches exactly.
    private var picture = CGRect.zero
    /// The size of one half of the inner screen, in points, and how far the model is turned to fit
    /// the picture: 0 with the hinge upright (a wide inner screen), -90 degrees with it across (a tall one).
    private var half = CGSize(width: 100, height: 140)
    private var turn: CGFloat = 0
    /// How each screen's picture is turned on its glass, in the device's own space: 0, or a quarter
    /// turn for a tall inner picture or a wide outer one. At rest it undoes `turn`, so the picture is
    /// upright. It is set the moment a picture of another shape arrives and `turn` is then animated
    /// to match, so the picture rides on the device as it is turned upright, as it does on a real
    /// one, and always fills its glass.
    private var innerContent: CGFloat = 0, outerContent: CGFloat = 0
    /// True from the fingers lifting, or a button, until the device has finished moving to its angle.
    /// The device is not turned in the hand while it is still folding: the two together tumble.
    private var settling = false
    /// What to do when it has: turn to the way the caller expects the picture to be held, or show
    /// the screen and picture shape that arrived meanwhile, which wins.
    private var turnWhenSettled: Bool?
    private var showWhenSettled: (outer: Bool, wide: Bool)?
    /// Whether the hinge runs up and down the view (folded like a book) rather than across it (like a laptop).
    var hingeIsUpright: Bool { turn == 0 }

    /// How dark a face gets as it turns edge on: enough to read as a turn, not so much that the
    /// picture on a half-open device is hard to see.
    private static let shading = 0.26

    /// The angles the device stops at for a moment: closed, half open and flat.
    private static let stops: [Double] = [0, 90, 180]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityLabel = "iPhone Duo hinge"
        accessibilityTraits = .adjustable
        accessibilityIdentifier = "stream.foldModel"
        layer.addSublayer(cam)
        cam.addSublayer(closer)
        closer.addSublayer(leftHalf)
        closer.addSublayer(rightHalf)
        leftHalf.anchorPoint = CGPoint(x: 1, y: 0.5)
        rightHalf.anchorPoint = CGPoint(x: 0, y: 0.5)
        for (face, glass, live, shade) in [(leftFront, leftGlass, leftLive, leftShade), (rightFront, rightGlass, rightLive, rightShade)] {
            face.masksToBounds = true
            face.isDoubleSided = false
            face.backgroundColor = UIColor(white: 0.24, alpha: 1).cgColor      // the frame round the screen
            glass.masksToBounds = true
            glass.backgroundColor = UIColor.black.cgColor
            face.addSublayer(glass)
            // The picture keeps its shape: one of another shape than the screen is fitted, not stretched.
            live.videoGravity = .resizeAspect
            glass.addSublayer(live)
            shade.backgroundColor = UIColor(white: 0.05, alpha: 1).cgColor     // an unlit screen: dark glass
            shade.opacity = 0
            glass.addSublayer(shade)
        }
        for (half, isLeft) in [(leftHalf, true), (rightHalf, false)] {
            for _ in 0..<Self.slices {
                let slice = CALayer()
                slice.backgroundColor = UIColor(white: 0.2, alpha: 1).cgColor
                half.addSublayer(slice)
                if isLeft { leftBody.append(slice) } else { rightBody.append(slice) }
            }
        }
        leftHalf.addSublayer(leftFront)
        rightHalf.addSublayer(rightFront)
        for (face, light) in [(leftFront, leftLight), (rightFront, rightLight), (leftBack, leftBackLight), (rightBack, rightBackLight)] {
            light.backgroundColor = UIColor.black.cgColor
            light.opacity = 0
            face.addSublayer(light)
        }
        for back in [leftBack, rightBack] {
            back.masksToBounds = true
            back.isDoubleSided = false
            back.backgroundColor = UIColor(white: 0.15, alpha: 1).cgColor
            back.borderColor = UIColor(white: 0.24, alpha: 1).cgColor
        }
        outerLive.videoGravity = .resizeAspect
        leftBack.addSublayer(outerLive)
        outerShade.backgroundColor = UIColor(white: 0.05, alpha: 1).cgColor
        leftBack.addSublayer(outerShade)
        leftBack.addSublayer(leftBackLight)     // above the picture
        leftHalf.addSublayer(leftBack)
        rightHalf.addSublayer(rightBack)

        pan.addTarget(self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        addGestureRecognizer(tap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Poses

    /// Lays the device over `picture` as the flat picture it is now: open flat when the inner screen
    /// is lit, closed with its outer screen towards you when that is. Call before showing the view.
    func matchPicture(_ picture: CGRect, outerLit: Bool, innerIsWide: Bool) {
        self.picture = picture
        self.outerLit = outerLit
        hold(for: picture, outerLit: outerLit, innerIsWide: innerIsWide)
        innerContent = -turn; outerContent = -turn
        notSettling()
        angle = outerLit ? 0 : 180
        tiltX = 0; tiltY = 0; scale = 1; bezel = 0
        pickedUp = false
        apply(animated: false)
    }

    /// Which way the device is held, and the size of one half, for a flat picture to be exactly it.
    /// An upright picture of the outer screen, or a wide one of the inner screen, is a device with
    /// its hinge upright; the other two are one with its hinge across, turned a quarter turn.
    private func hold(for picture: CGRect, outerLit: Bool, innerIsWide: Bool) {
        let upright = outerLit ? picture.height >= picture.width : innerIsWide
        turn = upright ? 0 : -.pi / 2
        if outerLit {
            half = upright ? picture.size : CGSize(width: picture.height, height: picture.width)
        } else {
            half = upright ? CGSize(width: picture.width / 2, height: picture.height) : CGSize(width: picture.height / 2, height: picture.width)
        }
    }

    /// Picks the device up: smaller, face on, with its frame, at the simulator's own angle.
    func pickUp(at degrees: Double) {
        angle = degrees
        tiltX = 0; tiltY = 0        // face on; a drag around it tilts it
        pickedUp = true
        scale = fittingScale()
        bezel = max(3, min(half.width, half.height) * 0.035)
        apply(animated: true, duration: 0.55)
    }

    /// The room the picked-up device has: this view without the strip at the bottom where the
    /// caller puts its buttons, so the two never overlap however small the view is.
    var bottomReserve: CGFloat = 0
    private var pickedUp = false
    /// A strip at the top is left too, for the one line of notice the caller may show there.
    private static let topReserve: CGFloat = 44
    private var stage: CGRect {
        CGRect(x: bounds.minX, y: bounds.minY + Self.topReserve, width: bounds.width, height: max(120, bounds.height - bottomReserve - Self.topReserve))
    }

    /// The room changed while the device was up, as when this phone is turned or folded: the device
    /// is sized and placed for the room it has now.
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != fittedTo else { return }
        fittedTo = bounds.size
        guard pickedUp else { return }
        scale = fittingScale()
        apply(animated: false)
    }
    private var fittedTo = CGSize.zero

    /// Small enough to open flat inside the stage, whichever way it starts: a closed Duo picked up
    /// is one half wide, and opens to twice that.
    private func fittingScale() -> CGFloat {
        let open = turn == 0 ? CGSize(width: 2 * half.width, height: half.height) : CGSize(width: half.height, height: 2 * half.width)
        return min(0.82, stage.width * 0.88 / max(1, open.width), stage.height * 0.84 / max(1, open.height))
    }

    /// Lays the device flat again over `picture`, as the flat picture it gives way to, and calls
    /// `done` when it is there.
    func layDown(over picture: CGRect, outerLit: Bool, innerIsWide: Bool, done: @escaping () -> Void) {
        self.picture = picture
        self.outerLit = outerLit
        hold(for: picture, outerLit: outerLit, innerIsWide: innerIsWide)
        innerContent = -turn; outerContent = -turn
        notSettling()
        angle = outerLit ? 0 : 180
        tiltX = 0; tiltY = 0; scale = 1; bezel = 0
        pickedUp = false
        apply(animated: true, duration: 0.45, completion: done)
    }

    /// The simulator's lit screen, or the shape of its picture, changed while folding. The live
    /// picture moves to that screen and fills its glass at once, as the device is held now: an
    /// upright outer picture or a wide inner one belongs to a device with its hinge upright, and a
    /// wide outer picture or a tall inner one to a device with its hinge across. If that is not how
    /// the device is held, the picture is on its side for a moment and the device is then turned in
    /// the hand until it is upright, as a real one would be.
    func show(outerLit outer: Bool, pictureIsWide: Bool) {
        if settling { showWhenSettled = (outer, pictureIsWide); return }
        let wantedTurn: CGFloat = outer != pictureIsWide ? 0 : -.pi / 2
        guard outer != outerLit || wantedTurn != turn || (outer ? outerContent : innerContent) != -wantedTurn else { return }
        outerLit = outer
        if outer { outerContent = -wantedTurn } else { innerContent = -wantedTurn }
        apply(animated: false)
        roll(to: wantedTurn)
    }

    /// The caller has asked for a fold whose picture it knows the shape of: once the device has
    /// finished folding it is turned in the hand to the way that picture is held, before the
    /// picture arrives, as you turn a real one as you open it. If the simulator then shows
    /// something else, `show` turns it to that.
    func turnWhenFolded(upright: Bool) {
        if settling { turnWhenSettled = upright } else { roll(to: upright ? 0 : -.pi / 2) }
    }

    private func roll(to wantedTurn: CGFloat) {
        guard wantedTurn != turn else { return }
        turn = wantedTurn
        if pickedUp { scale = fittingScale() }
        apply(animated: true, duration: 0.4)
    }

    /// The device has finished moving to the angle it was let go at.
    private func settled() {
        guard settling else { return }
        settling = false
        let turnTo = turnWhenSettled, shown = showWhenSettled
        turnWhenSettled = nil; showWhenSettled = nil
        if let shown { show(outerLit: shown.outer, pictureIsWide: shown.wide) } else if let turnTo { roll(to: turnTo ? 0 : -.pi / 2) }
    }

    private func notSettling() {
        settling = false
        turnWhenSettled = nil; showWhenSettled = nil
    }

    private func apply(animated: Bool, duration: CFTimeInterval = 0.3, completion: (() -> Void)? = nil) {
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1))
        } else {
            CATransaction.setDisableActions(true)
        }
        CATransaction.setCompletionBlock(completion)
        layout()
        CATransaction.commit()
    }

    private func layout() {
        let w = half.width, h = half.height
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / max(900, max(bounds.width, bounds.height) * 1.8)
        layer.sublayerTransform = perspective

        // Laid flat it is the picture; picked up it has the middle of the stage.
        cam.position = pickedUp ? CGPoint(x: stage.midX, y: stage.midY) : CGPoint(x: picture.midX, y: picture.midY)
        var camera = CATransform3DMakeRotation(turn, 0, 0, 1)
        camera = CATransform3DConcat(camera, CATransform3DMakeScale(scale, scale, scale))
        camera = CATransform3DConcat(camera, CATransform3DConcat(CATransform3DMakeRotation(radians(tiltY), 0, 1, 0), CATransform3DMakeRotation(radians(tiltX), 1, 0, 0)))
        cam.transform = camera

        // Each half turns half the fold. Short of half open the whole device turns as well, up to a
        // quarter turn when closed, which brings the outer screen round to face the viewer.
        let each = (180 - angle) / 2
        let yaw = 90 * Self.smooth(max(0, min(1, (90 - angle) / 90)))
        // Where the hinge and the halves' outer edges then are, across the view; the device is slid
        // so that what it covers stays centred.
        let e = each * .pi / 180, y = yaw * .pi / 180
        let depth = Double(w) * sin(e) * sin(y)
        let leftEdge = -Double(w) * cos(e) * cos(y) + depth, rightEdge = Double(w) * cos(e) * cos(y) + depth
        centring = CGFloat((min(0, leftEdge, rightEdge) + max(0, leftEdge, rightEdge)) / 2)
        closer.transform = CATransform3DConcat(CATransform3DMakeRotation(radians(yaw), 0, 1, 0), CATransform3DMakeTranslation(-centring, 0, 0))
        // How far each face has turned from square on, for its shading.
        let leftTurn = abs(cos(e + y)), rightTurn = abs(cos(y - e))
        let thickness: CGFloat = bezel > 0 ? max(3, min(w, h) * 0.035) : 0
        for side in [leftHalf, rightHalf] { side.bounds = CGRect(x: 0, y: 0, width: w, height: h); side.position = .zero }
        leftHalf.transform = CATransform3DMakeRotation(radians(each), 0, 1, 0)
        rightHalf.transform = CATransform3DMakeRotation(radians(-each), 0, 1, 0)
        for (body, isLeft) in [(leftBody, true), (rightBody, false)] {
            for (index, slice) in body.enumerated() {
                slice.bounds = CGRect(x: 0, y: 0, width: w, height: h)
                slice.position = CGPoint(x: w / 2, y: h / 2)
                slice.zPosition = -thickness * CGFloat(index + 1) / CGFloat(Self.slices + 1)
                slice.cornerRadius = bezel > 0 ? min(w, h) * 0.07 : 0
                slice.maskedCorners = isLeft ? [.layerMinXMinYCorner, .layerMinXMaxYCorner] : [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
                slice.opacity = bezel > 0 ? 1 : 0
            }
        }

        // The inner screen's picture spans both halves; each half shows its own side of it. A tall
        // picture lies a quarter turn round on the glass, which the model's own turn undoes.
        let radius = bezel > 0 ? min(w, h) * 0.07 : 0
        for (face, glass, live, shade, isLeft) in [(leftFront, leftGlass, leftLive, leftShade, true), (rightFront, rightGlass, rightLive, rightShade, false)] {
            // Laid flat as the picture, the halves overlap by a hair at the hinge, or a dark line shows between them.
            let overlap: CGFloat = bezel > 0 ? 0 : 0.5
            face.frame = CGRect(x: isLeft ? 0 : -overlap, y: 0, width: w + overlap, height: h)
            face.cornerRadius = radius
            face.maskedCorners = isLeft ? [.layerMinXMinYCorner, .layerMinXMaxYCorner] : [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
            // The glass: inside the frame on the three outer sides, and right up to the hinge. The
            // frame is as much wider at the far end as keeps the glass the screen's own shape, so
            // the picture fills it exactly.
            let end = h > 0 ? 2 * bezel * w / h : bezel
            let glassWidth = w + overlap - end
            glass.frame = CGRect(x: isLeft ? end : 0, y: bezel, width: glassWidth, height: h - 2 * bezel)
            glass.cornerRadius = max(0, radius - bezel)
            glass.maskedCorners = face.maskedCorners
            // The whole inner screen, in model space, centred on the hinge.
            let content = CGSize(width: 2 * (w - end), height: h - 2 * bezel)
            let upright = innerContent == 0 ? content : CGSize(width: content.height, height: content.width)
            live.bounds = CGRect(origin: .zero, size: upright)
            live.position = CGPoint(x: isLeft ? glassWidth : overlap, y: glass.bounds.height / 2)
            live.transform = CATransform3DMakeRotation(innerContent, 0, 0, 1)
            shade.frame = glass.bounds
            shade.opacity = outerLit ? 1 : 0
            let light = isLeft ? leftLight : rightLight
            light.frame = face.bounds
            light.opacity = bezel > 0 ? Float(Self.shading * (1 - (isLeft ? leftTurn : rightTurn))) : 0
        }
        for (back, isLeft) in [(leftBack, true), (rightBack, false)] {
            back.bounds = CGRect(x: 0, y: 0, width: w, height: h)
            back.position = CGPoint(x: w / 2, y: h / 2)
            back.transform = CATransform3DConcat(CATransform3DMakeRotation(.pi, 0, 1, 0), CATransform3DMakeTranslation(0, 0, -max(1, thickness)))
            let light = isLeft ? leftBackLight : rightBackLight
            light.frame = back.bounds
            light.opacity = bezel > 0 ? Float(Self.shading * (1 - (isLeft ? leftTurn : rightTurn))) : 0
            back.borderWidth = bezel
            back.cornerRadius = radius
            // Seen from behind, the left half's outer edge is on the right.
            back.maskedCorners = isLeft ? [.layerMaxXMinYCorner, .layerMaxXMaxYCorner] : [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        }
        let outerSize = outerContent == 0 ? CGSize(width: w, height: h) : CGSize(width: h, height: w)
        outerLive.bounds = CGRect(origin: .zero, size: outerSize)
        outerLive.position = CGPoint(x: w / 2, y: h / 2)
        outerLive.transform = CATransform3DMakeRotation(outerContent, 0, 0, 1)
        outerShade.frame = leftBack.bounds
        outerShade.opacity = outerLit ? 0 : 1

        accessibilityValue = "\(Int(angle.rounded())) degrees"
    }

    // MARK: Folding by hand

    private enum Drag { case fold(direction: CGFloat, from: Double), tilt(fromX: Double, fromY: Double) }
    private var drag: Drag?
    private let pan = UIPanGestureRecognizer()
    private var pinchFrom: Double?
    /// Below this the device is as good as closed: one slab, which a drag either way opens.
    private static let asGoodAsClosed = 12.0

    /// A vector on screen, in the model's own space, where the hinge is upright.
    private func modelVector(_ v: CGPoint) -> CGPoint { v.applying(CGAffineTransform(rotationAngle: -turn)) }

    /// Whether a point of this view is on the device, with a margin for a fingertip.
    private func isOnDevice(_ point: CGPoint) -> Bool {
        let local = modelVector(CGPoint(x: point.x - cam.position.x, y: point.y - cam.position.y))
        let open = cos((180 - angle) / 2 * .pi / 180)
        let reach = CGSize(width: half.width * scale * CGFloat(max(1.0, 2 * open)), height: half.height * scale)
        return abs(local.x) <= reach.width / 2 + 28 && abs(local.y) <= reach.height / 2 + 28
    }

    private func fold(to degrees: Double) {
        let next = Self.snap(max(0, min(180, degrees)))
        if settling { notSettling() }       // a finger is folding it again
        guard next != angle else { return }
        angle = next
        apply(animated: false)
        onFolding?(angle)
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            let start = pan.location(in: self)
            if isOnDevice(start) {
                // Which half the finger is on: the hinge is `centring` from the middle.
                let local = modelVector(CGPoint(x: start.x - cam.position.x, y: start.y - cam.position.y))
                let side: CGFloat = local.x < -centring * scale ? -1 : 1
                drag = .fold(direction: angle < Self.asGoodAsClosed ? 0 : side, from: angle)
            } else {
                drag = .tilt(fromX: tiltX, fromY: tiltY)
            }
            onDragging?(true)
        case .changed:
            let move = pan.translation(in: self)
            switch drag {
            case .fold(let direction, let from)?:
                // Closed, there is only one way to go: a drag either way opens it.
                let across = modelVector(move).x
                let along = direction == 0 ? abs(across) : across * direction
                fold(to: from + Double(along) * 180 / Double(max(60, half.width * scale)))
            case .tilt(let fromX, let fromY)?:
                tiltY = max(-25, min(25, fromY + Double(move.x) * 0.15))
                tiltX = max(-30, min(15, fromX - Double(move.y) * 0.15))
                apply(animated: false)
            case nil:
                return
            }
        case .ended, .cancelled, .failed:
            if case .fold = drag, pinchFrom == nil { release() }
            drag = nil
            if pinchFrom == nil { onDragging?(false) }
        default:
            break
        }
    }

    /// Two fingers spread apart open the device, and pinched together close it: twice as far apart
    /// is the whole way open.
    @objc private func pinched(_ pinch: UIPinchGestureRecognizer) {
        switch pinch.state {
        case .began:
            pinchFrom = angle
            // The pinch takes over from a drag the first finger may have started.
            pan.isEnabled = false
            pan.isEnabled = true
            onDragging?(true)
        case .changed:
            guard let pinchFrom, pinch.scale > 0 else { return }
            fold(to: pinchFrom + log2(Double(pinch.scale)) * 180)
        case .ended, .cancelled, .failed:
            guard pinchFrom != nil else { return }
            pinchFrom = nil
            release()
            onDragging?(false)
        default:
            break
        }
    }

    /// The fingers have lifted. A device left nearly closed or nearly flat goes the rest of the way,
    /// as a real hinge falls shut or flat; then the angle is reported as chosen.
    private func release() {
        if angle < 25 { angle = 0 } else if angle > 155 { angle = 180 }
        settling = true
        apply(animated: true, duration: 0.25) { [weak self] in self?.settled() }
        onFold?(angle)
    }

    /// A tap on the closed device opens it flat; there is nothing else a closed device can do.
    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        guard angle < Self.asGoodAsClosed, isOnDevice(tap.location(in: self)) else { return }
        set(180)
    }

    /// Folds the device to an angle with an animation, as a button does, and reports it as chosen.
    func set(_ degrees: Double) {
        angle = max(0, min(180, degrees))
        settling = true
        apply(animated: true, duration: 0.45) { [weak self] in self?.settled() }
        onFold?(angle)
    }

    /// VoiceOver: swipe up to open the hinge 15 degrees, down to close it.
    override func accessibilityIncrement() { step(15) }
    override func accessibilityDecrement() { step(-15) }
    private func step(_ by: Double) { set(angle + by) }

    private static func snap(_ a: Double) -> Double { stops.first { abs(a - $0) < 6 } ?? a }
    private static func smooth(_ t: Double) -> Double { t * t * (3 - 2 * t) }
    private func radians(_ degrees: Double) -> CGFloat { CGFloat(degrees * .pi / 180) }
}
