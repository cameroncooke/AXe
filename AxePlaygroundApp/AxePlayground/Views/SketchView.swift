import PencilKit
import SwiftUI
import UIKit

/// A PencilKit canvas with the system tool picker. A finger draws, so AXe's touch input paints real
/// ink, and the picker's tools and colours are chosen by tapping them like any other control.
/// The stroke count and the last stroke's ink are reported through accessibility values.
struct SketchView: View {
    var body: some View {
        SketchControllerView()
            .defersSystemGestures(on: .all)
    }
}

private struct SketchControllerView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> SketchController { SketchController() }
    func updateUIViewController(_ controller: SketchController, context: Context) {}
}

final class SketchController: UIViewController, PKCanvasViewDelegate, PKToolPickerObserver {
    private let canvas = PKCanvasView()
    private let picker = PKToolPicker()
    private let strokeCount = UILabel()
    private let lastInk = UILabel()
    private let lastBounds = UILabel()
    private let tool = UILabel()
    private let drawable = UILabel()
    private var popWasEnabled: [UIGestureRecognizer: Bool] = [:]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "sketch.screen"

        let clear = UIButton(type: .system)
        clear.setTitle("Clear", for: .normal)
        clear.accessibilityIdentifier = "sketch.clear"
        clear.addTarget(self, action: #selector(clearDrawing), for: .touchUpInside)
        clear.setContentCompressionResistancePriority(.required, for: .horizontal)
        clear.setContentHuggingPriority(.required, for: .horizontal)

        let rows = [
            UIStackView(arrangedSubviews: [
                field(strokeCount, id: "sketch.strokeCount", name: "Stroke count"),
                field(tool, id: "sketch.tool", name: "Selected tool"),
                clear,
            ]),
            UIStackView(arrangedSubviews: [
                field(lastInk, id: "sketch.last.ink", name: "Last ink"),
                field(lastBounds, id: "sketch.last.bounds", name: "Last bounds"),
            ]),
            UIStackView(arrangedSubviews: [field(drawable, id: "sketch.drawable", name: "Drawable area")]),
        ]
        for row in rows {
            row.spacing = 12
            row.distribution = .fill
        }

        // A finger draws; without this only Apple Pencil does. One finger never scrolls the canvas.
        canvas.drawingPolicy = .anyInput
        canvas.isScrollEnabled = false
        canvas.backgroundColor = .white
        canvas.overrideUserInterfaceStyle = .light
        canvas.delegate = self
        canvas.accessibilityIdentifier = "sketch.canvas"

        let outer = UIStackView(arrangedSubviews: rows + [canvas])
        outer.axis = .vertical
        outer.spacing = 4
        outer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            outer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            outer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            outer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        // The canvas observes first, so its tool is already current when this controller is told.
        picker.addObserver(canvas)
        picker.addObserver(self)
        publish()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // A stroke that starts near the leading edge or crosses the page must not pop the screen.
        for recognizer in popRecognizers() {
            popWasEnabled[recognizer] = recognizer.isEnabled
            recognizer.isEnabled = false
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        picker.setVisible(true, forFirstResponder: canvas)
        canvas.becomeFirstResponder()
        publish()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        for (recognizer, enabled) in popWasEnabled { recognizer.isEnabled = enabled }
        popWasEnabled = [:]
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        publish()
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) { publish() }
    func toolPickerSelectedToolItemDidChange(_ toolPicker: PKToolPicker) { publishAfterToolChange() }
    func toolPickerSelectedToolDidChange(_ toolPicker: PKToolPicker) { publishAfterToolChange() }
    func toolPickerFramesObscuredDidChange(_ toolPicker: PKToolPicker) { publish() }
    func toolPickerVisibilityDidChange(_ toolPicker: PKToolPicker) { publish() }

    /// A weight or colour change reaches the canvas in the same pass as this callback; report it after.
    private func publishAfterToolChange() {
        DispatchQueue.main.async { [weak self] in self?.publish() }
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

    private func field(_ label: UILabel, id: String, name: String) -> UILabel {
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.accessibilityIdentifier = id
        label.accessibilityLabel = name
        label.isAccessibilityElement = true
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        return label
    }

    @objc private func clearDrawing() {
        canvas.drawing = PKDrawing()
        publish()
    }

    /// The part of the canvas the tool picker does not cover, in screen points.
    private func drawableFrame() -> CGRect {
        guard let window = view.window else { return .zero }
        var frame = canvas.convert(canvas.bounds, to: window.screen.coordinateSpace)
        let obscured = picker.frameObscured(in: canvas)
        if !obscured.isNull, !obscured.isEmpty, obscured.minY > canvas.bounds.minY {
            frame.size.height = max(0, frame.height - (canvas.bounds.maxY - obscured.minY))
        }
        return frame
    }

    private func describe(_ ink: PKInk) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        ink.color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
            .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let name = ink.inkType.rawValue.split(separator: ".").last.map(String.init) ?? ink.inkType.rawValue
        return String(format: "%@ #%02X%02X%02X", name, Int((red * 255).rounded()), Int((green * 255).rounded()),
                      Int((blue * 255).rounded()))
    }

    private func publish() {
        let strokes = canvas.drawing.strokes
        set(strokeCount, "strokes", String(strokes.count))
        if let inking = canvas.tool as? PKInkingTool {
            set(tool, "tool", String(format: "%@ width %.1f", describe(inking.ink), inking.width))
        } else {
            set(tool, "tool", canvas.tool is PKEraserTool ? "eraser" : "other")
        }
        if let last = strokes.last, let window = view.window {
            set(lastInk, "last ink", describe(last.ink))
            let bounds = canvas.convert(last.renderBounds, to: window.screen.coordinateSpace)
            set(lastBounds, "last bounds", String(format: "%.0f,%.0f,%.0f,%.0f", bounds.minX, bounds.minY, bounds.maxX, bounds.maxY))
        } else {
            set(lastInk, "last ink", "none")
            set(lastBounds, "last bounds", "none")
        }
        let frame = drawableFrame()
        set(drawable, "drawable", String(format: "%.0f,%.0f,%.0f,%.0f", frame.minX, frame.minY, frame.width, frame.height))
    }

    private func set(_ label: UILabel, _ name: String, _ value: String) {
        label.text = "\(name): \(value)"
        label.accessibilityValue = value
    }
}
