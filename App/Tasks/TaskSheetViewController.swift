import UIKit

/// One row of a Tasks sheet (components/list/ListGroup.tsx ListRow): a title with an optional subtitle, a trailing
/// value or a checkmark, and what tapping it does.
struct TaskSheetRow {
  var title: String
  var subtitle: String?
  /// Shown trailing, greyed, as `ListRow`'s `value`.
  var value: String?
  var selected = false
  /// A leading dot, as the repository and state rows have.
  var dot: UIColor?
  var disabled = false
  /// Opens another sheet: a chevron instead of a checkmark.
  var navigates = false
  var destructive = false
  /// A two-way choice drawn as a segmented control (the issue-source rows): its titles and the one picked.
  var segments: [String] = []
  var selectedSegment = 0
  var onSegment: ((Int) -> Void)?
  var action: (() -> Void)?

  init(
    title: String, subtitle: String? = nil, value: String? = nil, selected: Bool = false, dot: UIColor? = nil,
    disabled: Bool = false, navigates: Bool = false, action: (() -> Void)? = nil
  ) {
    self.title = title
    self.subtitle = subtitle
    self.value = value
    self.selected = selected
    self.dot = dot
    self.disabled = disabled
    self.navigates = navigates
    self.action = action
  }
}

struct TaskSheetSection {
  var header: String?
  var footer: String?
  var rows: [TaskSheetRow]
}

/// The Tasks screen's pickers and Filter & display: grouped rows rebuilt from the screen's state after every tap,
/// so choices apply as they're made and the sheet stays open to change more.
final class TaskSheetViewController: UITableViewController, UISearchResultsUpdating {
  private let build: (TaskSheetViewController) -> [TaskSheetSection]
  private var sections: [TaskSheetSection] = []
  /// Shown above the rows, as the official sheets' subtitle.
  private let subtitle: String?
  /// What the search field holds, when the sheet has one.
  private(set) var searchText = ""

  init(
    title: String, subtitle: String? = nil, searchPlaceholder: String? = nil,
    build: @escaping (TaskSheetViewController) -> [TaskSheetSection]
  ) {
    self.build = build
    self.subtitle = subtitle
    super.init(style: .insetGrouped)
    self.title = title
    if let searchPlaceholder {
      let search = UISearchController(searchResultsController: nil)
      search.obscuresBackgroundDuringPresentation = false
      search.searchBar.placeholder = searchPlaceholder
      search.searchBar.autocapitalizationType = .none
      search.searchBar.autocorrectionType = .no
      search.searchResultsUpdater = self
      navigationItem.searchController = search
      navigationItem.hidesSearchBarWhenScrolling = false
    }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      title: String(localized: "tasks.filterSheet.done", defaultValue: "Done"), style: .prominent, target: nil, action: nil)
    navigationItem.rightBarButtonItem?.primaryAction = UIAction(
      title: String(localized: "tasks.filterSheet.done", defaultValue: "Done")
    ) { [weak self] _ in self?.dismiss(animated: true) }
    tableView.backgroundColor = Palette.bgBase
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
    if let subtitle {
      let label = UILabel()
      label.text = subtitle
      label.font = .systemFont(ofSize: 13)
      label.textColor = Palette.textSecondary
      label.numberOfLines = 0
      let header = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
      label.translatesAutoresizingMaskIntoConstraints = false
      header.addSubview(label)
      NSLayoutConstraint.activate([
        label.leadingAnchor.constraint(equalTo: header.layoutMarginsGuide.leadingAnchor, constant: Spacing.sm),
        label.trailingAnchor.constraint(equalTo: header.layoutMarginsGuide.trailingAnchor, constant: -Spacing.sm),
        label.topAnchor.constraint(equalTo: header.topAnchor, constant: Spacing.xs),
        label.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -Spacing.xs),
      ])
      tableView.tableHeaderView = header
    }
    reload()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // The subtitle header sizes to its text at the sheet's width.
    guard let header = tableView.tableHeaderView else { return }
    let size = header.systemLayoutSizeFitting(
      CGSize(width: tableView.bounds.width, height: UIView.layoutFittingCompressedSize.height),
      withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
    if abs(header.frame.height - size.height) > 0.5 {
      header.frame.size.height = size.height
      tableView.tableHeaderView = header
    }
  }

  /// Rebuilds the rows from the screen's state.
  func reload() {
    sections = build(self)
    guard isViewLoaded else { return }
    tableView.reloadData()
  }

  func updateSearchResults(for searchController: UISearchController) {
    searchText = searchController.searchBar.text ?? ""
    reload()
  }

  override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    sections[section].rows.count
  }

  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    sections[section].header
  }

  override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
    sections[section].footer
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let row = sections[indexPath.section].rows[indexPath.row]
    let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
    cell.backgroundColor = Palette.bgPanel
    var content = UIListContentConfiguration.subtitleCell()
    content.text = row.title
    content.textProperties.numberOfLines = 2
    content.textProperties.color =
      row.disabled ? Palette.textMuted : (row.destructive ? Palette.statusRed : Palette.textPrimary)
    content.secondaryText = row.subtitle
    content.secondaryTextProperties.color = Palette.textSecondary
    content.secondaryTextProperties.numberOfLines = 2
    if let dot = row.dot {
      content.image = UIImage(systemName: "circle.fill")?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 9))
      content.imageProperties.tintColor = dot
      content.imageProperties.reservedLayoutSize = CGSize(width: 14, height: 14)
    }
    cell.contentConfiguration = content
    cell.tintColor = Palette.textPrimary
    cell.selectionStyle = row.action == nil || row.disabled ? .none : .default
    cell.accessoryView = nil
    cell.accessoryType = row.navigates ? .disclosureIndicator : (row.selected ? .checkmark : .none)
    if let value = row.value {
      // ListRow's trailing value, before the chevron when the row opens another sheet.
      let label = UILabel()
      label.text = value
      label.font = .systemFont(ofSize: 17)
      label.textColor = Palette.textSecondary
      label.lineBreakMode = .byTruncatingTail
      let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
      chevron.tintColor = Palette.textMuted
      chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
      chevron.isHidden = !row.navigates
      let stack = UIStackView(arrangedSubviews: [label, chevron])
      stack.spacing = Spacing.sm
      stack.alignment = .center
      let fitted = stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
      stack.frame.size = CGSize(width: min(fitted.width, 200), height: max(fitted.height, 22))
      cell.accessoryView = stack
    }
    if !row.segments.isEmpty {
      let control = UISegmentedControl(items: row.segments)
      control.selectedSegmentIndex = row.selectedSegment
      control.addAction(
        UIAction { [weak control] _ in
          guard let control else { return }
          Haptics.select()
          row.onSegment?(control.selectedSegmentIndex)
        }, for: .valueChanged)
      control.sizeToFit()
      cell.accessoryView = control
    }
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    let row = sections[indexPath.section].rows[indexPath.row]
    guard let action = row.action, !row.disabled else { return }
    Haptics.select()
    action()
    reload()
  }
}

extension UIViewController {
  /// Presents a Tasks sheet at half height, growing to full.
  @discardableResult
  func presentTaskSheet(_ sheet: TaskSheetViewController, large: Bool = false) -> TaskSheetViewController {
    let navigation = UINavigationController(rootViewController: sheet)
    navigation.sheetPresentationController?.detents = large ? [.large()] : [.medium(), .large()]
    navigation.sheetPresentationController?.prefersGrabberVisible = true
    topPresenter.present(navigation, animated: true)
    return sheet
  }

  /// The controller a new sheet goes over. An active search (its field docked in the toolbar) is itself presented
  /// over the page, and UIKit drops a `present` from a controller that is already presenting, silently.
  var topPresenter: UIViewController {
    var presenter: UIViewController = self
    while let next = presenter.presentedViewController, !next.isBeingDismissed { presenter = next }
    return presenter
  }
}
