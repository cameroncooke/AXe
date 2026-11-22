import AVFoundation
import SwiftUI
import UIKit

/// Pairs this device with a Mac: scan the QR code that `axe mirror pair` shows, or type its code.
struct PairView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    private enum Way: String, CaseIterable { case scan = "Scan", type = "Type the code" }
    private enum Stage: Equatable { case entering, working, failed(String), paired(PairedHost) }

    @State private var way: Way = AVCaptureDevice.default(for: .video) == nil ? .type : .scan
    @State private var typed = ""
    @State private var stage: Stage = .entering
    /// The pairing under way, so that Cancel can stop it.
    @State private var pairing: Task<Void, Never>?
    @FocusState private var typing: Bool

    var body: some View {
        NavigationStack {
            Group {
                if case .paired(let host) = stage {
                    paired(host)
                } else {
                    entry
                }
            }
            .navigationTitle("Pair with your Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if case .paired = stage {
                        EmptyView()
                    } else {
                        Button("Cancel") {
                            pairing?.cancel()
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    private var entry: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 6) {
                    Text("On your Mac, run")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("axe mirror pair")
                        .font(.title3.monospaced().weight(.semibold))
                        .textSelection(.enabled)
                    Text("It shows a QR code and a ten-character code. Either works once, for ten minutes.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Picker("How to enter the code", selection: $way) {
                    ForEach(Way.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(stage == .working)

                switch way {
                case .scan: scanner
                case .type: typedEntry
                }

                if stage == .working {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Looking for your Mac. This can take a few seconds.")
                            .font(.subheadline)
                    }
                    .accessibilityElement(children: .combine)
                }
                if case .failed(let message) = stage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
    }

    private var scanner: some View {
        QRScanner(isActive: stage != .working) { text in
            guard stage == .entering || isFailed else { return }
            submit(text)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.quaternary))
        .accessibilityLabel("Camera, looking for the pairing QR code")
    }

    private var isFailed: Bool { if case .failed = stage { return true } else { return false } }

    private var typedEntry: some View {
        VStack(spacing: 14) {
            TextField("XXXXX-XXXXX", text: $typed)
                .font(.title2.monospaced())
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .submitLabel(.go)
                .focused($typing)
                .padding(.vertical, 12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onSubmit { if MirrorPairingCode.normalise(typed) != nil { submit(typed) } }
                .accessibilityIdentifier("pair.code")
            Button {
                submit(typed)
            } label: {
                Text("Pair").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(MirrorPairingCode.normalise(typed) == nil || stage == .working)
            .accessibilityIdentifier("pair.submit")
        }
        .onAppear { typing = true }
    }

    private func paired(_ host: PairedHost) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text("Paired with \(host.name)")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            VStack(spacing: 6) {
                Text("To use its simulators from here, run this on your Mac:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("axe mirror")
                    .font(.body.monospaced().weight(.semibold))
                    .textSelection(.enabled)
                Text("Then tap the Mac in the list.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Button {
                dismiss()
            } label: {
                Text("Done").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
        .padding(24)
        .frame(maxWidth: 520)
    }

    private func submit(_ text: String) {
        guard stage != .working else { return }
        typing = false
        stage = .working
        pairing = Task {
            switch await model.pair(code: text) {
            case .failure(.cancelled):
                break
            case .success(let host):
                stage = .paired(host)
            case .failure(.badCode):
                stage = .failed("That is not a pairing code. Scan the QR code from axe mirror pair, or type its ten characters.")
            case .failure(.notFound):
                stage = .failed("No Mac is showing that code, or it could not be reached. Codes last ten minutes; run axe mirror pair again and check both devices are online.")
            case .failure(.refused), .failure(.badReply):
                stage = .failed("Your Mac did not accept the code. It may have been used already; run axe mirror pair again.")
            }
        }
    }
}

/// A live camera view that reports the text of the first QR code it sees, at most once a second.
struct QRScanner: UIViewRepresentable {
    var isActive: Bool
    var onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIView(context: Context) -> ScannerView {
        let view = ScannerView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: ScannerView, context: Context) {
        context.coordinator.onCode = onCode
        context.coordinator.setRunning(isActive)
    }

    static func dismantleUIView(_ view: ScannerView, coordinator: Coordinator) {
        coordinator.setRunning(false)
    }

    final class ScannerView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        let message = UILabel()

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
            previewLayer.videoGravity = .resizeAspectFill
            message.textColor = .white
            message.font = .preferredFont(forTextStyle: .subheadline)
            message.adjustsFontForContentSizeCategory = true
            message.numberOfLines = 0
            message.textAlignment = .center
            addSubview(message)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func layoutSubviews() {
            super.layoutSubviews()
            message.frame = bounds.insetBy(dx: 24, dy: 24)
        }
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: (String) -> Void
        private let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "axemirror.scanner")
        private var configured = false
        private var wanted = false
        private var lastReport = Date.distantPast
        private weak var view: ScannerView?

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func attach(to view: ScannerView) {
            self.view = view
            view.previewLayer.session = session
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                configure()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    DispatchQueue.main.async { granted ? self?.configure() : self?.show("Camera access is off. Allow it in Settings, or type the code instead.") }
                }
            default:
                show("Camera access is off. Allow it in Settings, or type the code instead.")
            }
        }

        private func show(_ text: String) { view?.message.text = text }

        private func configure() {
            guard !configured else { return }
            guard let camera = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: camera),
                  session.canAddInput(input) else {
                show("This device has no camera to scan with. Type the code instead.")
                return
            }
            let output = AVCaptureMetadataOutput()
            session.beginConfiguration()
            session.addInput(input)
            guard session.canAddOutput(output) else { session.commitConfiguration(); return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = output.availableMetadataObjectTypes.contains(.qr) ? [.qr] : []
            session.commitConfiguration()
            configured = true
            setRunning(wanted)
        }

        func setRunning(_ running: Bool) {
            wanted = running
            guard configured else { return }
            let session = session
            queue.async {
                if running, !session.isRunning { session.startRunning() }
                if !running, session.isRunning { session.stopRunning() }
            }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard let text = objects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first,
                  MirrorPairingCode.fromScan(text) != nil, Date().timeIntervalSince(lastReport) > 1 else { return }
            lastReport = Date()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onCode(text)
        }
    }
}
