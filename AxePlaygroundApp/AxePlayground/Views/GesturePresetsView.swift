//
//  GesturePresetsView.swift
//  AxePlayground
//
//  Created by Cameron on 23/05/2025.
//

import SceneKit
import SwiftUI
import UIKit

/// A cube to handle with real fingers: drag with one finger to spin it, pinch to zoom, twist two
/// fingers to turn it, double-tap to put it back. The cube stays where it is left.
///
/// Each finished gesture is also named and counted ("scroll-up", "pinch-out", "rotate"), which is
/// what AXe's gesture tests read from this screen's labels.
struct GesturePresetsView: View {
    @StateObject private var model = CubeModel()

    var body: some View {
        ZStack {
            CubeSurface(model: model)
                .ignoresSafeArea(edges: .bottom)

            VStack(spacing: 12) {
                VStack(spacing: 6) {
                    Text("Gesture Presets Playground").font(.title3).fontWeight(.bold)
                    Text("Drag to spin. Pinch to zoom. Twist with two fingers. Double-tap to reset.")
                        .font(.footnote).foregroundColor(.secondary).multilineTextAlignment(.center)
                    Text("Detected: \(model.count)").font(.headline).foregroundColor(.purple)
                        .accessibilityIdentifier("gesture-count").accessibilityValue("\(model.count)")
                    Text("Latest Gesture: \(model.latest)")
                        .accessibilityIdentifier("latest-gesture").accessibilityValue(model.latest)
                    Text(model.stateText).font(.system(.footnote, design: .monospaced))
                        .accessibilityIdentifier("cube-state")
                }
                .padding(12).background(Material.thin).cornerRadius(12)

                HStack {
                    Circle().fill(model.active.isEmpty ? Color.gray : Color.green).frame(width: 12, height: 12)
                    Text(model.active.isEmpty ? "Ready for gestures" : model.active).font(.caption).foregroundColor(.secondary)
                }

                Spacer()

                if !model.history.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recent:").font(.caption).fontWeight(.semibold)
                        ForEach(model.history.suffix(5)) { event in
                            HStack(spacing: 8) {
                                Text(event.gesture).font(.caption2).fontWeight(.medium)
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(Color.purple.opacity(0.15)).cornerRadius(4)
                                Spacer()
                                Text(event.timestamp.formatted(date: .omitted, time: .standard))
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal).padding(.vertical, 8)
                    .background(Material.regular).cornerRadius(8)
                }
            }
            .padding()
            .allowsHitTesting(false)
        }
        .navigationTitle("Gesture Presets")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Reset") { model.resetRequests += 1 }.accessibilityIdentifier("cube-reset")
            }
        }
        .accessibilityIdentifier("gesture-presets-screen")
    }
}

struct GestureEvent: Identifiable {
    let id = UUID()
    let gesture: String
    let timestamp: Date
}

/// What the screen shows about the cube and the gestures made on it.
final class CubeModel: ObservableObject {
    @Published var history: [GestureEvent] = []
    @Published var count = 0
    @Published var latest = "None"
    @Published var scale: Float = 1
    @Published var twist: Float = 0         // degrees turned by two-finger twists since the last reset
    @Published var spin: Float = 0          // degrees between the cube's attitude and where it started
    @Published var touches = 0
    @Published var active = ""
    @Published var resetRequests = 0

    var stateText: String {
        String(format: "Scale ×%.2f, twist %.0f°, spin %.0f°, touches %d", scale, twist, spin, touches)
    }

    func record(_ gesture: String) {
        history.append(GestureEvent(gesture: gesture, timestamp: Date()))
        if history.count > 20 { history.removeFirst(history.count - 20) }
        count += 1
        latest = gesture
    }

    /// The same summary the screen has always published for tests: how many, and the last five.
    var summary: String {
        guard count > 0 else { return "no-gestures-detected" }
        let recent = history.suffix(5).map { "\($0.gesture):\($0.timestamp.timeIntervalSince1970)" }
        return "count:\(count);recent:[\(recent.joined(separator: ","))]"
    }
}

private struct CubeSurface: UIViewControllerRepresentable {
    @ObservedObject var model: CubeModel

    func makeUIViewController(context: Context) -> CubeController { CubeController(model: model) }

    func updateUIViewController(_ controller: CubeController, context: Context) {
        controller.surface.accessibilityValue = model.summary
        controller.resetIfAsked(model.resetRequests)
    }
}

final class CubeController: UIViewController, UIGestureRecognizerDelegate {
    private static let home = simd_quatf(angle: 0.5, axis: simd_float3(0, 1, 0)) * simd_quatf(angle: 0.35, axis: simd_float3(1, 0, 0))
    private static let scaleLimits: ClosedRange<Float> = 0.4...2.0     // at 2 the cube is as wide as a phone's screen
    private static let radiansPerPoint: Float = 0.012

    let surface = CubeTouchSurface()
    private let model: CubeModel
    private let cube = SCNNode()
    private let pan = UIPanGestureRecognizer()
    private let pinch = UIPinchGestureRecognizer()
    private let rotation = UIRotationGestureRecognizer()
    private var orientation = CubeController.home
    private var scale: Float = 1
    private var panTotal = CGPoint.zero
    private var panFingers = 0
    private var panHadTwoFingers = false
    private var pinchTotal: Float = 1
    private var twistTotal: Float = 0
    private var resetsDone = 0
    private var popWasEnabled: [UIGestureRecognizer: Bool] = [:]

    init(model: CubeModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() { view = surface }

    override func viewDidLoad() {
        super.viewDidLoad()
        surface.isMultipleTouchEnabled = true
        surface.isAccessibilityElement = true
        surface.accessibilityIdentifier = "gesture-detection-area"
        surface.accessibilityLabel = "Cube"
        surface.accessibilityTraits = .allowsDirectInteraction
        surface.accessibilityValue = model.summary
        surface.onTouches = { [weak self] count in self?.model.touches = count }

        let sceneView = SCNView()
        sceneView.backgroundColor = .clear
        sceneView.isUserInteractionEnabled = false
        sceneView.antialiasingMode = .multisampling4X
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.frame = surface.bounds
        sceneView.scene = makeScene()
        surface.addSubview(sceneView)

        pan.addTarget(self, action: #selector(panned))
        pinch.addTarget(self, action: #selector(pinched))
        rotation.addTarget(self, action: #selector(twisted))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped))
        doubleTap.numberOfTapsRequired = 2
        for recognizer in [pan, pinch, rotation, doubleTap] {
            recognizer.delegate = self
            recognizer.cancelsTouchesInView = false     // the surface counts fingers itself
            surface.addGestureRecognizer(recognizer)
        }
        apply()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // A drag to the right must spin the cube, not pop the screen.
        for recognizer in popRecognizers() {
            popWasEnabled[recognizer] = recognizer.isEnabled
            recognizer.isEnabled = false
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        for (recognizer, enabled) in popWasEnabled { recognizer.isEnabled = enabled }
        popWasEnabled = [:]
    }

    private func popRecognizers() -> [UIGestureRecognizer] {
        guard let navigation = navigationController else { return [] }
        var recognizers: [UIGestureRecognizer] = []
        if let edge = navigation.interactivePopGestureRecognizer { recognizers.append(edge) }
        if #available(iOS 26.0, *), let content = navigation.interactiveContentPopGestureRecognizer {
            recognizers.append(content)
        }
        return recognizers
    }

    /// Pinch and twist are made with the same two fingers, so they must be able to run together;
    /// a drag that began with one finger must not stop a second finger from starting them.
    func gestureRecognizer(_ first: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith second: UIGestureRecognizer) -> Bool { true }

    // MARK: Scene

    private func makeScene() -> SCNScene {
        let scene = SCNScene()
        let box = SCNBox(width: 3, height: 3, length: 3, chamferRadius: 0.18)
        // Front, right, back, left, top, bottom: a number and a colour each, so every turn can be seen.
        let colours: [UIColor] = [.systemBlue, .systemOrange, .systemGreen, .systemPurple, .systemRed, .systemTeal]
        box.materials = colours.enumerated().map { index, colour in
            let material = SCNMaterial()
            material.diffuse.contents = Self.face(String(index + 1), colour)
            material.lightingModel = .lambert
            return material
        }
        cube.geometry = box
        cube.name = "cube"
        scene.rootNode.addChildNode(cube)

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.position = SCNVector3(0, 0, 12)
        scene.rootNode.addChildNode(camera)

        let light = SCNNode()
        light.light = SCNLight()
        light.light?.type = .omni
        light.light?.intensity = 900
        light.position = SCNVector3(4, 8, 12)
        scene.rootNode.addChildNode(light)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 500
        scene.rootNode.addChildNode(ambient)
        return scene
    }

    private static func face(_ text: String, _ colour: UIColor) -> UIImage {
        let side: CGFloat = 256
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            colour.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            UIColor.white.withAlphaComponent(0.85).setStroke()
            let border = UIBezierPath(roundedRect: CGRect(x: 14, y: 14, width: side - 28, height: side - 28), cornerRadius: 22)
            border.lineWidth = 8
            border.stroke()
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 150, weight: .heavy), .foregroundColor: UIColor.white]
            let size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (side - size.width) / 2, y: (side - size.height) / 2), withAttributes: attributes)
        }
    }

    // MARK: Gestures

    private var twoFingerGesture: Bool {
        [pinch.state, rotation.state].contains { $0 == .began || $0 == .changed }
    }

    @objc private func panned() {
        switch pan.state {
        case .began:
            panTotal = .zero
            panFingers = pan.numberOfTouches
            panHadTwoFingers = pan.numberOfTouches > 1
            pan.setTranslation(.zero, in: surface)
        case .changed:
            let step = pan.translation(in: surface)
            pan.setTranslation(.zero, in: surface)
            // The step in which a finger joins or leaves is the centre of the fingers jumping, not movement.
            let fingers = pan.numberOfTouches
            defer { panFingers = fingers }
            if fingers > 1 || twoFingerGesture { panHadTwoFingers = true }
            guard fingers == 1, panFingers == 1, !twoFingerGesture else { break }
            panTotal.x += step.x
            panTotal.y += step.y
            // The face under the finger follows it: right turns the cube about the upright axis, down about the level one.
            let turn = simd_quatf(angle: Float(step.x) * Self.radiansPerPoint, axis: simd_float3(0, 1, 0))
                * simd_quatf(angle: Float(step.y) * Self.radiansPerPoint, axis: simd_float3(1, 0, 0))
            orientation = simd_normalize(turn * orientation)
            apply()
        case .ended:
            // A plain one-finger drag is also reported by direction, as the scroll presets expect.
            if !panHadTwoFingers, hypot(panTotal.x, panTotal.y) > 30 {
                let name = abs(panTotal.x) > abs(panTotal.y) ? (panTotal.x > 0 ? "scroll-right" : "scroll-left") : (panTotal.y > 0 ? "scroll-down" : "scroll-up")
                model.record(name)
            }
        default:
            break
        }
        showActive()
    }

    @objc private func pinched() {
        switch pinch.state {
        case .began:
            pinchTotal = 1
            pinch.scale = 1
        case .changed:
            let step = Float(pinch.scale)
            pinch.scale = 1
            guard step.isFinite, step > 0 else { break }
            pinchTotal *= step
            scale = min(Self.scaleLimits.upperBound, max(Self.scaleLimits.lowerBound, scale * step))
            apply()
        case .ended:
            if abs(pinchTotal - 1) > 0.2 { model.record(pinchTotal > 1 ? "pinch-out" : "pinch-in") }
        default:
            break
        }
        showActive()
    }

    @objc private func twisted() {
        switch rotation.state {
        case .began:
            twistTotal = 0
            rotation.rotation = 0
        case .changed:
            let step = Float(rotation.rotation)
            rotation.rotation = 0
            twistTotal += step
            model.twist += step * 180 / .pi
            // Clockwise on the screen is a negative turn about the axis that points at the viewer.
            orientation = simd_normalize(simd_quatf(angle: -step, axis: simd_float3(0, 0, 1)) * orientation)
            apply()
        case .ended:
            if abs(twistTotal) > 0.3 { model.record("rotate") }
        default:
            break
        }
        showActive()
    }

    @objc private func doubleTapped() { reset() }

    func resetIfAsked(_ requests: Int) {
        guard requests != resetsDone else { return }
        resetsDone = requests
        reset()
    }

    private func reset() {
        orientation = Self.home
        scale = 1
        model.twist = 0
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.3
        apply()
        SCNTransaction.commit()
    }

    private func apply() {
        cube.simdOrientation = orientation
        cube.simdScale = simd_float3(repeating: scale)
        model.scale = scale
        let away = orientation * Self.home.inverse
        model.spin = 2 * acos(min(1, abs(away.real))) * 180 / .pi
    }

    private func showActive() {
        var names: [String] = []
        if pinch.state == .began || pinch.state == .changed { names.append(String(format: "Pinch ×%.2f", pinchTotal)) }
        if rotation.state == .began || rotation.state == .changed { names.append(String(format: "Twist %.0f°", twistTotal * 180 / .pi)) }
        if names.isEmpty, pan.state == .began || pan.state == .changed { names.append("Drag") }
        let text = names.joined(separator: ", ")
        if model.active != text { model.active = text }
    }
}

/// The view the fingers land on. It only counts them; the recognisers do the rest.
final class CubeTouchSurface: UIView {
    var onTouches: ((Int) -> Void)?
    private var down = Set<UITouch>()

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { down.formUnion(touches); onTouches?(down.count) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { down.subtract(touches); onTouches?(down.count) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { down.subtract(touches); onTouches?(down.count) }
}
