import OrcaCore
import UIKit

/// The workspace's pull request for the Source Control hub and the screens pushed from its PR tab
/// (use-mobile-pr-sidebar-controller.ts, use-mobile-pr-actions.ts): the PR the branch resolves to, its details
/// and checks, whether the branch can open one, and every write, each followed by a reread.
@MainActor
final class PullRequestController {
  enum State: Equatable {
    case idle, loading
    /// No PR for the branch; `orphanLinkedPR` names a linked one that no longer resolves.
    case none(orphanLinkedPR: Int?)
    case ready(PullRequestInfo)
    case error(String)
  }

  /// One thing being written, so its button can spin.
  enum Busy: Hashable {
    case merge, autoMerge, state, draft, title, body, rerun, link, unlink, comment, agent
    case reviewer(String)
    case reply(String)
    case resolve(String)
  }

  let session: HostSession
  let worktreeId: String
  private(set) var state = State.idle
  /// Nil until read; a failed read keeps the last one and sets `detailsFailed`.
  private(set) var details: PullRequestDetails?
  private(set) var detailsFailed = false
  private(set) var checks: [PullRequestCheck] = []
  private(set) var checksError: String?
  private(set) var eligibility: HostedReviewEligibility?
  /// The last write's failure, shown until the next one.
  private(set) var error: String?
  /// What the last agent launch said: started, or why it didn't.
  private(set) var agentNotice: (text: String, failed: Bool)?
  private(set) var busy = Set<Busy>()
  private(set) var linkedPR: Int?
  private var branch: String?
  private var headSha: String?
  private var lastStatus: GitStatus?
  private var loadTask: Task<Void, Never>?
  private var retryTask: Task<Void, Never>?
  private var observers: [UUID: () -> Void] = [:]

  init(session: HostSession, worktreeId: String) {
    self.session = session
    self.worktreeId = worktreeId
  }

  private var api: HostAPI { session.api }
  var pr: PullRequestInfo? { if case .ready(let pr) = state { pr } else { nil } }

  /// Calls `change` after every state change until the returned token is dropped.
  func observe(_ change: @escaping () -> Void) -> PRObservation {
    let id = UUID()
    observers[id] = change
    return PRObservation { [weak self] in self?.observers[id] = nil }
  }

  private func changed() {
    for observer in observers.values { observer() }
  }

  // MARK: Reading

  /// Reads the branch's PR, then its details and checks. `refresh` asks the host past its caches, as Refresh does.
  func load(branch: String?, headSha: String?, gitStatus: GitStatus?, refresh: Bool = false) {
    let moved = branch != self.branch
    self.branch = branch
    self.headSha = headSha
    retryTask?.cancel()
    guard let branch else {
      state = .none(orphanLinkedPR: nil)
      eligibility = nil
      changed()
      return
    }
    if moved || state == .idle {
      state = .loading
      details = nil
      checks = []
      changed()
    }
    loadTask?.cancel()
    let api = api
    let worktreeId = worktreeId
    // A reread keeps the last status the hub gave, for the Create eligibility.
    let gitStatus = gitStatus ?? lastStatus
    lastStatus = gitStatus
    let hasUncommitted = !(gitStatus?.entries.isEmpty ?? true)
    let upstream = gitStatus?.upstream
    loadTask = Task { [weak self] in
      let link = try? await api.worktreeReviewLink(worktreeId: worktreeId)
      do {
        let lookup = try await api.pullRequestForBranch(
          worktreeId: worktreeId, branch: branch, linkedPR: link?.linkedPR, headSha: headSha, refresh: refresh)
        guard !Task.isCancelled, let self else { return }
        linkedPR = link?.linkedPR
        switch lookup {
        case .found(let pr):
          let previous = self.pr?.number
          state = .ready(pr)
          if previous != pr.number {
            details = nil
            checks = []
          }
          changed()
          await readDetails(pr, refresh: refresh)
        case .none(let retry):
          state = .none(orphanLinkedPR: link?.linkedPR)
          details = nil
          checks = []
          changed()
          retryLater(retry)
        case .revalidating(let retry):
          if state == .loading || state == .idle { state = .loading }
          retryLater(retry)
        case .upstreamError(let message):
          state = .error(message.isEmpty ? String(localized: "session.prSidebarState.loadFailed", defaultValue: "Unable to load pull request") : message)
          changed()
        }
      } catch {
        guard !Task.isCancelled, let self else { return }
        // A failed refresh keeps the accepted PR.
        if pr == nil { state = .error(Self.message(error)) }
        changed()
      }
      guard !Task.isCancelled, let self else { return }
      eligibility = try? await api.hostedReviewEligibility(
        worktreeId: worktreeId, branch: branch, hasUncommittedChanges: hasUncommitted, upstream: upstream,
        linkedPR: link?.linkedPR)
      changed()
    }
  }

  private func retryLater(_ seconds: Double?) {
    guard let seconds, let branch else { return }
    let headSha = headSha
    retryTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(max(1, seconds)))
      guard !Task.isCancelled else { return }
      self?.load(branch: branch, headSha: headSha, gitStatus: nil)
    }
  }

  private func readDetails(_ pr: PullRequestInfo, refresh: Bool) async {
    let api = api
    let worktreeId = worktreeId
    let head = pr.headSha ?? headSha
    async let detailsRead = Self.capture {
      try await api.pullRequestDetails(worktreeId: worktreeId, number: pr.number, prRepo: pr.prRepo)
    }
    async let checksRead = Self.capture {
      try await api.pullRequestChecks(
        worktreeId: worktreeId, number: pr.number, headSha: head, prRepo: pr.prRepo, refresh: refresh)
    }
    let (detailsResult, checksResult) = await (detailsRead, checksRead)
    guard !Task.isCancelled, self.pr?.number == pr.number else { return }
    switch detailsResult {
    case .success(let value?):
      details = value
      detailsFailed = false
    default:
      detailsFailed = true
    }
    switch checksResult {
    case .success(let value):
      checks = value
      checksError = nil
    case .failure(let error):
      checksError = Self.message(error)
    }
    changed()
  }

  /// Rereads the shown PR after a write, or on the checks screen's timer.
  func reread() {
    load(branch: branch, headSha: headSha, gitStatus: nil, refresh: true)
  }

  static func message(_ error: Error) -> String {
    (error as? RPCError)?.message ?? error.localizedDescription
  }

  // MARK: Writing

  /// Runs one PR write as `key`, then rereads; a failure lands in `error`.
  @discardableResult
  func run(_ key: Busy, _ body: @escaping (HostAPI, String, PullRequestInfo?) async throws -> Void) async -> Bool {
    guard !busy.contains(key) else { return false }
    busy.insert(key)
    error = nil
    changed()
    let pr = pr
    var ok = true
    do {
      try await body(api, worktreeId, pr)
      UINotificationFeedbackGenerator().notificationOccurred(.success)
    } catch {
      UINotificationFeedbackGenerator().notificationOccurred(.error)
      self.error = Self.message(error)
      ok = false
    }
    busy.remove(key)
    changed()
    reread()
    return ok
  }

  func isBusy(_ key: Busy) -> Bool { busy.contains(key) }

  /// Merges with `method`; `reviewed` is the PR as the user saw it, so a push read since then isn't merged unseen.
  func merge(method: String, reviewed: PullRequestInfo? = nil) async -> Bool {
    await run(.merge) { api, id, pr in
      guard let pr = reviewed ?? pr else { return }
      try await api.mergePullRequest(worktreeId: id, pr: pr, method: method)
    }
  }

  func setAutoMerge(_ enabled: Bool) {
    Task { await run(.autoMerge) { api, id, pr in if let pr { try await api.setPullRequestAutoMerge(worktreeId: id, pr: pr, enabled: enabled) } } }
  }

  func setOpen(_ open: Bool) {
    Task { await run(.state) { api, id, pr in if let pr { try await api.setPullRequestState(worktreeId: id, pr: pr, open: open) } } }
  }

  func setDraft(_ draft: Bool) {
    Task { await run(.draft) { api, id, pr in if let pr { try await api.setPullRequestDraft(worktreeId: id, pr: pr, draft: draft) } } }
  }

  func updateTitle(_ title: String) async -> Bool {
    await run(.title) { api, id, pr in if let pr { try await api.updatePullRequestTitle(worktreeId: id, pr: pr, title: title) } }
  }

  func updateBody(_ body: String) async -> Bool {
    await run(.body) { api, id, pr in if let pr { try await api.updatePullRequestBody(worktreeId: id, pr: pr, body: body) } }
  }

  func setReviewer(_ login: String, requested: Bool) {
    Task {
      await run(.reviewer(login.lowercased())) { api, id, pr in
        if let pr { try await api.setPullRequestReviewer(worktreeId: id, pr: pr, login: login, requested: requested) }
      }
    }
  }

  func rerunFailedChecks() {
    Task { await run(.rerun) { api, id, pr in if let pr { try await api.rerunFailedChecks(worktreeId: id, pr: pr) } } }
  }

  func addComment(_ body: String) async -> Bool {
    await run(.comment) { api, id, pr in if let pr { try await api.addPullRequestComment(worktreeId: id, pr: pr, body: body) } }
  }

  func reply(to comment: PullRequestComment, body: String) async -> Bool {
    await run(.reply(comment.threadId ?? "\(comment.id)")) { api, id, pr in
      if let pr { try await api.replyToReviewThread(worktreeId: id, pr: pr, to: comment, body: body) }
    }
  }

  func resolveThread(_ threadId: String, resolve: Bool) {
    Task {
      await run(.resolve(threadId)) { api, id, pr in
        if let pr { try await api.resolveReviewThread(worktreeId: id, pr: pr, threadId: threadId, resolve: resolve) }
      }
    }
  }

  func link(_ number: Int) async -> Bool {
    await run(.link) { api, id, _ in try await api.setLinkedPullRequest(worktreeId: id, number: number) }
  }

  /// Unlinks the PR and suppresses it, so branch discovery doesn't bring it straight back.
  func unlink() {
    guard let number = pr?.number else { return }
    Task { await run(.unlink) { api, id, _ in try await api.setLinkedPullRequest(worktreeId: id, number: nil, suppressing: number) } }
  }

  // MARK: Agents

  /// The agent Source Control's AI buttons start: the host's default when it has it, else the first found.
  func launchAgentName() async -> String? {
    guard let repoId = session.worktree(id: worktreeId)?.repoId else { return nil }
    async let detected = try? api.automationAgents(repoId: repoId)
    async let policy = api.agentLaunchPolicy()
    let (found, launch) = await (detected, policy)
    let disabled = launch?.disabled ?? []
    let available = NewWorkspaceViewController.agentOrder.filter { id in
      !disabled.contains(id) && (found.map { $0.contains(id) } ?? true)
    }
    if let preferred = launch?.defaultAgent, available.contains(preferred) { return preferred }
    return available.first
  }

  /// The agent's name for "Fix with …" and "Resolve with …"; nil until read, and then the generic AI.
  private(set) var agentLabel: String?
  private var agentLabelRead = false

  func loadAgentLabel() {
    guard !agentLabelRead else { return }
    agentLabelRead = true
    Task { [weak self] in
      guard let self, let agent = await launchAgentName() else { return }
      agentLabel = NewWorkspaceViewController.agentNames[agent] ?? agent
      changed()
    }
  }

  /// Hands `prompt` to an agent in this workspace; the host starts it and submits the prompt.
  func launchAgent(prompt: @escaping () async -> String) {
    guard !busy.contains(.agent) else { return }
    guard session.status?.capabilities.contains(HostCapability.agentLaunch) == true else {
      agentNotice = (
        String(
          localized: "session.prAiTriageLaunch.updateRequired",
          defaultValue: "Update Orca on this host to start an agent from your phone."), true
      )
      changed()
      return
    }
    busy.insert(.agent)
    agentNotice = nil
    changed()
    let api = api
    let worktreeId = worktreeId
    Task { [weak self] in
      guard let self else { return }
      let agent = await launchAgentName()
      let text = await prompt()
      do {
        guard let agent else {
          throw PullRequestReplyError.refused(
            String(localized: "session.prAiTriageLaunch.loadFailed", defaultValue: "Could not load the available agents."))
        }
        let result = try await api.launchAgent(agent, worktree: "id:\(worktreeId)", prompt: text, operationId: UUID().uuidString)
        // A missing receipt underclaims, as the official client does: the agent may run without the prompt.
        let outcome = result["prompt"]?["outcome"]?.stringValue
        guard outcome != nil, outcome != "not-delivered" else {
          throw PullRequestReplyError.refused(
            String(localized: "session.prAiTriageLaunch.promptNotSent", defaultValue: "The agent started, but the prompt wasn't sent."))
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        let label = session.worktree(id: worktreeId)?.displayName
        agentNotice = (
          label.map {
            String(format: String(localized: "session.prAiTriageLaunch.agentStartedIn", defaultValue: "Agent started in %1$@"), $0)
          } ?? String(localized: "session.prAiTriageLaunch.agentStarted", defaultValue: "Agent started"),
          false
        )
      } catch {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        agentNotice = (Self.message(error), true)
      }
      busy.remove(.agent)
      changed()
    }
  }

  /// The prompt for the PR's failing checks, with each one's log tail where the host can read it.
  func fixChecksPrompt(_ target: [PullRequestCheck]? = nil) -> () async -> String {
    let api = api
    let worktreeId = worktreeId
    let pr = pr
    let checks = target ?? checks
    return {
      guard let pr else { return "" }
      var tails: [String: String] = [:]
      for check in checks.filter(\.isBroken).prefix(5) {
        if let tail = await api.pullRequestCheckLogTail(worktreeId: worktreeId, check: check, prRepo: pr.prRepo) {
          tails[check.name] = tail
        }
      }
      return SourceControlPrompts.fixChecks(number: pr.number, title: pr.title, url: pr.url, checks: checks, logTails: tails)
    }
  }
}

/// Ends an observation when released.
final class PRObservation {
  private let cancel: () -> Void
  init(_ cancel: @escaping () -> Void) { self.cancel = cancel }
  deinit { cancel() }
}

extension PullRequestController {
  nonisolated static func capture<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, Error> {
    do { return .success(try await body()) } catch { return .failure(error) }
  }
}
