import SwiftUI
import UIKit

/// Strong colour markers make upright capture and frame changes visible.
struct MediaPatternView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> MediaPatternController { MediaPatternController() }
    func updateUIViewController(_ controller: MediaPatternController, context: Context) {}
}

final class MediaPatternController: UIViewController {
    private let status = UILabel()
    private let advance = UIButton(type: .system)
    private let cells = (0..<4).map { _ in UILabel() }
    private var phase = 0
    private let colours = [UIColor(red: 1, green: 0, blue: 0, alpha: 1),
        UIColor(red: 0, green: 1, blue: 0, alpha: 1), UIColor(red: 0, green: 0, blue: 1, alpha: 1),
        UIColor(red: 1, green: 1, blue: 0, alpha: 1)]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.accessibilityIdentifier = "media-pattern-screen"
        status.textColor = .white
        status.accessibilityIdentifier = "media-pattern-phase"
        status.textAlignment = .center
        view.addSubview(status)
        advance.setTitle("Next marker", for: .normal)
        advance.accessibilityIdentifier = "media-pattern-next"
        advance.addTarget(self, action: #selector(nextMarker), for: .touchUpInside)
        view.addSubview(advance)
        for (index, cell) in cells.enumerated() {
            cell.textAlignment = .center
            cell.textColor = .black
            cell.font = .boldSystemFont(ofSize: 24)
            cell.accessibilityIdentifier = "media-pattern-cell-\(index)"
            cell.isAccessibilityElement = true
            view.addSubview(cell)
        }
        updateMarkers()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds.inset(by: view.safeAreaInsets).insetBy(dx: 8, dy: 8)
        status.frame = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width * 0.5, height: 40)
        advance.frame = CGRect(x: bounds.midX, y: bounds.minY, width: bounds.width * 0.5, height: 40)
        let content = CGRect(x: bounds.minX, y: bounds.minY + 48, width: bounds.width, height: max(20, bounds.height - 48))
        for (index, cell) in cells.enumerated() {
            cell.frame = CGRect(x: content.minX + CGFloat(index % 2) * content.width / 2,
                y: content.minY + CGFloat(index / 2) * content.height / 2,
                width: content.width / 2 - 4, height: content.height / 2 - 4)
        }
    }

    @objc private func nextMarker() { phase = (phase + 1) % 4; updateMarkers() }
    private func updateMarkers() {
        status.text = "Marker \(phase)"
        status.accessibilityValue = String(phase)
        for (index, cell) in cells.enumerated() {
            let marker = (index + phase) % 4
            cell.backgroundColor = colours[marker]
            cell.text = ["TOP LEFT", "TOP RIGHT", "BOTTOM LEFT", "BOTTOM RIGHT"][index]
            cell.accessibilityValue = String(marker)
        }
    }
}
