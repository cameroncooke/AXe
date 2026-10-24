import Photos
import SwiftUI
import UIKit

/// Normal visible examples of duplicate targets, long text, delayed changes and system permission UI.
struct AgentExamplesView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> AgentExamplesController { AgentExamplesController() }
    func updateUIViewController(_ controller: AgentExamplesController, context: Context) {}
}

final class AgentExamplesController: UIViewController, UITextFieldDelegate, UIScrollViewDelegate {
    private let generation = UUID()
    private let field = UITextField()
    private let status = UILabel()
    private let longLabel = UILabel()
    private let outer = UIScrollView()
    private let list = UIScrollView()
    private let tapCounter = UIButton(type: .system)
    private let summary = UILabel()
    private let observer = DuoControlsTouchObserver()
    private var contacts: [DuoControlsContact] = []
    private var contactsDropped = 0
    private var taps = 0
    private var textChanges = 0
    private var lastListSize = CGSize.zero
    private var photosStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite).rawValue
    private var timer: Timer?

    override var shouldAutorotate: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }
    deinit { timer?.invalidate() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "agent-examples.screen"
        let content = UIStackView()
        content.axis = .vertical
        content.spacing = 5
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            content.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -4),
        ])
        summary.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        summary.numberOfLines = 2
        summary.accessibilityIdentifier = "agent-examples.summary"
        summary.heightAnchor.constraint(equalToConstant: 28).isActive = true
        content.addArrangedSubview(summary)
        configureButton(tapCounter, title: "Target", id: "agent-examples.tap", action: #selector(tapped))
        addRow([tapCounter, button("Reset", id: "agent-examples.reset", action: #selector(reset))], to: content)
        field.borderStyle = .roundedRect
        field.placeholder = "Input"
        field.accessibilityIdentifier = "agent-examples.text"
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.delegate = self
        field.addTarget(self, action: #selector(textChanged), for: .editingChanged)
        field.heightAnchor.constraint(equalToConstant: 36).isActive = true
        content.addArrangedSubview(field)
        addRow([button("Add space in 8s", id: "agent-examples.space", action: #selector(scheduleSpace)),
                button("Dismiss", id: "agent-examples.dismiss", action: #selector(dismissField))], to: content)
        addRow([button("Same", id: nil, action: #selector(tapped)),
                button("Same", id: nil, action: #selector(tapped))], to: content)
        let blank = button("", id: nil, action: #selector(tapped))
        blank.isAccessibilityElement = true
        blank.accessibilityLabel = nil
        blank.backgroundColor = .systemOrange
        status.text = "a"
        status.accessibilityIdentifier = "agent-examples.status"
        addRow([blank, status], to: content)
        let covered = UIView()
        covered.heightAnchor.constraint(equalToConstant: 34).isActive = true
        for (title, id) in [("Covered", "agent-examples.covered"), ("Cover", "agent-examples.cover")] {
            let item = button(title, id: id, action: #selector(tapped))
            item.translatesAutoresizingMaskIntoConstraints = false
            covered.addSubview(item)
            NSLayoutConstraint.activate([item.leadingAnchor.constraint(equalTo: covered.leadingAnchor),
                item.trailingAnchor.constraint(equalTo: covered.trailingAnchor),
                item.topAnchor.constraint(equalTo: covered.topAnchor), item.bottomAnchor.constraint(equalTo: covered.bottomAnchor)])
        }
        content.addArrangedSubview(covered)
        addRow([button("Long content", id: "agent-examples.long", action: #selector(showLong)),
                button("Photos permission", id: "agent-examples.photos", action: #selector(requestPhotos))], to: content)
        longLabel.isHidden = true
        longLabel.numberOfLines = 1
        longLabel.lineBreakMode = .byTruncatingTail
        longLabel.accessibilityIdentifier = "agent-examples.longLabel"
        let longHeight = longLabel.heightAnchor.constraint(equalToConstant: 24)
        longHeight.priority = .defaultHigh
        longHeight.isActive = true
        content.addArrangedSubview(longLabel)
        outer.accessibilityIdentifier = "agent-examples.outer"
        outer.delegate = self
        outer.alwaysBounceVertical = true
        outer.backgroundColor = .secondarySystemBackground
        outer.heightAnchor.constraint(equalToConstant: 150).isActive = true
        content.addArrangedSubview(outer)
        list.accessibilityIdentifier = "agent-examples.list"
        list.delegate = self
        list.alwaysBounceVertical = true
        outer.addSubview(list)
        for index in 0..<30 {
            let label = UILabel(frame: CGRect(x: 8, y: CGFloat(index * 36), width: 300, height: 36))
            label.text = "Table row \(index)"
            label.accessibilityIdentifier = "agent-examples.row.\(index)"
            list.addSubview(label)
        }
        let hidden = UILabel()
        hidden.text = "Hidden note"
        hidden.isHidden = true
        hidden.isAccessibilityElement = true
        view.addSubview(hidden)
        observer.cancelsTouchesInView = false
        observer.delaysTouchesBegan = false
        observer.delaysTouchesEnded = false
        observer.onContact = { [weak self] contact in
            guard let self else { return }
            self.contacts.append(contact)
            if self.contacts.count > 4096 { self.contacts.removeFirst(); self.contactsDropped += 1 }
            self.publish()
        }
        view.addGestureRecognizer(observer)
        publish()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard outer.bounds.size != lastListSize else { return }
        lastListSize = outer.bounds.size
        outer.contentSize = CGSize(width: outer.bounds.width, height: 900)
        list.frame = CGRect(x: 0, y: 0, width: outer.bounds.width, height: outer.bounds.height)
        list.contentSize = CGSize(width: list.bounds.width, height: 1080)
        for label in list.subviews where label is UILabel { label.frame.size.width = list.bounds.width - 16 }
        publish()
    }

    private func configureButton(_ item: UIButton, title: String, id: String?, action: Selector) {
        item.setTitle(title, for: .normal)
        item.accessibilityIdentifier = id
        item.addTarget(self, action: action, for: .touchUpInside)
        item.backgroundColor = .secondarySystemBackground
        item.layer.cornerRadius = 6
    }
    private func button(_ title: String, id: String?, action: Selector) -> UIButton {
        let value = UIButton(type: .system)
        configureButton(value, title: title, id: id, action: action)
        return value
    }
    private func addRow(_ items: [UIView], to content: UIStackView) {
        let row = UIStackView(arrangedSubviews: items)
        row.distribution = .fillEqually
        row.spacing = 8
        row.heightAnchor.constraint(equalToConstant: 34).isActive = true
        content.addArrangedSubview(row)
    }
    @objc private func tapped() { taps += 1; publish() }
    @objc private func textChanged() { textChanges += 1; publish() }
    @objc private func dismissField() { field.resignFirstResponder(); publish() }
    @objc private func scheduleSpace() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.status.text = (self.status.text ?? "") + " "
            self.publish()
        }
    }
    @objc private func showLong() { longLabel.text = String(repeating: "\"", count: 900_000); longLabel.isHidden = false; publish() }
    @objc private func requestPhotos() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] authorization in
            DispatchQueue.main.async {
                self?.photosStatus = authorization.rawValue
                self?.publish()
            }
        }
    }
    @objc private func reset() {
        timer?.invalidate()
        status.text = "a"
        longLabel.text = ""
        longLabel.isHidden = true
        field.text = ""
        field.resignFirstResponder()
        taps = 0
        textChanges = 0
        outer.contentOffset = .zero
        list.contentOffset = .zero
        publish()
    }
    func textFieldDidBeginEditing(_ textField: UITextField) { publish() }
    func textFieldDidEndEditing(_ textField: UITextField) { publish() }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { publish() }

    private func publish() {
        guard isViewLoaded else { return }
        tapCounter.accessibilityValue = String(taps)
        summary.text = "Target taps \(taps), text edits \(textChanges), Photos \(photosStatus)\nLog: Documents/agent-examples.json"
        let value = AgentExamplesDocument(generation: generation, pid: ProcessInfo.processInfo.processIdentifier,
            taps: taps, textChanges: textChanges, text: field.text ?? "", focused: field.isFirstResponder,
            status: status.text ?? "", longVisible: !longLabel.isHidden, longLength: longLabel.text?.utf8.count ?? 0,
            outerOffset: Double(outer.contentOffset.y), listOffset: Double(list.contentOffset.y), photosStatus: photosStatus,
            activeWindowTouches: observer.activeCount, windowTraceDropped: contactsDropped, windowTouchTrace: contacts)
        do { try JSONEncoder().encode(value).write(to: URL.documentsDirectory.appending(path: "agent-examples.json"), options: .atomic) }
        catch { summary.text = "Log failed: \(error.localizedDescription)" }
    }
}

private struct AgentExamplesDocument: Encodable {
    let generation: UUID
    let pid: Int32
    let taps: Int
    let textChanges: Int
    let text: String
    let focused: Bool
    let status: String
    let longVisible: Bool
    let longLength: Int
    let outerOffset: Double
    let listOffset: Double
    let photosStatus: Int
    let activeWindowTouches: Int
    let windowTraceDropped: Int
    let windowTouchTrace: [DuoControlsContact]
}
