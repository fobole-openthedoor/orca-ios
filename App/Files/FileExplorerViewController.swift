import OrcaCore
import UIKit

/// The workspace's files (files/explorer/MobileFileExplorerPanel.tsx): one folder per page, folders first, read a
/// page at a time with Show more for the rest. Folders drill in, files open their preview; a long press copies the
/// name or path or shares the file. Hosts older than `files.readDir` list the whole tree once with `files.list`.
final class FileExplorerViewController: UITableViewController, UISearchResultsUpdating {
  private let session: HostSession
  private let worktreeId: String
  private let path: String
  private var entries: [FileDirEntry] = []
  private var total = 0
  private var hasMore = false
  private var loadingMore = false
  private var query = ""
  /// Set when the host answered with the old whole-tree listing; child folders read from it.
  private var legacy: FileListing?

  convenience init(session: HostSession, worktreeId: String) {
    self.init(session: session, worktreeId: worktreeId, path: "", legacy: nil)
  }

  private init(session: HostSession, worktreeId: String, path: String, legacy: FileListing?) {
    self.session = session
    self.worktreeId = worktreeId
    self.path = path
    self.legacy = legacy
    super.init(style: .insetGrouped)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private static let pageSize = 500

  override func viewDidLoad() {
    super.viewDidLoad()
    if path.isEmpty {
      title = String(localized: "files.fileExplorerPanel.title", defaultValue: "Files")
      navigationItem.subtitle = session.worktree(id: worktreeId)?.displayName
    } else {
      title = (path as NSString).lastPathComponent
      navigationItem.subtitle = (path as NSString).deletingLastPathComponent.nilIfEmpty
    }
    navigationItem.largeTitleDisplayMode = .never
    navigationItem.backButtonDisplayMode = .minimal
    let search = UISearchController(searchResultsController: nil)
    search.searchResultsUpdater = self
    search.obscuresBackgroundDuringPresentation = false
    search.searchBar.placeholder = String(
      localized: "files.fileExplorerPanel.filterPlaceholder", defaultValue: "Filter files")
    navigationItem.searchController = search
    navigationItem.hidesSearchBarWhenScrolling = true
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
    let refresh = UIRefreshControl()
    refresh.addAction(UIAction { [weak self] _ in self?.reload() }, for: .valueChanged)
    refreshControl = refresh
    contentUnavailableConfiguration = loadingConfiguration()
    reload()
  }

  private func loadingConfiguration() -> UIContentUnavailableConfiguration {
    var config = UIContentUnavailableConfiguration.loading()
    config.text = String(localized: "files.fileExplorerPanel.loading", defaultValue: "Loading files…")
    return config
  }

  func updateSearchResults(for searchController: UISearchController) {
    query = searchController.searchBar.text?.trimmingCharacters(in: .whitespaces) ?? ""
    tableView.reloadData()
    updateEmptyState()
  }

  // MARK: Loading

  private func reload() {
    if legacy != nil, !path.isEmpty {
      show(legacy?.entries(in: path) ?? [], total: nil, hasMore: false)
      refreshControl?.endRefreshing()
      return
    }
    let api = session.api
    let worktreeId = worktreeId
    let path = path
    // A refresh reads as many rows as were shown, so pages already opened stay.
    let limit = min(5000, max(Self.pageSize, entries.count))
    Task { [weak self] in
      do {
        let page = try await api.readDirectory(worktreeId: worktreeId, path: path, limit: limit)
        self?.legacy = nil
        self?.show(page.entries, total: page.total, hasMore: page.hasMore)
      } catch let error as RPCError where path.isEmpty && FileShare.isMethodUnavailable(error) {
        do {
          let listing = try await api.listFiles(worktreeId: worktreeId)
          self?.legacy = listing
          self?.show(listing.entries(in: ""), total: nil, hasMore: false)
        } catch {
          self?.showError(error)
        }
      } catch {
        self?.showError(error)
      }
      self?.refreshControl?.endRefreshing()
    }
  }

  private func loadMore() {
    guard hasMore, !loadingMore, let last = entries.last else { return }
    loadingMore = true
    tableView.reloadSections(IndexSet(integer: 1), with: .none)
    let api = session.api
    let worktreeId = worktreeId
    let path = path
    Task { [weak self] in
      do {
        let page = try await api.readDirectory(worktreeId: worktreeId, path: path, after: last, limit: Self.pageSize)
        guard let self else { return }
        loadingMore = false
        show(entries + page.entries, total: page.total, hasMore: page.hasMore)
      } catch {
        guard let self else { return }
        loadingMore = false
        tableView.reloadData()
        showAlert(error)
      }
    }
  }

  private func show(_ entries: [FileDirEntry], total: Int?, hasMore: Bool) {
    self.entries = entries
    self.total = total ?? entries.count
    self.hasMore = hasMore
    tableView.reloadData()
    updateEmptyState()
  }

  private func updateEmptyState() {
    if visible.isEmpty {
      var config = UIContentUnavailableConfiguration.empty()
      config.image = Lucide.folder.image(size: 32)
      config.text = String(localized: "files.fileExplorerPanel.emptyState", defaultValue: "No files found")
      if !query.isEmpty {
        config.secondaryText = String(
          localized: "files.fileExplorerPanel.noMatchesHint", defaultValue: "Only folders you have opened are searched.")
      }
      contentUnavailableConfiguration = config
    } else {
      contentUnavailableConfiguration = nil
    }
  }

  private func showError(_ error: Error) {
    guard entries.isEmpty else {
      showAlert(error)
      return
    }
    var config = UIContentUnavailableConfiguration.empty()
    config.image = Lucide.folder.image(size: 32)
    config.text =
      path.isEmpty
      ? String(localized: "files.fileExplorerPanel.loadFailed", defaultValue: "Unable to load files")
      : String(localized: "files.fileExplorerRow.loadFolderFailed", defaultValue: "Unable to load folder")
    config.secondaryText = (error as? RPCError)?.message ?? error.localizedDescription
    var retry = UIButton.Configuration.gray()
    retry.title = String(localized: "common.retry", defaultValue: "Retry")
    config.button = retry
    config.buttonProperties.primaryAction = UIAction { [weak self] _ in
      guard let self else { return }
      contentUnavailableConfiguration = loadingConfiguration()
      reload()
    }
    contentUnavailableConfiguration = config
  }

  private func showAlert(_ error: Error) {
    let alert = UIAlertController(
      title: String(localized: "files.fileExplorerRow.loadFolderFailed", defaultValue: "Unable to load folder"),
      message: (error as? RPCError)?.message ?? error.localizedDescription, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: String(localized: "common.ok", defaultValue: "OK"), style: .default))
    present(alert, animated: true)
  }

  // MARK: Rows

  private var visible: [FileDirEntry] {
    query.isEmpty ? entries : entries.filter { $0.name.localizedCaseInsensitiveContains(query) }
  }

  private func relativePath(_ entry: FileDirEntry) -> String {
    path.isEmpty ? entry.name : "\(path)/\(entry.name)"
  }

  private var showsMoreRow: Bool { hasMore && query.isEmpty }

  override func numberOfSections(in tableView: UITableView) -> Int { 2 }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    section == 0 ? visible.count : (showsMoreRow ? 1 : 0)
  }

  override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
    guard section == 0, let legacy, legacy.truncated, path.isEmpty else { return nil }
    return String(
      format: String(localized: "files.fileExplorerPanel.truncatedList", defaultValue: "%1$@ - Showing first 5000"),
      session.worktree(id: worktreeId)?.displayName ?? "")
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
    cell.accessoryView = nil
    if indexPath.section == 1 {
      var content = UIListContentConfiguration.cell()
      let remaining = max(0, total - entries.count)
      content.text = String(
        format: String(localized: "files.fileExplorerRow.showMore", defaultValue: "Show %1$@ more"),
        "\(min(Self.pageSize, remaining))")
      content.secondaryText = String(
        format: String(localized: "files.fileExplorerRow.loadedOfTotal", defaultValue: "%1$@ of %2$@"),
        "\(entries.count)", "\(total)")
      content.textProperties.color = Palette.accentBlue
      content.secondaryTextProperties.color = Palette.textSecondary
      content.prefersSideBySideTextAndSecondaryText = true
      cell.contentConfiguration = content
      cell.accessoryType = .none
      if loadingMore {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        cell.accessoryView = spinner
      }
      return cell
    }
    let entry = visible[indexPath.row]
    var content = UIListContentConfiguration.cell()
    content.text = entry.name
    content.textProperties.lineBreakMode = .byTruncatingMiddle
    content.textProperties.numberOfLines = 1
    content.image = Self.icon(for: entry).image(size: 20)
    content.imageProperties.tintColor = entry.isDirectory ? Palette.accentBlue : Palette.textSecondary
    content.imageProperties.reservedLayoutSize = CGSize(width: 24, height: 24)
    cell.contentConfiguration = content
    cell.accessoryType = entry.isDirectory ? .disclosureIndicator : .none
    cell.accessibilityLabel =
      entry.isDirectory
      ? String(format: String(localized: "files.fileExplorerRow.openFolder", defaultValue: "Open folder %1$@"), entry.name)
      : String(format: String(localized: "files.fileExplorerRow.previewFile", defaultValue: "Preview file %1$@"), entry.name)
    return cell
  }

  static func icon(for entry: FileDirEntry) -> Lucide {
    if entry.isDirectory { return .folder }
    switch FilePreviewViewController.Kind(path: entry.name) {
    case .image: return .image
    case .text: return .fileText
    case .media: return .file
    }
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    if indexPath.section == 1 {
      loadMore()
      return
    }
    let entry = visible[indexPath.row]
    let target = relativePath(entry)
    if entry.isDirectory {
      navigationController?.pushViewController(
        FileExplorerViewController(session: session, worktreeId: worktreeId, path: target, legacy: legacy),
        animated: true)
    } else {
      navigationController?.pushViewController(
        FilePreviewViewController(session: session, worktreeId: worktreeId, path: target), animated: true)
    }
  }

  override func tableView(
    _ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint
  ) -> UIContextMenuConfiguration? {
    guard indexPath.section == 0 else { return nil }
    let entry = visible[indexPath.row]
    let target = relativePath(entry)
    return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
      var children: [UIMenuElement] = [
        UIAction(
          title: String(localized: "files.fileExplorerRowActions.copyName", defaultValue: "Copy Name"),
          image: Lucide.copy.image(size: 18)
        ) { _ in UIPasteboard.general.string = entry.name },
        UIAction(
          title: String(localized: "files.fileExplorerRowActions.copyRelativePath", defaultValue: "Copy Relative Path"),
          image: Lucide.link.image(size: 18)
        ) { _ in UIPasteboard.general.string = target },
      ]
      if !entry.isDirectory, let self {
        children.append(
          UIAction(
            title: String(localized: "files.fileShare.share", defaultValue: "Share"),
            image: Lucide.share.image(size: 18)
          ) { [weak self] _ in
            guard let self else { return }
            FileShare.share(session: session, worktreeId: worktreeId, path: target, from: self, source: nil)
          })
      }
      return UIMenu(children: children)
    })
  }
}

extension String {
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
