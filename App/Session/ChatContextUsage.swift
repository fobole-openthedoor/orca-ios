import OrcaCore
import UIKit

/// How full the context window is (native-chat-context-usage-summary.ts): a ring beside the mic that fills
/// as the window does and turns red past 90%. Tapping it opens the breakdown.
final class ContextRingButton: UIControl {
  private let track = CAShapeLayer()
  private let fill = CAShapeLayer()
  private(set) var usage: ChatOptions.ContextUsage?

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    for layer in [track, fill] {
      layer.fillColor = UIColor.clear.cgColor
      layer.lineWidth = 2.5
      layer.lineCap = .round
      self.layer.addSublayer(layer)
    }
    NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 36), heightAnchor.constraint(equalToConstant: 36)])
    isAccessibilityElement = true
    accessibilityTraits = .button
    isHidden = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func show(_ usage: ChatOptions.ContextUsage?) {
    self.usage = usage
    isHidden = usage == nil
    guard let usage else { return }
    fill.strokeEnd = min(max(usage.percentage, 0), 100) / 100
    fill.strokeColor = (usage.percentage >= 90 ? Palette.statusRed : Palette.textSecondary).resolvedColor(with: traitCollection).cgColor
    accessibilityLabel = String(
      format: String(localized: "chat.contextUsage.label", defaultValue: "Context %1$@/%2$@ tokens, %3$@% used"),
      ContextUsageFormat.tokens(usage.usedTokens), ContextUsageFormat.tokens(usage.windowTokens),
      "\(Int(usage.percentage))")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let rect = bounds.insetBy(dx: 9.5, dy: 9.5)
    let path = UIBezierPath(
      arcCenter: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2, startAngle: -.pi / 2,
      endAngle: .pi * 1.5, clockwise: true)
    track.path = path.cgPath
    fill.path = path.cgPath
    track.strokeColor = Palette.borderSubtle.resolvedColor(with: traitCollection).cgColor
  }

  override func traitCollectionDidChange(_ previous: UITraitCollection?) {
    super.traitCollectionDidChange(previous)
    setNeedsLayout()
    show(usage)
  }
}

enum ContextUsageFormat {
  /// 71,000 as "7.1万" in Chinese, "71k" elsewhere; a whole million as "100万" / "1M".
  static func tokens(_ value: Int) -> String {
    let chinese = Locale.current.language.languageCode?.identifier == "zh"
    if chinese {
      guard value >= 10_000 else { return value.formatted() }
      let wan = Double(value) / 10_000
      let traditional = Locale.current.language.script?.identifier == "Hant"
      return trim(String(format: "%.1f", wan)) + (traditional ? "萬" : "万")
    }
    if Double(value) / 100 >= 10_000 { return trim(String(format: "%.1f", Double(value) / 1_000_000)) + "M" }
    if value >= 1000 { return trim(String(format: "%.1f", Double(value) / 1000)) + "k" }
    return "\(value)"
  }

  static func percent(_ tokens: Int, of window: Int) -> String {
    guard window > 0 else { return "—" }
    return String(format: "%.1f%%", Double(tokens) / Double(window) * 100)
  }

  private static func trim(_ text: String) -> String {
    text.hasSuffix(".0") ? String(text.dropLast(2)) : text
  }

  /// The provider names its kinds in English; the desktop shows them in the reader's language.
  static func name(_ raw: String) -> String {
    guard Locale.current.language.languageCode?.identifier == "zh" else { return raw }
    let traditional = Locale.current.language.script?.identifier == "Hant"
    var base = raw
    var suffix = ""
    if let range = raw.range(of: " (deferred)", options: .caseInsensitive) {
      base = String(raw[..<range.lowerBound])
      suffix = traditional ? "（延遲載入）" : "（延迟加载）"
    }
    let names: [String: (String, String)] = [
      "messages": ("消息", "訊息"), "system tools": ("系统工具", "系統工具"), "system prompt": ("系统提示", "系統提示"),
      "mcp tools": ("MCP 工具", "MCP 工具"), "mcp server instructions": ("MCP 服务器说明", "MCP 伺服器說明"),
      "memory files": ("记忆文件", "記憶檔案"), "custom agents": ("自定义智能体", "自訂代理"),
      "free space": ("可用空间", "可用空間"), "autocompact buffer": ("自动压缩缓冲区", "自動壓縮緩衝區"),
    ]
    let translated = names[base.lowercased()].map { traditional ? $0.1 : $0.0 } ?? base
    return translated + suffix
  }

  /// Each kind of context in its own colour, as the desktop's breakdown draws them. Deferred kinds are grey:
  /// they sit outside the total.
  static func color(_ name: String, deferred: Bool = false) -> UIColor {
    if deferred { return UIColor(white: 0.45, alpha: 1) }
    let key = name.lowercased()
    if key.contains("free") { return UIColor(white: 0.22, alpha: 1) }
    if key.contains("buffer") || key.contains("compact") { return UIColor(white: 0.45, alpha: 1) }
    if key.contains("message") { return UIColor(red: 0.30, green: 0.55, blue: 0.97, alpha: 1) }
    if key.contains("system tool") || key == "tools" { return UIColor(red: 0.88, green: 0.48, blue: 0.24, alpha: 1) }
    if key.contains("system prompt") { return UIColor(red: 0.30, green: 0.71, blue: 0.54, alpha: 1) }
    if key.contains("skill") { return UIColor(red: 0.88, green: 0.69, blue: 0.25, alpha: 1) }
    if key.contains("mcp") { return UIColor(red: 0.64, green: 0.45, blue: 0.93, alpha: 1) }
    if key.contains("agent") { return UIColor(red: 0.91, green: 0.42, blue: 0.62, alpha: 1) }
    if key.contains("memory") { return UIColor(red: 0.27, green: 0.70, blue: 0.80, alpha: 1) }
    return UIColor(white: 0.55, alpha: 1)
  }
}

/// The breakdown: "已使用 7%  7.1万 / 100万", a bar split by kind, then a row per kind with its colour, tokens
/// and share. The buffer and free space follow the used kinds; deferred tools come last, outside the total.
final class ContextUsageViewController: UIViewController {
  private let usage: ChatOptions.ContextUsage

  init(usage: ChatOptions.ContextUsage) {
    self.usage = usage
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  static func sheet(_ usage: ChatOptions.ContextUsage) -> UIViewController {
    let controller = ContextUsageViewController(usage: usage)
    if let sheet = controller.sheetPresentationController {
      sheet.detents = [.custom { _ in CGFloat(220 + 34 * max(usage.categories.count, 1)) }, .large()]
      sheet.prefersGrabberVisible = true
    }
    return controller
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    let title = TextLabel(String(localized: "chat.contextUsage.title", defaultValue: "Context"), size: 15, weight: .semibold, color: Palette.textSecondary)
    let used = TextLabel(
      "\(Int(usage.percentage))%", size: 22, weight: .semibold, color: usage.percentage >= 90 ? Palette.statusRed : Palette.textPrimary, tabular: true)
    let total = TextLabel(
      "\(ContextUsageFormat.tokens(usage.usedTokens)) / \(ContextUsageFormat.tokens(usage.windowTokens))", size: 15,
      color: Palette.textMuted, tabular: true)
    let head = UIStackView(arrangedSubviews: [used, UIView(), total])
    head.alignment = .lastBaseline

    let column = UIStackView(arrangedSubviews: [title, head, bar()])
    column.axis = .vertical
    column.spacing = Spacing.sm
    column.setCustomSpacing(Spacing.md, after: head)

    let shown = usage.categories.filter { !$0.deferred }
    // The buffer, then free space, as the desktop lists them.
    let room = shown.filter { Self.isRoom($0.name) }.sorted { a, _ in !a.name.lowercased().contains("free") }
    let parts = shown.filter { !Self.isRoom($0.name) }
    let deferred = usage.categories.filter(\.deferred)
    var groups: [[ChatOptions.ContextUsage.Category]] = [parts, room, deferred]
    groups.removeAll(where: \.isEmpty)
    for (index, group) in groups.enumerated() {
      let rows = UIStackView(arrangedSubviews: group.map(row))
      rows.axis = .vertical
      rows.spacing = 4
      column.setCustomSpacing(index == 0 ? Spacing.lg : Spacing.xl, after: column.arrangedSubviews.last!)
      column.addArrangedSubview(rows)
    }
    var notes: [String] = []
    if usage.estimated {
      notes.append(String(localized: "chat.contextUsage.estimated", defaultValue: "Estimated from the last response."))
    }
    if !deferred.isEmpty {
      notes.append(String(localized: "chat.contextUsage.deferredNote", defaultValue: "Loaded on demand; not counted in the total."))
    }
    if !notes.isEmpty {
      let note = TextLabel(notes.joined(separator: " "), size: 12, color: Palette.textMuted, lines: 0)
      column.setCustomSpacing(Spacing.lg, after: column.arrangedSubviews.last!)
      column.addArrangedSubview(note)
    }

    let scroll = UIScrollView()
    scroll.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(scroll)
    scroll.pin(to: view)
    column.translatesAutoresizingMaskIntoConstraints = false
    scroll.addSubview(column)
    NSLayoutConstraint.activate([
      column.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Spacing.xl),
      column.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Spacing.xl),
      column.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Spacing.xl),
      column.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Spacing.xl),
    ])
  }

  /// The autocompact buffer and free space: room in the window rather than what fills it.
  private static func isRoom(_ name: String) -> Bool {
    let key = name.lowercased()
    return key.contains("free") || key.contains("buffer") || key.contains("compact")
  }

  /// The used kinds side by side, each as wide as its share; the rest of the track is empty.
  private func bar() -> UIView {
    let track = UIView()
    track.backgroundColor = Palette.bgRaised
    track.layer.cornerRadius = 3
    track.clipsToBounds = true
    track.translatesAutoresizingMaskIntoConstraints = false
    track.heightAnchor.constraint(equalToConstant: 6).isActive = true
    let parts = usage.categories.filter { !$0.deferred && !Self.isRoom($0.name) }
    let segments = parts.isEmpty
      ? [(Palette.textSecondary as UIColor, Double(usage.usedTokens))]
      : parts.map { (ContextUsageFormat.color($0.name), Double($0.tokens)) }
    var previous: NSLayoutXAxisAnchor = track.leadingAnchor
    for (color, tokens) in segments {
      let piece = UIView()
      piece.backgroundColor = color
      piece.translatesAutoresizingMaskIntoConstraints = false
      track.addSubview(piece)
      let share = usage.windowTokens > 0 ? min(1, tokens / Double(usage.windowTokens)) : 0
      NSLayoutConstraint.activate([
        piece.leadingAnchor.constraint(equalTo: previous, constant: 1),
        piece.topAnchor.constraint(equalTo: track.topAnchor),
        piece.bottomAnchor.constraint(equalTo: track.bottomAnchor),
        piece.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: max(share, 0.004)),
      ])
      previous = piece.trailingAnchor
    }
    return track
  }

  private func row(_ category: ChatOptions.ContextUsage.Category) -> UIView {
    let swatch = UIView()
    swatch.backgroundColor = ContextUsageFormat.color(category.name, deferred: category.deferred)
    swatch.layer.cornerRadius = 3
    swatch.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([swatch.widthAnchor.constraint(equalToConstant: 12), swatch.heightAnchor.constraint(equalToConstant: 12)])
    let name = TextLabel(ContextUsageFormat.name(category.name), size: 15, color: Palette.textSecondary, lines: 1)
    name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let tokens = TextLabel(ContextUsageFormat.tokens(category.tokens), size: 15, color: Palette.textMuted, alignment: .right, tabular: true)
    let share = TextLabel(
      category.deferred ? "—" : ContextUsageFormat.percent(category.tokens, of: usage.windowTokens), size: 15,
      color: Palette.textPrimary, alignment: .right, tabular: true)
    share.widthAnchor.constraint(equalToConstant: 64).isActive = true
    let row = UIStackView(arrangedSubviews: [swatch, name, UIView(), tokens, share])
    row.spacing = Spacing.md
    row.alignment = .center
    row.heightAnchor.constraint(equalToConstant: 30).isActive = true
    return row
  }
}
