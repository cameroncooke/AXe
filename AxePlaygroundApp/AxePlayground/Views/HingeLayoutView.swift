import SwiftUI
import UIKit

/// A visible document that moves its controls around the device's real fold region.
struct HingeLayoutView: View {
    var body: some View {
        if #available(iOS 27.1, *) {
            HingeLayoutContent()
        } else {
            Text("Hinge layout requires iOS 27.1 or later.")
        }
    }
}

@available(iOS 27.1, *)
private struct HingeLayoutContent: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> HingeLayoutController { HingeLayoutController() }
    func updateUIViewController(_ controller: HingeLayoutController, context: Context) {}
}

@available(iOS 27.1, *)
private final class HingeLayoutController: UIViewController, UITextFieldDelegate, UIScrollViewDelegate {
    private let generation = UUID()
    private let status = UILabel()
    private let document = UIScrollView()
    private let button = UIButton(type: .system)
    private let field = UITextField()
    private let dismiss = UIButton(type: .system)
    private var hinge: UIHinge?
    private var hingeUpdates = 0
    private var marks = 0
    private var textChanges = 0
    private var sequence = 0
    private var layoutRevision = 0
    private var layoutSignature = ""
    private var mode = "single"
    private var divisions: [HingeRegionRecord] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "hinge-layout-screen"
        status.numberOfLines = 3
        status.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        status.accessibilityIdentifier = "hinge-layout-status"
        view.addSubview(status)
        document.delegate = self
        document.backgroundColor = .secondarySystemBackground
        document.contentInsetAdjustmentBehavior = .never
        document.accessibilityIdentifier = "hinge-layout-document"
        view.addSubview(document)
        for row in 1...30 {
            let label = UILabel()
            label.text = "Document row \(row)"
            label.accessibilityIdentifier = "hinge-layout-row-\(row)"
            label.tag = row
            document.addSubview(label)
        }
        button.setTitle("Add mark", for: .normal)
        button.accessibilityIdentifier = "hinge-layout-button"
        button.addTarget(self, action: #selector(addMark), for: .touchUpInside)
        view.addSubview(button)
        field.placeholder = "Write a note"
        field.accessibilityLabel = "Note"
        field.accessibilityIdentifier = "hinge-layout-field"
        field.borderStyle = .roundedRect
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.delegate = self
        field.addTarget(self, action: #selector(textChanged), for: .editingChanged)
        view.addSubview(field)
        dismiss.setTitle("Dismiss keyboard", for: .normal)
        dismiss.accessibilityIdentifier = "hinge-layout-dismiss"
        dismiss.addTarget(self, action: #selector(dismissKeyboard), for: .touchUpInside)
        view.addSubview(dismiss)
        let interaction = UIHingeInteraction { [weak self] _, update in
            guard let self else { return }
            self.hinge = update.hinge
            self.hingeUpdates += 1
            self.view.setNeedsLayout()
        }
        view.addInteraction(interaction)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let usable = view.bounds.inset(by: view.safeAreaInsets).insetBy(dx: 12, dy: 12)
        var doc = CGRect(x: usable.minX, y: usable.minY, width: usable.width, height: floor(usable.height * 0.60))
        var controls = CGRect(x: usable.minX, y: doc.maxY + 8, width: usable.width, height: usable.maxY - doc.maxY - 8)
        let regions = view.reservedRegions(kind: .division, options: .includeInactive)
        divisions = regions.map { HingeRegionRecord(frame: LayoutRect($0.frame), active: $0.isActive) }
        mode = "single"
        if hinge?.status == .partiallyOpen {
            mode = "partial-region-unavailable"
            let active = regions.filter(\.isActive)
            if active.count == 1, let division = active.first?.frame {
                if division.height > division.width, division.midX > usable.minX, division.midX < usable.maxX {
                    doc = CGRect(x: usable.minX, y: usable.minY, width: division.minX - usable.minX - 8, height: usable.height)
                    controls = CGRect(x: division.maxX + 8, y: usable.minY, width: usable.maxX - division.maxX - 8, height: usable.height)
                    mode = "split-vertical"
                } else if division.width > division.height, division.midY > usable.minY, division.midY < usable.maxY {
                    doc = CGRect(x: usable.minX, y: usable.minY, width: usable.width, height: division.minY - usable.minY - 8)
                    controls = CGRect(x: usable.minX, y: division.maxY + 8, width: usable.width, height: usable.maxY - division.maxY - 8)
                    mode = "split-horizontal"
                }
            }
        }
        status.frame = CGRect(x: doc.minX, y: doc.minY, width: doc.width, height: 52)
        document.frame = CGRect(x: doc.minX, y: doc.minY + 56, width: doc.width, height: max(20, doc.height - 56))
        button.frame = CGRect(x: controls.minX, y: controls.minY, width: controls.width, height: 40)
        field.frame = CGRect(x: controls.minX, y: controls.minY + 44, width: controls.width, height: 40)
        dismiss.frame = CGRect(x: controls.minX, y: controls.minY + 88, width: controls.width, height: 40)
        for row in 1...30 {
            document.viewWithTag(row)?.frame = CGRect(x: 8, y: CGFloat(row - 1) * 44, width: max(20, document.bounds.width - 16), height: 44)
        }
        document.contentSize = CGSize(width: document.bounds.width, height: 30 * 44)
        let signature = "\(mode)|\(view.bounds)|\(document.frame)|\(field.frame)|\(hingeUpdates)"
        guard signature != layoutSignature else { return }
        layoutSignature = signature
        layoutRevision += 1
        publish()
    }

    @objc private func addMark() { marks += 1; publish() }
    @objc private func textChanged() { textChanges += 1; publish() }
    @objc private func dismissKeyboard() { field.resignFirstResponder(); publish() }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool { textField.resignFirstResponder(); publish(); return true }
    func textFieldDidBeginEditing(_ textField: UITextField) { publish() }
    func textFieldDidEndEditing(_ textField: UITextField) { publish() }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { publish() }

    private func publish() {
        guard isViewLoaded, view.window != nil else { return }
        sequence += 1
        status.text = "\(mode)  hinge updates \(hingeUpdates)\nMarks: \(marks)  Note: \(field.text ?? "")"
        status.accessibilityValue = mode
        let snapshot = HingeLayoutSnapshot(generation: generation, processIdentifier: ProcessInfo.processInfo.processIdentifier,
            sequence: sequence, layoutRevision: layoutRevision, mode: mode, hingeUpdates: hingeUpdates,
            hingeStatus: hinge?.status.rawValue, hingeRadians: hinge.map { Double($0.angle) }, divisions: divisions,
            button: LayoutRect(button.convert(button.bounds, to: view.window)),
            field: LayoutRect(field.convert(field.bounds, to: view.window)),
            document: LayoutRect(document.convert(document.bounds, to: view.window)),
            marks: marks, text: field.text ?? "", textChanges: textChanges, focused: field.isFirstResponder,
            scrollOffsetY: Double(document.contentOffset.y))
        do {
            try JSONEncoder().encode(snapshot).write(to: URL.documentsDirectory.appending(path: "hinge-layout.json"), options: .atomic)
        } catch {
            status.text = "Layout log error: \(error.localizedDescription)"
        }
    }
}

private struct HingeLayoutSnapshot: Encodable {
    let generation: UUID
    let processIdentifier: Int32
    let sequence: Int
    let layoutRevision: Int
    let mode: String
    let hingeUpdates: Int
    let hingeStatus: Int?
    let hingeRadians: Double?
    let divisions: [HingeRegionRecord]
    let button: LayoutRect
    let field: LayoutRect
    let document: LayoutRect
    let marks: Int
    let text: String
    let textChanges: Int
    let focused: Bool
    let scrollOffsetY: Double
}

private struct HingeRegionRecord: Encodable {
    let frame: LayoutRect
    let active: Bool
}

struct LayoutRect: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ frame: CGRect) {
        x = Double(frame.minX); y = Double(frame.minY)
        width = Double(frame.width); height = Double(frame.height)
    }
}
