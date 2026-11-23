import OrcaCore
import UIKit

/// Workspace options (workspace-options/workspace-options-sheet.tsx): grouping, order and filters, saved to the
/// desktop so every client shows the same list. A system sheet with a grouped list; pages push inside it.
final class WorkspaceOptionsViewController: UITableViewController {
  struct Project {
    let id: String
    let name: String
  }

  private enum Row {
    case projects
    case groupBy
    case sortBy
    case projectOrder
    case filter(String, WritableKeyPath<WorkspaceView, Bool>)
  }

  private var workspaceView: WorkspaceView
  private let projects: [Project]
  private let onChange: (WorkspaceView) -> Void
  private var sections: [(title: String?, rows: [Row])] = []

  init(view: WorkspaceView, projects: [Project], onChange: @escaping (WorkspaceView) -> Void) {
    workspaceView = view
    self.projects = projects
    self.onChange = onChange
    super.init(style: .insetGrouped)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// The sheet, in its own navigation stack so option pages push inside it.
  static func sheet(view: WorkspaceView, projects: [Project], onChange: @escaping (WorkspaceView) -> Void)
    -> UIViewController
  {
    let navigation = UINavigationController(
      rootViewController: WorkspaceOptionsViewController(view: view, projects: projects, onChange: onChange))
    if let sheet = navigation.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
    }
    return navigation
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(localized: "hostScreen.workspaceOptionsSheet.workspaceOptions", defaultValue: "Workspace options")
    navigationItem.subtitle = String(
      localized: "hostScreen.workspaceOptionsSheet.syncedAcrossDevices", defaultValue: "Synced across your devices")
    navigationItem.largeTitleDisplayMode = .never
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      title: String(localized: "hostScreen.workspaceOptionsSheet.reset", defaultValue: "Reset"),
      primaryAction: UIAction { [weak self] _ in
        guard let self else { return }
        self.update(self.workspaceView.cleared)
      })
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      title: String(localized: "hostScreen.workspaceOptionsSheet.done", defaultValue: "Done"), style: .prominent,
      target: nil, action: nil)
    navigationItem.rightBarButtonItem?.primaryAction = UIAction(
      title: String(localized: "hostScreen.workspaceOptionsSheet.done", defaultValue: "Done")
    ) { [weak self] _ in self?.dismiss(animated: true) }
    // The half-height sheet keeps its Liquid Glass behind the rows.
    tableView.backgroundColor = .clear
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
    rebuild()
  }

  private func update(_ view: WorkspaceView) {
    guard view != workspaceView else { return }
    workspaceView = view
    onChange(view)
    rebuild()
  }

  private func rebuild() {
    navigationItem.leftBarButtonItem?.isEnabled = workspaceView.activeFilterCount > 0
    sections = []
    if projects.count > 1 {
      sections.append((String(localized: "hostScreen.workspaceOptionsSheet.show", defaultValue: "Show"), [.projects]))
    }
    sections.append((String(localized: "hostScreen.workspaceOptionsSheet.groupBy", defaultValue: "Group by"), [.groupBy]))
    sections.append((nil, workspaceView.groupBy == "repo" ? [.sortBy, .projectOrder] : [.sortBy]))
    var filters: [Row] = [
      .filter(String(localized: "hostScreen.workspaceOptionsSheet.hideSleeping", defaultValue: "Hide sleeping"), \.hideSleeping)
    ]
    // The exemption only bites while sleeping workspaces are being swept.
    if workspaceView.hideSleeping {
      filters.append(
        .filter(
          String(localized: "hostScreen.workspaceOptionsSheet.exceptDefaultBranch", defaultValue: "Except default branch"),
          \.alwaysShowDefaultBranch))
    }
    filters += [
      .filter(
        String(localized: "hostScreen.workspaceOptionsSheet.hideDefaultBranch", defaultValue: "Hide default branch"),
        \.hideDefaultBranch),
      .filter(
        String(localized: "hostScreen.workspaceOptionsSheet.hideAutomationCreated", defaultValue: "Hide automation-created"),
        \.hideAutomationCreated),
      .filter(
        String(localized: "hostScreen.workspaceOptionsSheet.hideCliCreated", defaultValue: "Hide CLI-created"),
        \.hideCliCreated),
      .filter(
        String(localized: "hostScreen.workspaceOptionsSheet.hideDetachedHead", defaultValue: "Hide detached HEAD"),
        \.hideDetachedHead),
    ]
    sections.append((String(localized: "hostScreen.workspaceOptionsSheet.filters", defaultValue: "Filters"), filters))
    tableView.reloadData()
  }

  // MARK: Choices

  static var groupByChoices: [OptionChoice] {
    [
      OptionChoice(id: "none", title: String(localized: "hostScreen.workspaceOptionControls.none", defaultValue: "None")),
      OptionChoice(
        id: "workspace-status", title: String(localized: "hostScreen.workspaceOptionControls.status", defaultValue: "Status")),
      OptionChoice(id: "pr-status", title: String(localized: "hostScreen.workspaceOptionControls.pr", defaultValue: "PR")),
      OptionChoice(id: "repo", title: String(localized: "hostScreen.workspaceOptionControls.project", defaultValue: "Project")),
    ]
  }

  static var sortByChoices: [OptionChoice] {
    [
      OptionChoice(id: "name", title: String(localized: "hostScreen.workspaceOptionControls.name", defaultValue: "Name")),
      OptionChoice(
        id: "smart",
        title: String(localized: "hostScreen.workspaceOptionControls.agentActivitySort", defaultValue: "Agent Activity"),
        detail: String(
          localized: "hostScreen.workspaceOptionControls.agentActivitySortDescription",
          defaultValue: "Agents that need attention, then most recent activity.")),
      OptionChoice(id: "recent", title: String(localized: "hostScreen.workspaceOptionControls.recent", defaultValue: "Recent")),
      OptionChoice(id: "repo", title: String(localized: "hostScreen.workspaceOptionControls.project", defaultValue: "Project")),
      OptionChoice(
        id: "manual", title: String(localized: "hostScreen.workspaceOptionControls.manual", defaultValue: "Manual"),
        detail: String(
          localized: "hostScreen.workspaceOptionControls.manualWorkspaceOrderDescription",
          defaultValue: "Drag workspaces to arrange them within each group.")),
    ]
  }

  static var projectOrderChoices: [OptionChoice] {
    [
      OptionChoice(
        id: "manual", title: String(localized: "hostScreen.workspaceOptionControls.manual", defaultValue: "Manual"),
        detail: String(
          localized: "hostScreen.workspaceOptionControls.manualProjectOrderDescription",
          defaultValue: "Drag projects to arrange them")),
      OptionChoice(
        id: "recent", title: String(localized: "hostScreen.workspaceOptionControls.recent", defaultValue: "Recent"),
        detail: String(
          localized: "hostScreen.workspaceOptionControls.recentProjectOrderDescription",
          defaultValue: "Most recent workspace activity")),
    ]
  }

  private var projectsValue: String {
    let listed = projects.filter { workspaceView.filterRepoIds.contains($0.id) }
    if listed.isEmpty || listed.count == projects.count {
      return String(localized: "hostScreen.workspaceOptionControls.allProjects", defaultValue: "All projects")
    }
    return listed.count == 1 ? listed[0].name : "\(listed.count)/\(projects.count)"
  }

  // MARK: Table

  override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    sections[section].rows.count
  }

  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    sections[section].title
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
    cell.accessoryView = nil
    cell.accessoryType = .none
    cell.selectionStyle = .default
    cell.contentView.subviews.filter { $0 is UISegmentedControl }.forEach { $0.removeFromSuperview() }
    var content = UIListContentConfiguration.valueCell()
    switch sections[indexPath.section].rows[indexPath.row] {
    case .projects:
      content.text = String(localized: "hostScreen.workspaceOptionsSheet.projects", defaultValue: "Projects")
      content.secondaryText = projectsValue
      cell.accessoryType = .disclosureIndicator
    case .sortBy:
      content.text = String(localized: "hostScreen.workspaceOptionsSheet.sortBy", defaultValue: "Sort by")
      content.secondaryText = Self.sortByChoices.first { $0.id == workspaceView.sortBy }?.title
      cell.accessoryType = .disclosureIndicator
    case .projectOrder:
      content.text = String(localized: "hostScreen.workspaceOptionsSheet.projectOrder", defaultValue: "Project order")
      content.secondaryText = Self.projectOrderChoices.first { $0.id == workspaceView.projectOrderBy }?.title
      cell.accessoryType = .disclosureIndicator
    case .groupBy:
      cell.contentConfiguration = nil
      cell.selectionStyle = .none
      let choices = Self.groupByChoices
      let control = UISegmentedControl(
        items: choices.map(\.title))
      control.selectedSegmentIndex = choices.firstIndex { $0.id == workspaceView.groupBy } ?? UISegmentedControl.noSegment
      control.addAction(
        UIAction { [weak self, weak control] _ in
          guard let self, let index = control?.selectedSegmentIndex, choices.indices.contains(index) else { return }
          var view = self.workspaceView
          view.groupBy = choices[index].id
          self.update(view)
        }, for: .valueChanged)
      control.translatesAutoresizingMaskIntoConstraints = false
      cell.contentView.addSubview(control)
      NSLayoutConstraint.activate([
        control.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
        control.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
        control.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: Spacing.sm),
        control.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -Spacing.sm),
      ])
      return cell
    case .filter(let title, let path):
      content.text = title
      cell.selectionStyle = .none
      let toggle = UISwitch()
      toggle.isOn = workspaceView[keyPath: path]
      toggle.addAction(
        UIAction { [weak self, weak toggle] _ in
          guard let self, let toggle else { return }
          var view = self.workspaceView
          view[keyPath: path] = toggle.isOn
          self.update(view)
        }, for: .valueChanged)
      cell.accessoryView = toggle
    }
    cell.contentConfiguration = content
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    Haptics.select()
    tableView.deselectRow(at: indexPath, animated: true)
    let page: UIViewController
    switch sections[indexPath.section].rows[indexPath.row] {
    case .sortBy:
      page = OptionChoiceViewController(
        title: String(localized: "hostScreen.workspaceOptionsSheet.sortBy", defaultValue: "Sort by"),
        choices: Self.sortByChoices, selected: [workspaceView.sortBy], multiple: false
      ) { [weak self] picked in
        guard let self, let id = picked.first else { return }
        var view = self.workspaceView
        view.sortBy = id
        self.update(view)
      }
    case .projectOrder:
      page = OptionChoiceViewController(
        title: String(localized: "hostScreen.workspaceOptionsSheet.projectOrder", defaultValue: "Project order"),
        choices: Self.projectOrderChoices, selected: [workspaceView.projectOrderBy], multiple: false
      ) { [weak self] picked in
        guard let self, let id = picked.first else { return }
        var view = self.workspaceView
        view.projectOrderBy = id
        self.update(view)
      }
    case .projects:
      // No project listed means all of them; the page shows that as every row checked.
      let listed = workspaceView.filterRepoIds.filter { id in projects.contains { $0.id == id } }
      page = OptionChoiceViewController(
        title: String(localized: "hostScreen.workspaceOptionsSheet.projects", defaultValue: "Projects"),
        choices: projects.map { OptionChoice(id: $0.id, title: $0.name) },
        selected: Set(listed.isEmpty ? projects.map(\.id) : listed), multiple: true
      ) { [weak self] picked in
        guard let self else { return }
        var view = self.workspaceView
        view.filterRepoIds = picked.count == self.projects.count ? [] : self.projects.map(\.id).filter(picked.contains)
        self.update(view)
      }
    default:
      return
    }
    navigationController?.pushViewController(page, animated: true)
  }
}

struct OptionChoice {
  let id: String
  let title: String
  var detail: String? = nil
}

/// One option's page: its choices with a check, one or several.
final class OptionChoiceViewController: UITableViewController {
  private let choices: [OptionChoice]
  private var selected: Set<String>
  private let multiple: Bool
  private let onPick: (Set<String>) -> Void

  init(title: String, choices: [OptionChoice], selected: Set<String>, multiple: Bool, onPick: @escaping (Set<String>) -> Void) {
    self.choices = choices
    self.selected = selected
    self.multiple = multiple
    self.onPick = onPick
    super.init(style: .insetGrouped)
    self.title = title
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      title: String(localized: "hostScreen.workspaceOptionsSheet.done", defaultValue: "Done"), style: .prominent,
      target: nil, action: nil)
    navigationItem.rightBarButtonItem?.primaryAction = UIAction(
      title: String(localized: "hostScreen.workspaceOptionsSheet.done", defaultValue: "Done")
    ) { [weak self] _ in self?.dismiss(animated: true) }
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "choice")
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { choices.count }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let choice = choices[indexPath.row]
    let cell = tableView.dequeueReusableCell(withIdentifier: "choice", for: indexPath)
    var content = UIListContentConfiguration.subtitleCell()
    content.text = choice.title
    content.secondaryText = choice.detail
    content.secondaryTextProperties.color = Palette.textSecondary
    cell.contentConfiguration = content
    cell.accessoryType = selected.contains(choice.id) ? .checkmark : .none
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
  Haptics.select()
    tableView.deselectRow(at: indexPath, animated: true)
    let id = choices[indexPath.row].id
    if multiple {
      // At least one stays checked; none listed would mean all again.
      if selected.contains(id) {
        guard selected.count > 1 else { return }
        selected.remove(id)
      } else {
        selected.insert(id)
      }
    } else {
      selected = [id]
    }
    UISelectionFeedbackGenerator().selectionChanged()
    tableView.reloadData()
    onPick(selected)
    if !multiple { navigationController?.popViewController(animated: true) }
  }
}
