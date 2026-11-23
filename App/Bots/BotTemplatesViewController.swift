import UIKit

/// New bot › Use template (bots/MobileBotTemplatesSheet.tsx): the templates by category with search, then a
/// blank bot. Picking one opens its page; Use template hands it back to New bot.
final class BotTemplatesViewController: UITableViewController, UISearchResultsUpdating {
  private let onPick: (BotTemplate?) -> Void
  private var query = ""
  private var groups: [(category: String, templates: [BotTemplate])] = []

  init(onPick: @escaping (BotTemplate?) -> Void) {
    self.onPick = onPick
    super.init(style: .insetGrouped)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(localized: "bots.templates.title", defaultValue: "Bot templates")
    navigationItem.largeTitleDisplayMode = .never
    let search = UISearchController(searchResultsController: nil)
    search.searchResultsUpdater = self
    search.obscuresBackgroundDuringPresentation = false
    search.searchBar.placeholder = String(localized: "bots.templates.search", defaultValue: "Search templates")
    navigationItem.searchController = search
    navigationItem.hidesSearchBarWhenScrolling = false
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
    rebuild()
  }

  func updateSearchResults(for searchController: UISearchController) {
    query = searchController.searchBar.text ?? ""
    rebuild()
  }

  private func rebuild() {
    let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
    let catalog = BotTemplate.catalog
    groups = catalog.categories.compactMap { category in
      let templates = catalog.templates.filter { template in
        template.category == category
          && (needle.isEmpty
            || [template.shownName, template.shownLine, template.name, template.line].contains {
              $0.lowercased().contains(needle)
            })
      }
      return templates.isEmpty ? nil : (category, templates)
    }
    tableView.reloadData()
  }

  // The last section is the blank bot, shown only without a search.
  private var showsBlank: Bool { query.isEmpty }

  override func numberOfSections(in tableView: UITableView) -> Int { groups.count + (showsBlank ? 1 : 0) }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    section < groups.count ? groups[section].templates.count : 1
  }

  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    section < groups.count ? BotTemplate.categoryName(groups[section].category) : nil
  }

  override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
    guard groups.isEmpty, !query.isEmpty else { return nil }
    return String(format: String(localized: "bots.templates.noMatch", defaultValue: "No templates match “%@”"), query)
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
    var content = UIListContentConfiguration.subtitleCell()
    content.secondaryTextProperties.color = Palette.textSecondary
    content.secondaryTextProperties.numberOfLines = 2
    if indexPath.section < groups.count {
      let template = groups[indexPath.section].templates[indexPath.row]
      content.text = template.shownName
      content.secondaryText = template.shownLine
      let avatar = BotAvatarView(size: 32)
      avatar.show(mascot: template.mascot)
      content.image = avatar.snapshotImage()
      content.imageProperties.cornerRadius = 8
      cell.accessoryType = .disclosureIndicator
    } else {
      content.text = String(localized: "bots.templates.blank", defaultValue: "Blank bot")
      content.secondaryText = String(
        localized: "bots.templates.blankLine", defaultValue: "Tell it what it’s for in its first chat.")
      content.image = Lucide.plus.image(size: 20)
      content.imageProperties.tintColor = Palette.textSecondary
      cell.accessoryType = .none
    }
    cell.contentConfiguration = content
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    guard indexPath.section < groups.count else {
      onPick(nil)
      navigationController?.popViewController(animated: true)
      return
    }
    let template = groups[indexPath.section].templates[indexPath.row]
    navigationController?.pushViewController(
      BotTemplateDetailViewController(template: template) { [weak self] picked in
        guard let self else { return }
        self.onPick(picked)
        if let root = self.navigationController?.viewControllers.first {
          self.navigationController?.popToViewController(root, animated: true)
        }
      }, animated: true)
  }
}

/// One template's page (bots/MobileBotTemplateDetail.tsx): what it is, what it does first, and what it comes with.
final class BotTemplateDetailViewController: UITableViewController {
  private enum Row {
    case skill(String), schedule(BotTemplate.Schedule), connector(String)
  }

  private let template: BotTemplate
  private let onUse: (BotTemplate) -> Void
  private var comesWith: [Row] = []

  init(template: BotTemplate, onUse: @escaping (BotTemplate) -> Void) {
    self.template = template
    self.onUse = onUse
    super.init(style: .insetGrouped)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = template.shownName
    navigationItem.subtitle = String(
      format: String(localized: "bots.templates.byOrca", defaultValue: "%@ · by Orca"),
      BotTemplate.categoryName(template.category))
    navigationItem.largeTitleDisplayMode = .never
    let use = UIBarButtonItem(
      title: String(localized: "bots.templates.useTemplate", defaultValue: "Use template…"), style: .prominent,
      target: nil, action: nil)
    use.primaryAction = UIAction(title: use.title ?? "") { [weak self] _ in
      guard let self else { return }
      self.onUse(self.template)
    }
    navigationItem.rightBarButtonItem = use
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
    comesWith = template.skills.map(Row.skill) + template.schedules.map(Row.schedule) + template.connectors.map(Row.connector)

    let header = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 140))
    let avatar = BotAvatarView(size: 64)
    avatar.show(mascot: template.mascot)
    let line = TextLabel(template.shownLine, size: 15, color: Palette.textSecondary, alignment: .center, lines: 0)
    let stack = UIStackView(arrangedSubviews: [avatar, line])
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = Spacing.md
    stack.translatesAutoresizingMaskIntoConstraints = false
    header.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: header.topAnchor, constant: Spacing.md),
      stack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: Spacing.xl),
      stack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -Spacing.xl),
    ])
    tableView.tableHeaderView = header
  }

  private var sections: [String] {
    ["firstChat"] + (template.needsSetup == nil ? [] : ["needsSetup"]) + (comesWith.isEmpty ? [] : ["comesWith"])
  }

  override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    sections[section] == "comesWith" ? comesWith.count : 1
  }

  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    switch sections[section] {
    case "firstChat": String(localized: "bots.templates.firstChat", defaultValue: "What it does first")
    case "needsSetup": String(localized: "bots.templates.needsSetup", defaultValue: "Needs setup")
    default: String(localized: "bots.templates.comesWith", defaultValue: "Comes with")
    }
  }

  override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
    sections[section] == "comesWith"
      ? String(
        localized: "bots.templates.comesWithNote",
        defaultValue: "Schedules start turned off. Automations and connectors are set up in its first chat, once you pick the repo or channel.")
      : nil
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
    cell.selectionStyle = .none
    var content = UIListContentConfiguration.valueCell()
    switch sections[indexPath.section] {
    case "firstChat":
      content = UIListContentConfiguration.cell()
      content.text = template.word("firstChat", english: template.firstChat)
    case "needsSetup":
      content = UIListContentConfiguration.cell()
      content.text = template.word("needsSetup", english: template.needsSetup ?? "")
    default:
      switch comesWith[indexPath.row] {
      case .skill(let skill):
        content = UIListContentConfiguration.subtitleCell()
        content.text = BotTemplate.skillName(skill)
        content.secondaryText = BotTemplate.skillLine(skill)
        content.image = Lucide.bookOpen.image(size: 18)
      case .schedule(let schedule):
        content = UIListContentConfiguration.subtitleCell()
        content.text = template.word("schedules.\(schedule.id).when", english: schedule.when)
        content.secondaryText = template.word("schedules.\(schedule.id).what", english: schedule.what)
        content.image = Lucide.calendarClock.image(size: 18)
        let off = UILabel()
        off.text = String(localized: "bots.templates.stateOff", defaultValue: "Off")
        off.textColor = Palette.textMuted
        off.sizeToFit()
        cell.accessoryView = off
      case .connector(let connector):
        content.text = BotTemplate.connectorNames[connector] ?? connector
        content.secondaryText = String(localized: "bots.templates.stateNotConnected", defaultValue: "Not connected")
        content.image = Lucide.plug.image(size: 18)
      }
      content.imageProperties.tintColor = Palette.textSecondary
      content.secondaryTextProperties.color = Palette.textSecondary
    }
    content.textProperties.numberOfLines = 0
    content.secondaryTextProperties.numberOfLines = 0
    cell.contentConfiguration = content
    return cell
  }
}

extension UIView {
  /// The view drawn once at its own size, for places that take an image.
  func snapshotImage() -> UIImage {
    layoutIfNeeded()
    let size = systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
    bounds = CGRect(origin: .zero, size: size)
    layoutIfNeeded()
    return UIGraphicsImageRenderer(bounds: bounds).image { context in layer.render(in: context.cgContext) }
  }
}
