import SwiftUI
import UIKit

/// A zoomable scroll view that reports its scale and completed zoom gestures through accessibility values.
struct ZoomView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> ZoomController { ZoomController() }
    func updateUIViewController(_ controller: ZoomController, context: Context) {}
}

final class ZoomController: UIViewController, UIScrollViewDelegate {
    private let surface = UIScrollView()
    private let grid = ZoomGrid(frame: CGRect(x: 0, y: 0, width: 480, height: 480))
    private let scale = UILabel()
    private let events = UILabel()
    private let last = UILabel()
    private var eventCount = 0
    private var lastDirection = "none"
    private var startScale: CGFloat = 1
    private var resetting = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "zoom.screen"

        let reset = UIButton(type: .system)
        reset.setTitle("Reset", for: .normal)
        reset.accessibilityIdentifier = "zoom.reset"
        reset.addTarget(self, action: #selector(resetZoom), for: .touchUpInside)
        let header = UIStackView(arrangedSubviews: [
            field(scale, id: "zoom.scale", name: "Zoom scale"),
            field(events, id: "zoom.events", name: "Zoom events"),
            field(last, id: "zoom.last", name: "Last zoom"),
            reset,
        ])
        header.spacing = 12
        header.distribution = .fillEqually

        surface.delegate = self
        surface.minimumZoomScale = 0.25
        surface.maximumZoomScale = 8
        surface.backgroundColor = .secondarySystemBackground
        surface.isAccessibilityElement = true
        surface.accessibilityIdentifier = "zoom.surface"
        surface.accessibilityLabel = "Zoom surface"
        surface.addSubview(grid)
        surface.contentSize = grid.frame.size

        let outer = UIStackView(arrangedSubviews: [header, surface])
        outer.axis = .vertical
        outer.spacing = 4
        outer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            outer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            outer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            outer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -4),
        ])
        publish()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        centreContent()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { grid }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        startScale = scrollView.zoomScale
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centreContent()
        publish()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        guard !resetting else { return }
        eventCount += 1
        if scale > startScale {
            lastDirection = "in"
        } else if scale < startScale {
            lastDirection = "out"
        } else {
            lastDirection = "none"
        }
        publish()
    }

    @objc private func resetZoom() {
        resetting = true
        surface.setZoomScale(1, animated: false)
        resetting = false
        eventCount = 0
        lastDirection = "none"
        centreContent()
        publish()
    }

    /// Keeps the grid centred while it is smaller than the visible surface.
    private func centreContent() {
        let size = surface.bounds.size
        let content = grid.frame.size
        let horizontal = max(0, (size.width - content.width) / 2)
        let vertical = max(0, (size.height - content.height) / 2)
        surface.contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    private func field(_ label: UILabel, id: String, name: String) -> UILabel {
        label.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        label.accessibilityIdentifier = id
        label.accessibilityLabel = name
        label.isAccessibilityElement = true
        return label
    }

    private func publish() {
        let value = String(format: "%.2f", surface.zoomScale)
        scale.text = "scale: \(value)"
        scale.accessibilityValue = value
        events.text = "events: \(eventCount)"
        events.accessibilityValue = String(eventCount)
        last.text = "last: \(lastDirection)"
        last.accessibilityValue = lastDirection
    }
}

/// A labelled 8 x 8 grid with coloured quadrants so zoom level and position are visible in captures.
private final class ZoomGrid: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .white
        contentMode = .redraw
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override func draw(_ rect: CGRect) {
        let side = bounds.width / 8
        let quadrants: [UIColor] = [.systemRed, .systemGreen, .systemBlue, .systemYellow]
        for row in 0..<8 {
            for column in 0..<8 {
                let quadrant = (row < 4 ? 0 : 2) + (column < 4 ? 0 : 1)
                let alpha: CGFloat = (row + column).isMultiple(of: 2) ? 0.35 : 0.6
                quadrants[quadrant].withAlphaComponent(alpha).setFill()
                let cell = CGRect(x: CGFloat(column) * side, y: CGFloat(row) * side, width: side, height: side)
                UIRectFill(cell)
                let text = "\(Character(UnicodeScalar(65 + row)!))\(column + 1)" as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.boldSystemFont(ofSize: 14), .foregroundColor: UIColor.black,
                ]
                let size = text.size(withAttributes: attributes)
                text.draw(at: CGPoint(x: cell.midX - size.width / 2, y: cell.midY - size.height / 2),
                    withAttributes: attributes)
            }
        }
        UIColor.black.setStroke()
        let lines = UIBezierPath()
        for index in 0...8 {
            let offset = CGFloat(index) * side
            lines.move(to: CGPoint(x: offset, y: 0))
            lines.addLine(to: CGPoint(x: offset, y: bounds.height))
            lines.move(to: CGPoint(x: 0, y: offset))
            lines.addLine(to: CGPoint(x: bounds.width, y: offset))
        }
        lines.lineWidth = 1
        lines.stroke()
    }
}
