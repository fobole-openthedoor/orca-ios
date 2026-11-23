import OrcaCore
import PhotosUI
import SafariServices
import UIKit
import UniformTypeIdentifiers

/// One agent chat: the transcript over the glass composer.
final class ChatViewController: UIViewController {
  let model: ChatSessionModel
  private lazy var collection = UICollectionView(frame: .zero, collectionViewLayout: Self.layout())
  private var dataSource: UICollectionViewDiffableDataSource<Int, ChatLine>!
  private let composer = ChatComposerView()
  private let dock = ChatDockView()
  private let toBottom = UIButton(configuration: .glass())
  private var projection = ChatProjection(rows: [], expanded: [], transcript: ChatTranscript())
  private var expanded: Set<String> = []
  private var openThoughts: Set<String> = []
  /// Activity lines opened to their calls, and calls opened to their input and output.
  private var openRuns: Set<String> = []
  private var openCalls: Set<String> = []
  private var lastWorking: Bool?
  /// Questions this screen already opened on its own; closing one never reopens it unasked.
  private var presentedPrompts: Set<String> = []
  private var followsBottom = true
  /// Called when the agent starts or stops, or its latest words change: (working, latest text).
  var onActivity: ((Bool, String?) -> Void)?
  /// A file path tapped in the transcript, as written there.
  var onOpenPath: ((String) -> Void)?
  /// Fork from a response: a new chat holding this one through that item.
  var onFork: ((String) -> Void)?
  /// Reads the images messages point at from the workspace's host.
  /// A bot's chat: its quiet answers (NO_REPLY) don't show their marker.
  var isBotChat = false
  var imageLoader: ChatImageLoader? {
    didSet {
      model.onImageUploaded = { [weak imageLoader] path, data in
        Task { @MainActor in imageLoader?.remember(path, data: data) }
      }
    }
  }
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
    view.addSubview(dock)
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
      dock.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      dock.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      dock.bottomAnchor.constraint(equalTo: composer.topAnchor),
      toBottom.bottomAnchor.constraint(equalTo: dock.topAnchor, constant: -Spacing.sm),
    ])
    view.keyboardLayoutGuide.usesBottomSafeArea = true

    // What was typed here before, and not sent, comes back.
    let draft = ChatDraftStore.load(model.sessionId)
    composer.restore(text: draft.text, attachments: draft.attachments)
    NotificationCenter.default.addObserver(
      self, selector: #selector(saveDraft), name: UIApplication.willResignActiveNotification, object: nil)
    composer.onSend = { [weak self] text, attachments in
      guard let self else { return }
      ChatDraftStore.save(self.model.sessionId, text: "", attachments: [])
      self.followsBottom = true
      Task {
        if let refusal = await self.model.submit(text: text, attachments: attachments) { self.say(refusal) }
      }
    }
    composer.onPickPhotos = { [weak self] in self?.pickPhotos() }
    composer.onTakePhoto = { [weak self] in self?.takePhoto() }
    composer.onPickFiles = { [weak self] in self?.pickFiles() }
    composer.onOpenImages = { [weak self] images, index in
      self?.present(ImageViewerController(sources: images.map { .image($0) }, index: index), animated: true)
    }
    composer.onError = { [weak self] message in self?.say(message) }
    dock.onOpen = { [weak self] task in self?.openBackgroundTask(task) }
    dock.onGoal = { [weak self] change in
      guard let self else { return }
      Task { if let refusal = await self.model.changeGoal(change) { self.say(refusal) } }
    }
    dock.onStop = { [weak self] taskId in
      guard let self else { return }
      Task { if let refusal = await self.model.stopBackgroundTask(taskId) { self.say(refusal) } }
    }
    composer.onStop = { [weak self] in
      Task { await self?.model.stopTurn() }
    }
    composer.onHeightChange = { [weak self] in self?.view.setNeedsLayout() }
    configureDataSource()
    // Text size, font or spacing changed: every row lays out again.
    NotificationCenter.default.addObserver(forName: ChatTextSettings.changed, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        var snapshot = self.dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        self.dataSource.apply(snapshot, animatingDifferences: false)
        self.collection.collectionViewLayout.invalidateLayout()
      }
    }
    model.start()
    Task { await model.loadOptions() }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // The transcript scrolls under the composer; its last row stops above it.
    // The docked strips sit over the transcript's tail too.
    let top = dock.isHidden ? composer.frame.minY : dock.frame.minY
    let bottom = view.bounds.height - top + Spacing.sm - view.safeAreaInsets.bottom
    if collection.contentInset.bottom != bottom {
      collection.contentInset.bottom = bottom
      collection.verticalScrollIndicatorInsets.bottom = bottom
      if followsBottom { scrollToBottom(animated: false) }
    }
  }

  override func updateProperties() {
    super.updateProperties()
    projection = ChatProjection(
      rows: model.rows, expanded: expanded, openThoughts: openThoughts, openRuns: openRuns, transcript: model.transcript)
    var snapshot = NSDiffableDataSourceSnapshot<Int, ChatLine>()
    snapshot.appendSections([0])
    snapshot.appendItems(projection.lines)
    snapshot.reconfigureItems(projection.lines)
    dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
      if self?.followsBottom == true { self?.scrollToBottom(animated: false) }
    }
    composer.setWorking(model.isWorking)
    // A turn's end moves the goal's time and status; read them again.
    if lastWorking == true, !model.isWorking { Task { await model.refreshOptions() } }
    lastWorking = model.isWorking
    dock.show(tasks: model.transcript.backgroundTasks, stopsAll: model.transcript.stopsBackgroundTasks, goal: model.options?.goal)
    view.setNeedsLayout()
    presentNewPrompt()
    updateModelChip()
    // The newest words of the current turn: its latest answer, else what was asked, never the last turn's reply.
    let latest = projection.lines.reversed().lazy.compactMap { line -> String? in
      switch line {
      case .answer(let id), .user(let id):
        if let item = self.projection.items[id], case .message(let message) = item.body, !message.text.isEmpty {
          return message.text
        }
        return nil
      case .pending(let id): return self.projection.pending[id]?.text
      default: return nil
      }
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
    composer.setModel(title: current?.label, detail: effort, menu: modelMenu(options))
  }

  /// The chip's menu (native-chat session options): the model, its effort, fast and plan mode.
  private func modelMenu(_ options: ChatOptions) -> UIMenu {
    let current = options.currentModel
    let models = options.models.filter { !$0.id.isEmpty }.map { choice in
      UIAction(
        title: choice.label, subtitle: choice.description,
        state: choice.id == current?.id ? .on : .off
      ) { [weak self] _ in self?.setOption("model", choice.id) }
    }
    var children: [UIMenuElement] = [
      UIMenu(title: String(localized: "chat.sessionOptionCopy.model", defaultValue: "Model"), options: .displayInline, children: models)
    ]
    if let efforts = current?.efforts, !efforts.isEmpty {
      children.append(
        UIMenu(
          title: String(localized: "chat.sessionOptionCopy.effort", defaultValue: "Effort"), options: .displayInline,
          children: efforts.map { effort in
            UIAction(title: Self.effortLabel(effort), state: effort.id == options.effort ? .on : .off) { [weak self] _ in
              self?.setOption("effort", effort.id)
            }
          }))
    }
    var toggles: [UIMenuElement] = []
    if options.fastModeSupported, current?.supportsFastMode ?? true {
      let on = options.fastMode == true
      toggles.append(
        UIAction(
          title: String(localized: "chat.sessionOptionCopy.fastMode", defaultValue: "Fast mode"), image: UIImage(systemName: "hare"),
          state: on ? .on : .off
        ) { [weak self] _ in self?.setOption("fastMode", on ? "false" : "true") })
    }
    if options.planModeSupported {
      let planning = options.interactionMode == "plan"
      toggles.append(
        UIAction(
          title: String(localized: "chat.notice.plan", defaultValue: "Plan"), image: UIImage(systemName: "list.bullet.clipboard"),
          state: planning ? .on : .off
        ) { [weak self] _ in self?.setOption("interactionMode", planning ? "default" : "plan") })
    }
    if !toggles.isEmpty { children.append(UIMenu(options: .displayInline, children: toggles)) }
    return UIMenu(title: String(localized: "chat.sessionOptionCopy.sessionOptions", defaultValue: "Session options"), children: children)
  }

  /// An effort as the official picker names it, by its id.
  private static func effortLabel(_ effort: ChatOptions.Choice) -> String {
    let known = ["none", "off", "minimal", "low", "medium", "high", "xhigh", "max", "ultra", "ultracode"]
    guard known.contains(effort.id) else { return effort.label }
    return Bundle.main.localizedString(forKey: "chat.sessionOptionCopy.\(effort.id)", value: effort.label, table: nil)
  }

  private func setOption(_ key: String, _ value: String) {
    UISelectionFeedbackGenerator().selectionChanged()
    Task {
      if let refusal = await model.setOption(key, value) { say(refusal) }
    }
  }

  /// A link from the transcript, where Settings › Browser says (ask, the in-app browser, or Safari).
  private func open(_ url: URL) {
    guard url.scheme == "http" || url.scheme == "https" else {
      UIApplication.shared.open(url)
      return
    }
    let inApp = { [weak self] in self?.present(SFSafariViewController(url: url), animated: true) }
    let safari = { UIApplication.shared.open(url) }
    switch PhoneSettings.linkOpenMode {
    case .orcaBrowser: inApp()
    case .phoneBrowser: safari()
    case .ask:
      let sheet = UIAlertController(title: url.host, message: url.absoluteString, preferredStyle: .actionSheet)
      sheet.addAction(UIAlertAction(title: String(localized: "orcaios.links.inApp", defaultValue: "Open here"), style: .default) { _ in inApp() })
      sheet.addAction(UIAlertAction(title: String(localized: "orcaios.links.safari", defaultValue: "Open in Safari"), style: .default) { _ in safari() })
      sheet.addAction(UIAlertAction(title: String(localized: "common.copy", defaultValue: "Copy"), style: .default) { _ in
        UIPasteboard.general.url = url
      })
      sheet.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "Cancel"), style: .cancel))
      present(sheet, animated: true)
    }
  }

  /// Rewind to here, once confirmed: the message comes back to the composer to edit and send again.
  /// A background task's row opens the call that started it: a subagent's task and what it returned, or a
  /// shell's command and its output so far. Matched by call id, else by the label the strip shows.
  private func openBackgroundTask(_ task: BackgroundTask) {
    let label = task.label.trimmingCharacters(in: .whitespacesAndNewlines)
    let match = model.transcript.items.reversed().first { item in
      guard case .toolCall(let call) = item.body else { return false }
      if call.callId == task.id { return true }
      guard !label.isEmpty else { return false }
      return ["description", "command", "prompt"].contains { call.input[$0]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) == label }
    }
    guard let item = match, case .toolCall(let call) = item.body else {
      let alert = UIAlertController(title: label.isEmpty ? task.kind : label, message: nil, preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: String(localized: "common.ok", defaultValue: "OK"), style: .default))
      present(alert, animated: true)
      return
    }
    let model = self.model
    let id = item.id
    present(
      ToolOutputViewController.sheet(call: call) {
        guard let full = await model.fullItem(id), case .toolCall(let whole) = full.body else { return nil }
        return whole
      }, animated: true)
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    saveDraft()
  }

  @objc private func saveDraft() {
    ChatDraftStore.save(model.sessionId, text: composer.draftText, attachments: composer.attachments)
  }

  private func imageSources(_ paths: [String]) -> [ImageViewerController.Source] {
    guard let loader = imageLoader else { return [] }
    return paths.map { path in
      if let image = loader.cached(path) { return .image(image) }
      return .load { await loader.image(path) }
    }
  }

  private static func localImages(_ attachments: [OutgoingAttachment]) -> [ImageViewerController.Source] {
    attachments.filter { $0.kind == .image }.compactMap { UIImage(data: $0.data) }.map { .image($0) }
  }

  /// Opens the viewer on one message's image, with every image in the chat to swipe through in order.
  private func openImage(ownerId: String, index: Int) {
    var all: [ImageViewerController.Source] = []
    var start = 0
    for item in model.transcript.items {
      guard case .message(let message) = item.body, message.role == "user" else { continue }
      if item.id == ownerId { start = all.count + index }
      all += imageSources(message.imagePaths)
    }
    for send in model.pending {
      if send.id == ownerId { start = all.count + index }
      all += Self.localImages(send.attachments)
    }
    guard !all.isEmpty else { return }
    present(ImageViewerController(sources: all, index: start), animated: true)
  }

  private func rewind(to item: TranscriptItem, text: String) {
    guard !model.isWorking else { return say(String(localized: "chat.rewind.busy", defaultValue: "Available when the chat is idle")) }
    let alert = UIAlertController(
      title: String(localized: "chat.rewind.title", defaultValue: "Rewind to here?"),
      message: String(
        localized: "chat.rewind.confirmation",
        defaultValue: "Discard this message and everything after it? The message returns to the composer so you can edit and resend it. File changes on disk stay."),
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "Cancel"), style: .cancel))
    alert.addAction(
      UIAlertAction(title: String(localized: "chat.rewind.confirm", defaultValue: "Rewind"), style: .destructive) { [weak self] _ in
        guard let self else { return }
        Task {
          if let refusal = await self.model.rewind(to: item) {
            self.say(refusal == "unavailable" ? String(localized: "chat.rewind.unavailable", defaultValue: "Wait for the chat to finish connecting.") : refusal)
          } else {
            self.composer.setText(text)
          }
        }
      })
    present(alert, animated: true)
  }

  /// "Scroll this message to top": the row's top under the tab strip.
  private func scrollToTop(_ line: ChatLine) {
    guard let indexPath = dataSource.indexPath(for: line) else { return }
    followsBottom = false
    collection.scrollToItem(at: indexPath, at: .top, animated: true)
  }

  private func say(_ message: String) {
    let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: String(localized: "common.ok", defaultValue: "OK"), style: .default))
    present(alert, animated: true)
  }

  // MARK: Attach

  private func pickPhotos() {
    var configuration = PHPickerConfiguration()
    configuration.filter = .images
    configuration.selectionLimit = 10
    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = self
    present(picker, animated: true)
  }

  private func takePhoto() {
    guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.delegate = self
    present(picker, animated: true)
  }

  /// UIDocumentPickerViewController rather than fileImporter: the latter fails under self-signed installs.
  private func pickFiles() {
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
    picker.allowsMultipleSelection = true
    picker.delegate = self
    present(picker, animated: true)
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
          view.show(text: message.text, images: self.imageSources(message.imagePaths), at: item.observedAt, sending: false)
          view.onRewind = { [weak self] in self?.rewind(to: item, text: message.text) }
          view.onOpenImage = { [weak self] index in self?.openImage(ownerId: id, index: index) }
        }
      case .pending(let id):
        if let send = self.projection.pending[id] {
          view.show(text: send.text, images: Self.localImages(send.attachments), at: nil, sending: true)
          view.onOpenImage = { [weak self] index in self?.openImage(ownerId: id, index: index) }
        }
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
      // Only a turn's last words carry the time and actions, once it has ended.
      let streaming = !self.projection.finalAnswers.contains(id)
      var text = message.text
      if self.isBotChat {
        let quiet = BotQuietResult.strip(text)
        if quiet.quiet {
          // Only a turn's last words say there was nothing to report; mid-turn the marker just goes.
          text = quiet.words.isEmpty && !streaming
            ? String(localized: "bots.chat.nothingToReport", defaultValue: "Nothing to report")
            : quiet.words
        }
      }
      view.show(markdown: text, at: item.observedAt, streaming: streaming)
      view.onOpenURL = { [weak self] url in self?.open(url) }
      view.onFork = { [weak self] in self?.onFork?(id) }
      view.onScrollToTop = { [weak self] in self?.scrollToTop(line) }
      view.onOpenPath = { [weak self] path in self?.onOpenPath?(path) }
    }
    let activity = registration(ActivityRowView.init) { [weak self] view, line in
      guard let self else { return }
      switch line {
      case .run(let key):
        guard let run = self.projection.runs[key] else { return }
        let calls = run.calls
        // A running run names what it is doing now; a settled one counts what it did.
        let detail = run.running ? calls.last?.summary : nil
        view.show(
          icon: ToolCategory.icon(for: calls), text: ToolCategory.sentence(for: calls, live: run.running), detail: detail,
          running: run.running, expanded: self.openRuns.contains(key))
      case .thoughts(let key):
        guard let group = self.projection.thoughts[key] else { return }
        let text = group.live
          ? String(localized: "chat.turnStatus.thinking", defaultValue: "Thinking")
          : "Thought for " + Self.shortDuration(group.seconds ?? 1)
        view.show(icon: .brain, text: text, running: group.live, opens: !group.live, expanded: self.openThoughts.contains(key))
      case .prompt(let id):
        guard let item = self.projection.items[id] else { return }
        let waiting = ChatProjection.isWaiting(item)
        let approval: Bool = { if case .approval = item.body { true } else { false } }()
        var text: String
        if waiting {
          text = approval
            ? String(localized: "orcaios.chat.awaitingApproval", defaultValue: "Waiting for your approval")
            : String(localized: "orcaios.chat.awaitingAnswer", defaultValue: "Waiting for your answer")
        } else {
          text = Self.receipt(item)
        }
        view.show(icon: waiting ? .messageSquareMore : .check, text: text, detail: Self.promptTitle(item), running: false, attention: waiting, opens: waiting)
      case .working:
        view.show(icon: .circleDot, text: String(localized: "chat.turnStatus.working", defaultValue: "Working…"), running: true, opens: false)
      default: break
      }
    }
    let thoughtText = registration(ThoughtTextView.init) { [weak self] view, line in
      guard let self, case .thoughtText(let id) = line, let item = self.projection.items[id], case .message(let message) = item.body else { return }
      view.show(message.text)
    }
    let files = registration(ChangedFilesView.init) { [weak self] view, line in
      guard let self, case .files(let key) = line, let list = self.projection.files[key] else { return }
      view.show(list)
      view.onOpen = { [weak self] file in self?.present(PatchSheetController.sheet(file), animated: true) }
    }
    let call = registration(ToolCallView.init) { [weak self] view, line in
      guard let self, case .call(let id) = line, let item = self.projection.items[id], case .toolCall(let call) = item.body
      else { return }
      view.show(call, open: self.openCalls.contains(id))
      view.onShowFull = { [weak self] in
        guard let self else { return }
        let model = self.model
        self.present(
          ToolOutputViewController.sheet(call: call) {
            guard let full = await model.fullItem(id), case .toolCall(let whole) = full.body else { return nil }
            return whole
          }, animated: true)
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
      case .run, .thoughts, .prompt, .working: collection.dequeueConfiguredReusableCell(using: activity, for: indexPath, item: line)
      case .thoughtText: collection.dequeueConfiguredReusableCell(using: thoughtText, for: indexPath, item: line)
      case .call: collection.dequeueConfiguredReusableCell(using: call, for: indexPath, item: line)
      case .files: collection.dequeueConfiguredReusableCell(using: files, for: indexPath, item: line)
      }
    }
  }

  /// A question that arrives while this chat is on screen opens its sheet once.
  private func presentNewPrompt() {
    guard view.window != nil, presentedViewController == nil,
      let id = projection.waiting.first(where: { !presentedPrompts.contains($0) }), let item = projection.items[id]
    else { return }
    presentedPrompts.insert(id)
    presentPrompt(item)
  }

  private func presentPrompt(_ item: TranscriptItem) {
    guard presentedViewController == nil,
      let sheet = PromptSheetController.sheet(item: item, onAnswer: { [weak self] response in
        switch response {
        case .option(let id): return await self?.model.respond(to: item, optionId: id)
        case .answers(let answers): return await self?.model.answer(item, with: answers)
        }
      })
    else { return }
    presentedPrompts.insert(item.id)
    present(sheet, animated: true)
  }

  /// "1s", "2m 3s": the reasoning row's own short form, unlocalised as the official row writes it.
  static func shortDuration(_ seconds: Int) -> String {
    seconds < 60 ? "\(seconds)s" : seconds < 3600 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds / 3600)h \(seconds / 60 % 60)m"
  }

  static func promptTitle(_ item: TranscriptItem) -> String? {
    switch item.body {
    case .approval(let prompt), .question(let prompt): prompt.title
    default: nil
    }
  }

  /// A settled question's line: what was picked.
  static func receipt(_ item: TranscriptItem) -> String {
    switch item.body {
    case .approval(let prompt), .question(let prompt):
      if prompt.resolutionState == "cancelled" {
        return String(localized: "orcaios.chat.cancelled", defaultValue: "Cancelled")
      }
      // Structured answers name each question's picks, or the words typed instead.
      if !prompt.answers.isEmpty {
        let parts = prompt.answers.map { answer -> String in
          if let other = answer.other, !other.isEmpty { return other }
          let options = prompt.questions.first { $0.id == answer.questionId }?.options ?? prompt.options
          return answer.optionIds.compactMap { id in options.first { $0.id == id }?.label }.joined(separator: "、")
        }.filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: "；") }
      }
      let picked = prompt.options.first { $0.id == prompt.selectedOptionId }?.label
      return picked ?? String(localized: "chat.receipt.emptyAnswer", defaultValue: "Empty answer")
    default: return ""
    }
  }

  private func scrollToBottom(animated: Bool) {
    if animated {
      // A glide for the button; the settling pass below then lands exactly on the end.
      UIView.animate(withDuration: 0.3) { self.settleAtBottom() }
    } else {
      settleAtBottom()
    }
  }

  private func settleAtBottom() {
    // Rows size themselves as they come on screen, so the content grows while it scrolls there: settle it
    // a few passes until the end stops moving.
    var previous: CGFloat = -1
    for _ in 0..<4 {
      collection.layoutIfNeeded()
      let bottom = collection.contentSize.height + collection.adjustedContentInset.bottom - collection.bounds.height
      let target = max(-collection.adjustedContentInset.top, bottom)
      guard abs(target - previous) > 0.5 else { break }
      previous = target
      collection.setContentOffset(CGPoint(x: 0, y: target), animated: false)
    }
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    if followsBottom { scrollToBottom(animated: false) }
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
    switch dataSource.itemIdentifier(for: indexPath) {
    case .work, .run, .call: return true
    case .thoughts(let key): return projection.thoughts[key]?.live == false
    case .prompt(let id): return projection.items[id].map(ChatProjection.isWaiting) ?? false
    default: return false
    }
  }

  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    collectionView.deselectItem(at: indexPath, animated: false)
    switch dataSource.itemIdentifier(for: indexPath) {
    case .work(let key):
      // Opening work is reading, not following the tail.
      followsBottom = false
      UISelectionFeedbackGenerator().selectionChanged()
      if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
      setNeedsUpdateProperties()
    case .thoughts(let key):
      followsBottom = false
      UISelectionFeedbackGenerator().selectionChanged()
      if openThoughts.contains(key) { openThoughts.remove(key) } else { openThoughts.insert(key) }
      setNeedsUpdateProperties()
    case .run(let key):
      // Opens in place to its calls, as the official tool lines do.
      followsBottom = false
      UISelectionFeedbackGenerator().selectionChanged()
      if openRuns.contains(key) { openRuns.remove(key) } else { openRuns.insert(key) }
      setNeedsUpdateProperties()
    case .call(let id):
      followsBottom = false
      UISelectionFeedbackGenerator().selectionChanged()
      if openCalls.contains(id) { openCalls.remove(id) } else { openCalls.insert(id) }
      // The row keeps its identity, so it has to be redrawn to open.
      var snapshot = dataSource.snapshot()
      snapshot.reconfigureItems([.call(id: id)])
      dataSource.apply(snapshot, animatingDifferences: true)
    case .prompt(let id):
      if let item = projection.items[id] { presentPrompt(item) }
    default:
      break
    }
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

extension ChatViewController: PHPickerViewControllerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate,
  UIDocumentPickerDelegate
{
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    let providers = results.map(\.itemProvider)
    Task { composer.add(await AttachmentIntake.load(providers)) }
  }

  func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
    picker.dismiss(animated: true)
    guard let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9),
      let attachment = AttachmentIntake.image(data, name: "Photo.jpg")
    else { return }
    composer.add([attachment])
  }

  func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
    picker.dismiss(animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    composer.add(urls.compactMap { AttachmentIntake.attachment(fromFile: $0) })
  }
}
