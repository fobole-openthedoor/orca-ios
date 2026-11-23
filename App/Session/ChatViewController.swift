import TipKit
import OrcaCore
import PhotosUI
import SafariServices
import UIKit
import UniformTypeIdentifiers

/// One agent chat: the transcript over the glass composer.
final class ChatViewController: UIViewController {
  let model: ChatSessionModel
  /// The row on screen when an older page was asked for, and how far below the top it sat.
  private var olderAnchor: (line: ChatLine, y: CGFloat)?

  private lazy var collection = UICollectionView(frame: .zero, collectionViewLayout: Self.layout())
  /// Runs under the navigation bar and the tab strip, which blur it with the soft scroll edge.
  var edgeScrollView: UIScrollView { collection }
  private var dataSource: UICollectionViewDiffableDataSource<Int, ChatLine>!
  private let composer = ChatComposerView()
  private let dock = ChatDockView()
  private let suggestions = ChatSuggestionPanel()
  /// Dims the chat behind a full-screen composer.
  private let dim = UIView()
  private var suggestionTask: Task<Void, Never>?
  /// Workspace files matching a query, for @ mentions.
  var searchFiles: ((String) async -> [String])?
  private let toBottom = UIButton(configuration: .glass())
  private var projection = ChatProjection(rows: [], expanded: [], transcript: ChatTranscript()) {
    didSet { lineIndex = Dictionary(projection.lines.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first }) }
  }
  private var lineIndex: [ChatLine: Int] = [:]
  private var expanded: Set<String> = []
  private var openThoughts: Set<String> = []
  /// Activity lines opened to their calls, and calls opened to their input and output.
  private var openRuns: Set<String> = []
  private var openCalls: Set<String> = []
  private var lastWorking: Bool?
  /// Questions this screen already opened on its own; closing one never reopens it unasked.
  private var presentedPrompts: Set<String> = []
  private var followsBottom = true
  private var lastOpenedURL: (url: URL, at: Date)?
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
    dim.backgroundColor = .black
    dim.alpha = 0
    dim.isUserInteractionEnabled = false
    dim.translatesAutoresizingMaskIntoConstraints = false
    view.insertSubview(dim, aboveSubview: collection)
    view.addSubview(dock)
    view.addSubview(suggestions)
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
      suggestions.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      suggestions.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      suggestions.bottomAnchor.constraint(equalTo: composer.topAnchor),
      dim.topAnchor.constraint(equalTo: view.topAnchor),
      dim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      dim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      dim.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    view.keyboardLayoutGuide.usesBottomSafeArea = true

    // What was typed here before, and not sent, comes back.
    let draft = ChatDraftStore.load(model.sessionId)
    composer.restore(text: draft.text, attachments: draft.attachments)
    NotificationCenter.default.addObserver(
      self, selector: #selector(saveDraft), name: UIApplication.willResignActiveNotification, object: nil)
    composer.onSend = { [weak self] text, attachments, queue in
      guard let self else { return }
      ChatDraftStore.save(self.model.sessionId, text: "", attachments: [])
      self.followsBottom = true
      Task {
        if let refusal = await self.model.submit(text: text, attachments: attachments, queue: queue) { self.say(refusal) }
      }
    }
    composer.onToken = { [weak self] token in self?.suggest(token) }
    let uploader = model
    composer.upload = { attachment, progress in try await uploader.upload(attachment, progress: progress) }
    // Full screen: the field grows to just under the top bar, the chat dims behind it.
    composer.fullTextHeight = { [weak self] in
      guard let self else { return 0 }
      let room = self.composer.frame.maxY - self.view.safeAreaInsets.top - Spacing.md
      return room - (self.composer.frame.height - self.composer.textView.frame.height)
    }
    composer.onFullScreen = { [weak self] progress in
      self?.dim.alpha = 0.22 * progress
      self?.dock.alpha = 1 - progress
    }
    composer.contextRing.addAction(
      UIAction { [weak self] _ in
        guard let self, let usage = self.composer.contextRing.usage else { return }
        self.present(ContextUsageViewController.sheet(usage), animated: true)
      }, for: .touchUpInside)  // A bare UIControl never sends primaryActionTriggered.
    composer.onPickPhotos = { [weak self] in self?.pickPhotos() }
    composer.onTakePhoto = { [weak self] in self?.takePhoto() }
    composer.onPickFiles = { [weak self] in self?.pickFiles() }
    composer.onOpenImages = { [weak self] images, index in
      self?.present(ImageViewerController(sources: images.map { .image($0) }, index: index), animated: true)
    }
    composer.onError = { [weak self] message in self?.say(message) }
    dock.onOpen = { [weak self] task in self?.openBackgroundTask(task) }
    dock.onQueued = { [weak self] message, action in
      guard let self else { return }
      Task {
        switch action {
        case .send:
          if let refusal = await self.model.queuedMessage(message.id, send: true) { self.say(refusal) }
        case .delete:
          if let refusal = await self.model.queuedMessage(message.id, send: false) { self.say(refusal) }
        case .edit:
          // Back into the composer to change, out of the queue.
          if let refusal = await self.model.queuedMessage(message.id, send: false) {
            self.say(refusal)
          } else {
            self.composer.setText(message.text)
          }
        }
      }
    }
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
      guard let self else { return }
      if self.followsBottom {
        self.scrollToBottom(animated: false)
      } else {
        self.keepOlderAnchor()
        self.clampOffset()
      }
    }
    composer.setWorking(model.isWorking)
    // A turn's end moves the goal's time and status; read them again.
    if lastWorking == true, !model.isWorking { Task { await model.refreshOptions() } }
    lastWorking = model.isWorking
    dock.show(
      tasks: model.transcript.backgroundTasks, stopsAll: model.transcript.stopsBackgroundTasks, goal: model.goal,
      queued: model.transcript.queuedMessages)
    view.setNeedsLayout()
    presentNewPrompt()
    updateModelChip()
    composer.contextRing.show(model.options?.contextUsage)
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
  /// The model chip's menu, in levels: the model and the effort as submenus naming the current choice, the
  /// toggles beside them. Under Model, the newest of each family and the one in use; the rest under More.
  private func modelMenu(_ options: ChatOptions) -> UIMenu {
    let current = options.currentModel
    let all = options.models.filter { !$0.id.isEmpty }
    let action: (ChatOptions.Model) -> UIAction = { choice in
      UIAction(title: choice.label, subtitle: choice.description, state: choice.id == current?.id ? .on : .off) {
        [weak self] _ in self?.setOption("model", choice.id)
      }
    }
    let common = Self.commonModels(all, current: current?.id)
    var restSeen = Set(common.map(\.label))
    let rest = all.filter { model in !common.contains { $0.id == model.id } && restSeen.insert(model.label).inserted }
    var modelItems: [UIMenuElement] = common.map(action)
    if !rest.isEmpty {
      modelItems.append(
        UIMenu(
          title: String(localized: "chat.sessionOptionRows.moreModels", defaultValue: "More models"),
          image: UIImage(systemName: "ellipsis.circle"), children: rest.map(action)))
    }
    let modelMenu = UIMenu(
      title: String(localized: "chat.sessionOptionCopy.model", defaultValue: "Model"), image: UIImage(systemName: "cpu"),
      children: modelItems)
    modelMenu.subtitle = current?.label
    var children: [UIMenuElement] = [modelMenu]
    if let efforts = current?.efforts, !efforts.isEmpty {
      let effortMenu = UIMenu(
        title: String(localized: "chat.sessionOptionCopy.effort", defaultValue: "Effort"), image: UIImage(systemName: "gauge.with.dots.needle.50percent"),
        children: efforts.map { effort in
          UIAction(title: Self.effortLabel(effort), state: effort.id == options.effort ? .on : .off) { [weak self] _ in
            self?.setOption("effort", effort.id)
          }
        })
      effortMenu.subtitle = efforts.first { $0.id == options.effort }.map(Self.effortLabel)
      children.append(effortMenu)
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

  /// The newest model of each family ("Opus 5.5" over "Opus 4.8"), the default, and the one in use, in the
  /// host's order. A label without a version stays in the list.
  private static func commonModels(_ models: [ChatOptions.Model], current: String?) -> [ChatOptions.Model] {
    func parts(_ label: String) -> (family: String, version: [Int])? {
      let words = label.split(separator: " ")
      guard let family = words.first, words.count > 1,
        let version = words.dropFirst().first.map({ $0.split(separator: ".").compactMap { Int($0) } }), !version.isEmpty
      else { return nil }
      return (family.lowercased(), version)
    }
    var newest: [String: [Int]] = [:]
    for model in models {
      guard let (family, version) = parts(model.label) else { continue }
      if newest[family].map({ version.lexicographicallyPrecedes($0) == false }) ?? true { newest[family] = version }
    }
    let picked = models.filter { model in
      if model.id == current || model.isDefault { return true }
      guard let (family, version) = parts(model.label) else { return true }
      return newest[family] == version
    }
    // The host can list one model under two ids (an alias and the version it points at); one row each,
    // the one in use where it is one of them.
    var seen = Set<String>()
    return picked.sorted { a, _ in a.id == current }.filter { seen.insert($0.label).inserted }
      .sorted { a, b in (picked.firstIndex { $0.id == a.id } ?? 0) < (picked.firstIndex { $0.id == b.id } ?? 0) }
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
    // One tap can arrive twice from the Markdown view; open it once.
    let now = Date()
    guard lastOpenedURL?.url != url || now.timeIntervalSince(lastOpenedURL!.at) > 1 else { return }
    lastOpenedURL = (url, now)
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
  /// shell's command and its output so far. Matched by call id, by the id a background shell's output names,
  /// or by the label the strip shows; older pages are read in until it turns up. Without a match the task's
  /// own facts show.
  private func openBackgroundTask(_ task: OrcaCore.BackgroundTask) {
    // A subagent's own words and calls, when the journal carries them under its id.
    let own = task.kind == "agent" ? model.subagentItems(task.id) : []
    if !own.isEmpty {
      var call = backgroundTaskCall(task)?.1 ?? Self.placeholderCall(for: task)
      call.output = Self.transcriptText(own)
      present(ToolOutputViewController.sheet(call: call, load: nil), animated: true)
      return
    }
    let model = self.model
    if let (id, call) = backgroundTaskCall(task) {
      present(
        ToolOutputViewController.sheet(call: call) {
          guard let full = await model.fullItem(id), case .toolCall(let whole) = full.body else { return nil }
          return whole
        }, animated: true)
      return
    }
    // Its call is on an older page: the page opens at once with what the strip knows, and older history is
    // read in behind it until the call turns up.
    present(
      ToolOutputViewController.sheet(call: Self.placeholderCall(for: task), load: { [weak self] in
        var pages = 0
        while let self, self.backgroundTaskCall(task) == nil, model.transcript.hasOlder, pages < 8 {
          await model.loadOlder()
          pages += 1
        }
        guard let (id, call) = self?.backgroundTaskCall(task) else { return nil }
        if let full = await model.fullItem(id), case .toolCall(let whole) = full.body { return whole }
        return call
      }, alwaysLoad: true), animated: true)
  }

  private func backgroundTaskCall(_ task: OrcaCore.BackgroundTask) -> (String, TranscriptItem.ToolCall)? {
    let label = task.label.trimmingCharacters(in: .whitespacesAndNewlines)
    for item in model.transcript.items.reversed() {
      guard case .toolCall(let call) = item.body else { continue }
      if call.callId == task.id { return (item.id, call) }
      // "Command running in background with ID: b3jmij2mn."
      if let output = call.output, output.contains("ID: \(task.id)") { return (item.id, call) }
      if !label.isEmpty,
        ["description", "command", "prompt"].contains(where: {
          call.input[$0]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) == label
        })
      {
        return (item.id, call)
      }
    }
    return nil
  }

  /// A subagent's rows as plain text: its words, its calls with their arguments, its thoughts marked.
  private static func transcriptText(_ items: [TranscriptItem]) -> String {
    items.compactMap { item -> String? in
      switch item.body {
      case .message(let message) where message.role == "reasoning": return "› " + message.text
      case .message(let message): return message.text
      case .toolCall(let call):
        let head = "$ \(call.name) \(call.summary)"
        return [head, call.output].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
      default: return nil
      }
    }.joined(separator: "\n\n")
  }

  /// What the strip knows of a task whose starting call is out of reach: its label, kind and running time.
  private static func placeholderCall(for task: OrcaCore.BackgroundTask) -> TranscriptItem.ToolCall {
    var facts = [task.kind]
    if let started = task.startedAt, started > 0 {
      facts.append(WorkSummaryView.duration(max(1, Int(Date().timeIntervalSince1970 - started / 1000))))
    }
    if let tokens = task.totalTokens, tokens > 0 { facts.append("\(ChatDockView.compact(tokens)) tokens") }
    return TranscriptItem.ToolCall(
      name: task.label.isEmpty ? task.kind : task.label, input: .string(facts.joined(separator: " · ")),
      output: nil)
  }

  /// Fills the suggestion panel for what is being typed: the agent's slash commands, or workspace files.
  private func suggest(_ token: ComposerToken?) {
    suggestionTask?.cancel()
    guard let token else {
      suggestions.show([])
      return
    }
    let pick: ([ChatSuggestionPanel.Row]) -> Void = { [weak self] rows in
      guard let self else { return }
      self.suggestions.show(rows)
      self.suggestions.onPick = { [weak self] row in self?.composer.complete(token, with: row.insert) }
    }
    switch token {
    case .command(let query, _):
      pick(ChatCommand.matching(query, in: model.commands).prefix(30).map { command in
        ChatSuggestionPanel.Row(
          icon: command.kind == "skill" ? .sparkles : .squareChevronRight,
          title: "/" + command.name + (command.argumentHint.map { " " + $0 } ?? ""),
          detail: command.description, insert: "/" + command.name)
      })
    case .file(let query, _):
      guard let searchFiles else { return }
      suggestionTask = Task { [weak self] in
        // Waits for a pause in typing before asking the desktop.
        try? await Task.sleep(for: .milliseconds(query.isEmpty ? 0 : 150))
        guard !Task.isCancelled else { return }
        let paths = await searchFiles(query)
        guard !Task.isCancelled, self != nil else { return }
        pick(paths.prefix(30).map { path in
          let name = (path as NSString).lastPathComponent
          let folder = (path as NSString).deletingLastPathComponent
          return ChatSuggestionPanel.Row(
            icon: .fileText, title: name, detail: folder.isEmpty ? nil : folder, insert: "@" + path)
        })
      }
    }
  }

  /// A streaming answer laid out a longer document after its row was sized: size the rows again, and stay
  /// at the end if the reader was there.
  private func answerGrew() {
    collection.collectionViewLayout.invalidateLayout()
    if followsBottom { scrollToBottom(animated: false) }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    saveDraft()
  }

  @objc private func saveDraft() {
    ChatDraftStore.save(model.sessionId, text: composer.draftText, attachments: composer.attachments)
  }

  /// The chat for picture in picture: what the agent is doing now, then its newest words, calls and thoughts.
  func pipLines() -> (working: Bool, lines: [(text: String, style: PiPFrame.Style)]) {
    var lines: [(text: String, style: PiPFrame.Style)] = []
    let items = Array(model.transcript.items.suffix(24).filter { $0.agentId == nil })
    let detailed = PiPCenter.showsCommands
    var index = 0
    while index < items.count {
      let item = items[index]
      switch item.body {
      case .toolCall(let call) where !detailed:
        // As the chat draws them: a run of calls is one line saying what it did.
        var calls = [call]
        while index + 1 < items.count, case .toolCall(let next) = items[index + 1].body {
          calls.append(next)
          index += 1
        }
        let running = model.isWorking && index == items.count - 1
        lines.append((ToolCategory.sentence(for: calls, live: running), .muted))
      case .toolCall(let call):
        lines.append(("$ \(call.name) \(call.summary.replacingOccurrences(of: "\n", with: " ").prefix(120))", .call))
      case .message(let message) where message.role == "reasoning":
        if detailed {
          let thought = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
          if !thought.isEmpty { lines.append((String(thought.suffix(240)), .muted)) }
        } else {
          // Consecutive thoughts read as one "Thought" line.
          while index + 1 < items.count, case .message(let next) = items[index + 1].body, next.role == "reasoning" { index += 1 }
          let live = model.isWorking && index == items.count - 1
          lines.append((live ? String(localized: "chat.turnStatus.thinking", defaultValue: "Thinking") : "Thought", .muted))
        }
      case .message(let message) where message.role == "user":
        let words = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty { lines.append(("› " + String(words.prefix(160)), .muted)) }
      case .message(let message):
        // A bot's quiet marker goes before the Markdown is flattened, as the chat hides it.
        let text = isBotChat ? BotQuietResult.strip(message.text).words : message.text
        let words = Self.plain(text)
        if !words.isEmpty { lines.append((String(words.suffix(600)), .body)) }
      default: break
      }
      index += 1
    }
    if let activity = model.transcript.activity, model.isWorking, !activity.isEmpty {
      lines.append(("… " + activity, .muted))
    }
    return (model.isWorking, lines)
  }

  /// Markdown read as plain words: markers and fences dropped.
  private static func plain(_ markdown: String) -> String {
    markdown.replacingOccurrences(of: "```[a-zA-Z0-9]*", with: "", options: .regularExpression)
      .replacingOccurrences(of: "[*_`#>]", with: "", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Where a relative path the agent wrote may live on the desktop, most likely first: absolute paths it
  /// read or wrote that end with it, then the directories its commands changed into, joined with it.
  func candidatePaths(for relative: String) -> [String] {
    guard !relative.hasPrefix("/"), !relative.hasPrefix("~") else { return [] }
    var exact: [String] = []
    var joined: [String] = []
    let cd = try! NSRegularExpression(pattern: #"(?:^|[;&|]\s*)cd\s+("[^"]+"|'[^']+'|[^\s;&|]+)"#)
    for item in model.transcript.items.reversed() {
      guard case .toolCall(let call) = item.body else { continue }
      for key in ["file_path", "path", "notebook_path"] {
        if let value = call.input[key]?.stringValue, value.hasSuffix("/" + relative) { exact.append(value) }
      }
      if let command = call.input["command"]?.stringValue {
        let ns = command as NSString
        for match in cd.matches(in: command, range: NSRange(location: 0, length: ns.length)) {
          let dir = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
          guard dir.hasPrefix("/") || dir.hasPrefix("~") else { continue }
          joined.append((dir.hasSuffix("/") ? dir : dir + "/") + relative)
        }
      }
    }
    var seen = Set<String>()
    return (exact + joined).filter { seen.insert($0).inserted }.prefix(6).map { $0 }
  }

  /// Whether a line sits on the turn's activity thread: calls, thoughts, notes, questions and the working
  /// line do; the person's words, the agent's words and cards break it.
  private static func onThread(_ line: ChatLine?) -> Bool {
    switch line {
    case .run, .thoughts, .thoughtText, .call, .viewedImages, .prompt, .workItem, .working: true
    default: false
    }
  }

  /// Which neighbours a line joins on the thread.
  private func threadJoins(_ line: ChatLine) -> (up: Bool, down: Bool) {
    guard let index = lineIndex[line] else { return (false, false) }
    let lines = projection.lines
    return (
      index > 0 && Self.onThread(lines[index - 1]),
      index + 1 < lines.count && Self.onThread(lines[index + 1])
    )
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
      let joins = self.threadJoins(line)
      view.connect(up: joins.up, down: joins.down)
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
      view.show(markdown: text, id: id, at: item.observedAt, streaming: streaming, width: self.collection.bounds.width)
      view.onHeightChange = { [weak self] in self?.answerGrew() }
      view.onOpenURL = { [weak self] url in self?.open(url) }
      view.onFork = { [weak self] in self?.onFork?(id) }
      view.onScrollToTop = { [weak self] in self?.scrollToTop(line) }
      view.onOpenPath = { [weak self] path in self?.onOpenPath?(path) }
    }
    let activity = registration(ActivityRowView.init) { [weak self] view, line in
      guard let self else { return }
      let joins = self.threadJoins(line)
      view.connect(up: joins.up, down: joins.down)
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
    let viewed = registration(ViewedImagesView.init) { [weak self] view, line in
      guard let self, case .viewedImages(let key) = line, let paths = self.projection.viewedImages[key] else { return }
      let sources = self.imageSources(paths)
      view.stack.show(sources)
      view.stack.onOpen = { [weak self] index in
        self?.present(ImageViewerController(sources: sources, index: index), animated: true)
      }
      let joins = self.threadJoins(line)
      view.connect(up: joins.up, down: joins.down)
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
      case .viewedImages: collection.dequeueConfiguredReusableCell(using: viewed, for: indexPath, item: line)
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
    watchSendTip()
  }

  /// The send hint, once: shortly after the first chat settles on screen, unless something else is up.
  /// Tracked here rather than by TipKit's own rules, which could spend the one showing on a chat that
  /// never made it on screen. Settings › Orca iOS can bring it back.
  private func watchSendTip() {
    guard !SendHoldTip.seen else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
      guard let self, !SendHoldTip.seen, self.view.window != nil, self.presentedViewController == nil,
        self.parent?.presentedViewController == nil
      else { return }
      SendHoldTip.seen = true
      let popover = TipUIPopoverViewController(SendHoldTip(), sourceItem: self.composer.sendAnchor) { [weak self] action in
        self?.dismiss(animated: true)
        if action.id == "settings" {
          self?.navigationController?.pushViewController(OrcaIOSSettingsViewController(), animated: true)
        }
      }
      popover.popoverPresentationController?.permittedArrowDirections = .down
      self.present(popover, animated: true)
    }
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
    loadOlderNearTop()
  }

  /// Nearing the top of what is loaded reads the page before it, as the official list does.
  private func loadOlderNearTop() {
    guard model.transcript.hasOlder, !model.isLoadingOlder, olderAnchor == nil,
      collection.contentOffset.y + collection.adjustedContentInset.top < 600,
      let first = collection.indexPathsForVisibleItems.min(),
      let line = dataSource.itemIdentifier(for: first),
      let frame = collection.layoutAttributesForItem(at: first)?.frame
    else { return }
    olderAnchor = (line, frame.minY - collection.contentOffset.y)
    let model = model
    Task { [weak self] in
      await model.loadOlder()
      // Nothing came: let the next scroll ask again.
      try? await Task.sleep(for: .milliseconds(300))
      if self?.olderAnchor?.line == line { self?.olderAnchor = nil }
    }
  }

  /// Rows read in above stay out of the way: the row that was on screen stays where it was.
  private func keepOlderAnchor() {
    guard let anchor = olderAnchor, let indexPath = dataSource.indexPath(for: anchor.line) else { return }
    collection.layoutIfNeeded()
    guard let frame = collection.layoutAttributesForItem(at: indexPath)?.frame else { return }
    let target = frame.minY - anchor.y
    if abs(target - collection.contentOffset.y) > 0.5 {
      collection.setContentOffset(CGPoint(x: 0, y: target), animated: false)
      olderAnchor = nil
    }
  }

  /// The transcript got shorter under a reader scrolled past its new end (a fresh snapshot, rows folding):
  /// back to the end, rather than a screen of nothing.
  private func clampOffset() {
    let end = max(
      -collection.adjustedContentInset.top,
      collection.contentSize.height + collection.adjustedContentInset.bottom - collection.bounds.height)
    if collection.contentOffset.y > end + 1 {
      collection.setContentOffset(CGPoint(x: 0, y: end), animated: false)
    }
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
    // A live thought opens too, and its words stream in under it.
    case .thoughts: return true
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
    composer.adding { await AttachmentIntake.load(providers) }
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
