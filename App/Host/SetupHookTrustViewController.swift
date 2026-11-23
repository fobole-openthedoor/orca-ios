import OrcaCore
import UIKit

/// Run setup from this repository? (components/hook-trust/OrcaHookTrustDrawer.tsx): what the setup script runs,
/// and Always trust, Run once (Run hooks when only this version can be approved) or Don't run.
final class SetupHookTrustViewController: UITableViewController {
  struct Prompt {
    var repoId: String
    var repoName: String
    var script: SetupHookScript
    var previouslyApproved: Bool
    /// The repository id is on several hosts, so only this version can be approved.
    var versionOnly: Bool
    /// The workspace exists; its branch's setup differs from the one approved and didn't run.
    var createdBranch: Bool
  }

  private enum Action { case alwaysTrust, runOnce, dontRun }

  private let prompt: Prompt
  private let onAnswer: (_ run: Bool, _ alwaysTrust: Bool) -> Void
  private var busy = false

  init(prompt: Prompt, onAnswer: @escaping (_ run: Bool, _ alwaysTrust: Bool) -> Void) {
    self.prompt = prompt
    self.onAnswer = onAnswer
    super.init(style: .insetGrouped)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private var repoWideTrust: Bool { !prompt.versionOnly }

  private var actions: [Action] { repoWideTrust ? [.alwaysTrust, .runOnce, .dontRun] : [.runOnce, .dontRun] }

  override func viewDidLoad() {
    super.viewDidLoad()
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    // Answering is the only way on; going back would leave the create half asked.
    navigationItem.hidesBackButton = true
    tableView.tableHeaderView = header()
  }

  /// A question too long for the bar heads the page instead.
  private var heading: String {
    let changed = prompt.versionOnly && prompt.previouslyApproved
    if prompt.createdBranch {
      return String(
        localized: "components.setupHookTrustDrawer.branchDiffersTitle",
        defaultValue: "This workspace's branch has different setup commands")
    } else if changed {
      return String(
        format: String(
          localized: "components.setupHookTrustDrawer.scriptChangedTitle", defaultValue: "%1$@'s setup script changed"),
        prompt.repoName)
    } else {
      return String(
        format: String(localized: "components.setupHookTrustDrawer.runSetupTitle", defaultValue: "Run setup from %1$@?"),
        prompt.repoName)
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    guard let header = tableView.tableHeaderView else { return }
    let height = header.systemLayoutSizeFitting(
      CGSize(width: tableView.bounds.width, height: 0), withHorizontalFittingPriority: .required,
      verticalFittingPriority: .fittingSizeLevel
    ).height
    if header.frame.height != height {
      header.frame.size.height = height
      tableView.tableHeaderView = header
    }
  }

  /// The description, the script in a box, and what Always trust covers.
  private func header() -> UIView {
    let headingLabel = UILabel()
    headingLabel.font = .systemFont(ofSize: 22, weight: .bold)
    headingLabel.textColor = Palette.textPrimary
    headingLabel.numberOfLines = 0
    headingLabel.text = heading
    headingLabel.accessibilityTraits = .header
    let description = UILabel()
    description.font = .systemFont(ofSize: 14)
    description.textColor = Palette.textSecondary
    description.numberOfLines = 0
    description.text =
      prompt.createdBranch
      ? String(
        localized: "components.setupHookTrustDrawer.branchDiffersDescription",
        defaultValue:
          "The workspace was created, but its setup didn't run: its branch's orca.yaml differs from what you approved. Run it in this workspace only if you trust this repository."
      )
      : String(
        localized: "components.setupHookTrustDrawer.description",
        defaultValue:
          "This repository's orca.yaml runs before the workspace starts. Only run it if you trust this repository.")

    let scriptLabel = UILabel()
    scriptLabel.font = .systemFont(ofSize: 12, weight: .semibold)
    scriptLabel.textColor = Palette.textSecondary
    scriptLabel.text =
      prompt.createdBranch
      ? String(localized: "components.setupHookTrustDrawer.branchSetupLabel", defaultValue: "Branch's setup script")
      : prompt.versionOnly && prompt.previouslyApproved
        ? String(localized: "components.setupHookTrustDrawer.newScriptLabel", defaultValue: "New setup script")
        : String(localized: "components.setupHookTrustDrawer.scriptLabel", defaultValue: "Setup script")
    let script = UILabel()
    script.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    script.textColor = Palette.textPrimary
    script.numberOfLines = 0
    script.text = prompt.script.scriptContent
    let box = UIStackView(arrangedSubviews: [scriptLabel, script])
    box.axis = .vertical
    box.spacing = Spacing.xs
    box.isLayoutMarginsRelativeArrangement = true
    box.directionalLayoutMargins = .init(top: Spacing.md, leading: Spacing.md, bottom: Spacing.md, trailing: Spacing.md)
    box.backgroundColor = Palette.sheetSurface
    box.layer.cornerRadius = Radius.control
    box.layer.cornerCurve = .continuous

    var views: [UIView] = [headingLabel, description, box]
    if repoWideTrust {
      let scope = UILabel()
      scope.font = .systemFont(ofSize: 13)
      scope.textColor = Palette.textSecondary
      scope.numberOfLines = 0
      scope.text = String(
        format: String(
          localized: "components.setupHookTrustDrawer.alwaysTrustScope",
          defaultValue: "Always trust runs future orca.yaml changes in %1$@ without asking."), prompt.repoName)
      views.append(scope)
    }
    let stack = UIStackView(arrangedSubviews: views)
    stack.axis = .vertical
    stack.spacing = Spacing.md
    stack.isLayoutMarginsRelativeArrangement = true
    stack.directionalLayoutMargins = .init(top: Spacing.sm, leading: Spacing.xl, bottom: Spacing.sm, trailing: Spacing.xl)
    stack.frame = CGRect(x: 0, y: 0, width: 390, height: 200)
    return stack
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { actions.count }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
    var content = UIListContentConfiguration.cell()
    let action = actions[indexPath.row]
    switch action {
    case .alwaysTrust:
      content.text = String(localized: "components.setupHookTrustDrawer.alwaysTrust", defaultValue: "Always trust")
    case .runOnce:
      content.text =
        repoWideTrust
        ? String(localized: "components.setupHookTrustDrawer.runOnce", defaultValue: "Run once")
        : String(localized: "components.setupHookTrustDrawer.runHooks", defaultValue: "Run hooks")
    case .dontRun:
      content.text = String(localized: "components.setupHookTrustDrawer.dontRun", defaultValue: "Don't run")
    }
    // The first choice is the primary one.
    let primary = indexPath.row == 0
    content.textProperties.font = .systemFont(ofSize: 17, weight: primary ? .semibold : .regular)
    content.textProperties.color = Palette.textPrimary
    content.image = action == .dontRun ? nil : Lucide.check.image(size: 16)
    content.imageProperties.tintColor = Palette.textPrimary
    content.imageProperties.reservedLayoutSize = CGSize(width: 20, height: 20)
    cell.contentConfiguration = content
    cell.isUserInteractionEnabled = !busy
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    guard !busy else { return }
    busy = true
    tableView.reloadData()
    switch actions[indexPath.row] {
    case .alwaysTrust: onAnswer(true, true)
    case .runOnce: onAnswer(true, false)
    case .dontRun: onAnswer(false, false)
    }
  }
}
