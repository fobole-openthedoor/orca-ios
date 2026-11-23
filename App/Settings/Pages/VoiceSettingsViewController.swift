import OrcaCore
import UIKit

/// Settings › Voice (settings/voice-settings-screen.tsx): where dictation is transcribed (this phone), and
/// the desktop's dictation switch, shortcut mode and speech model (`speech.*`).
final class VoiceSettingsViewController: SettingsPageViewController {
  private let model = AppModel.shared
  private var hostId: PairedHost.ID?
  private var setup: DictationSetup?
  private var loading = false
  private var loadError: String?
  private var changeError: String?
  /// Bumped by every change, so a reply that a newer change overtook is dropped.
  private var epoch = 0

  private var session: HostSession? { hostId.flatMap(model.session(for:)) }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(localized: "settings.voiceSettingsScreen.title", defaultValue: "Voice")
    hostId = model.orderedHosts.first { model.session(for: $0.id)?.connectionState == .connected }?.id
      ?? model.orderedHosts.first?.id
    rebuild()
    load()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    // Back from the model list, which may have changed the selection.
    if setup != nil { load() }
  }

  private func load() {
    guard let session, session.connectionState == .connected else {
      rebuild()
      return
    }
    let epoch = epoch
    loading = true
    rebuild()
    Task {
      do {
        let next = try await session.api.dictationSetup()
        if epoch == self.epoch {
          setup = next
          loadError = nil
        }
      } catch {
        if epoch == self.epoch { loadError = Self.message(error) }
      }
      loading = false
      rebuild()
    }
  }

  private func configure(enabled: Bool? = nil, mode: String? = nil) {
    guard let session, var setup else { return }
    changeError = nil
    epoch += 1
    let epoch = epoch
    if let enabled { setup.enabled = enabled }
    var dictationMode: String?
    var holdToRecord: Bool?
    if let mode {
      dictationMode = mode == "hold" ? "hold" : "toggle"
      // Only a desktop that reports hold-to-record has Auto.
      if setup.dictationHoldToRecord != nil { holdToRecord = mode == "auto" }
      setup.dictationMode = dictationMode
      if holdToRecord != nil { setup.dictationHoldToRecord = holdToRecord }
    }
    self.setup = setup
    rebuild()
    Task {
      do {
        let reply = try await session.api.configureDictation(
          enabled: enabled, dictationMode: dictationMode, holdToRecord: holdToRecord)
        if epoch == self.epoch { self.setup = reply }
      } catch {
        changeError =
          (error as? RPCError)?.message
          ?? String(localized: "settings.voiceSettingsScreen.updateFailed", defaultValue: "Could not update")
        if epoch == self.epoch { load() }
      }
      rebuild()
    }
  }

  private func rebuild() {
    var sections: [Section] = [transcribeOnSection()]
    let hosts = model.orderedHosts
    if hosts.count > 1 {
      sections.append(
        Section(rows: [
          .menu(
            icon: .monitor, title: String(localized: "automations.mobile.host", defaultValue: "Host"),
            value: session?.name ?? "",
            options: hosts.map { host in
              Option(title: model.session(for: host.id)?.name ?? host.name, selected: host.id == hostId) { [weak self] in
                guard let self, self.hostId != host.id else { return }
                self.hostId = host.id
                self.setup = nil
                self.loadError = nil
                self.changeError = nil
                self.epoch += 1
                self.load()
              }
            })
        ]))
    }
    guard let session, session.connectionState == .connected || setup != nil else {
      sections.append(
        Section(
          footer: String(
            localized: "settings.voiceSettingsScreen.connectDesktop",
            defaultValue: "Connect to a desktop to manage voice settings."), rows: []))
      self.sections = sections
      return
    }
    guard let setup else {
      if loading || loadError == nil {
        sections.append(
          Section(rows: [
            .spinner(String(localized: "settings.voiceSettingsScreen.loading", defaultValue: "Loading voice settings…"))
          ]))
      } else {
        sections.append(
          Section(
            footer: loadError
              ?? String(localized: "settings.voiceSettingsScreen.loadFailedMessage", defaultValue: "Failed to load voice settings."),
            rows: [
              .button(title: String(localized: "common.retry", defaultValue: "Retry")) { [weak self] in self?.load() }
            ]))
      }
      self.sections = sections
      return
    }
    let offersAuto = setup.dictationHoldToRecord != nil
    let modes =
      offersAuto
      ? [
        ("auto", String(localized: "settings.voiceSettingsScreen.autoMode", defaultValue: "Auto")),
        ("hold", String(localized: "settings.voiceSettingsScreen.holdMode", defaultValue: "Hold")),
        ("toggle", String(localized: "settings.voiceSettingsScreen.toggleMode", defaultValue: "Toggle")),
      ]
      : [
        ("toggle", String(localized: "settings.voiceSettingsScreen.toggleMode", defaultValue: "Toggle")),
        ("hold", String(localized: "settings.voiceSettingsScreen.holdMode", defaultValue: "Hold")),
      ]
    let currentMode = offersAuto ? setup.shortcutMode : (setup.dictationMode == "hold" ? "hold" : "toggle")
    sections.append(
      Section(
        header: String(localized: "settings.voiceSettingsScreen.dictationHeading", defaultValue: "DICTATION"),
        footer: offersAuto
          ? String(
            localized: "settings.voiceSettingsScreen.dictationModeWithAutoDescription",
            defaultValue:
              "Auto: tap to start and stop; on your computer, holding the shortcut records until you let go. Hold: dictate while held. Toggle: press once to start, again to stop."
          )
          : String(
            localized: "settings.voiceSettingsScreen.dictationModeDescription",
            defaultValue: "Toggle: press once to start, again to stop. Hold: dictate while held."),
        rows: [
          .toggle(
            title: String(localized: "settings.voiceSettingsScreen.enableDictation", defaultValue: "Enable Voice Dictation"),
            subtitle: String(
              localized: "settings.voiceSettingsScreen.dictationDescription",
              defaultValue: "Dictate text into any focused pane on your desktop."),
            isOn: setup.enabled, onChange: { [weak self] on in self?.configure(enabled: on) }),
          .segmented(
            title: String(localized: "settings.voiceSettingsScreen.dictationMode", defaultValue: "Dictation Mode"),
            items: modes.map(\.1), selected: modes.firstIndex { $0.0 == currentMode } ?? 0, enabled: setup.enabled,
            onChange: { [weak self] index in self?.configure(mode: modes[index].0) }),
        ]))
    let selected = setup.models.first { $0.id == setup.selectedModelId }
    sections.append(
      Section(
        header: String(localized: "settings.voiceSettingsScreen.speechModelHeading", defaultValue: "SPEECH MODEL"),
        footer: changeError ?? loadError,
        rows: [
          .value(
            title: String(localized: "settings.voiceSettingsScreen.speechModel", defaultValue: "Speech Model"),
            subtitle: selected?.label
              ?? String(localized: "settings.voiceSettingsScreen.noneSelected", defaultValue: "None selected"),
            navigates: true, enabled: setup.enabled,
            action: { [weak self] in
              guard let self, let session = self.session, let setup = self.setup else { return }
              self.navigationController?.pushViewController(
                SpeechModelsViewController(session: session, setup: setup), animated: true)
            })
        ]))
    self.sections = sections
  }

  private func transcribeOnSection() -> Section {
    let current = PhoneSettings.dictationEngine
    func row(_ engine: PhoneSettings.DictationEngine, _ title: String) -> Row {
      .check(title: title, checked: current == engine) { [weak self] in
        PhoneSettings.dictationEngine = engine
        self?.rebuild()
      }
    }
    return Section(
      header: String(localized: "settings.voiceTranscribeOn.heading", defaultValue: "TRANSCRIBE ON"),
      footer: String(
        localized: "settings.voiceTranscribeOn.description",
        defaultValue: "Speech heard on this phone stays on it. Automatic uses your computer when this phone can’t transcribe."),
      rows: [
        row(.automatic, String(localized: "settings.voiceTranscribeOn.automatic", defaultValue: "Automatic")),
        row(.phone, String(localized: "settings.voiceTranscribeOn.phone", defaultValue: "This phone")),
        row(.computer, String(localized: "settings.voiceTranscribeOn.computer", defaultValue: "Computer")),
      ])
  }

  fileprivate static func message(_ error: Error) -> String {
    (error as? RPCError)?.message
      ?? String(localized: "settings.voiceSettingsScreen.loadFailed", defaultValue: "Failed to load voice settings")
  }
}

/// The desktop's speech models: use one, download one, or swipe to delete a downloaded one. Polls while a
/// download runs.
private final class SpeechModelsViewController: SettingsPageViewController {
  private let session: HostSession
  private var setup: DictationSetup
  private var busy: String?
  private var poll: Task<Void, Never>?

  init(session: HostSession, setup: DictationSetup) {
    self.session = session
    self.setup = setup
    super.init()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(localized: "settings.voiceSettingsScreen.speechModel", defaultValue: "Speech Model")
    rebuild()
    pollIfNeeded()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    poll?.cancel()
    poll = nil
  }

  private func rebuild() {
    sections = [
      Section(
        rows: setup.models.map { model in
          let selected = model.id == setup.selectedModelId
          let meta = [Self.meta(model), model.recommended ? String(localized: "components.voiceModelList.recommended", defaultValue: "Recommended") : nil]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
          if model.id == busy {
            return .spinner(model.label)
          }
          if selected {
            return .status(
              icon: .check, color: Palette.statusGreen, title: model.label,
              detail: [meta, String(localized: "components.voiceModelList.inUse", defaultValue: "In use")]
                .filter { !$0.isEmpty }.joined(separator: " · "))
          }
          if model.status == "ready" {
            return .value(
              title: model.label, value: String(localized: "components.voiceModelList.use", defaultValue: "Use"),
              subtitle: meta.isEmpty ? " " : meta, enabled: busy == nil
            ) { [weak self] in self?.use(model) }
          }
          // mobile-dictation-setup.ts: a cloud model isn't downloaded; it waits for a key set on the desktop.
          if model.provider == "openai" {
            return .value(
              title: model.label,
              value: String(localized: "dictation.setup.cloudModelNeedsKey", defaultValue: "Needs an OpenAI key"),
              subtitle: meta.isEmpty ? " " : meta, enabled: false)
          }
          if model.isInFlight {
            return .value(title: model.label, subtitle: meta.isEmpty ? " " : meta, enabled: false)
          }
          return .value(
            title: model.label,
            value: String(localized: "components.dictationSetupSheet.download", defaultValue: "Download"),
            subtitle: meta.isEmpty ? " " : meta, enabled: busy == nil
          ) { [weak self] in self?.download(model) }
        })
    ]
  }

  override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
    -> UISwipeActionsConfiguration?
  {
    let model = setup.models[indexPath.row]
    guard model.provider != "openai", model.status == "ready", busy == nil else { return nil }
    let delete = UIContextualAction(
      style: .destructive, title: String(localized: "common.delete", defaultValue: "Delete")
    ) { [weak self] _, _, done in
      self?.delete(model)
      done(true)
    }
    return UISwipeActionsConfiguration(actions: [delete])
  }

  private func use(_ model: SpeechModel) {
    run(model) { try await self.session.api.configureDictation(enabled: true, modelId: model.id) }
  }

  private func delete(_ model: SpeechModel) {
    run(model) { try await self.session.api.deleteSpeechModel(model.id) }
  }

  private func download(_ model: SpeechModel) {
    run(model) {
      try await self.session.api.downloadSpeechModel(model.id)
      return try await self.session.api.dictationSetup()
    }
  }

  private func run(_ model: SpeechModel, _ change: @escaping () async throws -> DictationSetup) {
    busy = model.id
    rebuild()
    Task {
      do {
        setup = try await change()
      } catch {
        showAlert(title: model.label, message: (error as? RPCError)?.message ?? error.localizedDescription)
      }
      busy = nil
      rebuild()
      pollIfNeeded()
    }
  }

  private func pollIfNeeded() {
    guard poll == nil, setup.models.contains(where: \.isInFlight) else { return }
    poll = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(1500))
        guard let self, !Task.isCancelled else { return }
        if let next = try? await self.session.api.dictationSetup() {
          self.setup = next
          if self.busy == nil { self.rebuild() }
          if !next.models.contains(where: \.isInFlight) { break }
        }
      }
      self?.poll = nil
    }
  }

  private static func meta(_ model: SpeechModel) -> String {
    if model.provider == "openai" { return "OpenAI API" }
    let size =
      model.sizeBytes.flatMap { $0 > 0 ? $0 : nil }.map {
        String(format: String(localized: "components.voiceModelList.modelSize", defaultValue: "%1$@ MB"), "\(Int(($0 / 1_000_000).rounded()))")
      } ?? ""
    if model.isInFlight, let progress = model.progress {
      return String(
        format: String(localized: "components.voiceModelList.modelProgress", defaultValue: "%1$@ · %2$@%%"), size,
        "\(Int((progress * 100).rounded()))")
    }
    if model.status == "extracting" {
      return String(format: String(localized: "components.voiceModelList.modelExtracting", defaultValue: "%1$@ · extracting…"), size)
    }
    return size
  }
}
