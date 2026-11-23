import OrcaCore
import UIKit

/// The PR's reviewers (PrReviewersSheet.tsx): who is requested or reviewed and where each stands, removable;
/// searching lists the repository's people, and a tap requests or takes back a review.
final class PullRequestReviewersViewController: UITableViewController, UISearchResultsUpdating {
  private let controller: PullRequestController
  private var observation: PRObservation?
  private var people: [PullRequestUser]?
  private var peopleError: String?
  private var peopleTask: Task<Void, Never>?
  private var query = ""

  init(controller: PullRequestController) {
    self.controller = controller
    super.init(style: .insetGrouped)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  deinit { peopleTask?.cancel() }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(localized: "pullRequest.reviewersSection.title", defaultValue: "Reviewers")
    navigationItem.largeTitleDisplayMode = .never
    SettingsList.style(tableView)
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
    let search = UISearchController(searchResultsController: nil)
    search.searchResultsUpdater = self
    search.obscuresBackgroundDuringPresentation = false
    search.searchBar.placeholder = String(localized: "pullRequest.reviewersSheet.addReviewer", defaultValue: "Add a reviewer")
    search.searchBar.autocapitalizationType = .none
    search.searchBar.autocorrectionType = .no
    navigationItem.searchController = search
    navigationItem.hidesSearchBarWhenScrolling = false
    observation = controller.observe { [weak self] in self?.reload() }
    reload()
  }

  private func reload() {
    let approvals = controller.details?.latestReviews.filter { $0.state == "APPROVED" }.count ?? 0
    navigationItem.subtitle = String.localizedStringWithFormat(
      String(localized: "pullRequest.reviewersSheet.approvals", defaultValue: "%lld approvals"), approvals)
    tableView.reloadData()
  }

  private var searching: Bool { !query.isEmpty }

  func updateSearchResults(for searchController: UISearchController) {
    query = searchController.searchBar.text?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
    if searching, people == nil, peopleTask == nil { loadPeople() }
    tableView.reloadData()
  }

  /// The repository's assignable people, read once on the first search.
  private func loadPeople() {
    let api = controller.session.api
    let worktreeId = controller.worktreeId
    let prRepo = controller.pr?.prRepo
    peopleTask = Task { [weak self] in
      do {
        let users = try await api.pullRequestAssignableUsers(worktreeId: worktreeId, prRepo: prRepo)
        self?.people = users
      } catch {
        self?.peopleError = PullRequestController.message(error)
        self?.peopleTask = nil
      }
      self?.tableView.reloadData()
    }
  }

  // MARK: Rows

  private struct Reviewer {
    let login: String
    let name: String?
    let state: String
    let approved: Bool
  }

  private var reviewers: [Reviewer] {
    guard let details = controller.details else { return [] }
    return details.reviewerLogins.map { login in
      let lower = login.lowercased()
      let name = details.reviewRequests.first { $0.login.lowercased() == lower }?.name
      if details.reviewRequests.contains(where: { $0.login.lowercased() == lower }) {
        return Reviewer(
          login: login, name: name, state: String(localized: "pullRequest.reviewersSection.requested", defaultValue: "Requested"),
          approved: false)
      }
      let review = details.latestReviews.first { $0.login.lowercased() == lower }
      let state: String =
        switch review?.state {
        case "APPROVED": String(localized: "pullRequest.reviewersSection.approved", defaultValue: "Approved")
        case "CHANGES_REQUESTED":
          String(localized: "pullRequest.reviewersSection.changesRequested", defaultValue: "Changes requested")
        case "COMMENTED": String(localized: "pullRequest.reviewersSection.commented", defaultValue: "Commented")
        case "DISMISSED": String(localized: "pullRequest.reviewersSection.dismissed", defaultValue: "Dismissed")
        case "PENDING": String(localized: "pullRequest.reviewersSection.pending", defaultValue: "Pending")
        default: String(localized: "pullRequest.reviewersSection.reviewed", defaultValue: "Reviewed")
        }
      return Reviewer(login: login, name: name, state: state, approved: review?.state == "APPROVED")
    }
  }

  private var matches: [PullRequestUser] {
    let author = controller.details?.author?.lowercased()
    return (people ?? []).filter { $0.login.lowercased() != author }
      .filter { $0.login.lowercased().contains(query) || ($0.name ?? "").lowercased().contains(query) }
      .prefix(20).map { $0 }
  }

  private func isRequested(_ login: String) -> Bool {
    controller.details?.reviewRequests.contains { $0.login.lowercased() == login.lowercased() } ?? false
  }

  /// One row standing in for a list: still loading, failed, or empty.
  private var note: String? {
    if searching {
      if let peopleError, people == nil { return peopleError }
      if people == nil { return nil }
      return matches.isEmpty
        ? String(localized: "pullRequest.reviewerPickerDrawer.noMatches", defaultValue: "No matching people") : nil
    }
    if controller.details == nil {
      return controller.detailsFailed
        ? String(
          localized: "pullRequest.reviewersSection.loadFailed", defaultValue: "Could not load reviewers. Tap refresh to try again.")
        : nil
    }
    return reviewers.isEmpty
      ? String(localized: "pullRequest.reviewersSection.noReviewers", defaultValue: "No reviewers requested") : nil
  }

  private var loading: Bool { searching ? people == nil && peopleError == nil : controller.details == nil && !controller.detailsFailed }

  override func numberOfSections(in tableView: UITableView) -> Int { 1 }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    if loading || note != nil { return 1 }
    return searching ? matches.count : reviewers.count
  }

  override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { controller.error }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
    var content = UIListContentConfiguration.cell()
    cell.accessoryView = nil
    cell.accessoryType = .none
    cell.selectionStyle = .default
    if loading {
      let spinner = UIActivityIndicatorView(style: .medium)
      spinner.startAnimating()
      cell.accessoryView = spinner
      content.text = " "
      cell.selectionStyle = .none
    } else if let note {
      content.text = note
      content.textProperties.color = Palette.textSecondary
      cell.selectionStyle = .none
    } else if searching {
      let user = matches[indexPath.row]
      content.text = user.name.map { "\($0) (\(user.login))" } ?? user.login
      if controller.isBusy(.reviewer(user.login.lowercased())) {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        cell.accessoryView = spinner
      } else {
        cell.accessoryType = isRequested(user.login) ? .checkmark : .none
      }
    } else {
      let reviewer = reviewers[indexPath.row]
      content.text = reviewer.name.map { "\($0) (\(reviewer.login))" } ?? reviewer.login
      content.secondaryText = reviewer.state
      content.secondaryTextProperties.color = reviewer.approved ? Palette.statusGreen : Palette.textSecondary
      content.prefersSideBySideTextAndSecondaryText = true
      cell.selectionStyle = .none
      if controller.isBusy(.reviewer(reviewer.login.lowercased())) {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        cell.accessoryView = spinner
      }
    }
    SettingsList.size(&content)
    cell.contentConfiguration = content
    cell.backgroundColor = Palette.sheetGroup
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    guard searching, !loading, note == nil else { return }
    let user = matches[indexPath.row]
    Haptics.select()
    controller.setReviewer(user.login, requested: !isRequested(user.login))
  }

  override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
    -> UISwipeActionsConfiguration?
  {
    guard !searching, !loading, note == nil, controller.pr?.isOpen == true else { return nil }
    let reviewer = reviewers[indexPath.row]
    let remove = UIContextualAction(
      style: .destructive,
      title: String(format: String(localized: "pullRequest.reviewersSection.removeReviewer", defaultValue: "Remove %1$@"), reviewer.login)
    ) { [weak self] _, _, done in
      self?.controller.setReviewer(reviewer.login, requested: false)
      done(true)
    }
    remove.image = Lucide.x.image(size: 18)
    return UISwipeActionsConfiguration(actions: [remove])
  }
}
