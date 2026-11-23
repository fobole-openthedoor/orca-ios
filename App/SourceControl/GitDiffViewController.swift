import OrcaCore
import UIKit

/// One changed file's diff (source-control/review): the file's lines with additions and removals coloured, three
/// lines of context around each change and the rest folded until tapped. The toolbar stages, unstages or discards it.
final class GitDiffViewController: UITableViewController {
  private let session: HostSession
  private let worktreeId: String
  private let entry: GitStatusEntry
  private var rows: [LineDiff.Row] = []
  private var numberWidth = 1
  private var busy = false

  init(session: HostSession, worktreeId: String, entry: GitStatusEntry) {
    self.session = session
    self.worktreeId = worktreeId
    self.entry = entry
    super.init(style: .plain)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    let slash = entry.path.lastIndex(of: "/")
    title = slash.map { String(entry.path[entry.path.index(after: $0)...]) } ?? entry.path
    navigationItem.subtitle = slash.map { String(entry.path[..<$0]) }
    navigationItem.largeTitleDisplayMode = .never
    view.backgroundColor = Palette.editorSurface
    tableView.backgroundColor = Palette.editorSurface
    tableView.separatorStyle = .none
    tableView.register(DiffLineCell.self, forCellReuseIdentifier: DiffLineCell.reuseIdentifier)
    tableView.register(DiffFoldCell.self, forCellReuseIdentifier: DiffFoldCell.reuseIdentifier)
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      image: Lucide.copy.image(size: 18), style: .plain, target: nil, action: nil)
    navigationItem.rightBarButtonItem?.primaryAction = UIAction(
      title: String(localized: "session.sheets.copyPath", defaultValue: "Copy Path"), image: Lucide.copy.image(size: 18)
    ) { [entry] _ in UIPasteboard.general.string = entry.path }
    updateToolbar()
    load()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.setToolbarHidden(toolbarItems?.isEmpty ?? true, animated: animated)
  }

  private func load() {
    contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
    let api = session.api
    let worktreeId = worktreeId
    let entry = entry
    Task { [weak self] in
      do {
        let diff = try await api.gitDiff(worktreeId: worktreeId, entry: entry)
        guard let self else { return }
        switch diff {
        case .text(let original, let modified):
          let rows = await Task.detached(priority: .userInitiated) {
            LineDiff.rows(LineDiff.diff(original: original, modified: modified))
          }.value
          show(rows)
        case .binary:
          showNotice(
            String(localized: "components.diffReviewBody.binaryDiff", defaultValue: "Binary Diff"),
            String(
              localized: "components.diffReviewBody.binaryMessage",
              defaultValue: "This file cannot be rendered as text on mobile."))
        case .tooLarge:
          showNotice(
            String(localized: "components.diffReviewBody.diffTooLarge", defaultValue: "Diff Too Large"),
            String(
              localized: "components.diffReviewBody.tooLargeMessage",
              defaultValue: "This diff is too large for the mobile preview."))
        }
      } catch {
        self?.showNotice(
          String(localized: "components.diffReviewBody.diffUnavailable", defaultValue: "Diff Unavailable"),
          (error as? RPCError)?.message ?? error.localizedDescription, retry: true)
      }
    }
  }

  private func show(_ rows: [LineDiff.Row]) {
    self.rows = rows
    let largest = rows.reduce(0) { result, row in
      guard case .line(let line) = row else { return result }
      return max(result, line.oldNumber ?? 0, line.newNumber ?? 0)
    }
    numberWidth = max(2, String(largest).count)
    contentUnavailableConfiguration = nil
    if rows.isEmpty {
      var config = UIContentUnavailableConfiguration.empty()
      config.text = String(localized: "sourceControl.content.emptyTitle", defaultValue: "No local changes")
      contentUnavailableConfiguration = config
    }
    tableView.reloadData()
  }

  private func showNotice(_ title: String, _ message: String?, retry: Bool = false) {
    var config = UIContentUnavailableConfiguration.empty()
    config.image = Lucide.fileText.image(size: 32)
    config.text = title
    config.secondaryText = message
    if retry {
      var button = UIButton.Configuration.gray()
      button.title = String(localized: "common.retry", defaultValue: "Retry")
      config.button = button
      config.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.load() }
    }
    contentUnavailableConfiguration = config
  }

  // MARK: Actions

  private func updateToolbar() {
    var items: [UIBarButtonItem] = []
    if entry.canDiscard {
      let discard = UIBarButtonItem(
        title: String(localized: "sourceControl.fileRows.discard", defaultValue: "Discard"), style: .plain, target: nil,
        action: nil)
      discard.primaryAction = UIAction(
        title: String(localized: "sourceControl.fileRows.discard", defaultValue: "Discard"), attributes: .destructive
      ) { [weak self] _ in self?.confirmDiscard() }
      discard.tintColor = Palette.statusRed
      items.append(discard)
    }
    items.append(.flexibleSpace())
    if busy {
      let spinner = UIActivityIndicatorView(style: .medium)
      spinner.startAnimating()
      items.append(UIBarButtonItem(customView: spinner))
    } else if entry.canStage {
      let title = String(localized: "orcaios.sourceControl.stage", defaultValue: "Stage")
      let stage = UIBarButtonItem(title: title, style: .prominent, target: nil, action: nil)
      stage.primaryAction = UIAction(title: title) { [weak self] _ in
        self?.run { try await $0.gitStage(worktreeId: $1, path: $2.path) }
      }
      items.append(stage)
    } else if entry.canUnstage {
      let title = String(localized: "components.diffReviewDrawers.unstageFile", defaultValue: "Unstage")
      let unstage = UIBarButtonItem(title: title, style: .prominent, target: nil, action: nil)
      unstage.primaryAction = UIAction(title: title) { [weak self] _ in
        self?.run { try await $0.gitUnstage(worktreeId: $1, path: $2.path) }
      }
      items.append(unstage)
    }
    // The flexible space alone means this file has nothing to act on.
    toolbarItems = items.count > 1 ? items : []
  }

  /// Runs the change and goes back to the list, which reads status again on appearing.
  private func run(_ body: @escaping (HostAPI, String, GitStatusEntry) async throws -> Void) {
    guard !busy else { return }
    busy = true
    updateToolbar()
    let api = session.api
    let worktreeId = worktreeId
    let entry = entry
    Task { [weak self] in
      do {
        try await body(api, worktreeId, entry)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        self?.navigationController?.popViewController(animated: true)
      } catch {
        guard let self else { return }
        busy = false
        updateToolbar()
        let alert = UIAlertController(
          title: String(localized: "sourceControl.commitRunners.actionFailed", defaultValue: "Source control action failed"),
          message: (error as? RPCError)?.message ?? error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "common.ok", defaultValue: "OK"), style: .default))
        present(alert, animated: true)
      }
    }
  }

  private func confirmDiscard() {
    let alert = UIAlertController(
      title: String(localized: "sourceControl.modals.discardTitle", defaultValue: "Discard Change"),
      message: String(
        format: String(
          localized: "sourceControl.modals.discardConfirmMessage",
          defaultValue: "Discard changes to \"%1$@\"? This cannot be undone."), entry.path),
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "Cancel"), style: .cancel))
    alert.addAction(
      UIAlertAction(
        title: String(localized: "sourceControl.modals.discardButton", defaultValue: "Discard"), style: .destructive
      ) { [weak self] _ in self?.run { try await $0.gitDiscard(worktreeId: $1, path: $2.path) } })
    present(alert, animated: true)
  }

  // MARK: Table

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    switch rows[indexPath.row] {
    case .line(let line):
      let cell =
        tableView.dequeueReusableCell(withIdentifier: DiffLineCell.reuseIdentifier, for: indexPath) as! DiffLineCell
      cell.configure(line, numberWidth: numberWidth)
      return cell
    case .fold(let lines):
      let cell =
        tableView.dequeueReusableCell(withIdentifier: DiffFoldCell.reuseIdentifier, for: indexPath) as! DiffFoldCell
      cell.configure(count: lines.count)
      return cell
    }
  }

  override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
    if case .fold = rows[indexPath.row] { return true }
    return false
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    guard case .fold(let lines) = rows[indexPath.row] else { return }
    rows.replaceSubrange(indexPath.row...indexPath.row, with: lines.map(LineDiff.Row.line))
    let inserted = (indexPath.row..<(indexPath.row + lines.count)).map { IndexPath(row: $0, section: 0) }
    tableView.performBatchUpdates {
      tableView.deleteRows(at: [indexPath], with: .fade)
      tableView.insertRows(at: inserted, with: .fade)
    }
  }
}

/// One diff line: its line number, a +/- sign and the text, wrapped, on the added/removed tint.
private final class DiffLineCell: UITableViewCell {
  static let reuseIdentifier = "diffLine"

  private let numberLabel = UILabel()
  private let signLabel = UILabel()
  private let textLine = UILabel()
  private let gutter = UIView()
  private var numberWidthConstraint: NSLayoutConstraint!

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
    let font = Typography.mono(12)
    numberLabel.font = font
    numberLabel.textColor = Palette.diffLineNumber
    numberLabel.textAlignment = .right
    signLabel.font = font
    signLabel.textAlignment = .center
    textLine.font = font
    textLine.numberOfLines = 0
    textLine.lineBreakMode = .byCharWrapping
    for view in [gutter, numberLabel, signLabel, textLine] {
      view.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(view)
    }
    let digit = ("0" as NSString).size(withAttributes: [.font: font]).width
    numberWidthConstraint = numberLabel.widthAnchor.constraint(equalToConstant: digit * 3)
    NSLayoutConstraint.activate([
      gutter.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      gutter.topAnchor.constraint(equalTo: contentView.topAnchor),
      gutter.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
      gutter.trailingAnchor.constraint(equalTo: numberLabel.trailingAnchor, constant: Spacing.xs),
      numberLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Spacing.sm),
      numberLabel.firstBaselineAnchor.constraint(equalTo: textLine.firstBaselineAnchor),
      numberWidthConstraint,
      signLabel.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
      signLabel.widthAnchor.constraint(equalToConstant: digit * 2),
      signLabel.firstBaselineAnchor.constraint(equalTo: textLine.firstBaselineAnchor),
      textLine.leadingAnchor.constraint(equalTo: signLabel.trailingAnchor),
      textLine.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Spacing.sm),
      textLine.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 1),
      textLine.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -1),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(_ line: LineDiff.Line, numberWidth: Int) {
    let digit = ("0" as NSString).size(withAttributes: [.font: Typography.mono(12)]).width
    numberWidthConstraint.constant = ceil(digit * CGFloat(numberWidth))
    numberLabel.text = (line.kind == .removed ? line.oldNumber : line.newNumber).map(String.init)
    textLine.text = line.text.isEmpty ? " " : line.text.replacingOccurrences(of: "\t", with: "    ")
    switch line.kind {
    case .added:
      signLabel.text = "+"
      signLabel.textColor = Palette.diffAddedSign
      textLine.textColor = Palette.textPrimary
      contentView.backgroundColor = Palette.diffAddedBg
      gutter.backgroundColor = Palette.diffAddedGutter
    case .removed:
      signLabel.text = "−"
      signLabel.textColor = Palette.diffDeletedSign
      textLine.textColor = Palette.textPrimary
      contentView.backgroundColor = Palette.diffDeletedBg
      gutter.backgroundColor = Palette.diffDeletedGutter
    case .context:
      signLabel.text = " "
      textLine.textColor = Palette.textSecondary
      contentView.backgroundColor = Palette.editorSurface
      gutter.backgroundColor = .clear
    }
  }
}

/// Folded unchanged lines; tapping shows them.
private final class DiffFoldCell: UITableViewCell {
  static let reuseIdentifier = "diffFold"

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    backgroundColor = Palette.diffFoldBg
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(count: Int) {
    var content = UIListContentConfiguration.cell()
    content.text = String.localizedStringWithFormat(
      String(localized: "components.diffReviewBody.unchangedLines", defaultValue: "%lld unchanged lines"), count)
    content.textProperties.font = Typography.mono(12)
    content.textProperties.color = Palette.diffFoldText
    content.textProperties.alignment = .center
    content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)
    contentConfiguration = content
    accessibilityLabel = String.localizedStringWithFormat(
      String(localized: "components.diffReviewBody.showUnchangedLines", defaultValue: "Show %lld unchanged lines"), count)
  }
}
