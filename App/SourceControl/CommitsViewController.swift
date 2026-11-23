import OrcaCore
import UIKit

/// What the Commits page asks of the hub: the branch's remote step for the Not pushed header, and Update
/// branch (a rebase onto the base) for the base row.
struct CommitsPageActions {
  /// The label, whether it can run now, and whether it is running; nil when the branch has no remote step.
  var remoteStep: () -> (label: String, enabled: Bool, busy: Bool)?
  var runRemoteStep: () -> Void
  var rebase: (String) -> Void
  var isRebasing: () -> Bool
  /// A git action's failure, shown above the list.
  var actionError: () -> String?
}

/// The branch's commits (MobileGitHistoryList.tsx, MobileCommitListRows.tsx): Not pushed then On origin on a
/// timeline, down to where the branch left its base with Update branch when the base moved on. Without a
/// base it lists HEAD's whole history. A commit opens its detail.
final class CommitsViewController: UITableViewController {
  private enum Item {
    case header(title: String, push: Bool)
    case commit(GitHistoryItem, lineAbove: Bool, lineBelow: Bool)
    case base(GitHistoryPage.BranchRange, lineAbove: Bool)
  }

  private let session: HostSession
  private let worktreeId: String
  private let actions: CommitsPageActions
  private var items: [GitHistoryItem] = []
  private var branch: GitHistoryPage.BranchRange?
  private var hasMore = false
  private var nextSkip = 0
  private var baseRef: String?
  private var rows: [Item] = []
  private var loaded = false
  private var loadError: String?
  private var moreState = "idle"
  private var generation = 0

  init(session: HostSession, worktreeId: String, branchName: String?, actions: CommitsPageActions) {
    self.session = session
    self.worktreeId = worktreeId
    self.actions = actions
    super.init(style: .plain)
    title = String(localized: "sourceControl.commits.title", defaultValue: "Commits")
    navigationItem.subtitle = branchName
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    navigationItem.largeTitleDisplayMode = .never
    tableView.backgroundColor = Palette.bgBase
    tableView.separatorStyle = .none
    tableView.register(CommitRowCell.self, forCellReuseIdentifier: CommitRowCell.reuseIdentifier)
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "plain")
    let refresh = UIRefreshControl()
    refresh.addAction(UIAction { [weak self] _ in self?.reload() }, for: .valueChanged)
    tableView.refreshControl = refresh
    reload()
  }

  /// Reads page one again: on pull, and when the hub's status moved (a push, a rebase, a commit on the desktop).
  func reload() {
    generation += 1
    let current = generation
    let api = session.api
    let worktreeId = worktreeId
    let repoId = session.worktree(id: worktreeId)?.repoId ?? String(worktreeId.split(separator: ":").first ?? "")
    Task { [weak self] in
      let baseRef = await api.effectiveBaseRef(worktreeId: worktreeId, repoId: repoId)
      do {
        let page = try await api.gitHistory(worktreeId: worktreeId, baseRef: baseRef)
        guard let self, current == generation else { return }
        self.baseRef = baseRef
        items = page.items
        branch = page.branch
        hasMore = page.canPage
        nextSkip = (page.skip ?? 0) + page.items.count
        loadError = nil
        moreState = "idle"
      } catch {
        guard let self, current == generation else { return }
        loadError = PullRequestController.message(error)
      }
      guard let self, current == generation else { return }
      loaded = true
      tableView.refreshControl?.endRefreshing()
      rebuild()
    }
  }

  private func loadMore() {
    guard hasMore, moreState == "idle", loaded else { return }
    moreState = "loading"
    rebuild()
    let current = generation
    let api = session.api
    let worktreeId = worktreeId
    let baseRef = baseRef
    let skip = nextSkip
    Task { [weak self] in
      do {
        let page = try await api.gitHistory(worktreeId: worktreeId, baseRef: baseRef, skip: skip)
        guard let self, current == generation else { return }
        // HEAD can move between pages; drop repeats rather than show a commit twice.
        let seen = Set(items.map(\.id))
        items += page.items.filter { !seen.contains($0.id) }
        branch = page.branch ?? branch
        hasMore = page.canPage
        nextSkip = (page.skip ?? 0) + page.items.count
        moreState = "idle"
      } catch {
        guard let self, current == generation else { return }
        moreState = "error"
      }
      self?.rebuild()
    }
  }

  private func rebuild() {
    rows = []
    if let branch {
      let notPushed = items.filter { $0.pushed != true }
      let onOrigin = items.filter { $0.pushed == true }
      let showBase = !hasMore
      if !notPushed.isEmpty {
        rows.append(
          .header(
            title: String.localizedStringWithFormat(
              String(localized: "sourceControl.commits.notPushed", defaultValue: "Not pushed %lld"), branch.unpushed),
            push: true))
        rows += timeline(notPushed, continuesBelow: showBase && onOrigin.isEmpty)
      }
      if !onOrigin.isEmpty {
        rows.append(
          .header(
            title: String.localizedStringWithFormat(
              String(localized: "sourceControl.commits.onOrigin", defaultValue: "On origin %lld"),
              max(0, branch.ahead - branch.unpushed)),
            push: false))
        rows += timeline(onOrigin, continuesBelow: showBase)
      }
      if showBase { rows.append(.base(branch, lineAbove: !rows.isEmpty)) }
    } else {
      rows = timeline(items, continuesBelow: false)
    }
    tableView.backgroundView = backgroundState()
    tableView.reloadData()
  }

  private func timeline(_ list: [GitHistoryItem], continuesBelow: Bool) -> [Item] {
    list.enumerated().map { index, item in
      .commit(item, lineAbove: index > 0, lineBelow: index < list.count - 1 || continuesBelow)
    }
  }

  private func backgroundState() -> UIView? {
    guard rows.isEmpty else { return nil }
    var config: UIContentUnavailableConfiguration
    if let loadError {
      config = .empty()
      config.text = loadError
      var retry = UIButton.Configuration.gray()
      retry.title = String(localized: "common.retry", defaultValue: "Retry")
      config.button = retry
      config.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.reload() }
    } else if !loaded {
      config = .loading()
      config.text = String(localized: "sourceControl.gitHistoryList.loading", defaultValue: "Loading commits…")
    } else {
      config = .empty()
      config.image = Lucide.gitCommitHorizontal.image(size: 32)
      config.text = String(localized: "sourceControl.gitHistoryList.noCommits", defaultValue: "No commits.")
    }
    return UIContentUnavailableView(configuration: config)
  }

  // MARK: Table

  override func numberOfSections(in tableView: UITableView) -> Int { 1 }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    rows.count + (moreState == "idle" ? 0 : 1)
  }

  override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
    guard indexPath.row < rows.count else { return 56 }
    switch rows[indexPath.row] {
    case .header: return 40
    case .commit: return 60
    case .base: return 64
    }
  }

  override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
    guard let error = actions.actionError() else { return nil }
    let label = TextLabel(error, size: Typography.metaSize, color: Palette.statusRed, lines: 0)
    let holder = UIView()
    holder.addSubview(label)
    label.pin(to: holder, insets: UIEdgeInsets(top: Spacing.sm, left: Spacing.lg, bottom: Spacing.sm, right: Spacing.lg))
    return holder
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    guard indexPath.row < rows.count else {
      let cell = tableView.dequeueReusableCell(withIdentifier: "plain", for: indexPath)
      var content = UIListContentConfiguration.cell()
      if moreState == "loading" {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        cell.accessoryView = spinner
        content.text = nil
      } else {
        cell.accessoryView = nil
        content.text = String(localized: "sourceControl.commits.loadMoreFailed", defaultValue: "Retry loading commits")
        content.textProperties.alignment = .center
        content.textProperties.color = Palette.textSecondary
      }
      cell.contentConfiguration = content
      cell.backgroundColor = Palette.bgBase
      return cell
    }
    let cell = tableView.dequeueReusableCell(withIdentifier: CommitRowCell.reuseIdentifier, for: indexPath) as! CommitRowCell
    switch rows[indexPath.row] {
    case .header(let title, let push):
      let step = push ? actions.remoteStep() : nil
      cell.showHeader(title, action: step.map { step in (step.label, step.enabled, step.busy, actions.runRemoteStep) })
    case .commit(let item, let above, let below):
      cell.showCommit(item, lineAbove: above, lineBelow: below)
    case .base(let range, let above):
      var update: (busy: Bool, disabled: Bool, run: () -> Void)?
      if range.behind > 0, range.canUpdateFromBase, let base = baseRef {
        let rebasing = actions.isRebasing()
        let rebase = actions.rebase
        update = (rebasing, rebasing, { rebase(base) })
      }
      cell.showBase(range, lineAbove: above, update: update)
    }
    return cell
  }

  override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
    guard indexPath.row < rows.count else { return moreState == "error" }
    if case .commit = rows[indexPath.row] { return true }
    return false
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    guard indexPath.row < rows.count else {
      moreState = "idle"
      loadMore()
      return
    }
    guard case .commit(let item, _, _) = rows[indexPath.row] else { return }
    Haptics.select()
    navigationController?.pushViewController(
      CommitDetailViewController(session: session, worktreeId: worktreeId, commit: item), animated: true)
  }

  override func scrollViewDidScroll(_ scrollView: UIScrollView) {
    let remaining = scrollView.contentSize.height - scrollView.contentOffset.y - scrollView.bounds.height
    if remaining < scrollView.bounds.height / 2 { loadMore() }
  }

  /// How long ago, in the history's short units (mobile-git-history.ts formatCommitTime).
  static func relativeTime(_ timestamp: Double?, now: Date = Date()) -> String {
    guard let timestamp else { return "" }
    let delta = now.timeIntervalSince1970 * 1000 - timestamp
    if delta < 60_000 { return String(localized: "sourceControl.gitHistory.justNow", defaultValue: "just now") }
    let minutes = Int(delta / 60_000)
    let hours = minutes / 60
    let days = hours / 24
    let months = days / 30
    let (format, count): (String, Int) =
      minutes < 60
      ? (String(localized: "sourceControl.gitHistory.minutes", defaultValue: "%lldm"), minutes)
      : hours < 24
        ? (String(localized: "sourceControl.gitHistory.hours", defaultValue: "%lldh"), hours)
        : days < 30
          ? (String(localized: "sourceControl.gitHistory.days", defaultValue: "%lldd"), days)
          : months < 12
            ? (String(localized: "sourceControl.gitHistory.months", defaultValue: "%lldmo"), months)
            : (String(localized: "sourceControl.gitHistory.years", defaultValue: "%lldy"), months / 12)
    return String.localizedStringWithFormat(format, count)
  }
}

/// A row of the Commits list: a section title (with the branch's Push), a commit on the timeline, or the base.
private final class CommitRowCell: UITableViewCell {
  static let reuseIdentifier = "commitRow"

  private let dot = UIView()
  private let lineAbove = UIView()
  private let lineBelow = UIView()
  private let title = TextLabel(size: Typography.bodySize)
  private let meta = TextLabel(size: Typography.metaSize, color: Palette.textMuted)
  private let stat = TextLabel(size: Typography.metaSize)
  private let chevron = LucideView(.chevronRight, size: 16, strokeWidth: 2.2, color: Palette.textMuted)
  private let button = UIButton(type: .system)
  private let divider = Hairline()
  private let timeline = UIView()
  private var buttonAction: (() -> Void)?
  private var textLeading: NSLayoutConstraint!

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    backgroundColor = Palette.bgBase
    var background = UIBackgroundConfiguration.clear()
    background.backgroundColor = Palette.bgBase
    backgroundConfiguration = background
    meta.font = Typography.mono(Typography.metaSize)
    stat.font = Typography.mono(Typography.metaSize)
    for line in [lineAbove, lineBelow] { line.backgroundColor = Palette.translucentFill }
    dot.layer.cornerRadius = 5
    for part in [lineAbove, dot, lineBelow] {
      part.translatesAutoresizingMaskIntoConstraints = false
      timeline.addSubview(part)
    }
    var configuration = UIButton.Configuration.plain()
    configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: Spacing.md, bottom: 6, trailing: Spacing.md)
    button.configuration = configuration
    button.addAction(UIAction { [weak self] _ in self?.buttonAction?() }, for: .touchUpInside)
    let text = UIStackView(arrangedSubviews: [title, meta])
    text.axis = .vertical
    text.spacing = 2
    title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    meta.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    stat.setContentCompressionResistancePriority(.required, for: .horizontal)
    stat.setContentHuggingPriority(.required, for: .horizontal)
    button.setContentHuggingPriority(.required, for: .horizontal)
    button.setContentCompressionResistancePriority(.required, for: .horizontal)
    for part in [timeline, text, stat, chevron, button, divider] as [UIView] {
      part.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(part)
    }
    textLeading = text.leadingAnchor.constraint(equalTo: timeline.trailingAnchor)
    NSLayoutConstraint.activate([
      timeline.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Spacing.lg),
      timeline.topAnchor.constraint(equalTo: contentView.topAnchor),
      timeline.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
      timeline.widthAnchor.constraint(equalToConstant: 10 + Spacing.md),
      dot.leadingAnchor.constraint(equalTo: timeline.leadingAnchor),
      dot.centerYAnchor.constraint(equalTo: timeline.centerYAnchor),
      dot.widthAnchor.constraint(equalToConstant: 10),
      dot.heightAnchor.constraint(equalToConstant: 10),
      lineAbove.centerXAnchor.constraint(equalTo: dot.centerXAnchor),
      lineAbove.widthAnchor.constraint(equalToConstant: 1),
      lineAbove.topAnchor.constraint(equalTo: timeline.topAnchor),
      lineAbove.bottomAnchor.constraint(equalTo: dot.topAnchor),
      lineBelow.centerXAnchor.constraint(equalTo: dot.centerXAnchor),
      lineBelow.widthAnchor.constraint(equalToConstant: 1),
      lineBelow.topAnchor.constraint(equalTo: dot.bottomAnchor),
      lineBelow.bottomAnchor.constraint(equalTo: timeline.bottomAnchor),
      textLeading,
      text.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      stat.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: Spacing.sm),
      stat.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      chevron.leadingAnchor.constraint(equalTo: stat.trailingAnchor, constant: Spacing.sm),
      chevron.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Spacing.lg),
      chevron.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      button.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Spacing.md),
      button.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      button.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: Spacing.sm),
      divider.leadingAnchor.constraint(equalTo: text.leadingAnchor),
      divider.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Spacing.lg),
      divider.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func showHeader(_ text: String, action: (label: String, enabled: Bool, busy: Bool, run: () -> Void)?) {
    timeline.isHidden = true
    textLeading.constant = -(10 + Spacing.md)
    title.text = text
    title.font = Typography.font(13, .medium)
    title.textColor = Palette.textSecondary
    meta.isHidden = true
    stat.isHidden = true
    chevron.isHidden = true
    divider.isHidden = true
    showButton(action.map { ($0.label, $0.enabled, $0.busy, $0.run) }, pill: false)
    selectionStyle = .none
    accessibilityTraits = .header
  }

  func showCommit(_ item: GitHistoryItem, lineAbove above: Bool, lineBelow below: Bool) {
    timeline.isHidden = false
    textLeading.constant = 0
    lineAbove.isHidden = !above
    lineBelow.isHidden = !below
    if item.pushed == false {
      dot.backgroundColor = .clear
      dot.layer.borderWidth = 2
      dot.layer.borderColor = Palette.accentBlue.cgColor
      dot.layer.cornerRadius = 5
    } else {
      dot.backgroundColor = Palette.textMuted
      dot.layer.borderWidth = 0
      dot.layer.cornerRadius = 5
    }
    title.font = Typography.font(Typography.bodySize)
    title.textColor = Palette.textPrimary
    title.text =
      item.subject.isEmpty
      ? String(localized: "sourceControl.gitHistory.noCommitMessage", defaultValue: "(no commit message)") : item.subject
    meta.isHidden = false
    meta.text = [item.shortId, item.author, CommitsViewController.relativeTime(item.timestamp)].filter { !$0.isEmpty }
      .joined(separator: " · ")
    stat.isHidden = false
    stat.runs = CommitDetailViewController.lineStat(added: item.insertions, removed: item.deletions)
    chevron.isHidden = false
    divider.isHidden = false
    showButton(nil, pill: false)
    selectionStyle = .default
    var background = UIBackgroundConfiguration.clear()
    background.backgroundColor = Palette.bgBase
    backgroundConfiguration = background
    accessibilityTraits = .button
    accessibilityLabel = title.text
  }

  func showBase(_ range: GitHistoryPage.BranchRange, lineAbove above: Bool, update: (busy: Bool, disabled: Bool, run: () -> Void)?) {
    timeline.isHidden = false
    textLeading.constant = 0
    lineAbove.isHidden = !above
    lineBelow.isHidden = true
    dot.backgroundColor = .clear
    dot.layer.borderWidth = 1.5
    dot.layer.borderColor = Palette.textMuted.cgColor
    dot.layer.cornerRadius = 2
    title.font = Typography.font(Typography.bodySize)
    title.textColor = Palette.textPrimary
    title.text = String(
      format: String(localized: "sourceControl.commits.branchedFrom", defaultValue: "Branched from %1$@"), range.baseRef)
    meta.isHidden = false
    meta.text =
      range.behind == 0
      ? String(localized: "sourceControl.commits.baseUpToDate", defaultValue: "Up to date")
      : String.localizedStringWithFormat(
        String(localized: "sourceControl.commits.baseNewer", defaultValue: "%lld newer commits"), range.behind)
    stat.isHidden = true
    chevron.isHidden = true
    divider.isHidden = true
    showButton(
      update.map { (String(localized: "sourceControl.commits.updateBranch", defaultValue: "Update branch"), !$0.disabled, $0.busy, $0.run) },
      pill: true)
    selectionStyle = .none
    accessibilityTraits = .staticText
  }

  private func showButton(_ action: (label: String, enabled: Bool, busy: Bool, run: () -> Void)?, pill: Bool) {
    button.isHidden = action == nil
    buttonAction = action?.run
    guard let action else { return }
    var configuration = button.configuration ?? .plain()
    configuration.attributedTitle = AttributedString(
      action.label, attributes: AttributeContainer([.font: Typography.font(13, .semibold), .foregroundColor: Palette.textPrimary]))
    configuration.showsActivityIndicator = action.busy
    configuration.background.backgroundColor = pill ? Palette.bgRaised : .clear
    configuration.cornerStyle = .capsule
    button.configuration = configuration
    button.isEnabled = action.enabled && !action.busy
  }
}

/// One commit (MobileCommitDetailPage.tsx): its message, author, date and whether origin has it, then the
/// files it changed. The ⋯ menu copies the SHA.
final class CommitDetailViewController: UIViewController {
  private let session: HostSession
  private let worktreeId: String
  private let commit: GitHistoryItem
  private let stack = UIStackView()
  private let filesStack = UIStackView()

  init(session: HostSession, worktreeId: String, commit: GitHistoryItem) {
    self.session = session
    self.worktreeId = worktreeId
    self.commit = commit
    super.init(nibName: nil, bundle: nil)
    title = String(localized: "sourceControl.commitDetail.title", defaultValue: "Commit")
    navigationItem.subtitle = commit.shortId
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// `+3 −1` in the diff colours, a zero side dropped.
  static func lineStat(added: Int, removed: Int) -> [(String, UIColor)] {
    var runs: [(String, UIColor)] = []
    if added > 0 { runs.append(("+\(added)", Palette.gitDecorationAdded)) }
    if added > 0 && removed > 0 { runs.append((" ", Palette.textMuted)) }
    if removed > 0 { runs.append(("−\(removed)", Palette.gitDecorationDeleted)) }
    return runs
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = Palette.bgBase
    navigationItem.largeTitleDisplayMode = .never
    let sha = commit.id
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      image: Lucide.ellipsis.image(size: 20),
      menu: UIMenu(children: [
        UIAction(
          title: String(localized: "sourceControl.commitDetail.copySha", defaultValue: "Copy SHA"), image: Lucide.copy.image(size: 18)
        ) { _ in UIPasteboard.general.string = sha }
      ]))
    navigationItem.rightBarButtonItem?.accessibilityLabel = String(
      localized: "sourceControl.commitDetail.more", defaultValue: "More commit actions")
    let scroll = UIScrollView()
    scroll.alwaysBounceVertical = true
    view.addSubview(scroll)
    scroll.pin(to: view)
    stack.axis = .vertical
    stack.spacing = Spacing.md
    scroll.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Spacing.lg),
      stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Spacing.lg),
      stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Spacing.lg),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Spacing.xl),
    ])
    let subject = TextLabel(
      commit.subject.isEmpty
        ? String(localized: "sourceControl.gitHistory.noCommitMessage", defaultValue: "(no commit message)") : commit.subject,
      size: Typography.titleSize, weight: .semibold, lineHeight: 24, lines: 0)
    stack.addArrangedSubview(subject)
    let (body, coAuthors) = commit.bodyAndCoAuthors
    if !body.isEmpty {
      stack.addArrangedSubview(TextLabel(body, size: Typography.bodySize, color: Palette.textSecondary, lineHeight: 20, lines: 0))
    }
    let author =
      coAuthors.isEmpty
      ? commit.author
      : String(
        format: String(localized: "sourceControl.commitDetail.authorWithCoAuthors", defaultValue: "%1$@, with %2$@"),
        commit.author, coAuthors.joined(separator: ", "))
    let facts = ListGroupView(rows: [
      ListRowView(title: String(localized: "sourceControl.commitDetail.author", defaultValue: "Author"), value: author)
    ])
    if let timestamp = commit.timestamp {
      let date = Date(timeIntervalSince1970: timestamp / 1000).formatted(date: .abbreviated, time: .shortened)
      facts.add(ListRowView(title: String(localized: "sourceControl.commitDetail.date", defaultValue: "Date"), value: date))
    }
    if let pushed = commit.pushed {
      let label = TextLabel(
        pushed
          ? String(localized: "sourceControl.commitDetail.onOrigin", defaultValue: "On origin")
          : String(localized: "sourceControl.commitDetail.notPushed", defaultValue: "Not pushed"),
        size: 15, color: pushed ? Palette.textSecondary : Palette.accentBlue)
      facts.add(ListRowView(title: String(localized: "sourceControl.commitDetail.status", defaultValue: "Status"), accessory: label))
    }
    stack.addArrangedSubview(facts)
    filesStack.axis = .vertical
    filesStack.spacing = Spacing.sm
    stack.addArrangedSubview(filesStack)
    loadFiles()
  }

  private func loadFiles() {
    filesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    filesStack.addArrangedSubview(SectionLabelView(String(localized: "sourceControl.commitDetail.filesHeader", defaultValue: "Files")))
    let spinner = UIActivityIndicatorView(style: .medium)
    spinner.startAnimating()
    filesStack.addArrangedSubview(spinner)
    let api = session.api
    let worktreeId = worktreeId
    let id = commit.id
    Task { [weak self] in
      let result = await PullRequestController.capture { try await api.gitCommitFiles(worktreeId: worktreeId, commitId: id) }
      self?.showFiles(result)
    }
  }

  private func showFiles(_ result: Result<[GitChangedFile], Error>) {
    filesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    switch result {
    case .failure(let error):
      filesStack.addArrangedSubview(
        SectionLabelView(
          String(localized: "sourceControl.commitDetail.filesHeader", defaultValue: "Files"),
          action: (String(localized: "common.retry", defaultValue: "Retry"), { [weak self] in self?.loadFiles() })))
      filesStack.addArrangedSubview(
        TextLabel(PullRequestController.message(error), size: Typography.metaSize, color: Palette.statusRed, lines: 0))
    case .success(let files):
      let header = SectionLabelView(
        String.localizedStringWithFormat(
          String(localized: "sourceControl.commitDetail.files", defaultValue: "%lld files"), files.count))
      filesStack.addArrangedSubview(header)
      guard !files.isEmpty else {
        filesStack.addArrangedSubview(
          TextLabel(
            String(localized: "sourceControl.gitHistoryList.noFileChanges", defaultValue: "No file changes"),
            size: Typography.bodySize, color: Palette.textSecondary))
        return
      }
      let group = ListGroupView()
      for file in files {
        let stat = TextLabel(size: Typography.metaSize)
        stat.font = Typography.mono(Typography.metaSize)
        stat.runs = Self.lineStat(added: file.added ?? 0, removed: file.removed ?? 0)
        let letter = TextLabel(
          GitFileCell.letter(file.status), size: Typography.metaSize, weight: .bold, color: GitFileCell.color(file.status))
        let name = (file.path as NSString).lastPathComponent
        let folder = (file.path as NSString).deletingLastPathComponent
        group.add(ListRowView(title: name, subtitle: folder.isEmpty ? nil : folder, leading: letter, accessory: stat))
      }
      filesStack.addArrangedSubview(group)
    }
  }
}
