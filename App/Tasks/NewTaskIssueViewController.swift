import OrcaCore
import UIKit

/// New issue (workspace-creation/mobile-tasks-create-drawers.tsx): where it goes (a repository for GitHub, a team
/// for Linear), a fork's issue source, a title and a description.
final class NewTaskIssueViewController: UITableViewController {
  /// Where an issue can be filed: its picker label and, for a repository, its badge colour.
  struct Target {
    var id: String
    var label: String
    var detail: String?
  }

  /// A fork's choice of where issues are filed: the two slugs and the one in use.
  struct IssueSource {
    var upstream: String
    var origin: String
    var usesOrigin: Bool
  }

  private let providerLabel: String
  private let isLinear: Bool
  private let targets: [Target]
  private var target: Target
  private let issueSource: (String) -> IssueSource?
  private let setIssueSource: (String, Bool) async throws -> Void
  private let create: (String, String, String) async throws -> Void
  private let onCreated: () -> Void
  private let titleField = UITextField()
  private let bodyView = UITextView()
  private var creating = false

  init(
    providerLabel: String, isLinear: Bool, targets: [Target], selected: String?,
    issueSource: @escaping (String) -> IssueSource? = { _ in nil },
    setIssueSource: @escaping (String, Bool) async throws -> Void = { _, _ in },
    create: @escaping (String, String, String) async throws -> Void, onCreated: @escaping () -> Void
  ) {
    self.providerLabel = providerLabel
    self.isLinear = isLinear
    self.targets = targets
    target = targets.first { $0.id == selected } ?? targets[0]
    self.issueSource = issueSource
    self.setIssueSource = setIssueSource
    self.create = create
    self.onCreated = onCreated
    super.init(style: .insetGrouped)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(
      format: String(localized: "tasks.tasksCreateDrawers.newIssueTitle", defaultValue: "New %@ Issue"), providerLabel)
    navigationItem.subtitle =
      isLinear
      ? String(
        localized: "tasks.tasksCreateDrawers.linearTeamSubtitle", defaultValue: "Create an issue in the selected Linear team.")
      : String(
        localized: "tasks.tasksCreateDrawers.repositorySubtitle",
        defaultValue: "Create an issue in the selected repository.")
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
    let submit = UIBarButtonItem(
      title: String(localized: "tasks.tasksCreateDrawers.createIssue", defaultValue: "Create Issue"), style: .prominent,
      target: nil, action: nil)
    submit.primaryAction = UIAction(
      title: String(localized: "tasks.tasksCreateDrawers.createIssue", defaultValue: "Create Issue")
    ) { [weak self] _ in self?.submit() }
    navigationItem.rightBarButtonItem = submit
    tableView.backgroundColor = Palette.bgBase
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
    titleField.placeholder = String(localized: "tasks.tasksCreateDrawers.titlePlaceholder", defaultValue: "Task title")
    titleField.font = .systemFont(ofSize: 17)
    titleField.addAction(UIAction { [weak self] _ in self?.updateSubmit() }, for: .editingChanged)
    bodyView.font = .systemFont(ofSize: 17)
    bodyView.backgroundColor = .clear
    bodyView.textContainerInset = .zero
    bodyView.textContainer.lineFragmentPadding = 0
    updateSubmit()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    titleField.becomeFirstResponder()
  }

  private var issueTitle: String { (titleField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

  private func updateSubmit() {
    navigationItem.rightBarButtonItem?.isEnabled = !issueTitle.isEmpty && !creating
  }

  private func submit() {
    guard !issueTitle.isEmpty, !creating else { return }
    creating = true
    updateSubmit()
    let target = target
    let title = issueTitle
    let body = bodyView.text ?? ""
    Task {
      do {
        try await create(target.id, title, body)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss(animated: true) { self.onCreated() }
      } catch {
        creating = false
        updateSubmit()
        alert(TasksViewController.message(error))
      }
    }
  }

  private func alert(_ message: String) {
    let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: String(localized: "common.ok", defaultValue: "OK"), style: .default))
    present(alert, animated: true)
  }

  private enum Section { case target, source, title, body }

  private var layout: [Section] {
    issueSource(target.id) == nil ? [.target, .title, .body] : [.target, .source, .title, .body]
  }

  override func numberOfSections(in tableView: UITableView) -> Int { layout.count }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }

  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    switch layout[section] {
    case .target:
      isLinear
        ? String(localized: "tasks.tasksCreateDrawers.team", defaultValue: "Team")
        : String(localized: "tasks.tasksCreateDrawers.repository", defaultValue: "Repository")
    case .source: String(localized: "tasks.tasksCreateDrawers.issueSource", defaultValue: "Issue source")
    case .title: String(localized: "tasks.tasksCreateDrawers.title", defaultValue: "Title")
    case .body: String(localized: "tasks.tasksCreateDrawers.description", defaultValue: "Description")
    }
  }

  override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
    guard layout[section] == .source, let source = issueSource(target.id) else { return nil }
    return String(
      format: String(localized: "tasks.tasksCreateDrawers.fileIn", defaultValue: "File in %@"),
      source.usesOrigin ? source.origin : source.upstream)
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
    cell.backgroundColor = Palette.bgPanel
    cell.selectionStyle = .none
    cell.contentView.subviews.filter { $0 === titleField || $0 === bodyView || $0 is UIButton || $0 is UISegmentedControl }
      .forEach { $0.removeFromSuperview() }
    cell.contentConfiguration = nil
    cell.accessoryView = nil
    switch layout[indexPath.section] {
    case .target:
      var content = UIListContentConfiguration.subtitleCell()
      content.text = target.label
      content.secondaryText = target.detail
      content.secondaryTextProperties.color = Palette.textSecondary
      cell.contentConfiguration = content
      let picker = UIButton(type: .system)
      picker.showsMenuAsPrimaryAction = true
      picker.menu = UIMenu(
        title: isLinear
          ? String(localized: "tasks.tasksCreateDrawers.linearTeam", defaultValue: "Linear Team")
          : String(localized: "tasks.tasksCreateDrawers.repository", defaultValue: "Repository"),
        children: targets.map { choice in
          UIAction(title: choice.label, subtitle: choice.detail, state: choice.id == target.id ? .on : .off) {
            [weak self] _ in
            self?.target = choice
            self?.tableView.reloadData()
          }
        })
      picker.translatesAutoresizingMaskIntoConstraints = false
      cell.contentView.addSubview(picker)
      picker.pin(to: cell.contentView)
      let chevrons = UIImageView(image: Lucide.chevronsUpDown.image(size: 14))
      chevrons.tintColor = Palette.textMuted
      cell.accessoryView = chevrons
    case .source:
      let source = issueSource(target.id)
      let control = UISegmentedControl(items: [
        String(localized: "tasks.tasksCreateDrawers.upstream", defaultValue: "Upstream"),
        String(localized: "tasks.tasksCreateDrawers.origin", defaultValue: "Origin"),
      ])
      control.selectedSegmentIndex = source?.usesOrigin == true ? 1 : 0
      let id = target.id
      control.addAction(
        UIAction { [weak self, weak control] _ in
          guard let self, let control else { return }
          Haptics.select()
          let origin = control.selectedSegmentIndex == 1
          Task {
            do {
              try await self.setIssueSource(id, origin)
            } catch {
              self.alert(TasksViewController.message(error))
            }
            self.tableView.reloadData()
          }
        }, for: .valueChanged)
      control.translatesAutoresizingMaskIntoConstraints = false
      cell.contentView.addSubview(control)
      NSLayoutConstraint.activate([
        control.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
        control.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
        control.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: Spacing.sm),
        control.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -Spacing.sm),
        control.heightAnchor.constraint(equalToConstant: 32),
      ])
    case .title:
      embed(titleField, in: cell, height: 44)
    case .body:
      embed(bodyView, in: cell, height: 140)
    }
    return cell
  }

  private func embed(_ field: UIView, in cell: UITableViewCell, height: CGFloat) {
    field.translatesAutoresizingMaskIntoConstraints = false
    cell.contentView.addSubview(field)
    NSLayoutConstraint.activate([
      field.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
      field.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
      field.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: height > 44 ? Spacing.md : 0),
      field.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: height > 44 ? -Spacing.md : 0),
      field.heightAnchor.constraint(equalToConstant: height > 44 ? height - 2 * Spacing.md : height),
    ])
  }
}
