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
    preview.frame.size.height = TerminalPreviewView.height + Spacing.sm + Spacing.xs
    tableView.tableHeaderView = preview
    rebuild()
    loadRestoreDelays()
  }

  private func rebuild() {
    preview.apply(size: PhoneSettings.terminalFontSize, columnsWidth: columnsWidth)
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
              self?.preview.apply(size: next, columnsWidth: self?.columnsWidth ?? 0)
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

  /// The width a terminal gets on this phone, which the preview counts columns for: the whole window.
  private var columnsWidth: CGFloat {
    view.window?.bounds.width ?? view.window?.windowScene?.screen.bounds.width ?? tableView.bounds.width
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    // The window is known only now; the first pass counted on the table's width.
    preview.apply(size: PhoneSettings.terminalFontSize, columnsWidth: columnsWidth)
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

/// The official preview (TerminalFontPreview.tsx): a Claude Code turn in the chosen font on the terminal's
/// background, and how many columns a terminal this wide gets at that size.
private final class TerminalPreviewView: UIView {
  static let height: CGFloat = 180

  private let label = UILabel()
  private let columns = UILabel()
  private let box = UIView()

  /// The terminal theme's colours (terminal-webview-html/theme.ts), the same in either app theme.
  private enum Tone {
    case plain, green, blue, magenta, yellow, red, dim, cursor

    var color: UIColor {
      switch self {
      case .plain, .cursor: UIColor(hex: 0xc0caf5)
      case .green: UIColor(hex: 0x9ece6a)
      case .blue: UIColor(hex: 0x7aa2f7)
      case .magenta: UIColor(hex: 0xbb9af7)
      case .yellow: UIColor(hex: 0xe0af68)
      case .red: UIColor(hex: 0xf7768e)
      case .dim: UIColor(hex: 0x414868)
      }
    }
  }

  /// terminal-font-preview-html.ts SAMPLE_LINES: prompt, tool rows, a rule and the input box, so weight
  /// and spacing show on real shapes.
  private static let sample: [[(String, Tone, Bool)]] = [
    [("➜", .green, false), (" ", .plain, false), ("~/orca", .blue, false), (" ", .plain, false), ("main", .magenta, false),
     (" ", .plain, false), ("❯", .dim, false), (" claude", .plain, false)],
    [("✻", .yellow, true), (" ", .plain, false), ("Claude Code", .plain, true), ("  ", .plain, false), ("~/orca/mobile", .dim, false)],
    [],
    [("●", .green, false), (" Read ", .plain, false), ("src/terminal/text-scaling.ts", .plain, true)],
    [("●", .green, false), (" Bash(pnpm test resume --maxWorkers=2)", .plain, false)],
    [("  ", .plain, false), ("⎿", .dim, false), ("  ", .plain, false), ("✓", .green, false), (" 42 passed ", .plain, false),
     ("(1.8s)", .dim, false), ("  ", .plain, false), ("0 failed", .red, false)],
    [(String(repeating: "─", count: 60), .dim, false)],
    [("❯", .dim, false), (" fix the flaky resume test", .plain, false), (" ", .cursor, false)],
    [("  ⏵⏵ accept edits on · 12% context left", .dim, false)],
  ]

  override init(frame: CGRect) {
    super.init(frame: frame)
    box.backgroundColor = Palette.terminalBg
    box.layer.cornerRadius = Radius.surface
    box.layer.cornerCurve = .continuous
    box.clipsToBounds = true
    box.isAccessibilityElement = true
    box.accessibilityLabel = String(localized: "app.terminalSettings.previewLabel", defaultValue: "Terminal preview")
    // Each sample line stays one line; the box cuts off what runs past its edge, as a terminal would.
    label.numberOfLines = 0
    columns.font = .systemFont(ofSize: 11)
    columns.textColor = UIColor(hex: 0xa9b1d6).withAlphaComponent(0.7)
    for view in [box, label, columns] { view.translatesAutoresizingMaskIntoConstraints = false }
    addSubview(box)
    box.addSubview(label)
    box.addSubview(columns)
    NSLayoutConstraint.activate([
      box.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
      box.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
      box.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.sm),
      box.heightAnchor.constraint(equalToConstant: Self.height),
      label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
      label.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
      columns.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -Spacing.md),
      columns.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -Spacing.sm),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func apply(size: Double, columnsWidth: CGFloat) {
    let font = PhoneSettings.terminalFont.font(size: size, weight: PhoneSettings.terminalFontWeight)
    let bold = PhoneSettings.terminalFont.font(size: size, weight: PhoneSettings.terminalFontWeight + 200)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineHeightMultiple = PhoneSettings.terminalLineHeight
    let text = NSMutableAttributedString()
    for (index, line) in Self.sample.enumerated() {
      for (run, tone, strong) in line {
        var attributes: [NSAttributedString.Key: Any] = [
          .font: strong ? bold : font, .foregroundColor: tone.color, .paragraphStyle: paragraph,
        ]
        if tone == .cursor { attributes[.backgroundColor] = tone.color }
        text.append(NSAttributedString(string: run, attributes: attributes))
      }
      if index < Self.sample.count - 1 {
        text.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: paragraph]))
      }
    }
    label.attributedText = text

    // As xterm sizes a cell: the width of "W", floored to device pixels.
    let scale = window?.screen.scale ?? traitCollection.displayScale
    let cell = floor(("W" as NSString).size(withAttributes: [.font: font]).width * scale) / max(scale, 1)
    guard cell > 0, columnsWidth > 0 else {
      columns.text = " "
      return
    }
    let count = Int(columnsWidth / cell)
    columns.text = String.localizedStringWithFormat(
      String(localized: "app.terminalSettings.previewColumns", defaultValue: "%lld columns"), count)
    box.accessibilityValue = columns.text
  }
}
