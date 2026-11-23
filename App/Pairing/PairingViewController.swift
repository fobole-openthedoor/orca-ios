import AVFoundation
import OrcaCore
import UIKit

/// Pair with desktop (app/pair-scan.tsx): the three steps, a live QR scanner, and Paste code instead.
/// Presented in its own navigation controller; closes itself once the desktop is saved.
final class PairingViewController: UIViewController {
  private enum Phase: Equatable {
    case scanning
    case cameraUnavailable
    case connecting
    case failed(String)
  }

  private let preview = UIView()
  private let capture = AVCaptureSession()
  private var previewLayer: AVCaptureVideoPreviewLayer?
  private let titleLabel = TextLabel(
    String(localized: "app.pairScan.title", defaultValue: "Pair with desktop"), size: 20, weight: .bold,
    alignment: .center, lines: 0)
  private let messageLabel = TextLabel(
    String(
      localized: "app.pairScan.cameraPermissionDescription",
      defaultValue: "Scan the QR code shown by Orca on your desktop, or paste the pairing code"),
    size: 15, color: Palette.textSecondary, lineHeight: 20, alignment: .center, lines: 0)
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let primary = UIButton(configuration: .prominentGlass())
  private let paste = UIButton(configuration: .glass())
  private var phase: Phase = .scanning { didSet { render() } }
  private var handledCode = false
  /// A code from a deep link pairs on appear instead of scanning.
  private let initialOffer: PairingOffer?

  init(offer: PairingOffer? = nil) {
    initialOffer = offer
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = Palette.bgBase
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })

    let steps = UIStackView(arrangedSubviews: [
      step(1, String(localized: "app.pairScan.openDesktopStep", defaultValue: "Open Orca on your computer")),
      step(2, String(localized: "app.pairScan.openMobileSettingsStep", defaultValue: "Go to Settings → Mobile")),
      step(3, String(localized: "app.pairScan.scanCodeStep", defaultValue: "Scan the QR code")),
    ])
    steps.axis = .vertical
    steps.spacing = Spacing.sm
    steps.translatesAutoresizingMaskIntoConstraints = false

    preview.translatesAutoresizingMaskIntoConstraints = false
    preview.backgroundColor = Palette.bgRaised
    preview.layer.cornerRadius = Radius.surface
    preview.clipsToBounds = true
    let reticle = LucideView(.qrCode, size: 48, strokeWidth: 1.5, color: UIColor.white.withAlphaComponent(0.85))
    preview.addSubview(reticle)

    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.hidesWhenStopped = true

    primary.configuration?.baseBackgroundColor = Palette.accentBlue
    primary.configuration?.image = Lucide.qrCode.image(size: 18, strokeWidth: 2.2)
    primary.configuration?.imagePadding = Spacing.sm
    primary.translatesAutoresizingMaskIntoConstraints = false
    paste.configuration?.title = String(localized: "app.pairScan.pasteInstead", defaultValue: "Paste code instead")
    paste.configuration?.image = Lucide.clipboard.image(size: 17, strokeWidth: 2)
    paste.configuration?.imagePadding = Spacing.sm
    paste.configuration?.baseForegroundColor = Palette.textPrimary
    paste.translatesAutoresizingMaskIntoConstraints = false
    paste.addAction(UIAction { [weak self] _ in self?.askForCode() }, for: .primaryActionTriggered)

    for view in [steps, preview, titleLabel, messageLabel, spinner, primary, paste] as [UIView] {
      self.view.addSubview(view)
    }
    let guide = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      steps.topAnchor.constraint(equalTo: guide.topAnchor, constant: Spacing.md),
      steps.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: Spacing.xl),
      steps.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -Spacing.xl),
      preview.topAnchor.constraint(equalTo: steps.bottomAnchor, constant: Spacing.xl),
      preview.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
      preview.widthAnchor.constraint(equalTo: guide.widthAnchor, multiplier: 0.72),
      preview.heightAnchor.constraint(equalTo: preview.widthAnchor),
      reticle.centerXAnchor.constraint(equalTo: preview.centerXAnchor),
      reticle.centerYAnchor.constraint(equalTo: preview.centerYAnchor),
      titleLabel.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: Spacing.xl),
      titleLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: Spacing.xl),
      titleLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -Spacing.xl),
      messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: Spacing.sm),
      messageLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      messageLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
      spinner.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: Spacing.lg),
      spinner.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
      paste.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -Spacing.lg),
      paste.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
      primary.bottomAnchor.constraint(equalTo: paste.topAnchor, constant: -Spacing.md),
      primary.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
    ])
    render()
    if let initialOffer {
      handledCode = true
      pair(initialOffer)
    } else {
      startCamera()
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    previewLayer?.frame = preview.bounds
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    let capture = capture
    DispatchQueue.global(qos: .userInitiated).async { capture.stopRunning() }
  }

  private func step(_ number: Int, _ text: String) -> UIView {
    let row = UIView()
    let disc = UIView()
    disc.translatesAutoresizingMaskIntoConstraints = false
    disc.backgroundColor = Palette.bgRaised
    disc.layer.cornerRadius = 11
    let digit = TextLabel("\(number)", size: 12, weight: .semibold, color: Palette.textSecondary, tabular: true)
    disc.addSubview(digit)
    let label = TextLabel(text, size: 15, color: Palette.textSecondary, lines: 0)
    row.addSubview(disc)
    row.addSubview(label)
    NSLayoutConstraint.activate([
      disc.leadingAnchor.constraint(equalTo: row.leadingAnchor),
      disc.centerYAnchor.constraint(equalTo: label.centerYAnchor),
      disc.widthAnchor.constraint(equalToConstant: 22),
      disc.heightAnchor.constraint(equalToConstant: 22),
      digit.centerXAnchor.constraint(equalTo: disc.centerXAnchor),
      digit.centerYAnchor.constraint(equalTo: disc.centerYAnchor),
      label.leadingAnchor.constraint(equalTo: disc.trailingAnchor, constant: Spacing.md),
      label.trailingAnchor.constraint(equalTo: row.trailingAnchor),
      label.topAnchor.constraint(equalTo: row.topAnchor),
      label.bottomAnchor.constraint(equalTo: row.bottomAnchor),
    ])
    return row
  }

  private func render() {
    switch phase {
    case .scanning:
      messageLabel.text = String(
        localized: "app.pairScan.cameraPermissionDescription",
        defaultValue: "Scan the QR code shown by Orca on your desktop, or paste the pairing code")
      messageLabel.textColor = Palette.textSecondary
      spinner.stopAnimating()
      primary.isHidden = true
      paste.isHidden = false
    case .cameraUnavailable:
      titleLabel.text = String(localized: "app.pairScan.cameraDisabledTitle", defaultValue: "Camera Access Disabled")
      messageLabel.text = String(
        localized: "app.pairScan.cameraDisabledDescription",
        defaultValue: "Enable camera access in Settings, or paste the pairing code")
      messageLabel.textColor = Palette.textSecondary
      spinner.stopAnimating()
      primary.isHidden = false
      primary.configuration?.title = String(localized: "app.pairScan.openSettings", defaultValue: "Open Settings")
      primary.configuration?.image = nil
      primary.removeTarget(nil, action: nil, for: .allEvents)
      primary.addAction(
        UIAction { _ in
          if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        }, for: .primaryActionTriggered)
    case .connecting:
      messageLabel.text = String(localized: "app.pairScan.connecting", defaultValue: "Connecting…")
      messageLabel.textColor = Palette.textSecondary
      spinner.startAnimating()
      primary.isHidden = true
      paste.isHidden = true
    case .failed(let message):
      messageLabel.text = message
      messageLabel.textColor = Palette.statusRed
      spinner.stopAnimating()
      primary.isHidden = false
      paste.isHidden = false
      primary.configuration?.title = String(localized: "app.pairScan.tryAgain", defaultValue: "Try Again")
      primary.configuration?.image = nil
      primary.removeTarget(nil, action: nil, for: .allEvents)
      primary.addAction(
        UIAction { [weak self] _ in
          self?.handledCode = false
          self?.phase = .scanning
        }, for: .primaryActionTriggered)
    }
  }

  private func startCamera() {
    AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
      DispatchQueue.main.async {
        guard let self else { return }
        guard granted, let device = AVCaptureDevice.default(for: .video),
          let input = try? AVCaptureDeviceInput(device: device), self.capture.canAddInput(input)
        else {
          self.phase = .cameraUnavailable
          return
        }
        self.capture.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard self.capture.canAddOutput(output) else {
          self.phase = .cameraUnavailable
          return
        }
        self.capture.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: self.capture)
        layer.videoGravity = .resizeAspectFill
        layer.frame = self.preview.bounds
        self.preview.layer.insertSublayer(layer, at: 0)
        self.previewLayer = layer
        let capture = self.capture
        DispatchQueue.global(qos: .userInitiated).async { capture.startRunning() }
      }
    }
  }

  private func askForCode() {
    let alert = UIAlertController(
      title: String(localized: "app.pairScan.pasteCodeTitle", defaultValue: "Paste pairing code"),
      message: String(
        localized: "app.pairScan.pasteCodeMessage", defaultValue: "Copy the code shown under the QR code on your computer"),
      preferredStyle: .alert)
    alert.addTextField { field in
      field.placeholder = String(
        localized: "app.pairScan.pasteCodePlaceholder", defaultValue: "orca://pair?code=... or paste code")
      field.autocapitalizationType = .none
      field.autocorrectionType = .no
      field.clearButtonMode = .whileEditing
      if let clip = UIPasteboard.general.string, PairingCode.parse(clip) != nil { field.text = clip }
    }
    alert.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "Cancel"), style: .cancel))
    alert.addAction(
      UIAlertAction(title: String(localized: "common.save", defaultValue: "Save"), style: .default) { [weak self, weak alert] _ in
        let text = alert?.textFields?.first?.text ?? ""
        guard let offer = PairingCode.parse(text) else {
          self?.phase = .failed(
            String(
              localized: "app.pairScan.invalidPairingCode",
              defaultValue: "Invalid pairing code. Copy it from your computer and paste again"))
          return
        }
        self?.pair(offer)
      })
    present(alert, animated: true)
  }

  private func pair(_ offer: PairingOffer) {
    phase = .connecting
    Task {
      do {
        _ = try await AppModel.shared.pair(offer)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss(animated: true)
      } catch PairingError.rejected {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        phase = .failed(
          String(
            localized: "app.pairScan.codeNoLongerValid",
            defaultValue:
              "This pairing code expired, was used, or was replaced. Show a new code on your computer and scan again."))
      } catch {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        phase = .failed(
          String(
            format: String(localized: "app.pairScan.pairingFailed", defaultValue: "Pairing failed: %1$@"),
            error.localizedDescription))
      }
    }
  }
}

extension PairingViewController: AVCaptureMetadataOutputObjectsDelegate {
  func metadataOutput(
    _ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection
  ) {
    guard !handledCode, phase == .scanning,
      let value = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue
    else { return }
    guard let offer = PairingCode.parse(value) else {
      handledCode = true
      phase = .failed(String(localized: "app.pairScan.invalidQrCode", defaultValue: "Invalid Orca QR code"))
      return
    }
    handledCode = true
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    pair(offer)
  }
}
