import SwiftUI
import UIKit

/// Strong colour markers make upright capture and frame changes visible.
struct MediaPatternView: View {
    let onClose: () -> Void

    var body: some View {
        if #available(iOS 27.0, *) {
            pattern.toolbarVisibility(.hidden, for: .statusBar)
        } else {
            pattern.statusBarHidden()
        }
    }

    private var pattern: some View {
        MediaPatternCanvas(onClose: onClose)
            .ignoresSafeArea()
            .persistentSystemOverlays(.hidden)
    }
}

private struct MediaPatternCanvas: UIViewControllerRepresentable {
    let onClose: () -> Void

    func makeUIViewController(context: Context) -> MediaPatternController {
        MediaPatternController(onClose: onClose)
    }

    func updateUIViewController(_ controller: MediaPatternController, context: Context) {}
}

private final class MediaPatternController: UIViewController {
    private let onClose: () -> Void
    private let status = UILabel()
    private let advance = UIButton(type: .system)
    private let close = UIButton(type: .system)
    private let fills = (0..<4).map { _ in UIView() }
    private let cells = (0..<4).map { _ in UILabel() }
    private let fiducials = (0..<4).map { _ in UIView() }
    private var phase = 0
    private let colours = [UIColor(red: 1, green: 0, blue: 0, alpha: 1),
        UIColor(red: 0, green: 1, blue: 0, alpha: 1), UIColor(red: 0, green: 0, blue: 1, alpha: 1),
        UIColor(red: 1, green: 1, blue: 0, alpha: 1)]
    private let fiducialCenters = [CGPoint(x: 0.065, y: 0.18), CGPoint(x: 0.935, y: 0.22),
        CGPoint(x: 0.075, y: 0.79), CGPoint(x: 0.925, y: 0.84)]

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(onClose:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "media-pattern-screen"
        for fill in fills {
            fill.isUserInteractionEnabled = false
            view.addSubview(fill)
        }
        for fiducial in fiducials {
            fiducial.backgroundColor = .white
            fiducial.isUserInteractionEnabled = false
            view.addSubview(fiducial)
        }
        let cellTitles = ["TOP LEFT", "TOP RIGHT", "BOTTOM LEFT", "BOTTOM RIGHT"]
        for (index, cell) in cells.enumerated() {
            cell.text = cellTitles[index]
            cell.textAlignment = .center
            cell.textColor = .black
            cell.font = .boldSystemFont(ofSize: 24)
            cell.adjustsFontSizeToFitWidth = true
            cell.accessibilityIdentifier = "media-pattern-cell-\(index)"
            cell.isAccessibilityElement = true
            view.addSubview(cell)
        }

        status.textColor = .white
        status.textAlignment = .center
        status.accessibilityIdentifier = "media-pattern-phase"
        view.addSubview(status)
        advance.setTitle("Next marker", for: .normal)
        advance.accessibilityIdentifier = "media-pattern-next"
        advance.addTarget(self, action: #selector(nextMarker), for: .touchUpInside)
        close.setTitle("Close", for: .normal)
        close.accessibilityIdentifier = "media-pattern-close"
        close.addTarget(self, action: #selector(closePattern), for: .touchUpInside)
        for button in [advance, close] {
            button.setTitleColor(.white, for: .normal)
            view.addSubview(button)
        }
        for control in [status, advance, close] as [UIView] {
            control.backgroundColor = .black
            control.layer.cornerRadius = 8
            control.clipsToBounds = true
        }
        updateMarkers()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        let tileWidth = bounds.width / 2
        let tileHeight = bounds.height / 2
        let fiducialSide = min(bounds.width, bounds.height) * 0.045
        for (index, fill) in fills.enumerated() {
            let tile = CGRect(x: bounds.minX + CGFloat(index % 2) * tileWidth,
                y: bounds.minY + CGFloat(index / 2) * tileHeight, width: tileWidth, height: tileHeight)
            fill.frame = tile
            // Keep an AX-only gap at the seam for the overlay buttons' activation points.
            cells[index].frame = tile.insetBy(dx: 0.5, dy: 0)
            let center = fiducialCenters[index]
            fiducials[index].frame = CGRect(
                x: bounds.minX + center.x * bounds.width - fiducialSide / 2,
                y: bounds.minY + center.y * bounds.height - fiducialSide / 2,
                width: fiducialSide, height: fiducialSide)
        }

        let controls = bounds.inset(by: view.window?.safeAreaInsets ?? view.safeAreaInsets)
        status.frame = CGRect(x: bounds.midX - 46, y: controls.minY + 8, width: 92, height: 30)
        advance.frame = CGRect(x: bounds.midX - 58, y: status.frame.maxY + 4, width: 116, height: 44)
        close.frame = CGRect(x: bounds.midX - 40, y: controls.maxY - 52, width: 80, height: 44)
    }

    @objc private func nextMarker() {
        phase = (phase + 1) % colours.count
        updateMarkers()
    }

    @objc private func closePattern() { onClose() }

    private func updateMarkers() {
        status.text = "Marker \(phase)"
        status.accessibilityValue = String(phase)
        for (index, cell) in cells.enumerated() {
            let marker = (index + phase) % colours.count
            fills[index].backgroundColor = colours[marker]
            cell.accessibilityValue = String(marker)
        }
    }
}
