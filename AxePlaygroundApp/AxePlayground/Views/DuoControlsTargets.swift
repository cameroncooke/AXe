import UIKit

/// Visible examples for exact slider identity and delayed-target selection.
final class DuoControlsTargets: UIStackView {
    var onChange: ((String) -> Void)?
    private var sliders: [String: UISlider] = [:]
    private var timer: Timer?
    private let doubleTapCounter = UIButton(type: .system)
    private var doubleTapCount = 0
    private(set) var scheduleGeneration = 0
    private(set) var appearedUptime: TimeInterval = 0
    let target = UIButton(type: .system)
    let duplicate = UIButton(type: .system)
    let waitHeading = UILabel()
    var sliderValues: [String: Float] { sliders.mapValues(\.value) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        axis = .vertical
        spacing = 8
        accessibilityIdentifier = "feature.targets"
        doubleTapCounter.setTitle("Double-tap counter: 0", for: .normal)
        doubleTapCounter.accessibilityIdentifier = "feature.doubleTapCounter"
        doubleTapCounter.accessibilityLabel = "Double-tap counter"
        doubleTapCounter.accessibilityValue = "0"
        doubleTapCounter.accessibilityHint = "Tap twice to increase the counter."
        doubleTapCounter.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapActivated(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        doubleTapCounter.addGestureRecognizer(doubleTap)
        addArrangedSubview(doubleTapCounter)
        addArrangedSubview(text("Slider identity examples"))
        addSlider("longer", id: "feature.nativeSlider.extra", label: "Longer identifier slider")
        addSlider("exact", id: "feature.nativeSlider", label: "Exact native slider")
        addSlider("duplicateID1", id: "feature.duplicateSlider", label: "Duplicate identifier first")
        addSlider("duplicateID2", id: "feature.duplicateSlider", label: "Duplicate identifier second")
        addSlider("duplicateLabel1", id: "feature.labelSlider1", label: "Duplicate slider label")
        addSlider("duplicateLabel2", id: "feature.labelSlider2", label: "Duplicate slider label")
        waitHeading.text = "Delayed controls"
        waitHeading.font = .preferredFont(forTextStyle: .headline)
        addArrangedSubview(waitHeading)
        addRow([makeButton("Start 3 seconds", id: "wait.start3", action: #selector(startThree)),
                makeButton("Start 8 seconds", id: "wait.start8", action: #selector(startEight))])
        addRow([makeButton("Hide target", id: "wait.hide", action: #selector(hide)),
                makeButton("Show target", id: "wait.show", action: #selector(show))])
        addRow([makeButton("Toggle duplicate", id: "wait.duplicateControl", action: #selector(toggleDuplicate)),
                makeButton("Sentinel", id: "wait.sentinel", action: #selector(sentinel))])
        configureTarget(target, action: #selector(targetTapped))
        configureTarget(duplicate, action: #selector(duplicateTapped))
        addTargetSlot(target)
        addTargetSlot(duplicate)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { timer?.invalidate() }

    func reset() {
        cancelSchedule()
        for slider in sliders.values { slider.value = 50 }
        doubleTapCount = 0
        doubleTapCounter.setTitle("Double-tap counter: 0", for: .normal)
        doubleTapCounter.accessibilityValue = "0"
        target.isHidden = true
        duplicate.isHidden = true
        appearedUptime = 0
    }

    private func text(_ title: String) -> UILabel {
        let label = UILabel()
        label.text = title
        label.font = .preferredFont(forTextStyle: .headline)
        return label
    }

    private func addSlider(_ name: String, id: String, label: String) {
        let slider = UISlider()
        slider.minimumValue = 0
        slider.maximumValue = 100
        slider.value = 50
        slider.accessibilityIdentifier = id
        slider.accessibilityLabel = label
        slider.heightAnchor.constraint(equalToConstant: 34).isActive = true
        slider.addTarget(self, action: #selector(sliderChanged(_:)), for: .valueChanged)
        sliders[name] = slider
        addArrangedSubview(text("Example: " + label))
        addArrangedSubview(slider)
    }

    private func makeButton(_ title: String, id: String, action: Selector) -> UIButton {
        let value = UIButton(type: .system)
        value.setTitle(title, for: .normal)
        value.accessibilityIdentifier = id
        value.heightAnchor.constraint(equalToConstant: 38).isActive = true
        value.addTarget(self, action: action, for: .touchUpInside)
        return value
    }

    private func addRow(_ controls: [UIView]) {
        let row = UIStackView(arrangedSubviews: controls)
        row.distribution = .fillEqually
        row.spacing = 8
        addArrangedSubview(row)
    }

    // Keep the normal delayed-button rows in layout while each button is hidden.
    private func addTargetSlot(_ button: UIButton) {
        let slot = UIView()
        button.translatesAutoresizingMaskIntoConstraints = false
        slot.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: slot.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: slot.trailingAnchor),
            button.topAnchor.constraint(equalTo: slot.topAnchor),
            button.bottomAnchor.constraint(equalTo: slot.bottomAnchor),
        ])
        addArrangedSubview(slot)
    }

    private func configureTarget(_ button: UIButton, action: Selector) {
        button.setTitle("Delayed target", for: .normal)
        button.accessibilityIdentifier = "wait.target"
        button.accessibilityLabel = "Delayed target"
        button.accessibilityValue = "ready"
        button.isHidden = true
        button.heightAnchor.constraint(equalToConstant: 38).isActive = true
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func cancelSchedule() { timer?.invalidate(); timer = nil; scheduleGeneration += 1 }
    private func start(_ seconds: TimeInterval) {
        cancelSchedule()
        target.isHidden = true
        duplicate.isHidden = true
        appearedUptime = 0
        let expected = scheduleGeneration
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self, self.scheduleGeneration == expected else { return }
            self.timer = nil
            self.target.isHidden = false
            self.appearedUptime = ProcessInfo.processInfo.systemUptime
            self.onChange?("appeared")
        }
        onChange?(seconds == 3 ? "start3" : "start8")
    }
    @objc private func doubleTapActivated(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        doubleTapCount += 1
        doubleTapCounter.setTitle("Double-tap counter: \(doubleTapCount)", for: .normal)
        doubleTapCounter.accessibilityValue = String(doubleTapCount)
        onChange?("buttonDoubleTap")
    }
    @objc private func startThree() { start(3) }
    @objc private func startEight() { start(8) }
    @objc private func hide() { cancelSchedule(); target.isHidden = true; duplicate.isHidden = true; onChange?("hide") }
    @objc private func show() { cancelSchedule(); target.isHidden = false; appearedUptime = ProcessInfo.processInfo.systemUptime; onChange?("show") }
    @objc private func toggleDuplicate() { duplicate.isHidden.toggle(); onChange?("duplicateControl") }
    @objc private func sentinel() { onChange?("sentinel") }
    @objc private func targetTapped() { onChange?("target") }
    @objc private func duplicateTapped() { onChange?("duplicateTarget") }
    @objc private func sliderChanged(_ sender: UISlider) {
        guard let name = sliders.first(where: { $0.value === sender })?.key else { return }
        onChange?("slider." + name)
    }
}
