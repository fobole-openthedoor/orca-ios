import OrcaCore
import UIKit

/// Settings › Terminal (app/terminal-settings.tsx): the phone's terminal font, and per desktop whether a
/// terminal goes back to desktop size when the phone leaves it.
final class TerminalSettingsViewController: SettingsPageViewController {
  /// The official choices for "when you leave the app": nil keeps the phone's size.
  private static let restoreChoices: [Double?] = [nil, 60_000, 5 * 60_000, 30 * 60_000]

  private let model = AppModel.shared
  /// Each desktop's saved delay: missing while loading, `.some(nil)` for "keep phone size".
  private var restoreMs: [PairedHost.ID: Double?] = [:]
  private var loading: Set<PairedHost.ID> = []
  private let preview = TerminalPreviewView()

  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(localized: "app.terminalSettings.title", defaultValue: "Terminal")
    preview.frame.size.height = 132
    tableView.tableHeaderView = preview
    rebuild()
    loadRestoreDelays()
  }

  private func rebuild() {
    preview.apply(size: PhoneSettings.terminalFontSize)
    let font = PhoneSettings.terminalFont
    let lineHeights = PhoneSettings.terminalLineHeights
    let weights = PhoneSettings.terminalWeights
    let size = PhoneSettings.terminalFontSize
    sections = [
      Section(
        header: String(localized: "app.terminalSettings.fontHeading", defaultValue: "FONT"),
        footer: String(
          localized: "app.terminalSettings.fontDescription",
          defaultValue:
            "Pinch in a terminal to change the size; it saves here. Only changes this device, not the desktop terminal."),
        rows: [
          .menu(
            title: String(localized: "app.terminalSettings.font", defaultValue: "Font"), value: font.title,
            options: PhoneSettings.TerminalFont.allCases.map { choice in
              Option(
                title: choice.title,
                subtitle: choice == .system ? String(localized: "app.terminalSettings.defaultFont", defaultValue: "Default") : nil,
                selected: choice == font
              ) { [weak self] in
                PhoneSettings.terminalFont = choice
                self?.rebuild()
              }
            }),
          .slider(
            title: String(localized: "app.terminalSettings.size", defaultValue: "Size"), value: Self.points(size),
            range: PhoneSettings.terminalFontSizeRange, current: size, stepper: true,
            onPreview: { [weak self] next in
              self?.preview.apply(size: next)
              return Self.points(next)
            },
            onCommit: { [weak self] next in
              PhoneSettings.terminalFontSize = next
              self?.rebuild()
            }),
          .segmented(
            title: String(localized: "app.terminalSettings.lineSpacing", defaultValue: "Line spacing"),
            items: [
              String(localized: "app.terminalSettings.lineSpacingTight", defaultValue: "Tight"),
              String(localized: "app.terminalSettings.lineSpacingNormal", defaultValue: "Normal"),
              String(localized: "app.terminalSettings.lineSpacingRoomy", defaultValue: "Roomy"),
            ],
            selected: lineHeights.firstIndex(of: PhoneSettings.terminalLineHeight) ?? 0,
            onChange: { [weak self] index in
              PhoneSettings.terminalLineHeight = lineHeights[index]
              self?.rebuild()
            }),
          .segmented(
            title: String(localized: "app.terminalSettings.weight", defaultValue: "Weight"),
            items: [
              String(localized: "app.terminalSettings.weightLight", defaultValue: "Light"),
              String(localized: "app.terminalSettings.weightRegular", defaultValue: "Regular"),
              String(localized: "app.terminalSettings.weightMedium", defaultValue: "Medium"),
            ],
            selected: weights.firstIndex(of: PhoneSettings.terminalFontWeight) ?? 0,
            onChange: { [weak self] index in
              PhoneSettings.terminalFontWeight = weights[index]
              self?.rebuild()
            }),
        ]),
      Section(
        header: String(localized: "app.terminalSettings.leaveAppHeading", defaultValue: "WHEN YOU LEAVE THE APP"),
        footer: String(
          localized: "app.terminalSettings.leaveAppDescription",
          defaultValue:
            "While you're using a terminal on your phone, Orca shrinks it to fit your screen. When you close the app or switch away, this controls whether it stays at phone size (so interactive CLI tools don't reflow) or resizes back to your desktop. You can always use Restore on the desktop banner to resize manually."
        ),
        rows: hostRows()),
      Section(rows: [
        .button(title: String(localized: "app.terminalSettings.resetFont", defaultValue: "Reset font settings")) {
          [weak self] in
          PhoneSettings.resetTerminalFont()
          self?.rebuild()
        }
      ]),
    ]
  }

  private func hostRows() -> [Row] {
    let hosts = model.orderedHosts
    guard !hosts.isEmpty else {
      return [
        .value(
          title: String(
            localized: "app.terminalSettings.noPairedDesktops",
            defaultValue: "No paired desktops yet. Pair one to control terminal behavior."))
      ]
    }
    return hosts.map { host in
      let session = model.session(for: host.id)
      let name = session?.name ?? host.name
      let connected = session?.connectionState == .connected
      guard let saved = restoreMs[host.id] else {
        return .value(icon: .smartphone, title: name, value: "…", enabled: false)
      }
      let current = Self.nearestChoice(saved)
      return .menu(
        icon: .smartphone, title: name, value: Self.summary(saved),
        options: Self.restoreChoices.map { choice in
          Option(title: Self.label(choice), selected: choice == current) { [weak self] in
            self?.saveRestoreDelay(choice, for: host.id)
          }
        },
        enabled: connected)
    }
  }

  private func loadRestoreDelays() {
    for host in model.orderedHosts {
      guard let session = model.session(for: host.id), session.connectionState == .connected,
        !loading.contains(host.id)
      else { continue }
      loading.insert(host.id)
      Task {
        let ms = try? await session.api.terminalAutoRestoreFit()
        loading.remove(host.id)
        restoreMs[host.id] = .some(ms)
        rebuild()
      }
    }
  }

  private func saveRestoreDelay(_ ms: Double?, for hostId: PairedHost.ID) {
    guard let session = model.session(for: hostId) else { return }
    restoreMs[hostId] = .some(ms)
    rebuild()
    Task {
      do {
        restoreMs[hostId] = .some(try await session.api.setTerminalAutoRestoreFit(ms: ms))
      } catch {
        // Show what the desktop kept; a failed read leaves the choice as tapped until the next visit.
        if let current = try? await session.api.terminalAutoRestoreFit() { restoreMs[hostId] = .some(current) }
      }
      rebuild()
    }
  }

  private static func points(_ size: Double) -> String {
    String(format: String(localized: "app.terminalSettings.sizePoints", defaultValue: "%1$@ pt"), "\(Int(size))")
  }

  private static func label(_ ms: Double?) -> String {
    guard let ms else {
      return String(localized: "app.terminalSettings.keepPhoneSize", defaultValue: "Keep at phone size (default)")
    }
    let minutes = Int(ms / 60_000)
    return String(localized: "app.terminalSettings.restoreAfterMinutes", defaultValue: "After \(minutes) minutes")
  }

  /// A preset's label, or the seconds of a delay the desktop holds that no preset matches.
  private static func summary(_ ms: Double?) -> String {
    guard let ms, !restoreChoices.contains(ms) else { return label(ms) }
    let seconds = Int((ms / 1000).rounded())
    return String(localized: "app.terminalSettings.restoreAfterSeconds", defaultValue: "After \(seconds)s")
  }

  /// A custom delay checks the nearest preset, as the official picker snaps it.
  private static func nearestChoice(_ ms: Double?) -> Double? {
    guard let ms else { return nil }
    return restoreChoices.compactMap { $0 }.min { abs($0 - ms) < abs($1 - ms) }
  }
}

/// A few lines of terminal output in the chosen font, on the terminal's background.
private final class TerminalPreviewView: UIView {
  private let label = UILabel()
  private let box = UIView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    box.backgroundColor = Palette.terminalBg
    box.layer.cornerRadius = Radius.surface
    box.layer.cornerCurve = .continuous
    box.clipsToBounds = true
    box.isAccessibilityElement = true
    box.accessibilityLabel = String(localized: "app.terminalSettings.previewLabel", defaultValue: "Terminal preview")
    label.numberOfLines = 0
    box.translatesAutoresizingMaskIntoConstraints = false
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(box)
    box.addSubview(label)
    NSLayoutConstraint.activate([
      box.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
      box.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
      box.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.sm),
      box.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.xs),
      label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: Spacing.md),
      label.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -Spacing.md),
      label.topAnchor.constraint(equalTo: box.topAnchor, constant: Spacing.md),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func apply(size: Double) {
    let font = PhoneSettings.terminalFont.font(size: size, weight: PhoneSettings.terminalFontWeight)
    let bold = PhoneSettings.terminalFont.font(size: size, weight: PhoneSettings.terminalFontWeight + 200)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineHeightMultiple = PhoneSettings.terminalLineHeight
    let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor(hex: 0xc0caf5), .paragraphStyle: paragraph]
    let text = NSMutableAttributedString()
    text.append(NSAttributedString(string: "~/orca ", attributes: plain.merging([.foregroundColor: UIColor(hex: 0x7aa2f7), .font: bold]) { $1 }))
    text.append(NSAttributedString(string: "main ", attributes: plain.merging([.foregroundColor: UIColor(hex: 0x9ece6a)]) { $1 }))
    text.append(NSAttributedString(string: "$ pnpm test\n", attributes: plain))
    text.append(NSAttributedString(string: " ✓ ", attributes: plain.merging([.foregroundColor: UIColor(hex: 0x9ece6a)]) { $1 }))
    text.append(NSAttributedString(string: "src/resume.test.ts (12)\n", attributes: plain))
    text.append(NSAttributedString(string: " Tests  ", attributes: plain.merging([.font: bold]) { $1 }))
    text.append(NSAttributedString(string: "12 passed", attributes: plain.merging([.foregroundColor: UIColor(hex: 0x9ece6a)]) { $1 }))
    label.attributedText = text
  }
}
