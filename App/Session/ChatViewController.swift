import OrcaCore
import UIKit

/// One agent chat: the transcript over the glass composer.
final class ChatViewController: UIViewController {
  let model: ChatSessionModel
  private lazy var collection = UICollectionView(frame: .zero, collectionViewLayout: Self.layout())
  private var dataSource: UICollectionViewDiffableDataSource<Int, ChatLine>!
  private let composer = ChatComposerView()
  private let toBottom = UIButton(configuration: .glass())
  private var projection = ChatProjection(rows: [], expanded: [], transcript: ChatTranscript())
  private var expanded: Set<String> = []
  private var followsBottom = true
  /// Called when the agent starts or stops, or its latest words change: (working, latest text).
  var onActivity: ((Bool, String?) -> Void)?
  private var lastReported: (Bool, String?)?

  init(model: ChatSessionModel) {
    self.model = model
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = Palette.bgBase
    collection.backgroundColor = Palette.bgBase
    collection.keyboardDismissMode = .interactive
    collection.delegate = self
    collection.alwaysBounceVertical = true
    view.addSubview(collection)
    view.addSubview(composer)
    collection.translatesAutoresizingMaskIntoConstraints = false

    toBottom.configuration?.image = UIImage(
      systemName: "arrow.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold))
    toBottom.configuration?.baseForegroundColor = Palette.textPrimary
    toBottom.configuration?.cornerStyle = .capsule
    toBottom.configuration?.contentInsets = .init(top: 8, leading: 8, bottom: 8, trailing: 8)
    toBottom.translatesAutoresizingMaskIntoConstraints = false
    toBottom.alpha = 0
    toBottom.accessibilityLabel = String(localized: "chat.scrollToBottom", defaultValue: "Scroll to bottom")
    toBottom.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.collection.setContentOffset(self.collection.contentOffset, animated: false)
        self.followsBottom = true
        self.scrollToBottom(animated: true)
      }, for: .primaryActionTriggered)
    view.addSubview(toBottom)

    NSLayoutConstraint.activate([
      collection.topAnchor.constraint(equalTo: view.topAnchor),
      collection.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      collection.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      collection.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      composer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      composer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      // Rides the keyboard; at rest it sits on the home indicator's safe area.
      composer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
      toBottom.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Spacing.lg),
      toBottom.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -Spacing.sm),
    ])
    view.keyboardLayoutGuide.usesBottomSafeArea = true

    composer.onSend = { [weak self] text in
      guard let self else { return }
      self.followsBottom = true
      Task { await self.model.send(text: text, attachments: []) }
    }
    composer.onStop = { [weak self] in
      Task { await self?.model.stopTurn() }
    }
    composer.onHeightChange = { [weak self] in self?.view.setNeedsLayout() }
    configureDataSource()
    model.start()
    Task { await model.loadOptions() }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // The transcript scrolls under the composer; its last row stops above it.
    let bottom = view.bounds.height - composer.frame.minY + Spacing.sm - view.safeAreaInsets.bottom
    if collection.contentInset.bottom != bottom {
      collection.contentInset.bottom = bottom
      collection.verticalScrollIndicatorInsets.bottom = bottom
      if followsBottom { scrollToBottom(animated: false) }
    }
  }

  override func updateProperties() {
    super.updateProperties()
    projection = ChatProjection(rows: model.rows, expanded: expanded, transcript: model.transcript)
    var snapshot = NSDiffableDataSourceSnapshot<Int, ChatLine>()
    snapshot.appendSections([0])
    snapshot.appendItems(projection.lines)
    snapshot.reconfigureItems(projection.lines)
    dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
      if self?.followsBottom == true { self?.scrollToBottom(animated: false) }
    }
    composer.setWorking(model.isWorking)
    updateModelChip()
    let latest = projection.lines.reversed().lazy.compactMap { line -> String? in
      if case .answer(let id) = line, let item = self.projection.items[id], case .message(let message) = item.body {
        return message.text
      }
      return nil
    }.first
    let report = (model.isWorking, latest.map { String($0.prefix(160)) })
    if lastReported.map({ $0.0 != report.0 || $0.1 != report.1 }) ?? true {
      lastReported = report
      onActivity?(report.0, report.1)
    }
  }

  private func updateModelChip() {
    guard let options = model.options else {
      composer.setModel(title: nil, menu: nil)
      return
    }
    // "Opus 5.5 Med": the model's label, then the effort's.
    let current = options.currentModel
    // The chip uses the short effort names: Med, XHigh (native-chat-session-option-labels.ts).
    let effortChoice = current?.efforts.first { $0.id == options.effort }
    let effort: String? =
      switch effortChoice?.id {
      case "medium": "Med"
      case "xhigh": "XHigh"
      default: effortChoice?.label
      }
    composer.setModel(title: current?.label, detail: effort, menu: nil)
  }

  private static func layout() -> UICollectionViewLayout {
    var list = UICollectionLayoutListConfiguration(appearance: .plain)
    list.showsSeparators = false
    list.backgroundColor = Palette.bgBase
    return UICollectionViewCompositionalLayout.list(using: list)
  }

  private func configureDataSource() {
    func registration<View: UIView>(
      _ make: @escaping () -> View, configure: @escaping (View, ChatLine) -> Void
    ) -> UICollectionView.CellRegistration<UICollectionViewListCell, ChatLine> {
      UICollectionView.CellRegistration { cell, _, line in
        let host: HostedRowView<View>
        if let existing = cell.contentView.subviews.first as? HostedRowView<View> {
          host = existing
        } else {
          cell.contentView.subviews.forEach { $0.removeFromSuperview() }
          host = HostedRowView(make())
          cell.contentView.addSubview(host)
          host.pin(to: cell.contentView)
        }
        configure(host.content, line)
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = Palette.bgBase
        cell.backgroundConfiguration = background
      }
    }
    let user = registration(UserMessageView.init) { [weak self] view, line in
      guard let self else { return }
      switch line {
      case .user(let id):
        if let item = self.projection.items[id], case .message(let message) = item.body {
          view.show(text: message.text, at: item.observedAt, sending: false)
        }
      case .pending(let id):
        if let send = self.projection.pending[id] { view.show(text: send.text, at: nil, sending: true) }
      default: break
      }
    }
    let work = registration(WorkSummaryView.init) { [weak self] view, line in
      guard let self, case .work(let key) = line, let summary = self.projection.work[key] else { return }
      view.show(seconds: summary.seconds, running: summary.running, expanded: self.expanded.contains(key))
    }
    let workItem = registration(WorkItemView.init) { [weak self] view, line in
      guard let self, case .workItem(let id) = line, let item = self.projection.items[id] else { return }
      view.show(item)
    }
    let answer = registration(AnswerView.init) { [weak self] view, line in
      guard let self, case .answer(let id) = line, let item = self.projection.items[id],
        case .message(let message) = item.body
      else { return }
      // The action row shows once the turn has ended, whatever the item's own streaming flag says.
      view.show(markdown: message.text, at: item.observedAt, streaming: message.isStreaming && self.model.isWorking)
    }
    let prompt = registration(PromptCardView.init) { [weak self] view, line in
      guard let self, case .prompt(let id) = line, let item = self.projection.items[id] else { return }
      view.show(item) { [weak self] option in
        Task { _ = await self?.model.respond(to: item, optionId: option) }
      }
    }
    let notice = registration(NoticeDividerView.init) { view, _ in
      view.show(String(localized: "chat.notice.botCreated", defaultValue: "Bot created"))
    }
    dataSource = UICollectionViewDiffableDataSource(collectionView: collection) { collection, indexPath, line in
      switch line {
      case .notice: collection.dequeueConfiguredReusableCell(using: notice, for: indexPath, item: line)
      case .user, .pending: collection.dequeueConfiguredReusableCell(using: user, for: indexPath, item: line)
      case .work: collection.dequeueConfiguredReusableCell(using: work, for: indexPath, item: line)
      case .workItem: collection.dequeueConfiguredReusableCell(using: workItem, for: indexPath, item: line)
      case .answer: collection.dequeueConfiguredReusableCell(using: answer, for: indexPath, item: line)
      case .prompt: collection.dequeueConfiguredReusableCell(using: prompt, for: indexPath, item: line)
      }
    }
  }

  private func scrollToBottom(animated: Bool) {
    collection.layoutIfNeeded()
    let bottom = collection.contentSize.height + collection.adjustedContentInset.bottom - collection.bounds.height
    let target = max(-collection.adjustedContentInset.top, bottom)
    collection.setContentOffset(CGPoint(x: 0, y: target), animated: animated)
  }

  private var distanceFromBottom: CGFloat {
    collection.contentSize.height + collection.adjustedContentInset.bottom - collection.bounds.height
      - collection.contentOffset.y
  }

  private func updateToBottomButton() {
    let show = !followsBottom && distanceFromBottom > 80
    guard (toBottom.alpha > 0) != show else { return }
    UIView.animate(withDuration: 0.2) { self.toBottom.alpha = show ? 1 : 0 }
  }
}

extension ChatViewController: UICollectionViewDelegate {
  func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    followsBottom = false
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    updateToBottomButton()
  }

  func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    if distanceFromBottom <= 1 { followsBottom = true }
    updateToBottomButton()
  }

  func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    if !decelerate, distanceFromBottom <= 1 { followsBottom = true }
  }

  func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
    if case .work = dataSource.itemIdentifier(for: indexPath) { return true }
    return false
  }

  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    collectionView.deselectItem(at: indexPath, animated: false)
    guard case .work(let key) = dataSource.itemIdentifier(for: indexPath) else { return }
    // Opening work is reading, not following the tail.
    followsBottom = false
    UISelectionFeedbackGenerator().selectionChanged()
    if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
    setNeedsUpdateProperties()
  }
}

/// Wraps a plain view so a list cell can host it and keep it across reconfigures.
private final class HostedRowView<Content: UIView>: UIView {
  let content: Content

  init(_ content: Content) {
    self.content = content
    super.init(frame: .zero)
    content.translatesAutoresizingMaskIntoConstraints = false
    addSubview(content)
    content.pin(to: self)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// An approval or question waiting on the user: its title and one glass button per option, the allow
/// option prominent.
final class PromptCardView: UIView {
  private let card = UIView()
  private let title = TextLabel(size: 15, weight: .semibold, lines: 0)
  private let detail = TextLabel(size: Typography.bodySize, color: Palette.textSecondary, lineHeight: 20, lines: 6)
  private let buttons = UIStackView()

  init() {
    super.init(frame: .zero)
    card.translatesAutoresizingMaskIntoConstraints = false
    card.backgroundColor = Palette.bgPanel
    card.layer.cornerRadius = Radius.surface
    card.layer.borderWidth = 1
    buttons.axis = .vertical
    buttons.spacing = Spacing.sm
    let stack = UIStackView(arrangedSubviews: [title, detail, buttons])
    stack.axis = .vertical
    stack.spacing = Spacing.sm
    stack.setCustomSpacing(Spacing.md, after: detail)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(card)
    card.addSubview(stack)
    NSLayoutConstraint.activate([
      card.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.sm),
      card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.lg),
      card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.lg),
      card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.sm),
      stack.topAnchor.constraint(equalTo: card.topAnchor, constant: Spacing.lg),
      stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Spacing.lg),
      stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Spacing.lg),
      stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Spacing.lg),
    ])
    card.layer.borderColor = Palette.floatingCardBorder.resolvedColor(with: traitCollection).cgColor
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func show(_ item: TranscriptItem, onChoose: @escaping (String) -> Void) {
    let prompt: TranscriptItem.Prompt
    switch item.body {
    case .approval(let value), .question(let value): prompt = value
    default: return
    }
    title.text = prompt.title
    detail.text = prompt.detail
    detail.isHidden = (prompt.detail ?? "").isEmpty
    buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
    for option in prompt.options {
      let primary = option.intent?.hasPrefix("allow") ?? false
      var configuration: UIButton.Configuration = primary ? .prominentGlass() : .glass()
      configuration.title = option.label
      configuration.baseForegroundColor = primary ? Palette.onAccent : Palette.textPrimary
      if primary { configuration.baseBackgroundColor = Palette.accentBlue }
      let button = UIButton(configuration: configuration)
      button.isEnabled = prompt.isPending
      button.addAction(UIAction { _ in onChoose(option.id) }, for: .primaryActionTriggered)
      buttons.addArrangedSubview(button)
    }
  }
}
