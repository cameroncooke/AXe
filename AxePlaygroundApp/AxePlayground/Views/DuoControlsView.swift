import SwiftUI
import UIKit

/// A normal visible Playground page for controls, nested scrolling and contact readback.
struct DuoControlsView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> DuoControlsController { DuoControlsController() }
    func updateUIViewController(_ controller: DuoControlsController, context: Context) {}
}

final class DuoControlsController: UIViewController, UIGestureRecognizerDelegate, UIScrollViewDelegate, UITextFieldDelegate {
    private let generation = UUID()
    private let summary = UILabel()
    private let mainScroll = UIScrollView()
    private let listScroll = UIScrollView()
    private let canvas = UIScrollView()
    private let pad = DuoControlsPad()
    private let slider = UISlider()
    private let toggle = UISwitch()
    private let field = UITextField()
    private let observer = DuoControlsTouchObserver()
    private let targets = DuoControlsTargets()
    private var frameViews: [UIView] = []
    private var counts: [String: Int] = [:]
    private var contacts: [DuoControlsContact] = []
    private var recognizers: [DuoControlsRecognizerEvent] = []
    private var droppedContacts = 0
    private var droppedRecognizers = 0
    private var sequence = 0
    private var firstPoint = CGPoint.zero
    private var lastPoint = CGPoint.zero
    private var touchPoint = CGPoint.zero
    private var panDelta = CGPoint.zero
    private var pinchScale: CGFloat = 1
    private var rotation: CGFloat = 0
    private var lastSize = CGSize.zero
    private var resetting = false
    private var keyboardVisible = false

    override var shouldAutorotate: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "feature.screen"
        // UIKit scrolls the focused field above the keyboard while the keyboard animates in.
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardDidShow),
            name: UIResponder.keyboardDidShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardDidHide),
            name: UIResponder.keyboardDidHideNotification, object: nil)
        let outer = UIStackView()
        outer.axis = .vertical
        outer.spacing = 6
        outer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            outer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            outer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            outer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -4),
        ])
        summary.numberOfLines = 0
        summary.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        summary.accessibilityIdentifier = "feature.state"
        summary.heightAnchor.constraint(equalToConstant: 92).isActive = true
        outer.addArrangedSubview(summary)
        let toolbar = UIStackView(arrangedSubviews: [
            button("Reset", id: "feature.reset", action: #selector(resetControls)),
            button("Dismiss keyboard", id: "feature.dismissKeyboard", action: #selector(dismissKeyboard)),
            button("Show list", id: "feature.showList", action: #selector(showList)),
            button("Show canvas", id: "feature.showCanvas", action: #selector(showCanvas)),
            button("Targets", id: "feature.showTargets", action: #selector(showTargets)),
            button("Waits", id: "feature.showWaits", action: #selector(showWaits)),
        ])
        toolbar.distribution = .fillEqually
        toolbar.spacing = 6
        toolbar.heightAnchor.constraint(equalToConstant: 38).isActive = true
        outer.addArrangedSubview(toolbar)
        let inputToolbar = UIStackView(arrangedSubviews: [
            button("Show pad", id: "feature.showPad", action: #selector(showPad)),
            button("Show text", id: "feature.showText", action: #selector(showText)),
        ])
        inputToolbar.distribution = .fillEqually
        inputToolbar.spacing = 6
        inputToolbar.heightAnchor.constraint(equalToConstant: 32).isActive = true
        outer.addArrangedSubview(inputToolbar)
        mainScroll.accessibilityIdentifier = "feature.mainScroll"
        mainScroll.delegate = self
        mainScroll.alwaysBounceVertical = true
        outer.addArrangedSubview(mainScroll)
        let content = UIStackView()
        content.axis = .vertical
        content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false
        mainScroll.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: mainScroll.contentLayoutGuide.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: mainScroll.contentLayoutGuide.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: mainScroll.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: mainScroll.contentLayoutGuide.bottomAnchor),
            content.widthAnchor.constraint(equalTo: mainScroll.frameLayoutGuide.widthAnchor, constant: -24),
        ])
        let tap = button("Tap counter", id: "feature.tap", action: #selector(tapCounter))
        tap.heightAnchor.constraint(equalToConstant: 38).isActive = true
        content.addArrangedSubview(tap)
        configurePad()
        content.addArrangedSubview(pad)
        slider.minimumValue = 0
        slider.maximumValue = 100
        slider.value = 50
        slider.accessibilityIdentifier = "feature.slider"
        slider.accessibilityLabel = "Horizontal value"
        slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
        slider.heightAnchor.constraint(equalToConstant: 34).isActive = true
        content.addArrangedSubview(slider)
        toggle.accessibilityIdentifier = "feature.switch"
        toggle.accessibilityLabel = "Switch control"
        toggle.addTarget(self, action: #selector(switchChanged), for: .valueChanged)
        let switchRow = UIStackView(arrangedSubviews: [label("Switch control", id: "feature.switchLabel"), toggle])
        switchRow.spacing = 12
        content.addArrangedSubview(switchRow)
        field.borderStyle = .roundedRect
        field.placeholder = "Type or edit text"
        field.accessibilityIdentifier = "feature.text"
        field.accessibilityLabel = "Text entry"
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.delegate = self
        field.addTarget(self, action: #selector(textChanged), for: .editingChanged)
        field.heightAnchor.constraint(equalToConstant: 38).isActive = true
        content.addArrangedSubview(field)
        content.addArrangedSubview(label("Scroll list: 30 rows, separate from the page", id: "feature.scrollHelp"))
        configureList()
        content.addArrangedSubview(listScroll)
        content.addArrangedSubview(label("Canvas: scroll in all four directions", id: "feature.canvasHelp"))
        configureCanvas()
        content.addArrangedSubview(canvas)
        targets.onChange = { [weak self] name in self?.increment(name) }
        content.addArrangedSubview(targets)
        frameViews = [view, outer, summary, mainScroll, tap, pad, slider, toggle, field, listScroll, canvas, targets]
        observer.cancelsTouchesInView = false
        observer.delaysTouchesBegan = false
        observer.delaysTouchesEnded = false
        observer.onContact = { [weak self] contact in self?.recordContact(contact) }
        view.addGestureRecognizer(observer)
        publish("ready")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if view.bounds.size != lastSize {
            lastSize = view.bounds.size
            if field.isFirstResponder { showText() }
            publish("layoutChanged")
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        view.layoutIfNeeded()
        publish("appeared")
    }

    private func configurePad() {
        pad.isMultipleTouchEnabled = true
        pad.backgroundColor = .systemBlue
        pad.layer.cornerRadius = 8
        pad.isAccessibilityElement = true
        pad.accessibilityIdentifier = "feature.pad"
        pad.accessibilityLabel = "Gesture pad"
        pad.heightAnchor.constraint(equalToConstant: 116).isActive = true
        let help = label("Gesture pad: tap, hold, drag, pinch and rotate", id: "feature.padHelp")
        help.textColor = .white
        help.textAlignment = .center
        help.isAccessibilityElement = false
        help.translatesAutoresizingMaskIntoConstraints = false
        pad.addSubview(help)
        NSLayoutConstraint.activate([
            help.centerXAnchor.constraint(equalTo: pad.centerXAnchor),
            help.centerYAnchor.constraint(equalTo: pad.centerYAnchor),
            help.widthAnchor.constraint(lessThanOrEqualTo: pad.widthAnchor, constant: -12),
        ])
        pad.onTouches = { [weak self] name, touches in
            guard let self else { return }
            counts[name, default: 0] += touches.count
            if let touch = touches.first { touchPoint = touch.location(in: pad) }
            publish(name)
        }
        let single = UITapGestureRecognizer(target: self, action: #selector(padTapped(_:)))
        let double = UITapGestureRecognizer(target: self, action: #selector(padDoubleTapped(_:)))
        double.numberOfTapsRequired = 2
        single.require(toFail: double)
        let twoTap = UITapGestureRecognizer(target: self, action: #selector(twoTapped(_:)))
        twoTap.numberOfTouchesRequired = 2
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.5
        let twoHold = UILongPressGestureRecognizer(target: self, action: #selector(twoHeld(_:)))
        twoHold.numberOfTouchesRequired = 2
        twoHold.minimumPressDuration = 0.5
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        let rotate = UIRotationGestureRecognizer(target: self, action: #selector(rotated(_:)))
        let gestures: [UIGestureRecognizer] = [single, double, twoTap, hold, twoHold, pan, pinch, rotate]
        for recognizer in gestures {
            recognizer.delegate = self
            recognizer.cancelsTouchesInView = false
            pad.addGestureRecognizer(recognizer)
        }
    }

    private func configureList() {
        listScroll.accessibilityIdentifier = "feature.list"
        listScroll.delegate = self
        listScroll.alwaysBounceVertical = true
        listScroll.backgroundColor = .secondarySystemBackground
        listScroll.heightAnchor.constraint(equalToConstant: 140).isActive = true
        let rows = UIStackView()
        rows.axis = .vertical
        rows.translatesAutoresizingMaskIntoConstraints = false
        listScroll.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: listScroll.contentLayoutGuide.leadingAnchor, constant: 8),
            rows.trailingAnchor.constraint(equalTo: listScroll.contentLayoutGuide.trailingAnchor, constant: -8),
            rows.topAnchor.constraint(equalTo: listScroll.contentLayoutGuide.topAnchor),
            rows.bottomAnchor.constraint(equalTo: listScroll.contentLayoutGuide.bottomAnchor),
            rows.widthAnchor.constraint(equalTo: listScroll.frameLayoutGuide.widthAnchor, constant: -16),
        ])
        for index in 1...30 {
            let row = label(String(format: "Scroll row %02d", index), id: String(format: "feature.row.%02d", index))
            row.heightAnchor.constraint(equalToConstant: 36).isActive = true
            rows.addArrangedSubview(row)
        }
    }

    private func configureCanvas() {
        canvas.accessibilityIdentifier = "feature.canvas"
        canvas.accessibilityLabel = "Four direction canvas"
        canvas.delegate = self
        canvas.alwaysBounceHorizontal = true
        canvas.alwaysBounceVertical = true
        canvas.backgroundColor = .systemTeal.withAlphaComponent(0.12)
        canvas.heightAnchor.constraint(equalToConstant: 400).isActive = true
        canvas.contentSize = CGSize(width: 1600, height: 1600)
        for row in 0..<8 {
            for column in 0..<8 {
                let cell = label("Canvas \(column),\(row)", id: "feature.cell.\(column).\(row)")
                cell.frame = CGRect(x: CGFloat(column * 200), y: CGFloat(row * 200), width: 200, height: 200)
                cell.textAlignment = .center
                cell.backgroundColor = (row + column).isMultiple(of: 2) ? .systemTeal.withAlphaComponent(0.16) : .systemOrange.withAlphaComponent(0.12)
                canvas.addSubview(cell)
            }
        }
    }

    private func label(_ text: String, id: String) -> UILabel {
        let value = UILabel()
        value.text = text
        value.numberOfLines = 0
        value.font = .systemFont(ofSize: 14)
        value.accessibilityIdentifier = id
        return value
    }

    private func button(_ title: String, id: String, action: Selector) -> UIButton {
        let value = UIButton(type: .system)
        value.setTitle(title, for: .normal)
        value.accessibilityIdentifier = id
        value.backgroundColor = .secondarySystemBackground
        value.layer.cornerRadius = 8
        value.addTarget(self, action: action, for: .touchUpInside)
        return value
    }

    private func recordContact(_ value: DuoControlsContact) {
        if value.phase == "windowTouchBegan" && value.activeTouches == 1 { firstPoint = CGPoint(x: value.x, y: value.y) }
        lastPoint = CGPoint(x: value.x, y: value.y)
        contacts.append(value)
        if contacts.count > 4096 { contacts.removeFirst(); droppedContacts += 1 }
        increment(value.phase)
    }

    private func recognize(_ name: String, _ recognizer: UIGestureRecognizer, completesAt state: UIGestureRecognizer.State = .ended) {
        let point = recognizer.location(in: view.window)
        recognizers.append(DuoControlsRecognizerEvent(name: name, state: recognizer.state.rawValue,
            touches: recognizer.numberOfTouches, timestamp: ProcessInfo.processInfo.systemUptime,
            x: Double(point.x), y: Double(point.y)))
        if recognizers.count > 4096 { recognizers.removeFirst(); droppedRecognizers += 1 }
        if recognizer.state == state { increment(name) } else { publish(name + "Changed") }
    }

    func gestureRecognizer(_ first: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith second: UIGestureRecognizer) -> Bool {
        first.view === pad && second.view === pad
    }

    @objc private func tapCounter() { increment("tap") }
    @objc private func padTapped(_ value: UITapGestureRecognizer) { recognize("padTap", value) }
    @objc private func padDoubleTapped(_ value: UITapGestureRecognizer) { recognize("doubleTap", value) }
    @objc private func twoTapped(_ value: UITapGestureRecognizer) { recognize("twoFingerTap", value) }
    @objc private func held(_ value: UILongPressGestureRecognizer) { recognize("longPress", value, completesAt: .began) }
    @objc private func twoHeld(_ value: UILongPressGestureRecognizer) { recognize("twoFingerHold", value, completesAt: .began) }
    @objc private func panned(_ value: UIPanGestureRecognizer) { panDelta = value.translation(in: pad); recognize("pan", value) }
    @objc private func pinched(_ value: UIPinchGestureRecognizer) { pinchScale = value.scale; recognize("pinch", value) }
    @objc private func rotated(_ value: UIRotationGestureRecognizer) { rotation = value.rotation; recognize("rotation", value) }
    @objc private func sliderChanged() { increment("sliderChanged") }
    @objc private func switchChanged() { increment("switchChanged") }
    @objc private func textChanged() { increment("textChanged") }
    @objc private func dismissKeyboard() { view.endEditing(true); publish("keyboardDismissed") }
    @objc private func showList() { mainScroll.scrollRectToVisible(listScroll.convert(listScroll.bounds, to: mainScroll), animated: false); publish("showList") }
    @objc private func showPad() {
        let controls = CGRect(x: 0, y: -46, width: pad.bounds.width, height: pad.bounds.height + 46)
        mainScroll.scrollRectToVisible(pad.convert(controls, to: mainScroll), animated: false)
        publish("showPad")
    }
    @objc private func showText() {
        let top = toggle.convert(toggle.bounds, to: mainScroll)
        let bottom = field.convert(field.bounds, to: mainScroll)
        mainScroll.scrollRectToVisible(top.union(bottom), animated: false)
        publish("showText")
    }
    @objc private func showWaits() {
        view.layoutIfNeeded()
        let heading = targets.waitHeading.convert(targets.waitHeading.bounds, to: mainScroll)
        let lastTarget = targets.duplicate.convert(targets.duplicate.bounds, to: mainScroll)
        mainScroll.scrollRectToVisible(heading.union(lastTarget), animated: false)
        publish("showWaits")
    }
    @objc private func showTargets() { mainScroll.scrollRectToVisible(targets.convert(CGRect(x: 0, y: 0, width: targets.bounds.width, height: 180), to: mainScroll), animated: false); publish("showTargets") }
    @objc private func showCanvas() { mainScroll.scrollRectToVisible(canvas.convert(canvas.bounds, to: mainScroll), animated: false); publish("showCanvas") }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool { increment("returnKey"); textField.resignFirstResponder(); return true }
    func textFieldDidBeginEditing(_ textField: UITextField) { increment("textFocused") }
    func textFieldDidEndEditing(_ textField: UITextField) { publish("textBlurred") }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if !resetting { publish(scrollView === listScroll ? "listScrolled" : scrollView === canvas ? "canvasScrolled" : "pageScrolled") }
    }

    @objc private func resetControls() {
        resetting = true
        view.endEditing(true)
        counts = counts.filter { $0.key.hasPrefix("windowTouch") }
        slider.value = 50
        toggle.isOn = false
        field.text = ""
        pinchScale = 1
        rotation = 0
        panDelta = .zero
        touchPoint = .zero
        mainScroll.contentOffset = .zero
        listScroll.contentOffset = .zero
        canvas.contentOffset = .zero
        targets.reset()
        resetting = false
        // Keep real contact identities/history; a Reset tap must not manufacture a released touch.
        publish("reset")
    }

    @objc private func keyboardDidShow() { keyboardVisible = true; publish("keyboardDidShow") }
    @objc private func keyboardDidHide() { keyboardVisible = false; publish("keyboardDidHide") }

    private func increment(_ name: String) { counts[name, default: 0] += 1; publish(name) }

    private func publish(_ event: String) {
        sequence += 1
        summary.text = "Duo controls: tap \(counts["tap", default: 0]), pad \(counts["padTap", default: 0]), pan \(counts["pan", default: 0])\n"
            + "Held contacts \(observer.activeCount), slider \(Int(slider.value)), switch \(toggle.isOn)\n"
            + "List \(Int(listScroll.contentOffset.y)), page \(Int(mainScroll.contentOffset.y)), canvas \(Int(canvas.contentOffset.x)),\(Int(canvas.contentOffset.y))\n"
            + "Text: \(field.text ?? "")\n\(event); log Documents/state.json"
        var geometry: [String: DuoControlsRect] = [:]
        let frames = frameViews.map { item in
            if let identifier = item.accessibilityIdentifier { geometry[identifier] = DuoControlsRect(item.convert(item.bounds, to: view.window)) }
            return DuoControlsFrame(className: String(describing: type(of: item)), id: item.accessibilityIdentifier ?? "",
                frame: NSCoder.string(for: item.frame), bounds: NSCoder.string(for: item.bounds), hidden: item.isHidden,
                alpha: Double(item.alpha), inWindow: item.window != nil, subviewCount: item.subviews.count, ambiguous: item.hasAmbiguousLayout)
        }
        let state = DuoControlsState(generation: generation, pid: ProcessInfo.processInfo.processIdentifier,
            sequence: sequence, event: event, counts: counts, advancedSliders: targets.sliderValues,
            waitTargetVisible: !targets.target.isHidden, waitDuplicateVisible: !targets.duplicate.isHidden,
            targetAppearedUptime: targets.appearedUptime, scheduleGeneration: targets.scheduleGeneration, slider: slider.value, switchOn: toggle.isOn,
            text: field.text ?? "", textFocused: field.isFirstResponder, keyboardVisible: keyboardVisible, listOffsetY: Double(listScroll.contentOffset.y),
            pageOffsetY: Double(mainScroll.contentOffset.y), canvasOffsetX: Double(canvas.contentOffset.x), canvasOffsetY: Double(canvas.contentOffset.y),
            pinchScale: Double(pinchScale), rotationRadians: Double(rotation), panX: Double(panDelta.x), panY: Double(panDelta.y),
            touchX: Double(touchPoint.x), touchY: Double(touchPoint.y), width: Double(lastSize.width), height: Double(lastSize.height),
            interfaceOrientation: view.window?.windowScene?.interfaceOrientation.rawValue ?? 0,
            windowTraceDropped: droppedContacts, activeWindowTouches: observer.activeCount,
            windowFirstX: Double(firstPoint.x), windowFirstY: Double(firstPoint.y), windowLastX: Double(lastPoint.x), windowLastY: Double(lastPoint.y),
            windowTouchTrace: contacts, recognizerTraceDropped: droppedRecognizers, recognizerTrace: recognizers, frames: frames, geometry: geometry)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: URL.documentsDirectory.appending(path: "state.json"), options: .atomic)
        } catch {
            summary.text = (summary.text ?? "") + "\nLog write failed: \(error.localizedDescription)"
        }
    }
}
