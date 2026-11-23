import OrcaCore
import UIKit

/// Start from (source-selection/presentation/SmartWorkspaceSourceDrawer.tsx): the name field docked above the
/// keyboard, the search modes above it, and what the typed text finds: a name to use, the project's issues and pull
/// requests, its branches. Picking a row, Done or Return goes back to the form with the name kept.
final class WorkspaceSourcePickerViewController: UIViewController {
  private enum Mode: CaseIterable {
    case smart, github, branches, text

    var title: String {
      switch self {
      case .smart: String(localized: "tasks.smartSourceModes.smart", defaultValue: "Smart")
      case .github: "GitHub"
      case .branches: String(localized: "tasks.smartSourceModes.branch", defaultValue: "Branch")
      case .text: String(localized: "tasks.smartSourceModes.name", defaultValue: "Name")
      }
    }

    /// shared/new-workspace/smart-workspace-source-results.ts EMPTY_HINT_BY_MODE, English there too.
    var emptyHint: String {
      switch self {
      case .smart: "Start typing to create a name or find a source."
      case .github: "Start typing to search GitHub PRs and issues."
      case .branches: "No matching branches."
      case .text: ""
      }
    }
  }

  private enum Row {
    case useName(String)
    case createBranch(String)
    case item(GitHubWorkItem)
    case branch(BranchRef)
  }

  private let session: HostSession
  private let repo: Repo
  private let onName: (String) -> Void
  private let onPick: (WorkspaceStart, String?) -> Void
  private var mode: Mode
  private var name: String
  private var items: [GitHubWorkItem] = []
  private var branches: [BranchRef] = []
  private var rows: [Row] = []
  private var loading = false
  private var errorText: String?
  private var searchTask: Task<Void, Never>?

  private let table = UITableView(frame: .zero, style: .insetGrouped)
  private let modes = UISegmentedControl()
  private let field = UITextField()

  init(
    session: HostSession, repo: Repo, name: String, onName: @escaping (String) -> Void,
    onPick: @escaping (WorkspaceStart, String?) -> Void
  ) {
    self.session = session
    self.repo = repo
    self.name = name
    self.onName = onName
    self.onPick = onPick
    // A folder only takes a name.
    mode = repo.isFolder ? .text : .smart
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private var availableModes: [Mode] { repo.isFolder ? [.text] : Mode.allCases }

  override func viewDidLoad() {
    super.viewDidLoad()
    title =
      repo.isFolder
      ? String(localized: "components.smartWorkspaceSourceDrawer.workspaceName", defaultValue: "Workspace name")
      : String(localized: "components.smartWorkspaceSourceDrawer.startFrom", defaultValue: "Start from")
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      title: String(localized: "common.done", defaultValue: "Done"), style: .done, target: nil, action: nil)
    navigationItem.rightBarButtonItem?.primaryAction = UIAction(
      title: String(localized: "common.done", defaultValue: "Done")
    ) { [weak self] _ in self?.close() }

    table.dataSource = self
    table.delegate = self
    table.keyboardDismissMode = .none
    table.register(UITableViewCell.self, forCellReuseIdentifier: "row")
    table.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(table)

    for (index, mode) in availableModes.enumerated() {
      modes.insertSegment(withTitle: mode.title, at: index, animated: false)
    }
    modes.selectedSegmentIndex = availableModes.firstIndex(of: mode) ?? 0
    modes.isHidden = availableModes.count < 2
    modes.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.mode = self.availableModes[self.modes.selectedSegmentIndex]
        self.search()
      }, for: .valueChanged)

    field.text = name
    field.placeholder = String(
      localized: "components.smartWorkspaceSourceDrawer.searchPlaceholder", defaultValue: "Type a name or search a source")
    field.font = .systemFont(ofSize: 16)
    field.autocapitalizationType = .none
    field.autocorrectionType = .no
    field.returnKeyType = .done
    field.clearButtonMode = .whileEditing
    field.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.name = self.field.text ?? ""
        self.onName(self.name)
        self.search()
      }, for: .editingChanged)
    field.addAction(UIAction { [weak self] _ in self?.close() }, for: .editingDidEndOnExit)
    let box = UIView()
    box.layer.cornerRadius = Radius.control
    box.layer.cornerCurve = .continuous
    box.layer.borderWidth = 1
    box.layer.borderColor = Palette.accentBlue.resolvedColor(with: traitCollection).cgColor
    field.translatesAutoresizingMaskIntoConstraints = false
    box.addSubview(field)

    let dock = UIStackView(arrangedSubviews: [modes, box])
    dock.axis = .vertical
    dock.spacing = Spacing.sm
    dock.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(dock)
    NSLayoutConstraint.activate([
      table.topAnchor.constraint(equalTo: view.topAnchor),
      table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      table.bottomAnchor.constraint(equalTo: dock.topAnchor, constant: -Spacing.sm),
      dock.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
      dock.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
      dock.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -Spacing.sm),
      box.heightAnchor.constraint(equalToConstant: 44),
      field.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: Spacing.md),
      field.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -Spacing.sm),
      field.topAnchor.constraint(equalTo: box.topAnchor),
      field.bottomAnchor.constraint(equalTo: box.bottomAnchor),
    ])
    search()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    field.becomeFirstResponder()
  }

  private func close() {
    navigationController?.popViewController(animated: true)
  }

  // MARK: Search

  /// What the typed text finds in this mode; a typed burst reads once, 250 ms after it stops.
  private func search() {
    searchTask?.cancel()
    let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let mode = mode
    let wantsItems = mode == .smart || mode == .github
    let wantsBranches = mode == .branches || (mode == .smart && !query.isEmpty)
    if !wantsItems { items = [] }
    if !wantsBranches { branches = [] }
    errorText = nil
    loading = wantsItems || wantsBranches
    rebuild()
    guard loading else { return }
    let api = session.api
    let repo = repo
    searchTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled else { return }
      async let itemsReply: Result<[GitHubWorkItem], Error> = wantsItems ? await Result { try await api.searchWorkItems(repoId: repo.id, repoName: repo.displayName, query: query) } : .success([])
      async let branchesReply: Result<[BranchRef], Error> = wantsBranches ? await Result { try await api.searchBranches(repoId: repo.id, query: query) } : .success([])
      let (foundItems, foundBranches) = await (itemsReply, branchesReply)
      guard !Task.isCancelled, let self else { return }
      self.loading = false
      self.items = (try? foundItems.get()) ?? []
      self.branches = (try? foundBranches.get()) ?? []
      if case .failure(let error) = foundItems, case .failure = foundBranches {
        self.errorText = TasksViewController.message(error)
      } else if case .failure(let error) = foundItems, !wantsBranches {
        self.errorText = TasksViewController.message(error)
      } else if case .failure(let error) = foundBranches, !wantsItems {
        self.errorText = TasksViewController.message(error)
      }
      self.rebuild()
    }
  }

  /// shared/new-workspace/smart-workspace-source-results.ts buildSmartWorkspaceSourceRows, for these modes.
  private func rebuild() {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    var next: [Row] = []
    if !trimmed.isEmpty, mode == .smart { next.append(.useName(trimmed)) }
    if mode != .text {
      if mode == .smart || mode == .github { next += items.map(Row.item) }
      if mode == .branches || (mode == .smart && !trimmed.isEmpty) {
        let exact = branches.contains { $0.label == trimmed || $0.localBranchName == trimmed }
        if !trimmed.isEmpty, mode == .branches, !exact { next.append(.createBranch(trimmed)) }
        next += branches.map(Row.branch)
      }
    }
    rows = next
    table.reloadData()
    updateFooter()
  }

  private func updateFooter() {
    let text: String?
    if let errorText {
      text = errorText
    } else if loading {
      text = nil
    } else if mode == .text, rows.isEmpty {
      text = String(
        localized: "components.smartWorkspaceSourceDrawer.typeWorkspaceName",
        defaultValue: "Type a workspace name in the field below.")
    } else if rows.isEmpty {
      text =
        mode.emptyHint.isEmpty || !name.trimmingCharacters(in: .whitespaces).isEmpty
        ? String(localized: "components.smartWorkspaceSourceDrawer.noResults", defaultValue: "No results found.")
        : mode.emptyHint
    } else {
      text = nil
    }
    let footer = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: loading || text != nil ? 64 : 0))
    if loading && rows.isEmpty {
      let spinner = UIActivityIndicatorView(style: .medium)
      spinner.startAnimating()
      spinner.translatesAutoresizingMaskIntoConstraints = false
      footer.addSubview(spinner)
      spinner.centerXAnchor.constraint(equalTo: footer.centerXAnchor).isActive = true
      spinner.centerYAnchor.constraint(equalTo: footer.centerYAnchor).isActive = true
    } else if let text {
      let label = UILabel()
      label.text = text
      label.font = .systemFont(ofSize: 14)
      label.textColor = errorText == nil ? Palette.textSecondary : Palette.statusRed
      label.textAlignment = .center
      label.numberOfLines = 0
      label.translatesAutoresizingMaskIntoConstraints = false
      footer.addSubview(label)
      NSLayoutConstraint.activate([
        label.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: Spacing.xl),
        label.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -Spacing.xl),
        label.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
      ])
    }
    table.tableFooterView = footer
  }

  private func pick(_ row: Row) {
    switch row {
    case .useName(let text): onPick(.name, text)
    case .createBranch(let branch): onPick(.newBranch(branch), branch)
    case .item(let item):
      let seed = WorkspaceStart.slug(item.title)
      onPick(.workItem(item), seed.isEmpty ? "\(item.kind == .pr ? "pr" : "issue")-\(item.number)" : seed)
    case .branch(let ref): onPick(.branch(ref), ref.localBranchName)
    }
    close()
  }
}

extension WorkspaceSourcePickerViewController: UITableViewDataSource, UITableViewDelegate {
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
    var content = UIListContentConfiguration.subtitleCell()
    content.secondaryTextProperties.color = Palette.textSecondary
    content.imageProperties.reservedLayoutSize = CGSize(width: 22, height: 22)
    content.imageProperties.tintColor = Palette.textSecondary
    cell.accessoryView = nil
    // SmartWorkspaceSourceRow.tsx: each kind's glyph, title and second line.
    switch rows[indexPath.row] {
    case .useName(let text):
      content.image = Lucide.sparkles.image(size: 18)
      content.text = String(
        format: String(localized: "components.smartWorkspaceSourceRow.useName", defaultValue: "Use \"%@\""), text)
      content.secondaryText = String(
        localized: "components.smartWorkspaceSourceRow.nameWorkspace", defaultValue: "Name this workspace")
    case .createBranch(let branch):
      content.image = Lucide.gitBranch.image(size: 18)
      content.imageProperties.tintColor = Palette.accentBlue
      content.text = String(
        format: String(localized: "components.smartWorkspaceSourceRow.createBranch", defaultValue: "Create branch \"%@\""),
        branch)
      content.secondaryText = String(localized: "components.smartWorkspaceSourceRow.newBranch", defaultValue: "New branch")
    case .item(let item):
      content.image = (item.kind == .pr ? Lucide.gitPullRequest : Lucide.circleDot).image(size: 18)
      content.text = item.title
      content.secondaryText =
        item.kind == .pr
        ? String(
          format: String(localized: "components.smartWorkspaceSourceRow.pullRequest", defaultValue: "PR #%@"),
          "\(item.number)")
        : String(
          format: String(localized: "components.smartWorkspaceSourceRow.issue", defaultValue: "Issue #%@"),
          "\(item.number)")
      cell.accessoryView = Self.pill(item.state)
    case .branch(let ref):
      content.image = Lucide.gitBranch.image(size: 18)
      content.text = ref.label
      content.secondaryText = ref.localBranchName != ref.label ? ref.localBranchName : nil
    }
    content.textProperties.numberOfLines = 1
    cell.contentConfiguration = content
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    Haptics.select()
    tableView.deselectRow(at: indexPath, animated: true)
    pick(rows[indexPath.row])
  }

  /// The state, capitalised in a small pill.
  private static func pill(_ state: String) -> UIView {
    let label = StatePillLabel()
    label.text = state.capitalized
    label.font = .systemFont(ofSize: 11, weight: .semibold)
    label.textColor = Palette.textSecondary
    label.backgroundColor = Palette.sheetSurface
    label.layer.cornerRadius = 9
    label.layer.masksToBounds = true
    label.sizeToFit()
    return label
  }
}

/// A label with the pill's 8 pt sides and 2 pt top and bottom.
private final class StatePillLabel: UILabel {
  private let insets = UIEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)

  override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }

  override var intrinsicContentSize: CGSize {
    let size = super.intrinsicContentSize
    return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
  }

  override func sizeThatFits(_ size: CGSize) -> CGSize { intrinsicContentSize }
}
