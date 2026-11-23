import OrcaCore
import UIKit

/// The PR segment's body (MobilePRSidebar.tsx MobilePrTabBody): the PR's identity, the gates between it and a
/// merge (checks, threads, approvals, conflicts), its changes card and description; or, without a PR, what the
/// branch has ready and the quiet way to link one.
@MainActor
struct PullRequestTabContent {
  var controller: PullRequestController
  var branch: String?
  /// How many commits the branch has over its base, for the empty state.
  var commitsAhead: (count: Int, base: String)?
  var openChecks: () -> Void
  var openComments: () -> Void
  var openReviewers: () -> Void
  var openChanges: () -> Void
  var editDescription: () -> Void
  var linkPullRequest: () -> Void
  var retry: () -> Void

  /// Fills `stack` with the tab for the controller's state.
  func build(into stack: UIStackView, expandedDescription: Bool, toggleDescription: @escaping () -> Void) {
    stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    switch controller.state {
    case .idle, .loading:
      stack.addArrangedSubview(stateView(.loading(String(localized: "components.prSidebar.loading", defaultValue: "Loading pull request…"))))
    case .error(let message):
      stack.addArrangedSubview(stateView(.error(message)))
    case .none(let orphan):
      buildEmpty(into: stack, orphan: orphan)
    case .ready(let pr):
      buildReady(pr, into: stack, expandedDescription: expandedDescription, toggleDescription: toggleDescription)
    }
    if let notice = controller.error {
      stack.addArrangedSubview(TextLabel(notice, size: Typography.metaSize, color: Palette.statusRed, lines: 0))
    }
  }

  private enum StateKind {
    case loading(String)
    case error(String)
  }

  private func stateView(_ kind: StateKind) -> UIView {
    var config: UIContentUnavailableConfiguration
    switch kind {
    case .loading(let title):
      config = .loading()
      config.text = title
    case .error(let message):
      config = .empty()
      config.image = Lucide.gitPullRequest.image(size: 28, strokeWidth: 1.6)
      config.text = String(localized: "session.prSidebarState.loadFailed", defaultValue: "Unable to load pull request")
      config.secondaryText = message
      var retry = UIButton.Configuration.gray()
      retry.title = String(localized: "common.retry", defaultValue: "Retry")
      config.button = retry
      let action = self.retry
      config.buttonProperties.primaryAction = UIAction { _ in action() }
    }
    let view = UIContentUnavailableView(configuration: config)
    view.heightAnchor.constraint(equalToConstant: 320).isActive = true
    return view
  }

  // MARK: Empty

  private func buildEmpty(into stack: UIStackView, orphan: Int?) {
    let icon = LucideView(.gitPullRequest, size: 28, strokeWidth: 1.6, color: Palette.textMuted)
    let title = TextLabel(
      orphan.map {
        String(
          format: String(
            localized: "pullRequest.prSidebarCreateEmptyState.linkedPrUnavailable", defaultValue: "Linked PR #%1$@ unavailable"),
          "\($0)")
      } ?? String(localized: "pullRequest.emptyState.title", defaultValue: "No pull request yet"),
      size: 16, weight: .semibold, alignment: .center, lines: 0)
    let body: String
    if orphan != nil {
      body = String(
        localized: "pullRequest.prSidebarCreateEmptyState.refreshOrCreate",
        defaultValue: "Refresh to check again, or create a new PR for this branch.")
    } else if let branch, let ahead = commitsAhead, ahead.count > 0 {
      body = String.localizedStringWithFormat(
        String(
          localized: "pullRequest.emptyState.commitsReady",
          defaultValue: "%1$lld commits on %2$@ are ready to go into %3$@."), ahead.count, branch, ahead.base)
    } else if let branch {
      body = String(
        format: String(
          localized: "pullRequest.prSidebarCreateEmptyState.branchNotLinked", defaultValue: "%1$@ is not linked to an open PR."),
        branch)
    } else {
      body = String(
        localized: "pullRequest.prSidebarCreateEmptyState.currentBranchNotLinked",
        defaultValue: "The current branch is not linked to an open PR.")
    }
    let text = TextLabel(body, size: Typography.bodySize, color: Palette.textSecondary, lineHeight: 20, alignment: .center, lines: 0)
    let empty = UIStackView(arrangedSubviews: [icon, title, text])
    empty.axis = .vertical
    empty.alignment = .center
    empty.spacing = Spacing.sm
    empty.isLayoutMarginsRelativeArrangement = true
    empty.directionalLayoutMargins = NSDirectionalEdgeInsets(top: Spacing.xl * 2, leading: Spacing.xl, bottom: Spacing.xl, trailing: Spacing.xl)
    stack.addArrangedSubview(empty)
    let link = ListRowView(
      title: String(localized: "pullRequest.prSidebarCreateEmptyState.linkExistingPullRequest", defaultValue: "Link pull request"),
      leading: LucideView(.link2, size: 18, strokeWidth: 2, color: Palette.textSecondary), navigates: true,
      onPress: linkPullRequest)
    link.isEnabled = !controller.isBusy(.link)
    stack.addArrangedSubview(ListGroupView(rows: [link]))
  }

  // MARK: Ready

  private func buildReady(
    _ pr: PullRequestInfo, into stack: UIStackView, expandedDescription: Bool, toggleDescription: @escaping () -> Void
  ) {
    let details = controller.details
    stack.addArrangedSubview(header(pr, details: details))
    let rows = PullRequestGates.rows(pr: pr, details: details, detailsFailed: controller.detailsFailed,
      checks: controller.checks, checksError: controller.checksError)
    let group = ListGroupView(separatorInset: ListRowView.leadingInset)
    for gate in rows {
      let action: (() -> Void)? =
        switch gate.target {
        case .checks: openChecks
        case .comments: openComments
        case .reviewers: openReviewers
        case nil: nil
        }
      group.add(
        ListRowView(
          title: gate.title, subtitle: gate.subtitle, leading: gate.icon, navigates: action != nil,
          onPress: action.map { open in { Haptics.select(); open() } }))
    }
    stack.addArrangedSubview(group)
    if let card = changesCard(details) { stack.addArrangedSubview(card) }
    stack.addArrangedSubview(description(pr, expanded: expandedDescription, toggle: toggleDescription))
  }

  private func header(_ pr: PullRequestInfo, details: PullRequestDetails?) -> UIView {
    let meta = [
      details?.author,
      PRRelativeTime.string(details?.updatedAt ?? pr.updatedAt).map {
        String(format: String(localized: "pullRequest.tab.updated", defaultValue: "updated %1$@"), $0)
      },
    ].compactMap { $0 }.joined(separator: " · ")
    let number = TextLabel("#\(pr.number)", size: 13, weight: .semibold)
    number.setContentHuggingPriority(.required, for: .horizontal)
    let metaLabel = TextLabel(meta, size: Typography.metaSize, color: Palette.textSecondary)
    metaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let metaRow = UIStackView(arrangedSubviews: [PullRequestBadge.view(pr.state), number, metaLabel, UIView()])
    metaRow.spacing = Spacing.sm
    metaRow.alignment = .center
    let title = TextLabel(details?.title.isEmpty == false ? details?.title : pr.title, size: Typography.titleSize, weight: .semibold, lineHeight: 24, lines: 0)
    title.accessibilityTraits = .header
    let column = UIStackView(arrangedSubviews: [metaRow, title])
    column.axis = .vertical
    column.spacing = Spacing.xs
    if let head = details?.branchName ?? pr.headRefName, let base = details?.baseRefName ?? pr.baseRefName {
      func ref(_ text: String) -> UIView {
        let label = TextLabel(text, size: Typography.metaSize, color: Palette.textSecondary)
        label.font = Typography.mono(Typography.metaSize)
        label.lineBreakMode = .byTruncatingMiddle
        let chip = UIView()
        chip.backgroundColor = Palette.bgRaised
        chip.layer.cornerRadius = Radius.mark
        chip.addSubview(label)
        label.pin(to: chip, insets: UIEdgeInsets(top: 1, left: Spacing.xs, bottom: 1, right: Spacing.xs))
        chip.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return chip
      }
      let refs = UIStackView(arrangedSubviews: [
        ref(head), LucideView(.arrowRight, size: 12, strokeWidth: 2.2, color: Palette.textMuted), ref(base), UIView(),
      ])
      refs.spacing = Spacing.xs
      refs.alignment = .center
      column.addArrangedSubview(refs)
    }
    return column
  }

  /// Files changed, how many the viewer marked viewed, and inline comments; it opens the Changes segment.
  private func changesCard(_ details: PullRequestDetails?) -> UIView? {
    guard let details, let files = details.files, !files.isEmpty else { return nil }
    let additions = files.reduce(0) { $0 + $1.additions }
    let deletions = files.reduce(0) { $0 + $1.deletions }
    let viewed = files.filter(\.viewed).count
    let inline = details.comments.filter { $0.path != nil }
    var meta = [
      String(format: String(localized: "pullRequest.tab.viewedOf", defaultValue: "%1$@ of %2$@ viewed"), "\(viewed)", "\(files.count)")
    ]
    if !inline.isEmpty {
      meta.append(
        String(
          format: String(localized: "pullRequest.tab.commentsOnFiles", defaultValue: "%1$@ comments on %2$@ files"),
          "\(inline.count)", "\(Set(inline.compactMap(\.path)).count)"))
    }
    let title = TextLabel(
      String.localizedStringWithFormat(
        String(localized: "pullRequest.tab.filesChanged", defaultValue: "%lld files changed"), files.count),
      size: 15, weight: .medium)
    let plus = TextLabel("+\(additions)", size: Typography.metaSize, color: Palette.gitDecorationAdded)
    plus.font = Typography.mono(Typography.metaSize)
    let minus = TextLabel("−\(deletions)", size: Typography.metaSize, color: Palette.gitDecorationDeleted)
    minus.font = Typography.mono(Typography.metaSize)
    let top = UIStackView(arrangedSubviews: [title, plus, minus])
    top.spacing = Spacing.sm
    top.alignment = .center
    title.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let progress = UIProgressView(progressViewStyle: .bar)
    progress.progress = Float(viewed) / Float(files.count)
    progress.progressTintColor = Palette.accentBlue
    progress.trackTintColor = Palette.translucentFill
    progress.layer.cornerRadius = 1.5
    progress.clipsToBounds = true
    progress.heightAnchor.constraint(equalToConstant: 3).isActive = true
    let metaLabel = TextLabel(meta.joined(separator: " · "), size: Typography.metaSize, color: Palette.textSecondary, lines: 0)
    let column = UIStackView(arrangedSubviews: [top, progress, metaLabel])
    column.axis = .vertical
    column.spacing = 6
    column.isUserInteractionEnabled = false
    let card = PressableControl()
    card.backgroundColor = Palette.sheetGroup
    card.layer.cornerRadius = Radius.surface
    card.layer.cornerCurve = .continuous
    card.addSubview(column)
    column.pin(to: card, insets: UIEdgeInsets(top: Spacing.md, left: Spacing.lg, bottom: Spacing.md, right: Spacing.lg))
    let open = openChanges
    card.onPress = {
      Haptics.select()
      open()
    }
    card.onPressedChange = { [weak card] pressed in card?.animatePress(pressed, opacity: Feedback.pressedOpacity) }
    card.isAccessibilityElement = true
    card.accessibilityTraits = .button
    card.accessibilityLabel = "\(title.text ?? ""), \(meta.joined(separator: " · "))"
    return card
  }

  /// The PR's description, collapsed to a few lines with Show more, and Edit while the PR is open.
  private func description(_ pr: PullRequestInfo, expanded: Bool, toggle: @escaping () -> Void) -> UIView {
    let details = controller.details
    let editable = pr.isOpen && details != nil && !controller.detailsFailed
    let label = SectionLabelView(
      String(localized: "pullRequest.commentsSection.description", defaultValue: "Description"),
      action: editable ? (String(localized: "pullRequest.tab.edit", defaultValue: "Edit"), editDescription) : nil)
    let column = UIStackView(arrangedSubviews: [label])
    column.axis = .vertical
    column.spacing = Spacing.sm
    if details == nil && !controller.detailsFailed {
      let spinner = UIActivityIndicatorView(style: .medium)
      spinner.startAnimating()
      column.addArrangedSubview(spinner)
    } else if controller.detailsFailed && details == nil {
      column.addArrangedSubview(
        TextLabel(
          String(
            localized: "pullRequest.commentsSection.descriptionLoadFailed",
            defaultValue: "Could not load description. Tap refresh to try again."),
          size: Typography.bodySize, color: Palette.textMuted, lines: 0))
    } else if let body = details?.body.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
      let text = TextLabel(size: Typography.bodySize, lineHeight: 20, lines: expanded ? 0 : 4)
      text.styledText = PullRequestMarkdown.render(body)
      text.numberOfLines = expanded ? 0 : 4
      column.addArrangedSubview(text)
      // Four lines is about the official 84 pt fold; longer bodies get the toggle.
      if body.count > 240 || body.components(separatedBy: .newlines).count > 4 {
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = .zero
        configuration.attributedTitle = AttributedString(
          expanded
            ? String(localized: "pullRequest.tab.showLess", defaultValue: "Show less")
            : String(localized: "pullRequest.tab.showMore", defaultValue: "Show more"),
          attributes: AttributeContainer([.font: Typography.font(Typography.bodySize, .semibold), .foregroundColor: Palette.textPrimary]))
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in toggle() })
        button.contentHorizontalAlignment = .leading
        column.addArrangedSubview(button)
      }
    } else {
      column.addArrangedSubview(
        TextLabel(
          String(localized: "pullRequest.commentsSection.noDescription", defaultValue: "No description provided."),
          size: Typography.bodySize, color: Palette.textMuted, lines: 0))
    }
    return column
  }
}

/// A PR body or comment as styled text: the chat's Markdown, code blocks in mono.
enum PullRequestMarkdown {
  static func render(_ source: String, size: CGFloat = Typography.bodySize) -> NSAttributedString {
    let cleaned = source.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let output = NSMutableAttributedString()
    for block in ChatMarkdown.render(cleaned) {
      if output.length > 0 { output.append(NSAttributedString(string: "\n")) }
      switch block {
      case .text(let text): output.append(text)
      case .code(_, let code):
        output.append(
          NSAttributedString(
            string: code, attributes: [.font: Typography.mono(size - 1), .foregroundColor: Palette.textSecondary]))
      case .rule: break
      }
    }
    return output
  }
}

/// The gates between a PR and its merge (pr-tab-gates.ts): passed green, blocking red, waiting amber,
/// idle muted, loading a spinner.
enum PullRequestGates {
  enum Tone { case passed, blocking, waiting, idle, loading }
  enum Target { case checks, comments, reviewers }

  struct Row {
    var key: String
    var tone: Tone
    var title: String
    var subtitle: String?
    var target: Target?

    @MainActor var icon: UIView {
      if tone == .loading {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = Palette.textSecondary
        spinner.startAnimating()
        return spinner
      }
      let glyph: Lucide =
        switch tone {
        case .waiting where key == "threads": .messageCircle
        case .waiting where key == "checks": .loaderCircle
        case .passed: .circleCheck
        case .blocking: .circleX
        case .waiting: .circleDashed
        default: .circleMinus
        }
      let color: UIColor =
        switch tone {
        case .passed: Palette.statusGreen
        case .blocking: Palette.statusRed
        case .waiting: Palette.statusAmber
        default: Palette.textMuted
        }
      return LucideView(glyph, size: 20, strokeWidth: 2, color: color)
    }
  }

  static func rows(
    pr: PullRequestInfo, details: PullRequestDetails?, detailsFailed: Bool, checks: [PullRequestCheck], checksError: String?
  ) -> [Row] {
    let loading = details == nil && !detailsFailed
    return [
      checksGate(pr: pr, checks: checks, error: checksError),
      threadsGate(details: details, loading: loading),
      approvalsGate(pr: pr, details: details, loading: loading),
      conflictsGate(pr: pr, detailsBase: details?.baseRefName),
    ]
  }

  private static func checksGate(pr: PullRequestInfo, checks: [PullRequestCheck], error: String?) -> Row {
    if let error {
      return Row(
        key: "checks", tone: .idle,
        title: String(localized: "pullRequest.gates.checksUnavailable", defaultValue: "Checks unavailable"), subtitle: error,
        target: .checks)
    }
    let summary = PullRequestCheck.summarize(checks)
    let broken = checks.filter { $0.outcome == .failed && !$0.isCancelled }
    if !broken.isEmpty {
      return Row(
        key: "checks", tone: .blocking,
        title: String.localizedStringWithFormat(
          String(localized: "pullRequest.gates.checksFailing", defaultValue: "%lld checks failing"), broken.count),
        subtitle: broken.map(\.name).joined(separator: ", "), target: .checks)
    }
    if summary.pending > 0 {
      return Row(
        key: "checks", tone: .waiting,
        title: String.localizedStringWithFormat(
          String(localized: "pullRequest.gates.checksRunning", defaultValue: "%lld checks running"), summary.pending),
        subtitle: summary.passed > 0
          ? String.localizedStringWithFormat(
            String(localized: "pullRequest.gates.checksPassedSoFar", defaultValue: "%lld passed so far"), summary.passed)
          : nil,
        target: .checks)
    }
    if summary.outcome == "cancelled" {
      return Row(
        key: "checks", tone: .idle, title: String(localized: "pullRequest.checkStatus.cancelled", defaultValue: "Cancelled"),
        subtitle: nil, target: .checks)
    }
    if summary.total == 0 {
      return Row(
        key: "checks", tone: .idle, title: String(localized: "pullRequest.gates.noChecks", defaultValue: "No checks"),
        subtitle: nil, target: .checks)
    }
    let other = summary.total - summary.passed
    return Row(
      key: "checks", tone: summary.passed > 0 ? .passed : .idle,
      title: summary.passed == 0
        ? String(localized: "pullRequest.gates.checksFinished", defaultValue: "Checks finished")
        : String.localizedStringWithFormat(
          String(localized: "pullRequest.gates.checksPassed", defaultValue: "%lld checks passed"), summary.passed),
      subtitle: other > 0
        ? String.localizedStringWithFormat(
          String(localized: "pullRequest.gates.checksNeutral", defaultValue: "%lld neutral"), other)
        : nil,
      target: .checks)
  }

  private static func threadsGate(details: PullRequestDetails?, loading: Bool) -> Row {
    guard let details else {
      return Row(
        key: "threads", tone: loading ? .loading : .idle,
        title: String(localized: "pullRequest.gates.threads", defaultValue: "Review threads"),
        subtitle: loading ? nil : String(localized: "pullRequest.gates.commentsUnavailable", defaultValue: "Comments unavailable"),
        target: .comments)
    }
    let threads = PullRequestCommentGroup.group(details.comments).filter(\.isThread)
    let unresolved = threads.filter { !$0.isResolved }
    guard let first = unresolved.first?.root else {
      return Row(
        key: "threads", tone: threads.isEmpty ? .idle : .passed,
        title: threads.isEmpty
          ? String(localized: "pullRequest.gates.noThreads", defaultValue: "No review threads")
          : String(localized: "pullRequest.gates.allThreadsResolved", defaultValue: "All threads resolved"),
        subtitle: nil, target: .comments)
    }
    var parts = [
      first.path.flatMap { $0.split(separator: "/").last.map(String.init) }.map {
        String(format: String(localized: "pullRequest.gates.threadAuthorOnFile", defaultValue: "%1$@ on %2$@"), first.author, $0)
      } ?? first.author
    ]
    let bots = unresolved.filter(\.root.isBotAuthored).count
    if bots > 0 {
      parts.append(
        String.localizedStringWithFormat(String(localized: "pullRequest.gates.fromBots", defaultValue: "%lld from bots"), bots))
    }
    return Row(
      key: "threads", tone: .waiting,
      title: String.localizedStringWithFormat(
        String(localized: "pullRequest.gates.unresolvedThreads", defaultValue: "%lld unresolved threads"), unresolved.count),
      subtitle: parts.joined(separator: " · "), target: .comments)
  }

  private static func approvalsGate(pr: PullRequestInfo, details: PullRequestDetails?, loading: Bool) -> Row {
    let decision = details?.reviewDecision ?? pr.reviewDecision
    let reviews = details?.latestReviews ?? []
    let approved = reviews.filter { $0.state == "APPROVED" }.map(\.login)
    let changes = reviews.filter { $0.state == "CHANGES_REQUESTED" }.map(\.login)
    let requested = (details?.reviewRequests ?? []).map(\.login)
    if decision == "CHANGES_REQUESTED" || !changes.isEmpty {
      return Row(
        key: "approvals", tone: .blocking,
        title: String(localized: "pullRequest.gates.changesRequested", defaultValue: "Changes requested"),
        subtitle: changes.isEmpty
          ? nil
          : String(
            format: String(localized: "pullRequest.gates.requestedChangesBy", defaultValue: "%1$@ requested changes"),
            changes.joined(separator: ", ")),
        target: .reviewers)
    }
    var parts: [String] = []
    if !approved.isEmpty {
      parts.append(
        String(format: String(localized: "pullRequest.gates.approvedBy", defaultValue: "%1$@ approved"), approved.joined(separator: ", ")))
    }
    if !requested.isEmpty {
      parts.append(
        String(
          format: String(localized: "pullRequest.gates.reviewRequestedFrom", defaultValue: "%1$@ requested"),
          requested.joined(separator: ", ")))
    } else if decision == "REVIEW_REQUIRED" {
      parts.append(String(localized: "pullRequest.gates.reviewRequired", defaultValue: "Review required"))
    }
    let tone: Tone =
      details == nil && loading
      ? .loading
      : decision == "REVIEW_REQUIRED" || !requested.isEmpty ? .waiting : !approved.isEmpty || decision == "APPROVED" ? .passed : .idle
    return Row(
      key: "approvals", tone: tone,
      title: approved.isEmpty
        ? String(localized: "pullRequest.gates.noApprovals", defaultValue: "No approvals yet")
        : String.localizedStringWithFormat(
          String(localized: "pullRequest.gates.approvals", defaultValue: "%lld approvals"), approved.count),
      subtitle: parts.isEmpty ? nil : parts.joined(separator: " · "), target: .reviewers)
  }

  private static func conflictsGate(pr: PullRequestInfo, detailsBase: String?) -> Row {
    let base = pr.conflictBaseRef ?? pr.baseRefName ?? detailsBase
    if pr.hasConflicts {
      let files = pr.conflictFiles.count
      return Row(
        key: "conflicts", tone: .blocking,
        title: base.map {
          String(format: String(localized: "pullRequest.gates.conflictsWithBase", defaultValue: "Conflicts with %1$@"), $0)
        } ?? String(localized: "pullRequest.gates.conflicts", defaultValue: "Merge conflicts"),
        subtitle: files == 0
          ? nil
          : String.localizedStringWithFormat(String(localized: "pullRequest.gates.conflictFiles", defaultValue: "%lld files"), files),
        target: nil)
    }
    // Green only on GitHub's word: UNKNOWN or missing metadata means it is still computing.
    let clean =
      pr.mergeable == "MERGEABLE" || ["CLEAN", "UNSTABLE", "HAS_HOOKS", "BLOCKED", "BEHIND"].contains(pr.mergeStateStatus ?? "")
    guard clean else {
      return Row(
        key: "conflicts", tone: .idle,
        title: String(localized: "pullRequest.gates.conflictsChecking", defaultValue: "Checking for conflicts"), subtitle: nil,
        target: nil)
    }
    return Row(
      key: "conflicts", tone: .passed,
      title: base.map {
        String(format: String(localized: "pullRequest.gates.noConflictsWithBase", defaultValue: "No conflicts with %1$@"), $0)
      } ?? String(localized: "pullRequest.gates.noConflicts", defaultValue: "No conflicts"),
      subtitle: nil, target: nil)
  }
}
