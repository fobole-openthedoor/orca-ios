import OrcaCore
import UIKit

/// The PR's comments (PrCommentsScreen.tsx): Unresolved or All, unresolved threads first, resolved ones folded
/// at the end; each thread with Reply and Resolve, and a box at the foot for a new comment.
final class PullRequestCommentsViewController: UIViewController {
  private enum Filter: Int { case unresolved, all }

  private let controller: PullRequestController
  private let scroll = UIScrollView()
  private let stack = UIStackView()
  private let segments = UISegmentedControl()
  private let composeBar = UIView()
  private var observation: PRObservation?
  private var filter: Filter?
  private var hideBots = false
  private var showResolved = false

  init(controller: PullRequestController) {
    self.controller = controller
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = Palette.bgBase
    title = String(localized: "pullRequest.commentsSection.title", defaultValue: "Comments")
    navigationItem.largeTitleDisplayMode = .never
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      image: Lucide.listFilter.image(size: 20),
      menu: UIMenu(children: [
        UIDeferredMenuElement.uncached { [weak self] completion in
          guard let self else { return completion([]) }
          completion([
            UIAction(
              title: String(localized: "pullRequest.screens.hideBots", defaultValue: "Hide bots"), image: Lucide.bot.image(size: 18),
              state: hideBots ? .on : .off
            ) { [weak self] _ in
              self?.hideBots.toggle()
              self?.rebuild()
            }
          ])
        }
      ]))
    navigationItem.rightBarButtonItem?.accessibilityLabel = String(
      localized: "pullRequest.screens.filterComments", defaultValue: "Filter comments")

    segments.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        Haptics.select()
        filter = Filter(rawValue: segments.selectedSegmentIndex)
        rebuild()
      }, for: .valueChanged)

    scroll.alwaysBounceVertical = true
    scroll.keyboardDismissMode = .interactive
    stack.axis = .vertical
    stack.spacing = Spacing.md
    composeBar.backgroundColor = Palette.bgBase
    for part in [scroll, composeBar] as [UIView] {
      part.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(part)
    }
    scroll.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: view.topAnchor),
      scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: composeBar.topAnchor),
      composeBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      composeBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      composeBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Spacing.sm),
      stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Spacing.lg),
      stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Spacing.lg),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Spacing.xl),
    ])
    let refresh = UIRefreshControl()
    refresh.addAction(UIAction { [weak self] _ in self?.controller.reread() }, for: .valueChanged)
    scroll.refreshControl = refresh
    observation = controller.observe { [weak self] in self?.rebuild() }
    rebuild()
  }

  private func rebuild() {
    scroll.refreshControl?.endRefreshing()
    stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    composeBar.subviews.forEach { $0.removeFromSuperview() }
    guard let pr = controller.pr else { return }
    navigationItem.subtitle = "#\(pr.number)"
    if pr.isOpen { buildComposeBar(pr) }
    guard let details = controller.details else {
      if controller.detailsFailed {
        stack.addArrangedSubview(
          TextLabel(
            String(localized: "pullRequest.commentsSection.commentsLoadFailedRetry", defaultValue: "Could not load comments."),
            size: Typography.bodySize, color: Palette.statusRed, lines: 0))
      } else {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        stack.addArrangedSubview(spinner)
      }
      return
    }
    let groups = PullRequestCommentGroup.group(details.comments)
    let unresolved = groups.filter(\.isUnresolvedThread)
    let filter = filter ?? (unresolved.isEmpty ? .all : .unresolved)
    segments.removeAllSegments()
    segments.insertSegment(
      withTitle: String.localizedStringWithFormat(
        String(localized: "pullRequest.screens.unresolvedCount", defaultValue: "Unresolved %lld"), unresolved.count),
      at: 0, animated: false)
    segments.insertSegment(
      withTitle: String.localizedStringWithFormat(
        String(localized: "pullRequest.screens.allCount", defaultValue: "All %lld"), groups.count),
      at: 1, animated: false)
    segments.selectedSegmentIndex = filter.rawValue
    stack.addArrangedSubview(segments)

    let shown = { (group: PullRequestCommentGroup) in !self.hideBots || !group.root.isBotAuthored }
    let open = (filter == .unresolved ? unresolved : groups.filter { !$0.isResolved }).filter(shown)
      // Unresolved threads lead; conversation comments follow in timeline order.
      .enumerated().sorted { ($0.element.isUnresolvedThread ? 0 : 1, $0.offset) < ($1.element.isUnresolvedThread ? 0 : 1, $1.offset) }
      .map(\.element)
    let resolved = filter == .all ? groups.filter(\.isResolved).filter(shown) : []
    if open.isEmpty && resolved.isEmpty {
      stack.addArrangedSubview(
        TextLabel(
          filter == .unresolved
            ? String(localized: "pullRequest.screens.noUnresolved", defaultValue: "No unresolved threads.")
            : String(localized: "pullRequest.commentsSection.noComments", defaultValue: "No comments yet."),
          size: Typography.bodySize, color: Palette.textSecondary, lines: 0))
    }
    for group in open { stack.addArrangedSubview(card(group, pr: pr)) }
    if !resolved.isEmpty {
      let header = ListRowView(
        title: String.localizedStringWithFormat(
          String(localized: "pullRequest.screens.resolvedCount", defaultValue: "Resolved %lld"), resolved.count),
        accessory: LucideView(showResolved ? .chevronUp : .chevronDown, size: 16, strokeWidth: 2.2, color: Palette.textMuted)
      ) { [weak self] in
        guard let self else { return }
        Haptics.select()
        showResolved.toggle()
        rebuild()
      }
      stack.addArrangedSubview(ListGroupView(rows: [header]))
      if showResolved { for group in resolved { stack.addArrangedSubview(card(group, pr: pr)) } }
    }
    if let error = controller.error {
      stack.addArrangedSubview(TextLabel(error, size: 13, color: Palette.statusRed, lines: 0))
    }
  }

  /// The box at the foot; it opens the comment sheet.
  private func buildComposeBar(_ pr: PullRequestInfo) {
    let field = PressableControl()
    field.backgroundColor = Palette.composerSurface
    field.layer.cornerRadius = Radius.floating
    field.layer.borderWidth = 1
    field.layer.borderColor = Palette.composerBorder.cgColor
    let placeholder = String(
      format: String(localized: "pullRequest.screens.commentOnPr", defaultValue: "Comment on #%1$@…"), "\(pr.number)")
    let label = TextLabel(placeholder, size: 16, color: Palette.textMuted)
    label.isUserInteractionEnabled = false
    field.addSubview(label)
    label.pin(to: field, insets: UIEdgeInsets(top: Spacing.md, left: Spacing.lg, bottom: Spacing.md, right: Spacing.lg))
    field.accessibilityLabel = placeholder
    field.accessibilityTraits = .button
    field.isAccessibilityElement = true
    field.onPress = { [weak self] in
      guard let self else { return }
      let sheet = PullRequestTextSheet(
        title: String(localized: "pullRequest.commentsSection.comment", defaultValue: "Comment"), placeholder: placeholder,
        submitTitle: String(localized: "pullRequest.commentsSection.comment", defaultValue: "Comment")
      ) { [weak self] body in
        guard let self else { return nil }
        return await controller.addComment(body) ? nil : controller.error
      }
      present(sheet.presented(), animated: true)
    }
    composeBar.addSubview(field)
    field.pin(to: composeBar, insets: UIEdgeInsets(top: Spacing.sm, left: Spacing.lg, bottom: Spacing.sm, right: Spacing.lg))
  }

  /// One comment, or a thread with its replies, and the thread's Reply and Resolve.
  private func card(_ group: PullRequestCommentGroup, pr: PullRequestInfo) -> UIView {
    let column = UIStackView()
    column.axis = .vertical
    column.spacing = Spacing.md
    column.isLayoutMarginsRelativeArrangement = true
    column.directionalLayoutMargins = NSDirectionalEdgeInsets(top: Spacing.md, leading: Spacing.lg, bottom: Spacing.md, trailing: Spacing.lg)
    let root = group.root
    if let path = root.path {
      let location = TextLabel(
        root.line.map { "\(path):\($0)" } ?? path, size: Typography.metaSize, color: Palette.textSecondary)
      location.font = Typography.mono(Typography.metaSize)
      location.lineBreakMode = .byTruncatingHead
      column.addArrangedSubview(location)
    }
    let comments: [PullRequestComment] =
      switch group {
      case .standalone(let comment): [comment]
      case .thread(_, let root, let replies): [root] + replies
      }
    for comment in comments { column.addArrangedSubview(commentView(comment)) }
    if case .thread(let threadId, let root, _) = group, pr.isOpen {
      let reply = actionButton(
        String(localized: "pullRequest.commentCard.reply", defaultValue: "Reply"), icon: .reply,
        busy: controller.isBusy(.reply(threadId))
      ) { [weak self] in
        guard let self else { return }
        let sheet = PullRequestTextSheet(
          title: String(localized: "pullRequest.commentCard.replyToComment", defaultValue: "Reply to comment"),
          placeholder: String(localized: "pullRequest.commentCard.replyPlaceholder", defaultValue: "Write a reply…"),
          submitTitle: String(localized: "pullRequest.commentCard.reply", defaultValue: "Reply")
        ) { [weak self] body in
          guard let self else { return nil }
          return await controller.reply(to: root, body: body) ? nil : controller.error
        }
        present(sheet.presented(), animated: true)
      }
      let resolved = group.isResolved
      let resolve = actionButton(
        resolved
          ? String(localized: "pullRequest.commentCard.unresolve", defaultValue: "Unresolve")
          : String(localized: "pullRequest.commentCard.resolve", defaultValue: "Resolve"),
        icon: resolved ? .rotateCcw : .check, busy: controller.isBusy(.resolve(threadId))
      ) { [weak self] in self?.controller.resolveThread(threadId, resolve: !resolved) }
      let row = UIStackView(arrangedSubviews: [reply, resolve, UIView()])
      row.spacing = Spacing.sm
      column.addArrangedSubview(row)
    }
    let card = UIView()
    card.backgroundColor = Palette.sheetGroup
    card.layer.cornerRadius = Radius.surface
    card.layer.cornerCurve = .continuous
    card.addSubview(column)
    column.translatesAutoresizingMaskIntoConstraints = false
    column.pin(to: card)
    return card
  }

  private func commentView(_ comment: PullRequestComment) -> UIView {
    var runs: [(String, UIColor)] = [(comment.author, Palette.textPrimary)]
    if comment.isBotAuthored {
      runs.append((" · " + String(localized: "pullRequest.screens.bot", defaultValue: "bot"), Palette.textMuted))
    }
    if let time = PRRelativeTime.string(comment.createdAt) { runs.append((" · " + time, Palette.textSecondary)) }
    let byline = TextLabel(size: 13, weight: .semibold)
    byline.runs = runs
    byline.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    var header: [UIView] = [byline, UIView()]
    if let url = URL(string: comment.url), !comment.url.isEmpty {
      var configuration = UIButton.Configuration.plain()
      configuration.image = Lucide.externalLink.image(size: 15)
      configuration.baseForegroundColor = Palette.textMuted
      configuration.contentInsets = .zero
      let open = UIButton(configuration: configuration, primaryAction: UIAction { _ in UIApplication.shared.open(url) })
      open.accessibilityLabel = String(localized: "pullRequest.commentCard.openOnGitHub", defaultValue: "Open comment on GitHub")
      header.append(open)
    }
    let top = UIStackView(arrangedSubviews: header)
    top.alignment = .center
    top.spacing = Spacing.sm
    let body = TextLabel(size: Typography.bodySize, lines: 0)
    body.styledText = PullRequestMarkdown.render(comment.body)
    let column = UIStackView(arrangedSubviews: [top, body])
    column.axis = .vertical
    column.spacing = Spacing.xs
    return column
  }

  private func actionButton(_ title: String, icon: Lucide, busy: Bool, action: @escaping () -> Void) -> UIButton {
    var configuration = UIButton.Configuration.gray()
    configuration.cornerStyle = .capsule
    configuration.baseForegroundColor = Palette.textPrimary
    configuration.image = icon.image(size: 14, strokeWidth: 2.2)
    configuration.imagePadding = Spacing.xs
    configuration.showsActivityIndicator = busy
    configuration.attributedTitle = AttributedString(
      title, attributes: AttributeContainer([.font: Typography.font(13, .semibold)]))
    configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: Spacing.md, bottom: 6, trailing: Spacing.md)
    let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
    button.isEnabled = !busy
    return button
  }
}
