import OrcaCore
import UIKit

/// New workspace: the project, a name, and optionally an agent to start in it. Create makes it on this desktop
/// and opens it.
final class NewWorkspaceViewController: UITableViewController {
  private struct Agent {
    let id: String?
    let title: String
    let mark: FilledIcon?
  }

  private static let agents = [
    Agent(id: nil, title: String(localized: "hostScreen.workspaceOptionControls.none", defaultValue: "None"), mark: nil),
    Agent(id: "claude", title: "Claude Code", mark: AgentMark.claude),
    Agent(id: "codex", title: "Codex", mark: AgentMark.codex),
  ]

  private let session: HostSession
  private let projects: [Repo]
  private let onCreated: (String) -> Void
  private var project: Repo?
  private var agent = agents[0]
  private let nameField = UITextField()
  private var creating = false

  init(session: HostSession, projects: [Repo], onCreated: @escaping (String) -> Void) {
    self.session = session
    self.projects = projects
    self.onCreated = onCreated
    project = projects.first
    super.init(style: .insetGrouped)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  static func sheet(session: HostSession, projects: [Repo], onCreated: @escaping (String) -> Void) -> UIViewController {
    let navigation = UINavigationController(
      rootViewController: NewWorkspaceViewController(session: session, projects: projects, onCreated: onCreated))
    if let sheet = navigation.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
    }
    return navigation
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(localized: "hostScreen.hostBottomBar.newWorkspace", defaultValue: "New workspace")
    navigationItem.subtitle = session.name
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
    let create = UIBarButtonItem(
      title: String(localized: "bots.new.create", defaultValue: "Create"), style: .prominent, target: nil, action: nil)
    create.primaryAction = UIAction(title: String(localized: "bots.new.create", defaultValue: "Create")) {
      [weak self] _ in self?.create()
    }
    navigationItem.rightBarButtonItem = create
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
    tableView.keyboardDismissMode = .interactive

    nameField.placeholder = String(
      localized: "components.newWorktreeFormSheet.workspaceName", defaultValue: "Workspace name")
    nameField.font = .systemFont(ofSize: 17)
    nameField.returnKeyType = .done
    nameField.autocorrectionType = .no
    nameField.autocapitalizationType = .none
    nameField.clearButtonMode = .whileEditing
    nameField.addAction(UIAction { [weak self] _ in self?.updateCreate() }, for: .editingChanged)
    nameField.addAction(UIAction { [weak self] _ in self?.create() }, for: .editingDidEndOnExit)
    updateCreate()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    nameField.becomeFirstResponder()
  }

  private var name: String { (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

  private func updateCreate() {
    navigationItem.rightBarButtonItem?.isEnabled = !name.isEmpty && project != nil && !creating
  }

  private func create() {
    guard !name.isEmpty, let project, !creating else { return }
    creating = true
    updateCreate()
    nameField.resignFirstResponder()
    let api = session.api
    let name = name
    let agent = agent.id
    Task {
      do {
        guard let id = try await api.createWorktree(repoId: project.id, name: name, agent: agent) else {
          throw CancellationError()
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        await session.refresh()
        dismiss(animated: true) { self.onCreated(id) }
      } catch {
        creating = false
        updateCreate()
        let alert = UIAlertController(
          title: String(localized: "newWorkspace.loadingDrawer.failed", defaultValue: "Couldn’t create the workspace"),
          message: (error as? LocalizedError)?.errorDescription ?? "\(error)", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "common.ok", defaultValue: "OK"), style: .default))
        present(alert, animated: true)
      }
    }
  }

  // MARK: Table

  override func numberOfSections(in tableView: UITableView) -> Int { 2 }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    section == 0 ? 1 : 2
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
    cell.selectionStyle = .none
    cell.contentView.subviews.filter { $0 is UIButton }.forEach { $0.removeFromSuperview() }
    cell.accessoryView = nil
    if indexPath.section == 0 {
      cell.contentConfiguration = nil
      if nameField.superview !== cell.contentView {
        nameField.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(nameField)
        NSLayoutConstraint.activate([
          nameField.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
          nameField.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
          nameField.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
          nameField.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor),
          nameField.heightAnchor.constraint(equalToConstant: 52),
        ])
      }
      return cell
    }
    var content = UIListContentConfiguration.valueCell()
    let menu: UIMenu
    if indexPath.row == 0 {
      content.text = String(localized: "components.newWorktreeModalDrawers.project", defaultValue: "Project")
      content.secondaryText = project?.displayName
      menu = UIMenu(
        children: projects.map { repo in
          UIAction(title: repo.displayName, state: repo.id == project?.id ? .on : .off) { [weak self] _ in
            self?.project = repo
            self?.tableView.reloadSections([1], with: .none)
            self?.updateCreate()
          }
        })
    } else {
      content.text = String(localized: "bots.new.agent", defaultValue: "Agent")
      content.secondaryText = agent.title
      menu = UIMenu(
        children: Self.agents.map { choice in
          UIAction(title: choice.title, image: choice.mark?.image(size: 18), state: choice.id == agent.id ? .on : .off) {
            [weak self] _ in
            self?.agent = choice
            self?.tableView.reloadSections([1], with: .none)
          }
        })
    }
    cell.contentConfiguration = content
    // The whole row opens its choices.
    let picker = UIButton(type: .system)
    picker.showsMenuAsPrimaryAction = true
    picker.menu = menu
    picker.translatesAutoresizingMaskIntoConstraints = false
    cell.contentView.addSubview(picker)
    picker.pin(to: cell.contentView)
    let chevrons = UIImageView(image: Lucide.chevronsUpDown.image(size: 14))
    chevrons.tintColor = Palette.textMuted
    cell.accessoryView = chevrons
    return cell
  }
}
