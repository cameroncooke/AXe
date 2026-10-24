import SwiftUI
import UIKit

struct InsetWindowView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> InsetWindowHost { InsetWindowHost() }
    func updateUIViewController(_ controller: InsetWindowHost, context: Context) {}
}

final class InsetWindowHost: UIViewController {
    private var inset: UIWindow?
    private weak var originalWindow: UIWindow?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let show = UIButton(type: .system)
        show.setTitle("Open smaller window", for: .normal)
        show.accessibilityIdentifier = "inset-window-open"
        show.addTarget(self, action: #selector(openWindow), for: .touchUpInside)
        show.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(show)
        NSLayoutConstraint.activate([
            show.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            show.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            show.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    @objc private func openWindow() {
        guard inset == nil, let current = view.window, let scene = current.windowScene else { return }
        current.endEditing(true)
        originalWindow = current
        let window = UIWindow(windowScene: scene)
        window.accessibilityIdentifier = "inset-window"
        // Preserve the scene-supplied centre and transform. A frame is unsafe when transformed.
        window.bounds = CGRect(origin: .zero, size: CGSize(width: window.bounds.width * 0.8, height: window.bounds.height * 0.8))
        window.layer.borderColor = UIColor.systemOrange.cgColor
        window.layer.borderWidth = 4
        window.clipsToBounds = true
        window.windowLevel = current.windowLevel + 1
        let controls = InsetControlsController()
        controls.onClose = { [weak self] in self?.closeWindow() }
        window.rootViewController = controls
        inset = window
        window.makeKeyAndVisible()
    }

    private func closeWindow() {
        inset?.endEditing(true)
        inset?.isHidden = true
        inset?.rootViewController = nil
        inset = nil
        originalWindow?.makeKeyAndVisible()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent { closeWindow() }
    }
}

private final class InsetControlsController: UIViewController, UITextFieldDelegate {
    var onClose: (() -> Void)?
    private let generation = UUID()
    private let summary = UILabel()
    private let button = UIButton(type: .system)
    private let field = UITextField()
    private var taps = 0
    private var textChanges = 0
    private var sequence = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "inset-controls-screen"
        summary.accessibilityIdentifier = "inset-window-summary"
        summary.numberOfLines = 3
        button.setTitle("Tap in smaller window", for: .normal)
        button.accessibilityIdentifier = "inset-window-button"
        button.addTarget(self, action: #selector(tapped), for: .touchUpInside)
        field.placeholder = "Write in smaller window"
        field.accessibilityIdentifier = "inset-window-field"
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.borderStyle = .roundedRect
        field.delegate = self
        field.addTarget(self, action: #selector(edited), for: .editingChanged)
        let close = UIButton(type: .system)
        close.setTitle("Close smaller window", for: .normal)
        close.accessibilityIdentifier = "inset-window-close"
        close.addTarget(self, action: #selector(closeWindow), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [summary, button, field, close])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            button.heightAnchor.constraint(equalToConstant: 48),
            field.heightAnchor.constraint(equalToConstant: 44),
            close.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); publish() }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); publish() }
    @objc private func tapped() { taps += 1; publish() }
    @objc private func edited() { textChanges += 1; publish() }
    @objc private func closeWindow() { onClose?() }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool { textField.resignFirstResponder(); publish(); return true }

    private func publish() {
        guard let window = view.window, let scene = window.windowScene else { return }
        sequence += 1
        summary.text = "Smaller window\nButton taps: \(taps)\nText: \(field.text ?? "")"
        summary.accessibilityValue = String(taps)
        let sceneRect = window.convert(window.bounds, to: scene.coordinateSpace)
        let snapshot = InsetWindowSnapshot(generation: generation, processIdentifier: ProcessInfo.processInfo.processIdentifier,
            sequence: sequence, window: LayoutRect(sceneRect), scene: LayoutRect(scene.coordinateSpace.bounds),
            button: LayoutRect(button.convert(button.bounds, to: scene.coordinateSpace)),
            field: LayoutRect(field.convert(field.bounds, to: scene.coordinateSpace)),
            taps: taps, text: field.text ?? "", textChanges: textChanges, focused: field.isFirstResponder)
        do {
            try JSONEncoder().encode(snapshot).write(to: URL.documentsDirectory.appending(path: "inset-window.json"), options: .atomic)
        } catch {
            summary.text = "Window log error: \(error.localizedDescription)"
        }
    }
}

private struct InsetWindowSnapshot: Encodable {
    let generation: UUID
    let processIdentifier: Int32
    let sequence: Int
    let window: LayoutRect
    let scene: LayoutRect
    let button: LayoutRect
    let field: LayoutRect
    let taps: Int
    let text: String
    let textChanges: Int
    let focused: Bool
}
