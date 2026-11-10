import PencilKit
import SwiftUI
import UIKit

/// A PencilKit canvas with the system tool picker. A finger draws, so AXe's touch input paints real
/// ink, and the picker's tools and line weights are chosen by tapping them like any other control.
/// The system colour picker exposes no elements, so a row of swatches gives the selected tool a
/// named colour. The stroke count, the inks used and the last stroke are reported through
/// accessibility values.
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
    private let inks = UILabel()
    private let extent = UILabel()

    /// Swatches in the order they are shown; the identifier is `sketch.colour.<name>`.
    static let colours: [(name: String, hex: UInt32)] = [
        ("sky", 0x6EC6FF), ("sun", 0xFFD60A), ("orange", 0xFF9500), ("grass", 0x34C759), ("leaf", 0x1E7D32),
        ("wood", 0x8B5A2B), ("red", 0xD62828), ("white", 0xFFFFFF), ("night", 0x1D3557), ("black", 0x000000),
    ]
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
            UIStackView(arrangedSubviews: [
                field(drawable, id: "sketch.drawable", name: "Drawable area"),
                field(extent, id: "sketch.bounds", name: "Drawing bounds"),
            ]),
            UIStackView(arrangedSubviews: [field(inks, id: "sketch.inks", name: "Inks used")]),
        ]
        for row in rows {
            row.spacing = 12
            row.distribution = .fill
        }
        let swatches = UIStackView(arrangedSubviews: Self.colours.enumerated().map { index, colour in
            let button = UIButton(type: .custom)
            button.backgroundColor = Self.colour(colour.hex)
            button.layer.cornerRadius = 6
            button.layer.borderWidth = 1
            button.layer.borderColor = UIColor.separator.cgColor
            button.tag = index
            button.accessibilityIdentifier = "sketch.colour." + colour.name
            button.accessibilityLabel = colour.name + " colour"
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
            button.addTarget(self, action: #selector(pickColour(_:)), for: .touchUpInside)
            return button
        })
        swatches.spacing = 6
        swatches.distribution = .fillEqually

        // A finger draws; without this only Apple Pencil does. One finger never scrolls the canvas.
        canvas.drawingPolicy = .anyInput
        canvas.isScrollEnabled = false
        canvas.backgroundColor = .white
        canvas.overrideUserInterfaceStyle = .light
        canvas.delegate = self
        canvas.accessibilityIdentifier = "sketch.canvas"

        let outer = UIStackView(arrangedSubviews: rows + [swatches, canvas])
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
        label.minimumScaleFactor = 0.5
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private static func colour(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// Gives the selected tool the swatch's colour, keeping its kind and width. The tool picker gives
    /// the canvas its own tool again when another tool or weight is chosen there.
    @objc private func pickColour(_ sender: UIButton) {
        guard let inking = canvas.tool as? PKInkingTool, Self.colours.indices.contains(sender.tag) else { return }
        canvas.tool = PKInkingTool(inking.inkType, color: Self.colour(Self.colours[sender.tag].hex), width: inking.width)
        publish()
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
        var used: [String] = []
        for stroke in strokes where !used.contains(describe(stroke.ink)) { used.append(describe(stroke.ink)) }
        set(inks, "inks", used.isEmpty ? "none" : used.joined(separator: ", "))
        if let window = view.window, !strokes.isEmpty {
            let all = canvas.convert(canvas.drawing.bounds, to: window.screen.coordinateSpace)
            set(extent, "bounds", String(format: "%.0f,%.0f,%.0f,%.0f", all.minX, all.minY, all.maxX, all.maxY))
        } else {
            set(extent, "bounds", "none")
        }
        let frame = drawableFrame()
        set(drawable, "drawable", String(format: "%.0f,%.0f,%.0f,%.0f", frame.minX, frame.minY, frame.width, frame.height))
    }

    private func set(_ label: UILabel, _ name: String, _ value: String) {
        label.text = "\(name): \(value)"
        label.accessibilityValue = value
    }
}
