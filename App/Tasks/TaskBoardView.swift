import OrcaCore
import UIKit

/// Linear's Board layout (providers/linear/mobile-tasks-linear-list.tsx): one column per group, side by side and
/// scrolling sideways, each a card list under its dot, name and count.
final class TaskBoardView: UIView {
  struct Column {
    var title: String
    var color: UIColor
    var issues: [TrackerIssue]
  }

  var onSelect: ((TrackerIssue) -> Void)?
  /// The row text under each card's title.
  var subtitle: (TrackerIssue) -> String = { $0.identifier }

  private let scroll = UIScrollView()
  private let stack = UIStackView()
  private var columns: [Column] = []
  private var tables: [UITableView] = []

  override init(frame: CGRect) {
    super.init(frame: frame)
    scroll.showsHorizontalScrollIndicator = false
    scroll.alwaysBounceHorizontal = true
    scroll.translatesAutoresizingMaskIntoConstraints = false
    addSubview(scroll)
    stack.axis = .horizontal
    stack.spacing = Spacing.md
    stack.alignment = .fill
    stack.translatesAutoresizingMaskIntoConstraints = false
    scroll.addSubview(stack)
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: topAnchor),
      scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
      scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Spacing.md),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
      stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: Spacing.lg),
      stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -Spacing.lg),
      stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -Spacing.md),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func show(_ columns: [Column]) {
    self.columns = columns
    stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    tables = []
    for (index, column) in columns.enumerated() {
      stack.addArrangedSubview(columnView(column, index: index))
    }
  }

  private func columnView(_ column: Column, index: Int) -> UIView {
    let dot = UIView()
    dot.backgroundColor = column.color
    dot.layer.cornerRadius = 4
    let title = UILabel()
    title.text = column.title
    title.font = .systemFont(ofSize: 14, weight: .semibold)
    title.textColor = Palette.textPrimary
    let count = UILabel()
    count.text = "\(column.issues.count)"
    count.font = .systemFont(ofSize: 13)
    count.textColor = Palette.textMuted
    count.setContentHuggingPriority(.required, for: .horizontal)
    let header = UIStackView(arrangedSubviews: [dot, title, count])
    header.spacing = Spacing.sm
    header.alignment = .center

    let table = UITableView(frame: .zero, style: .plain)
    table.tag = index
    table.backgroundColor = .clear
    table.separatorStyle = .none
    table.showsVerticalScrollIndicator = false
    table.dataSource = self
    table.delegate = self
    table.register(UITableViewCell.self, forCellReuseIdentifier: "card")
    tables.append(table)

    let column = UIStackView(arrangedSubviews: [header, table])
    column.axis = .vertical
    column.spacing = Spacing.sm
    column.isLayoutMarginsRelativeArrangement = true
    column.directionalLayoutMargins = .init(top: Spacing.md, leading: Spacing.sm, bottom: 0, trailing: Spacing.sm)
    column.backgroundColor = Palette.bgPanel
    column.layer.cornerRadius = 16
    column.layer.cornerCurve = .continuous
    NSLayoutConstraint.activate([
      dot.widthAnchor.constraint(equalToConstant: 8),
      dot.heightAnchor.constraint(equalToConstant: 8),
      header.heightAnchor.constraint(equalToConstant: 24),
      column.widthAnchor.constraint(equalToConstant: 280),
    ])
    return column
  }
}

extension TaskBoardView: UITableViewDataSource, UITableViewDelegate {
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    columns.indices.contains(tableView.tag) ? columns[tableView.tag].issues.count : 0
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let issue = columns[tableView.tag].issues[indexPath.row]
    let cell = tableView.dequeueReusableCell(withIdentifier: "card", for: indexPath)
    var content = UIListContentConfiguration.subtitleCell()
    content.text = issue.title
    content.textProperties.font = .systemFont(ofSize: 15, weight: .medium)
    content.textProperties.numberOfLines = 3
    content.secondaryText = subtitle(issue)
    content.secondaryTextProperties.font = .systemFont(ofSize: 12)
    content.secondaryTextProperties.color = Palette.textSecondary
    content.secondaryTextProperties.numberOfLines = 2
    content.textToSecondaryTextVerticalPadding = Spacing.xs
    cell.contentConfiguration = content
    var background = UIBackgroundConfiguration.listCell()
    background.backgroundColor = Palette.bgRaised
    background.cornerRadius = 12
    background.backgroundInsets = .init(top: Spacing.xs, leading: 0, bottom: Spacing.xs, trailing: 0)
    cell.backgroundConfiguration = background
    cell.accessibilityLabel = "\(issue.identifier), \(issue.title)"
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    Haptics.select()
    onSelect?(columns[tableView.tag].issues[indexPath.row])
  }
}
