import OrcaCore
import UIKit

/// The PR's checks (PrChecksScreen.tsx): a bar split by outcome and the counts in words, then Failing and
/// Cancelled with Fix and Rerun, Running, Passed folded to one row, and Neutral. It rereads while open.
final class PullRequestChecksViewController: UIViewController {
  private let controller: PullRequestController
  private let scroll = UIScrollView()
  private let stack = UIStackView()
  private var observation: PRObservation?
  private var pollTask: Task<Void, Never>?
  private var showPassed = false

  init(controller: PullRequestController) {
    self.controller = controller
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  deinit { pollTask?.cancel() }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = Palette.bgBase
    title = String(localized: "pullRequest.checksSection.title", defaultValue: "Checks")
    navigationItem.largeTitleDisplayMode = .never
    scroll.alwaysBounceVertical = true
    stack.axis = .vertical
    stack.spacing = Spacing.md
    view.addSubview(scroll)
    scroll.pin(to: view)
    scroll.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Spacing.sm),
      stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Spacing.lg),
      stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Spacing.lg),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Spacing.xl),
    ])
    let refresh = UIRefreshControl()
    refresh.addAction(UIAction { [weak self] _ in self?.controller.reread() }, for: .valueChanged)
    scroll.refreshControl = refresh
    observation = controller.observe { [weak self] in self?.rebuild() }
    controller.loadAgentLabel()
    rebuild()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    // Live while open, as the official screen polls instead of offering a refresh button.
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(15))
        guard !Task.isCancelled else { return }
        self?.controller.reread()
      }
    }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    pollTask?.cancel()
  }

  private func rebuild() {
    scroll.refreshControl?.endRefreshing()
    stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    guard let pr = controller.pr else {
      let spinner = UIActivityIndicatorView(style: .medium)
      spinner.startAnimating()
      stack.addArrangedSubview(spinner)
      return
    }
    navigationItem.subtitle = "#\(pr.number)"
    let checks = PullRequestCheck.sortedBySeverity(controller.checks)
    let failing = checks.filter { $0.outcome == .failed && !$0.isCancelled }
    let cancelled = checks.filter { $0.outcome == .failed && $0.isCancelled }
    let running = checks.filter { $0.outcome == .pending }
    let passed = checks.filter { $0.outcome == .passed }
    let other = checks.filter { $0.outcome == .neutral }
    if let summary = summary(failing: failing.count, cancelled: cancelled.count, running: running.count, passed: passed.count) {
      stack.addArrangedSubview(summary)
    }
    if let error = controller.checksError {
      stack.addArrangedSubview(TextLabel(error, size: 13, color: Palette.statusRed, lines: 0))
    } else if checks.isEmpty {
      stack.addArrangedSubview(
        TextLabel(
          String(localized: "pullRequest.checksSection.noChecks", defaultValue: "No checks"), size: Typography.bodySize,
          color: Palette.textSecondary))
    }
    for (title, list) in [
      (String(localized: "pullRequest.screens.failing", defaultValue: "Failing"), failing),
      (String(localized: "pullRequest.checkStatus.cancelled", defaultValue: "Cancelled"), cancelled),
    ] where !list.isEmpty {
      section(title, rows: list.map { failureRow($0, pr: pr) })
    }
    if !failing.isEmpty || !cancelled.isEmpty {
      if let notice = controller.agentNotice {
        stack.addArrangedSubview(
          TextLabel(notice.text, size: 13, color: notice.failed ? Palette.statusRed : Palette.textSecondary, lines: 0))
      }
      if let error = controller.error {
        stack.addArrangedSubview(TextLabel(error, size: 13, color: Palette.statusRed, lines: 0))
      }
    }
    if !running.isEmpty {
      section(
        String(localized: "pullRequest.screens.runningSection", defaultValue: "Running"),
        rows: running.map {
          row(
            $0, tone: .running,
            subtitle: $0.status == "queued"
              ? String(localized: "pullRequest.screens.queued", defaultValue: "Queued")
              : String(localized: "pullRequest.screens.inProgress", defaultValue: "In progress"))
        })
    }
    if !passed.isEmpty {
      let names = passed.prefix(3).map(\.name).joined(separator: ", ")
      let folded =
        passed.count > 3
        ? String.localizedStringWithFormat(
          String(localized: "pullRequest.screens.namesAndMore", defaultValue: "%1$@ and %2$lld more"), names, passed.count - 3)
        : names
      let chevron = LucideView(showPassed ? .chevronUp : .chevronDown, size: 16, strokeWidth: 2.2, color: Palette.textMuted)
      let header = ListRowView(
        title: String.localizedStringWithFormat(
          String(localized: "pullRequest.checksSection.passed", defaultValue: "%lld passed"), passed.count),
        subtitle: showPassed ? nil : folded, leading: LucideView(.circleCheck, size: 20, color: Palette.statusGreen),
        accessory: chevron
      ) { [weak self] in
        guard let self else { return }
        Haptics.select()
        showPassed.toggle()
        rebuild()
      }
      section(
        String(localized: "pullRequest.screens.passedSection", defaultValue: "Passed"),
        rows: [header] + (showPassed ? passed.map { row($0, tone: .passed) } : []))
    }
    if !other.isEmpty {
      section(
        String(localized: "pullRequest.screens.neutralSection", defaultValue: "Neutral"),
        rows: other.map { row($0, tone: .other) })
    }
  }

  private func section(_ title: String, rows: [UIView]) {
    let label = SectionLabelView(title)
    stack.addArrangedSubview(label)
    stack.setCustomSpacing(Spacing.xs, after: label)
    stack.addArrangedSubview(ListGroupView(rows: rows, separatorInset: ListRowView.leadingInset))
  }

  private enum Tone { case running, passed, other }

  private func row(_ check: PullRequestCheck, tone: Tone, subtitle: String? = nil) -> UIView {
    let icon: LucideView =
      switch tone {
      case .running: LucideView(.loaderCircle, size: 20, color: Palette.statusAmber)
      case .passed: LucideView(.circleCheck, size: 20, color: Palette.statusGreen)
      case .other: LucideView(.circleMinus, size: 20, color: Palette.textMuted)
      }
    let url = check.url.flatMap(URL.init(string:))
    return ListRowView(
      title: check.name, subtitle: subtitle, leading: icon, navigates: url != nil,
      onPress: url.map { url in { UIApplication.shared.open(url) } })
  }

  /// A failing or cancelled check: Fix with the agent, Rerun, or open it on GitHub from its menu.
  private func failureRow(_ check: PullRequestCheck, pr: PullRequestInfo) -> UIView {
    let agent = controller.agentLabel
    var items: [UIMenuElement] = []
    if check.isBroken {
      items.append(
        UIAction(
          title: agent.map { String(format: String(localized: "pullRequest.screens.fixWith", defaultValue: "Fix with %1$@"), $0) }
            ?? String(localized: "pullRequest.screens.fixWithAi", defaultValue: "Fix with AI"),
          image: Lucide.sparkles.image(size: 18), attributes: controller.isBusy(.agent) ? .disabled : []
        ) { [weak self] _ in
          guard let self else { return }
          controller.launchAgent(prompt: controller.fixChecksPrompt([check]))
        })
      items.append(
        UIAction(
          title: String(localized: "pullRequest.screens.rerun", defaultValue: "Rerun"), image: Lucide.rotateCw.image(size: 18),
          attributes: controller.isBusy(.rerun) ? .disabled : []
        ) { [weak self] _ in self?.controller.rerunFailedChecks() })
    }
    if let url = check.url.flatMap(URL.init(string:)) {
      items.append(
        UIAction(
          title: String(localized: "pullRequest.screens.openOnGitHub", defaultValue: "Open on GitHub"),
          image: Lucide.externalLink.image(size: 18)
        ) { _ in UIApplication.shared.open(url) })
    }
    var configuration = UIButton.Configuration.plain()
    configuration.image = Lucide.ellipsis.image(size: 18)
    configuration.baseForegroundColor = Palette.textSecondary
    configuration.contentInsets = .zero
    configuration.showsActivityIndicator = controller.isBusy(.rerun) || controller.isBusy(.agent)
    let more = UIButton(configuration: configuration)
    more.menu = UIMenu(children: items)
    more.showsMenuAsPrimaryAction = true
    more.accessibilityLabel = String(
      format: String(localized: "pullRequest.screens.checkActions", defaultValue: "More for %1$@"), check.name)
    let icon = LucideView(
      check.isCancelled ? .circleMinus : .circleX, size: 20, color: check.isCancelled ? Palette.textMuted : Palette.statusRed)
    let row = ListRowView(
      title: check.name,
      subtitle: check.isCancelled
        ? String(localized: "pullRequest.checkStatus.cancelled", defaultValue: "Cancelled")
        : String(localized: "pullRequest.screens.failed", defaultValue: "Failed"),
      leading: icon, accessory: more)
    // The row itself stays inert so the menu button takes the touch.
    row.isUserInteractionEnabled = true
    return row
  }

  private func summary(failing: Int, cancelled: Int, running: Int, passed: Int) -> UIView? {
    guard failing + cancelled + running + passed > 0 else { return nil }
    let bar = UIStackView()
    bar.spacing = 3
    bar.distribution = .fill
    let parts: [(Int, UIColor)] = [
      (failing, Palette.statusRed), (cancelled, Palette.textMuted), (running, Palette.statusAmber), (passed, Palette.statusGreen),
    ]
    var first: UIView?
    var firstCount = 1
    for (count, color) in parts where count > 0 {
      let segment = UIView()
      segment.backgroundColor = color
      segment.layer.cornerRadius = 2
      bar.addArrangedSubview(segment)
      // Each segment's width follows its share, as flex weights do.
      if let first {
        segment.widthAnchor.constraint(equalTo: first.widthAnchor, multiplier: CGFloat(count) / CGFloat(firstCount)).isActive = true
      } else {
        first = segment
        firstCount = count
      }
    }
    bar.heightAnchor.constraint(equalToConstant: 4).isActive = true
    var rest: [String] = []
    if cancelled > 0 { rest.append("\(cancelled) \(String(localized: "pullRequest.checkStatus.cancelled", defaultValue: "Cancelled"))") }
    if running > 0 {
      rest.append(
        String.localizedStringWithFormat(String(localized: "pullRequest.screens.running", defaultValue: "%lld running"), running))
    }
    if passed > 0 {
      rest.append(
        String.localizedStringWithFormat(String(localized: "pullRequest.checksSection.passed", defaultValue: "%lld passed"), passed))
    }
    let counts = TextLabel(size: Typography.metaSize, color: Palette.textSecondary, lines: 0)
    var runs: [(String, UIColor)] = []
    if failing > 0 {
      runs.append(
        (
          String.localizedStringWithFormat(
            String(localized: "pullRequest.checksSection.failing", defaultValue: "%lld failing"), failing), Palette.statusRed
        ))
      if !rest.isEmpty { runs.append((" · ", Palette.textSecondary)) }
    }
    runs.append((rest.joined(separator: " · "), Palette.textSecondary))
    counts.runs = runs
    let dot = UIView()
    dot.backgroundColor = Palette.statusGreen
    dot.layer.cornerRadius = 3
    dot.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 6), dot.heightAnchor.constraint(equalToConstant: 6)])
    let live = UIStackView(arrangedSubviews: [
      dot, TextLabel(String(localized: "pullRequest.screens.live", defaultValue: "Live"), size: Typography.metaSize, color: Palette.textSecondary),
    ])
    live.spacing = Spacing.xs
    live.alignment = .center
    live.setContentHuggingPriority(.required, for: .horizontal)
    let row = UIStackView(arrangedSubviews: [counts, live])
    row.spacing = Spacing.sm
    row.alignment = .center
    let column = UIStackView(arrangedSubviews: [bar, row])
    column.axis = .vertical
    column.spacing = Spacing.sm
    return column
  }
}
