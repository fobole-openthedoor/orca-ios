import OrcaCore
import UIKit

/// Create a pull request for the branch (PrCreateSheet.tsx): the title and description seeded from the host's
/// prefill and the branch's commits, Write with AI, the base, and Create as draft. A branch the host says needs a
/// push is pushed first; the new PR is linked to the workspace.
final class CreatePullRequestViewController: UIViewController, UITextViewDelegate {
  private let session: HostSession
  private let worktreeId: String
  private let branch: String
  private let pushFirst: Bool
  private let publish: Bool
  private let onCreated: (Int, String) -> Void
  private var eligibility: HostedReviewEligibility?
  private let titleField = UITextField()
  private let bodyView = UITextView()
  private let bodyPlaceholder = UILabel()
  private let baseField = UITextField()
  private let draftSwitch = UISwitch()
  private let aiButton = UIButton(type: .system)
  private let errorLabel = TextLabel(size: Typography.metaSize, color: Palette.statusRed, lines: 0)
  private let stack = UIStackView()
  private var creating = false
  private var generating = false

  /// `pushFirst` pushes before creating; `publish` sets the upstream on that push.
  init(
    session: HostSession, worktreeId: String, branch: String, eligibility: HostedReviewEligibility?, pushFirst: Bool,
    publish: Bool, onCreated: @escaping (Int, String) -> Void
  ) {
    self.session = session
    self.worktreeId = worktreeId
    self.branch = branch
    self.eligibility = eligibility
    self.pushFirst = pushFirst
    self.publish = publish
    self.onCreated = onCreated
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private var reviewLabel: String {
    eligibility?.provider == "gitlab"
      ? String(localized: "sourceControl.hostedReview.mrCopy.reviewLabel", defaultValue: "merge request")
      : String(localized: "sourceControl.hostedReview.prCopy.reviewLabel", defaultValue: "pull request")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = Palette.sheetSurface
    title = String(format: String(localized: "pullRequest.createSheet.title", defaultValue: "Create %1$@"), reviewLabel)
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      title: String(localized: "orcaios.sourceControl.create", defaultValue: "Create"), style: .prominent, target: self,
      action: #selector(create))

    let scroll = UIScrollView()
    scroll.alwaysBounceVertical = true
    scroll.keyboardDismissMode = .interactive
    view.addSubview(scroll)
    scroll.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: view.topAnchor),
      scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
    ])
    stack.axis = .vertical
    stack.spacing = Spacing.sm
    scroll.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Spacing.md),
      stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Spacing.lg),
      stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Spacing.lg),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Spacing.xl),
    ])

    style(titleField, placeholder: String(localized: "pullRequest.createSheet.titleLabel", defaultValue: "Title"))
    style(baseField, placeholder: "main")
    baseField.autocapitalizationType = .none
    baseField.autocorrectionType = .no
    baseField.font = Typography.mono(15)
    for field in [titleField, baseField] {
      field.addAction(UIAction { [weak self] _ in self?.update() }, for: .editingChanged)
    }

    bodyView.font = Typography.font(16)
    bodyView.textColor = Palette.textPrimary
    bodyView.backgroundColor = Palette.sheetGroup
    bodyView.layer.cornerRadius = Radius.control
    bodyView.textContainerInset = UIEdgeInsets(top: Spacing.md, left: Spacing.sm, bottom: Spacing.md, right: Spacing.sm)
    bodyView.delegate = self
    bodyView.heightAnchor.constraint(equalToConstant: 200).isActive = true
    bodyPlaceholder.text = String(localized: "pullRequest.createSheet.descriptionPlaceholder", defaultValue: "Optional")
    bodyPlaceholder.font = bodyView.font
    bodyPlaceholder.textColor = Palette.textMuted
    bodyPlaceholder.translatesAutoresizingMaskIntoConstraints = false
    bodyView.addSubview(bodyPlaceholder)
    NSLayoutConstraint.activate([
      bodyPlaceholder.topAnchor.constraint(equalTo: bodyView.topAnchor, constant: Spacing.md),
      bodyPlaceholder.leadingAnchor.constraint(equalTo: bodyView.leadingAnchor, constant: Spacing.sm + 5),
    ])

    var ai = UIButton.Configuration.plain()
    ai.contentInsets = .zero
    ai.image = Lucide.sparkles.image(size: 14, strokeWidth: 2.2)
    ai.imagePadding = Spacing.xs
    ai.baseForegroundColor = Palette.textPrimary
    ai.attributedTitle = AttributedString(
      String(localized: "pullRequest.createSheet.writeWithAi", defaultValue: "Write with AI"),
      attributes: AttributeContainer([.font: Typography.font(13, .semibold)]))
    aiButton.configuration = ai
    aiButton.addAction(UIAction { [weak self] _ in self?.writeWithAI() }, for: .touchUpInside)
    let descriptionLabel = TextLabel(
      String(localized: "pullRequest.createSheet.descriptionLabel", defaultValue: "Description"), size: 13, weight: .medium,
      color: Palette.textSecondary)
    let descriptionHeader = UIStackView(arrangedSubviews: [descriptionLabel, UIView(), aiButton])
    descriptionHeader.alignment = .center

    let draftRow = UIStackView(arrangedSubviews: [
      TextLabel(String(localized: "pullRequest.createSheet.draft", defaultValue: "Create as draft"), size: 15), UIView(), draftSwitch,
    ])
    draftRow.alignment = .center
    draftRow.isLayoutMarginsRelativeArrangement = true
    draftRow.directionalLayoutMargins = NSDirectionalEdgeInsets(top: Spacing.sm, leading: Spacing.lg, bottom: Spacing.sm, trailing: Spacing.lg)
    draftRow.backgroundColor = Palette.sheetGroup
    draftRow.layer.cornerRadius = Radius.control
    draftSwitch.accessibilityLabel = String(localized: "pullRequest.createSheet.draft", defaultValue: "Create as draft")

    func label(_ text: String) -> UIView {
      TextLabel(text, size: 13, weight: .medium, color: Palette.textSecondary)
    }
    stack.addArrangedSubview(label(String(localized: "pullRequest.createSheet.titleLabel", defaultValue: "Title")))
    stack.addArrangedSubview(titleField)
    stack.setCustomSpacing(Spacing.lg, after: titleField)
    stack.addArrangedSubview(descriptionHeader)
    stack.addArrangedSubview(bodyView)
    stack.setCustomSpacing(Spacing.lg, after: bodyView)
    stack.addArrangedSubview(label(String(localized: "pullRequest.createSheet.base", defaultValue: "Base")))
    stack.addArrangedSubview(baseField)
    stack.setCustomSpacing(Spacing.lg, after: baseField)
    stack.addArrangedSubview(draftRow)
    stack.addArrangedSubview(errorLabel)
    errorLabel.isHidden = true
    seed()
    update()
  }

  private func style(_ field: UITextField, placeholder: String) {
    field.placeholder = placeholder
    field.font = Typography.font(16)
    field.textColor = Palette.textPrimary
    field.backgroundColor = Palette.sheetGroup
    field.layer.cornerRadius = Radius.control
    field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: Spacing.md, height: 1))
    field.leftViewMode = .always
    field.clearButtonMode = .whileEditing
    field.heightAnchor.constraint(equalToConstant: 48).isActive = true
  }

  /// The host's prefill, then GitHub's own default from the branch's commits (hosted-review-create-seed.ts).
  private func seed() {
    let api = session.api
    let worktreeId = worktreeId
    let branch = branch
    let repoId = session.worktree(id: worktreeId)?.repoId ?? ""
    baseField.text = Self.branchName(eligibility?.defaultBaseRef ?? "main")
    titleField.text = eligibility?.title?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? Self.humanize(branch)
    bodyView.text = eligibility?.body ?? ""
    Task { [weak self] in
      guard let base = await api.effectiveBaseRef(worktreeId: worktreeId, repoId: repoId) else { return }
      let compare = try? await api.gitBranchCompare(worktreeId: worktreeId, baseRef: base)
      let page = try? await api.gitHistory(worktreeId: worktreeId, baseRef: nil)
      guard let self, let page, let count = compare?.commitsAhead, count > 0, page.items.count >= count else { return }
      let commits = Array(page.items.prefix(count))
      // A merge in range means the ahead count isn't the branch's own commits.
      guard !commits.contains(where: { $0.parentIds.count > 1 }) else { return }
      let subjects = commits.reversed().map { $0.subject.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
      guard !subjects.isEmpty, (titleField.text ?? "").isEmpty || titleField.text == Self.humanize(branch) else { return }
      let hostTitle = eligibility?.title?.trimmingCharacters(in: .whitespaces).nilIfEmpty
      let hostBody = eligibility?.body?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      if subjects.count == 1 {
        if hostTitle == nil { titleField.text = subjects[0] }
        if hostBody == nil, bodyView.text.isEmpty { bodyView.text = commits[0].bodyAndCoAuthors.body }
      } else if hostBody == nil, bodyView.text.isEmpty {
        bodyView.text = subjects.map { "- \($0)" }.joined(separator: "\n")
      }
      update()
    }
  }

  /// A remote-qualified default (origin/main) as the branch name the API takes.
  private static func branchName(_ ref: String) -> String {
    var name = ref.replacingOccurrences(of: "refs/heads/", with: "").replacingOccurrences(of: "refs/remotes/", with: "")
    if let slash = name.firstIndex(of: "/"), name.hasPrefix("origin/") || name.hasPrefix("upstream/") {
      name = String(name[name.index(after: slash)...])
    }
    return name
  }

  /// `feature/fix-login_page` → "Fix login page".
  private static func humanize(_ branch: String) -> String {
    let leaf = branch.split(separator: "/").last.map(String.init) ?? branch
    let words = leaf.replacingOccurrences(of: "_", with: "-").split(separator: "-").joined(separator: " ")
    guard let first = words.first else { return branch }
    return first.uppercased() + words.dropFirst()
  }

  private func update() {
    bodyPlaceholder.isHidden = !bodyView.text.isEmpty
    let ready =
      !(titleField.text ?? "").trimmingCharacters(in: .whitespaces).isEmpty
      && !(baseField.text ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    navigationItem.rightBarButtonItem?.isEnabled = ready && !creating && !generating
    aiButton.isEnabled = !creating && !(baseField.text ?? "").isEmpty
    aiButton.configuration?.showsActivityIndicator = generating
    for field in [titleField, baseField] as [UIControl] { field.isEnabled = !creating && !generating }
    bodyView.isEditable = !creating && !generating
    draftSwitch.isEnabled = !creating
  }

  func textViewDidChange(_ textView: UITextView) { update() }

  /// `git.generatePullRequestFields`; tapping again while it runs cancels.
  private func writeWithAI() {
    let api = session.api
    let worktreeId = worktreeId
    if generating {
      Task { await api.cancelGeneratePullRequestFields(worktreeId: worktreeId) }
      return
    }
    generating = true
    errorLabel.isHidden = true
    update()
    let provider = eligibility?.provider ?? "github"
    let base = baseField.text ?? "main"
    let title = titleField.text ?? ""
    let body = bodyView.text ?? ""
    let draft = draftSwitch.isOn
    Task { [weak self] in
      do {
        let fields = try await api.generatePullRequestFields(
          worktreeId: worktreeId, provider: provider, base: base, title: title, body: body, draft: draft)
        self?.titleField.text = fields.title
        self?.bodyView.text = fields.body
        UINotificationFeedbackGenerator().notificationOccurred(.success)
      } catch {
        self?.showError(PullRequestController.message(error))
      }
      self?.generating = false
      self?.update()
    }
  }

  private func showError(_ message: String) {
    UINotificationFeedbackGenerator().notificationOccurred(.error)
    errorLabel.text = message
    errorLabel.isHidden = false
  }

  @objc private func create() {
    guard !creating else { return }
    view.endEditing(true)
    creating = true
    errorLabel.isHidden = true
    update()
    let spinner = UIActivityIndicatorView(style: .medium)
    spinner.startAnimating()
    let createItem = navigationItem.rightBarButtonItem
    navigationItem.rightBarButtonItem = UIBarButtonItem(customView: spinner)
    let api = session.api
    let worktreeId = worktreeId
    let pushFirst = pushFirst
    let publish = publish
    let provider = eligibility?.provider ?? "github"
    let base = (baseField.text ?? "").trimmingCharacters(in: .whitespaces)
    let title = titleField.text ?? ""
    let body = bodyView.text ?? ""
    let draft = draftSwitch.isOn
    Task { [weak self] in
      var pushed = false
      do {
        if pushFirst {
          do {
            try await api.gitPush(worktreeId: worktreeId, publish: publish)
            pushed = true
          } catch {
            throw PullRequestReplyError.refused(
              String(
                localized: "sourceControl.hostedReviewService.pushBeforeCreateFailed",
                defaultValue: "Push failed. Resolve the push error, then try again."))
          }
        }
        let created = try await api.createHostedReview(
          worktreeId: worktreeId, provider: provider, base: base, title: title, body: body, draft: draft)
        // The new PR becomes the workspace's link; a failed link still leaves the PR made.
        if provider == "github" { try? await api.setLinkedPullRequest(worktreeId: worktreeId, number: created.number) }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        guard let self else { return }
        onCreated(created.number, created.url)
        dismiss(animated: true)
      } catch {
        guard let self else { return }
        var message = PullRequestController.message(error)
        if pushed {
          message = String(
            format: String(
              localized: "sourceControl.hostedReviewCreate.pushSucceeded",
              defaultValue: "Push succeeded, but %1$@ creation failed: %2$@"),
            provider == "gitlab"
              ? String(localized: "sourceControl.hostedReview.mrCopy.shortLabel", defaultValue: "MR")
              : String(localized: "sourceControl.hostedReview.prCopy.shortLabel", defaultValue: "PR"),
            message.replacingOccurrences(of: "^Create (PR|MR) failed:\\s*", with: "", options: .regularExpression))
        }
        showError(message)
        creating = false
        navigationItem.rightBarButtonItem = createItem
        update()
      }
    }
  }
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
