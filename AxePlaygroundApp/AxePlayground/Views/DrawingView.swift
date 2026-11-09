import SwiftUI
import UIKit

/// Records raw UIKit touches as strokes and reports the last stroke through accessibility values.
/// Coordinates are in screen points, the same space AXe uses for touch input.
struct DrawingView: View {
    var body: some View {
        DrawingControllerView()
            .defersSystemGestures(on: .all)
    }
}

private struct DrawingControllerView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> DrawingController { DrawingController() }
    func updateUIViewController(_ controller: DrawingController, context: Context) {}
}

final class DrawingController: UIViewController {
    private let canvas = DrawingCanvas()
    private let strokeCount = UILabel()
    private let active = UILabel()
    private let points = UILabel()
    private let start = UILabel()
    private let end = UILabel()
    private let bounds = UILabel()
    private let length = UILabel()
    private let duration = UILabel()
    private let maxTouches = UILabel()
    private let path = UILabel()
    private let cancelled = UILabel()
    private var completedStrokes = 0
    private var lastStroke: DrawingStroke?
    private var popWasEnabled: [UIGestureRecognizer: Bool] = [:]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "drawing.screen"

        let clear = UIButton(type: .system)
        clear.setTitle("Clear", for: .normal)
        clear.accessibilityIdentifier = "drawing.clear"
        clear.addTarget(self, action: #selector(clearDrawing), for: .touchUpInside)

        let rows = [
            UIStackView(arrangedSubviews: [
                field(strokeCount, id: "drawing.strokeCount", name: "Stroke count"),
                field(active, id: "drawing.active", name: "Contact down"),
                field(points, id: "drawing.last.points", name: "Last points"),
                field(maxTouches, id: "drawing.last.maxTouches", name: "Last max touches"),
                field(cancelled, id: "drawing.last.cancelled", name: "Last cancelled"),
                clear,
            ]),
            UIStackView(arrangedSubviews: [
                field(start, id: "drawing.last.start", name: "Last start"),
                field(end, id: "drawing.last.end", name: "Last end"),
                field(length, id: "drawing.last.length", name: "Last length"),
                field(duration, id: "drawing.last.duration", name: "Last duration"),
            ]),
            UIStackView(arrangedSubviews: [field(bounds, id: "drawing.last.bounds", name: "Last bounds")]),
            UIStackView(arrangedSubviews: [field(path, id: "drawing.last.path", name: "Last path")]),
        ]
        for row in rows {
            row.spacing = 12
            row.distribution = row.arrangedSubviews.count > 1 ? .fillProportionally : .fill
        }
        path.numberOfLines = 2

        canvas.isAccessibilityElement = true
        canvas.accessibilityIdentifier = "drawing.canvas"
        canvas.accessibilityLabel = "Drawing canvas"
        canvas.onChange = { [weak self] in self?.publish() }
        canvas.onStroke = { [weak self] stroke in
            guard let self else { return }
            completedStrokes += 1
            lastStroke = stroke
            publish()
        }

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
        canvas.clear()
        completedStrokes = 0
        lastStroke = nil
        publish()
    }

    private func publish() {
        set(strokeCount, "strokes", String(completedStrokes))
        set(active, "down", canvas.isContactDown ? "true" : "false")
        guard let stroke = lastStroke else {
            for label in [points, start, end, bounds, length, duration, maxTouches, path] {
                set(label, label.accessibilityLabel ?? "", "")
            }
            set(cancelled, "cancelled", "false")
            return
        }
        set(points, "points", String(stroke.samples.count))
        set(start, "start", Self.format(stroke.samples.first ?? .zero, digits: 1))
        set(end, "end", Self.format(stroke.samples.last ?? .zero, digits: 1))
        let box = stroke.bounds
        set(bounds, "bounds", [box.minX, box.minY, box.maxX, box.maxY].map { Self.format($0, digits: 1) }
            .joined(separator: ","))
        set(length, "length", Self.format(stroke.length, digits: 1))
        set(duration, "duration", Self.format(stroke.duration, digits: 2))
        set(maxTouches, "max touches", String(stroke.maxTouches))
        set(path, "path", stroke.resampled(count: 16).map { Self.format($0, digits: 0) }.joined(separator: ";"))
        set(cancelled, "cancelled", stroke.cancelled ? "true" : "false")
    }

    private func set(_ label: UILabel, _ title: String, _ value: String) {
        label.text = "\(title): \(value.isEmpty ? "-" : value)"
        label.accessibilityValue = value
    }

    private static func format(_ point: CGPoint, digits: Int) -> String {
        "\(format(point.x, digits: digits)),\(format(point.y, digits: digits))"
    }

    private static func format(_ value: CGFloat, digits: Int) -> String {
        format(Double(value), digits: digits)
    }

    private static func format(_ value: Double, digits: Int) -> String {
        let text = String(format: "%.\(digits)f", value)
        // Avoid "-0.0" for values that round to zero.
        return Double(text) == 0 ? String(format: "%.\(digits)f", 0.0) : text
    }
}

/// One finger-down to all-fingers-up stroke. Samples follow the first contact, in screen points.
struct DrawingStroke {
    var samples: [CGPoint] = []
    var startTime: TimeInterval = 0
    var endTime: TimeInterval = 0
    var maxTouches = 0
    var cancelled = false

    var duration: Double { max(0, endTime - startTime) }

    var bounds: CGRect {
        guard let first = samples.first else { return .zero }
        return samples.dropFirst().reduce(CGRect(origin: first, size: .zero)) { box, point in
            box.union(CGRect(origin: point, size: .zero))
        }
    }

    var length: CGFloat {
        zip(samples, samples.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    /// The stroke resampled to `count` points evenly spaced by arc length, including both ends.
    func resampled(count: Int) -> [CGPoint] {
        guard let first = samples.first else { return [] }
        let total = length
        guard samples.count > 1, total > 0, count > 1 else { return Array(repeating: first, count: count) }
        var result: [CGPoint] = []
        var segment = 0
        var travelled: CGFloat = 0
        for index in 0..<count {
            let target = total * CGFloat(index) / CGFloat(count - 1)
            while segment < samples.count - 2 {
                let span = hypot(samples[segment + 1].x - samples[segment].x,
                    samples[segment + 1].y - samples[segment].y)
                if travelled + span >= target { break }
                travelled += span
                segment += 1
            }
            let a = samples[segment]
            let b = samples[segment + 1]
            let span = hypot(b.x - a.x, b.y - a.y)
            let t = span > 0 ? min(1, max(0, (target - travelled) / span)) : 0
            result.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
        return result
    }
}

private final class DrawingCanvas: UIView {
    var onChange: (() -> Void)?
    var onStroke: ((DrawingStroke) -> Void)?
    private var contacts: Set<ObjectIdentifier> = []
    private var primary: ObjectIdentifier?
    private var current: DrawingStroke?
    private var currentPath: UIBezierPath?
    private var finishedPaths: [UIBezierPath] = []

    var isContactDown: Bool { !contacts.isEmpty }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 8
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    func clear() {
        finishedPaths = []
        currentPath = nil
        current = nil
        primary = nil
        contacts = []
        setNeedsDisplay()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let ordered = touches.sorted { $0.timestamp < $1.timestamp }
        if contacts.isEmpty, let touch = ordered.first {
            primary = ObjectIdentifier(touch)
            let point = touch.location(in: self)
            var stroke = DrawingStroke()
            stroke.startTime = touch.timestamp
            stroke.samples = [screenPoint(point)]
            current = stroke
            let path = UIBezierPath()
            path.move(to: point)
            path.addLine(to: point)
            currentPath = path
        }
        for touch in ordered { contacts.insert(ObjectIdentifier(touch)) }
        if let seen = current?.maxTouches, contacts.count > seen { current?.maxTouches = contacts.count }
        setNeedsDisplay()
        onChange?()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first(where: { ObjectIdentifier($0) == primary }) else { return }
        let samples = event?.coalescedTouches(for: touch) ?? [touch]
        for sample in samples.isEmpty ? [touch] : samples {
            let point = sample.location(in: self)
            current?.samples.append(screenPoint(point))
            currentPath?.addLine(to: point)
        }
        setNeedsDisplay()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, event: event, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, event: event, cancelled: true)
    }

    private func finish(_ touches: Set<UITouch>, event: UIEvent?, cancelled: Bool) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            guard contacts.remove(id) != nil else { continue }
            if id == primary {
                let point = touch.location(in: self)
                let screen = screenPoint(point)
                if current?.samples.last != screen {
                    current?.samples.append(screen)
                    currentPath?.addLine(to: point)
                }
                current?.endTime = touch.timestamp
                if cancelled { current?.cancelled = true }
            } else if cancelled {
                current?.cancelled = true
            }
        }
        if contacts.isEmpty, let stroke = current {
            if let path = currentPath { finishedPaths.append(path) }
            current = nil
            currentPath = nil
            primary = nil
            setNeedsDisplay()
            onStroke?(stroke)
        } else {
            onChange?()
        }
    }

    private func screenPoint(_ point: CGPoint) -> CGPoint {
        guard let window else { return point }
        return convert(point, to: window.screen.coordinateSpace)
    }

    override func draw(_ rect: CGRect) {
        UIColor.systemBlue.setStroke()
        for path in finishedPaths { stroke(path) }
        if let currentPath {
            UIColor.systemRed.setStroke()
            stroke(currentPath)
        }
    }

    private func stroke(_ path: UIBezierPath) {
        path.lineWidth = 4
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }
}
