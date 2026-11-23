import OrcaCore
import UIKit

/// What the composer is completing: a slash command at the start, or an @ file mention under the cursor
/// (MobileNativeChatComposer's command and file pickers).
enum ComposerToken: Equatable {
  case command(query: String, range: NSRange)
  case file(query: String, range: NSRange)

  var range: NSRange {
    switch self {
    case .command(_, let range), .file(_, let range): range
    }
  }

  /// The token the cursor sits in, if any: `/word` as the whole first word, or `@path` after a space.
  static func at(_ text: String, cursor: Int) -> ComposerToken? {
    let ns = text as NSString
    guard cursor <= ns.length else { return nil }
    let before = ns.substring(to: cursor)
    // A slash command is the message's first word, still being typed.
    if before.hasPrefix("/"), !before.contains(where: \.isWhitespace) {
      return .command(query: String(before.dropFirst()), range: NSRange(location: 0, length: cursor))
    }
    // An @ mention starts after a space (or at the start) and runs to the cursor without one.
    let at = ns.range(of: "@", options: .backwards, range: NSRange(location: 0, length: cursor))
    guard at.location != NSNotFound else { return nil }
    let query = ns.substring(with: NSRange(location: at.location + 1, length: cursor - at.location - 1))
    guard !query.contains(where: \.isWhitespace) else { return nil }
    if at.location > 0 {
      let previous = ns.substring(with: NSRange(location: at.location - 1, length: 1))
      guard previous.rangeOfCharacter(from: .whitespacesAndNewlines) != nil else { return nil }
    }
    return .file(query: query, range: NSRange(location: at.location, length: cursor - at.location))
  }
}

/// The list over the composer while a command or mention is being typed: a glass card of up to five rows,
/// each an icon, a name and a muted line; tapping one fills it in.
final class ChatSuggestionPanel: UIView, UITableViewDataSource, UITableViewDelegate {
  struct Row: Equatable {
    var icon: Lucide
    var title: String
    var detail: String?
    /// What replaces the typed token.
    var insert: String
  }

  var onPick: ((Row) -> Void)?
  private let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
  private let table = UITableView(frame: .zero, style: .plain)
  private var rows: [Row] = []
  private var height: NSLayoutConstraint!
  private static let rowHeight: CGFloat = 48

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    glass.cornerConfiguration = .uniformCorners(radius: .fixed(Radius.surface))
    glass.clipsToBounds = true
    glass.translatesAutoresizingMaskIntoConstraints = false
    addSubview(glass)
    table.backgroundColor = .clear
    table.separatorStyle = .none
    table.rowHeight = Self.rowHeight
    table.dataSource = self
    table.delegate = self
    table.keyboardDismissMode = .none
    table.register(UITableViewCell.self, forCellReuseIdentifier: "row")
    table.translatesAutoresizingMaskIntoConstraints = false
    glass.contentView.addSubview(table)
    height = glass.heightAnchor.constraint(equalToConstant: 0)
    NSLayoutConstraint.activate([
      glass.topAnchor.constraint(equalTo: topAnchor),
      glass.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.sm),
      glass.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.lg),
      glass.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.lg),
      height,
    ])
    table.pin(to: glass.contentView)
    isHidden = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func show(_ rows: [Row]) {
    self.rows = rows
    isHidden = rows.isEmpty
    height.constant = CGFloat(min(rows.count, 5)) * Self.rowHeight + 8
    table.contentInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
    table.reloadData()
    if !rows.isEmpty { table.setContentOffset(CGPoint(x: 0, y: -4), animated: false) }
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let row = rows[indexPath.row]
    let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
    var content = UIListContentConfiguration.subtitleCell()
    content.image = row.icon.image(size: 16, strokeWidth: 2)
    content.imageProperties.tintColor = Palette.textSecondary
    content.text = row.title
    content.textProperties.font = .systemFont(ofSize: 15, weight: .medium)
    content.textProperties.numberOfLines = 1
    content.secondaryText = row.detail
    content.secondaryTextProperties.font = .systemFont(ofSize: 12)
    content.secondaryTextProperties.color = Palette.textMuted
    content.secondaryTextProperties.numberOfLines = 1
    content.textToSecondaryTextVerticalPadding = 2
    content.directionalLayoutMargins = .init(top: 4, leading: 14, bottom: 4, trailing: 14)
    cell.contentConfiguration = content
    cell.backgroundColor = .clear
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: false)
    UISelectionFeedbackGenerator().selectionChanged()
    onPick?(rows[indexPath.row])
  }
}
