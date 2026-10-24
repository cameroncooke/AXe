import SwiftUI
import UIKit

/// A normal Playground page that records real UIKit contacts, including cancellation.
struct TouchMonitorView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> TouchMonitorController {
        TouchMonitorController()
    }

    func updateUIViewController(_ controller: TouchMonitorController, context: Context) {}
}

final class TouchMonitorController: UIViewController {
    private let generation = UUID()
    private let summary = UILabel()
    private let tapCount = UILabel()
    private let pad = TouchMonitorPad()
    private var events: [TouchMonitorEvent] = []
    private var sequence = 0
    private var buttonTapCount = 0
    private var writeFailure: String?
    private let logURL = URL.documentsDirectory.appending(path: "touch-monitor.json")

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "touch-monitor-screen"

        let title = UILabel()
        title.text = "Touch Monitor"
        title.font = .preferredFont(forTextStyle: .title2)
        let explanation = UILabel()
        explanation.text = "Use one or two fingers. The page records movement and release. The latest log is Documents/touch-monitor.json."
        explanation.numberOfLines = 0
        explanation.font = .preferredFont(forTextStyle: .caption1)
        summary.numberOfLines = 0
        summary.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        summary.accessibilityIdentifier = "touch-monitor-summary"
        tapCount.accessibilityIdentifier = "touch-monitor-tap-count"

        let button = UIButton(type: .system)
        button.setTitle("Tap after changing the device", for: .normal)
        button.accessibilityIdentifier = "touch-monitor-button"
        button.addTarget(self, action: #selector(buttonTapped), for: .touchUpInside)
        button.heightAnchor.constraint(equalToConstant: 48).isActive = true

        pad.accessibilityIdentifier = "touch-monitor-pad"
        pad.onEvent = { [weak self] event in self?.record(event) }
        let stack = UIStackView(arrangedSubviews: [title, explanation, summary, tapCount, button, pad])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            pad.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
        ])
        publish()
    }

    @objc private func buttonTapped() {
        buttonTapCount += 1
        publish()
    }

    private func record(_ event: TouchMonitorEvent) {
        events.append(event)
        if events.count > 512 { events.removeFirst(events.count - 512) }
        publish()
    }

    private func publish() {
        sequence += 1
        let snapshot = TouchMonitorSnapshot(generation: generation,
            processIdentifier: ProcessInfo.processInfo.processIdentifier, sequence: sequence,
            activeContacts: pad.activeContactIDs.sorted(), events: events, buttonTapCount: buttonTapCount)
        do {
            try JSONEncoder().encode(snapshot).write(to: logURL, options: .atomic)
            writeFailure = nil
        } catch {
            writeFailure = error.localizedDescription
        }
        let lastEvent = events.last.map { "\nFinger \($0.contactID): \($0.phase) at (\(Int($0.x)), \(Int($0.y)))" } ?? ""
        summary.text = "Active contacts: \(pad.activeContactIDs.count)\nEvents: \(events.count)"
            + lastEvent
            + (writeFailure.map { "\nLog error: \($0)" } ?? "")
        summary.accessibilityValue = String(pad.activeContactIDs.count)
        tapCount.text = "Button taps: \(buttonTapCount)"
        tapCount.accessibilityValue = String(buttonTapCount)
    }
}

private final class TouchMonitorPad: UIView {
    var onEvent: ((TouchMonitorEvent) -> Void)?
    private var contacts: [ObjectIdentifier: Int] = [:]
    private var nextContactID = 1
    var activeContactIDs: [Int] { Array(contacts.values) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isAccessibilityElement = true
        accessibilityLabel = "Touch recording area"
        backgroundColor = .systemTeal.withAlphaComponent(0.18)
        layer.cornerRadius = 12
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches.sorted(by: { $0.location(in: self).x < $1.location(in: self).x }) {
            contacts[ObjectIdentifier(touch)] = nextContactID
            nextContactID += 1
            record(touch, phase: "began")
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { record(touch, phase: "moved") }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, phase: "ended")
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, phase: "cancelled")
    }

    private func finish(_ touches: Set<UITouch>, phase: String) {
        for touch in touches {
            guard let contactID = contacts.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            record(touch, contactID: contactID, phase: phase)
        }
    }

    private func record(_ touch: UITouch, phase: String) {
        guard let contactID = contacts[ObjectIdentifier(touch)] else { return }
        record(touch, contactID: contactID, phase: phase)
    }

    private func record(_ touch: UITouch, contactID: Int, phase: String) {
        let point = touch.location(in: window)
        onEvent?(TouchMonitorEvent(contactID: contactID, phase: phase,
            timestamp: touch.timestamp, x: Double(point.x), y: Double(point.y)))
    }
}

private struct TouchMonitorSnapshot: Encodable {
    let generation: UUID
    let processIdentifier: Int32
    let sequence: Int
    let activeContacts: [Int]
    let events: [TouchMonitorEvent]
    let buttonTapCount: Int
}

private struct TouchMonitorEvent: Encodable {
    let contactID: Int
    let phase: String
    let timestamp: TimeInterval
    let x: Double
    let y: Double
}
