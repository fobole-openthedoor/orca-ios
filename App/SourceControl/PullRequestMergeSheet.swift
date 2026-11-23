import OrcaCore
import UIKit

/// Merge #N into its base (MobilePrTabSheets.tsx PrMergeSheet): only the methods the repo allows, starting on
/// its default, each with what it leaves on the base; Merge sends the head the sheet opened on.
final class PullRequestMergeSheet: UITableViewController {
  private let controller: PullRequestController
  private let pr: PullRequestInfo
  private let label: (String) -> String
  private var method: String
  private var merging = false

  init(controller: PullRequestController, pr: PullRequestInfo, label: @escaping (String) -> String) {
    self.controller = controller
    self.pr = pr
    self.label = label
    method = pr.mergeMethods.defaultMethod
    super.init(style: .insetGrouped)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private var base: String { pr.baseRefName ?? "main" }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(format: String(localized: "pullRequest.mergeSheet.title", defaultValue: "Merge #%1$@"), "\(pr.number)")
    navigationItem.subtitle = String(format: String(localized: "pullRequest.mergeSheet.subtitle", defaultValue: "Into %1$@"), base)
    SettingsList.style(tableView)
    tableView.backgroundColor = Palette.sheetSurface
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "method")
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
    updateMergeButton()
  }

  private func updateMergeButton() {
    if merging {
      let spinner = UIActivityIndicatorView(style: .medium)
      spinner.startAnimating()
      navigationItem.rightBarButtonItem = UIBarButtonItem(customView: spinner)
    } else {
      navigationItem.rightBarButtonItem = UIBarButtonItem(
        title: String(localized: "pullRequest.prActionsSection.mergeButton", defaultValue: "Merge"), style: .prominent, target: self,
        action: #selector(merge))
    }
  }

  private func detail(_ method: String) -> String {
    switch method {
    case "merge": String(localized: "pullRequest.mergeSheet.mergeDetail", defaultValue: "Keeps every commit")
    case "rebase":
      String(format: String(localized: "pullRequest.mergeSheet.rebaseDetail", defaultValue: "Replays each commit onto %1$@"), base)
    default: String(format: String(localized: "pullRequest.mergeSheet.squashDetail", defaultValue: "One commit on %1$@"), base)
    }
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { pr.mergeMethods.methods.count }

  override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
    controller.error ?? String(
      format: String(
        localized: "pullRequest.prActionsState.mergeConfirmMessage", defaultValue: "This will merge #%1$@ into its base branch."),
      "\(pr.number)")
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let value = pr.mergeMethods.methods[indexPath.row]
    let cell = tableView.dequeueReusableCell(withIdentifier: "method", for: indexPath)
    var content = UIListContentConfiguration.subtitleCell()
    content.text = label(value)
    content.secondaryText = detail(value)
    content.secondaryTextProperties.color = Palette.textSecondary
    SettingsList.size(&content, emphasized: true)
    cell.contentConfiguration = content
    cell.accessoryType = value == method ? .checkmark : .none
    cell.backgroundColor = Palette.sheetGroup
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    guard !merging else { return }
    Haptics.select()
    method = pr.mergeMethods.methods[indexPath.row]
    tableView.reloadData()
  }

  @objc private func merge() {
    guard !merging else { return }
    merging = true
    isModalInPresentation = true
    updateMergeButton()
    Task { [weak self] in
      guard let self else { return }
      let ok = await controller.merge(method: method, reviewed: pr)
      merging = false
      isModalInPresentation = false
      if ok {
        dismiss(animated: true)
      } else {
        updateMergeButton()
        tableView.reloadData()
      }
    }
  }
}
