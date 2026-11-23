import Foundation

/// The repository a pull request lives in (`prRepo`); a fork's or an Enterprise host's, so actions never fall
/// back to a same-named github.com repository.
public struct GitHubRepoSlug: Sendable, Equatable {
  public var owner: String
  public var repo: String
  public var host: String?

  init?(_ json: JSONValue?) {
    guard let owner = json?["owner"]?.stringValue, !owner.isEmpty, let repo = json?["repo"]?.stringValue, !repo.isEmpty
    else { return nil }
    self.owner = owner
    self.repo = repo
    host = json?["host"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
  }

  var json: JSONValue {
    var object: [String: JSONValue] = ["owner": .string(owner), "repo": .string(repo)]
    if let host { object["host"] = .string(host) }
    return .object(object)
  }
}

/// A provider's roll-up of a PR's checks (`checksSummary`).
public struct PullRequestCheckSummary: Sendable, Equatable {
  /// `success`, `failure`, `pending`, `neutral` or `none`.
  public var state: String
  public var total: Int
  public var passed: Int
  public var failed: Int
  public var pending: Int
  public var neutral: Int
  /// Of `failed`, the ones only cancelled; absent from older hosts.
  public var cancelled: Int?

  public init(state: String, total: Int, passed: Int, failed: Int, pending: Int, neutral: Int, cancelled: Int?) {
    self.state = state
    self.total = total
    self.passed = passed
    self.failed = failed
    self.pending = pending
    self.neutral = neutral
    self.cancelled = cancelled
  }

  init?(_ json: JSONValue?) {
    guard let json, let state = json["state"]?.stringValue,
      ["success", "failure", "pending", "neutral", "none"].contains(state)
    else { return nil }
    self.state = state
    total = json["total"]?.intValue ?? 0
    passed = json["passed"]?.intValue ?? 0
    failed = json["failed"]?.intValue ?? 0
    pending = json["pending"]?.intValue ?? 0
    neutral = json["neutral"]?.intValue ?? 0
    cancelled = json["cancelled"]?.intValue
  }

  /// The roll-up with cancellations told apart (provider-check-summary.ts getProviderChecksOutcome):
  /// `failure`, `pending`, `cancelled`, `success`, `neutral` or `none`.
  public var outcome: String {
    guard let cancelled, cancelled <= failed, total == passed + failed + pending + neutral else { return state }
    if failed > cancelled { return "failure" }
    if pending > 0 { return "pending" }
    if cancelled > 0, state == "failure" { return "cancelled" }
    return state
  }
}

/// `github.prForBranch`'s pull request (PRInfo). Enums stay open strings; a newer host's value reads as unknown.
public struct PullRequestInfo: Sendable, Equatable {
  public struct MergeMethodSettings: Sendable, Equatable {
    public var defaultMethod: String
    public var allowed: Set<String>
  }

  public var number: Int
  public var title: String
  /// `open`, `closed`, `merged` or `draft`.
  public var state: String
  public var url: String
  /// `pending`, `success`, `failure` or `neutral`.
  public var checksStatus: String
  public var checksSummary: PullRequestCheckSummary?
  public var updatedAt: String
  /// `MERGEABLE`, `CONFLICTING` or `UNKNOWN`.
  public var mergeable: String
  /// `APPROVED`, `CHANGES_REQUESTED`, `REVIEW_REQUIRED`, or nil.
  public var reviewDecision: String?
  public var autoMergeEnabled: Bool?
  public var autoMergeAllowed: Bool?
  public var mergeQueueRequired: Bool?
  public var mergeStateStatus: String?
  public var headSha: String?
  public var headRefName: String?
  public var baseRefName: String?
  public var prRepo: GitHubRepoSlug?
  public var mergeMethodSettings: MergeMethodSettings?
  /// The base and files GitHub reports in conflict, from hosts that send them.
  public var conflictBaseRef: String?
  public var conflictFiles: [String]
  /// The PR sits in a stack; GitHub merges it with every PR below, which this client leaves to the desktop.
  public var isStacked: Bool

  init?(_ json: JSONValue) {
    guard let number = json["number"]?.intValue,
      let state = json["state"]?.stringValue, ["open", "closed", "merged", "draft"].contains(state)
    else { return nil }
    self.number = number
    self.state = state
    title = json["title"]?.stringValue ?? ""
    url = json["url"]?.stringValue ?? ""
    checksStatus = json["checksStatus"]?.stringValue ?? "pending"
    checksSummary = PullRequestCheckSummary(json["checksSummary"])
    updatedAt = json["updatedAt"]?.stringValue ?? ""
    mergeable = json["mergeable"]?.stringValue ?? "UNKNOWN"
    reviewDecision = json["reviewDecision"]?.stringValue
    autoMergeEnabled = json["autoMergeEnabled"]?.boolValue
    autoMergeAllowed = json["autoMergeAllowed"]?.boolValue
    mergeQueueRequired = json["mergeQueueRequired"]?.boolValue
    mergeStateStatus = json["mergeStateStatus"]?.stringValue
    headSha = json["headSha"]?.stringValue
    headRefName = json["headRefName"]?.stringValue
    baseRefName = json["baseRefName"]?.stringValue ?? json["conflictSummary"]?["baseRef"]?.stringValue
    prRepo = GitHubRepoSlug(json["prRepo"])
    if let settings = json["mergeMethodSettings"], let method = settings["defaultMethod"]?.stringValue {
      let allowed = settings["allowedMethods"]
      mergeMethodSettings = MergeMethodSettings(
        defaultMethod: method,
        allowed: Set(["merge", "squash", "rebase"].filter { allowed?[$0]?.boolValue == true }))
    }
    conflictBaseRef = json["conflictSummary"]?["baseRef"]?.stringValue
    conflictFiles = (json["conflictSummary"]?["files"]?.arrayValue ?? []).compactMap {
      $0.stringValue ?? $0["path"]?.stringValue
    }
    isStacked = json["stack"]?["number"]?.intValue != nil
  }

  public var isOpen: Bool { state == "open" || state == "draft" }
  public var hasConflicts: Bool { mergeable == "CONFLICTING" || mergeStateStatus == "DIRTY" }

  /// The repo's merge methods, its default first (pull-request-merge-methods.ts).
  public var mergeMethods: (defaultMethod: String, methods: [String]) {
    let order = ["squash", "merge", "rebase"]
    let allowed = mergeMethodSettings?.allowed ?? Set(order)
    let first = order.first(where: allowed.contains)
    let configured = mergeMethodSettings?.defaultMethod
    let defaultMethod = configured.flatMap { allowed.contains($0) ? $0 : nil } ?? first ?? "squash"
    let methods = ([defaultMethod] + order.filter { $0 != defaultMethod }).filter(allowed.contains)
    return (defaultMethod, methods.isEmpty ? order : methods)
  }
}

/// What `github.prForBranch` found for the branch.
public enum PullRequestLookup: Sendable, Equatable {
  case found(PullRequestInfo)
  /// No pull request; `retryAfter` when the host is still revalidating and asks to be read again that soon.
  case none(retryAfter: Double?)
  /// The host kept no answer yet; read again after this many seconds.
  case revalidating(retryAfter: Double)
  /// The host could not reach GitHub, in its own words.
  case upstreamError(String)

  init(_ json: JSONValue) throws {
    let retry = json["revalidation"]?["retryAfterMs"]?.doubleValue.map { $0 / 1000 }
    switch json["kind"]?.stringValue {
    case "upstream-error":
      self = .upstreamError(json["message"]?.stringValue ?? "")
    case "no-pr":
      self = .none(retryAfter: retry)
    case "found":
      guard let pr = PullRequestInfo(json["pr"] ?? .null) else { throw PullRequestReplyError.unreadable }
      self = .found(pr)
    case .some:
      throw PullRequestReplyError.unreadable
    case nil:
      if json.isNull {
        self = .none(retryAfter: nil)
      } else if json["revalidation"] != nil, json["number"] == nil {
        self = .revalidating(retryAfter: retry ?? 5)
      } else if let pr = PullRequestInfo(json) {
        // Older hosts answer with the bare PR.
        self = .found(pr)
      } else {
        throw PullRequestReplyError.unreadable
      }
    }
  }
}

public enum PullRequestReplyError: LocalizedError, Equatable {
  case unreadable
  /// The host declined a PR write with its own reason.
  case refused(String)

  public var errorDescription: String? {
    switch self {
    case .unreadable: "The host sent a pull request this version can't read."
    case .refused(let message): message
    }
  }
}

/// One check run on the PR's head (`github.prChecks`).
public struct PullRequestCheck: Sendable, Equatable {
  /// How a check reads (provider-check-summary.ts classifyCheckOutcome).
  public enum Outcome: Sendable, Equatable { case passed, failed, pending, neutral }

  public var name: String
  /// `queued`, `in_progress` or `completed`.
  public var status: String
  public var conclusion: String?
  public var url: String?
  public var checkRunId: Int?
  public var workflowRunId: Int?

  public init(name: String, status: String, conclusion: String?, url: String? = nil) {
    self.name = name
    self.status = status
    self.conclusion = conclusion
    self.url = url
  }

  init?(_ json: JSONValue) {
    guard let name = json["name"]?.stringValue, let status = json["status"]?.stringValue else { return nil }
    self.name = name
    self.status = status
    conclusion = json["conclusion"]?.stringValue
    url = json["url"]?.stringValue
    checkRunId = json["checkRunId"]?.intValue
    workflowRunId = json["workflowRunId"]?.intValue
  }

  public var outcome: Outcome {
    let conclusion = (conclusion ?? "").lowercased()
    if ["failure", "error", "startup_failure", "timed_out", "cancelled"].contains(conclusion) { return .failed }
    if conclusion == "action_required" { return .pending }
    if conclusion == "success" || conclusion == "skipped" { return .passed }
    if conclusion == "pending" || status.lowercased() != "completed" { return .pending }
    return .neutral
  }

  public var isCancelled: Bool { conclusion?.lowercased() == "cancelled" }
  /// What the host reruns as failed, and what Fix hands an agent (pr-checks-fix-prompt.ts isBrokenCheck).
  public var isBroken: Bool { ["failure", "cancelled", "timed_out"].contains(conclusion ?? "pending") }

  /// Failing first, then cancelled, running, passed, neutral, skipped (pr-check-severity-order.ts).
  public static func sortedBySeverity(_ checks: [PullRequestCheck]) -> [PullRequestCheck] {
    let ranks = [
      "failure": 0, "timed_out": 0, "action_required": 0, "cancelled": 1, "pending": 2, "success": 3, "neutral": 4,
      "skipped": 5,
    ]
    return checks.enumerated()
      .sorted { lhs, rhs in
        let left = ranks[lhs.element.conclusion ?? "pending"] ?? 6
        let right = ranks[rhs.element.conclusion ?? "pending"] ?? 6
        return left == right ? lhs.offset < rhs.offset : left < right
      }
      .map(\.element)
  }

  /// The counts a list of checks rolls up to.
  public static func summarize(_ checks: [PullRequestCheck]) -> PullRequestCheckSummary {
    var passed = 0, failed = 0, cancelled = 0, pending = 0, neutral = 0
    for check in checks {
      switch check.outcome {
      case .passed: passed += 1
      case .failed:
        failed += 1
        if check.isCancelled { cancelled += 1 }
      case .pending: pending += 1
      case .neutral: neutral += 1
      }
    }
    let state =
      checks.isEmpty ? "none" : failed > 0 ? "failure" : pending > 0 ? "pending" : passed > 0 ? "success" : "neutral"
    return PullRequestCheckSummary(
      state: state, total: checks.count, passed: passed, failed: failed, pending: pending, neutral: neutral,
      cancelled: cancelled)
  }
}

/// One conversation comment or review-thread comment (`comments` of `github.workItemDetails`).
public struct PullRequestComment: Sendable, Equatable, Identifiable {
  public var id: Int
  public var author: String
  public var body: String
  public var createdAt: String
  public var url: String
  /// The file a review comment is on; nil for a conversation comment.
  public var path: String?
  public var threadId: String?
  public var isResolved: Bool?
  public var isOutdated: Bool?
  public var line: Int?
  public var isBot: Bool?

  init?(_ json: JSONValue) {
    guard let id = json["id"]?.intValue else { return nil }
    self.id = id
    author = json["author"]?.stringValue ?? ""
    body = json["body"]?.stringValue ?? ""
    createdAt = json["createdAt"]?.stringValue ?? ""
    url = json["url"]?.stringValue ?? ""
    path = json["path"]?.stringValue
    threadId = json["threadId"]?.stringValue
    isResolved = json["isResolved"]?.boolValue
    isOutdated = json["isOutdated"]?.boolValue
    line = json["line"]?.intValue
    isBot = json["isBot"]?.boolValue
  }

  /// A bot or review service, by the desktop's rules (pr-comment-audience.ts).
  public var isBotAuthored: Bool {
    let login = author.trimmingCharacters(in: .whitespaces)
    let normalized = login.lowercased()
    if isBot == true || normalized.hasSuffix("[bot]") { return true }
    let services = [
      "chatgpt-codex-connector", "codex-connector", "qodo", "coderabbit", "codium", "sonarcloud", "sonarqube",
      "sourcery-ai", "deepsource", "snyk", "codecov", "greptile", "ellipsis", "graphite-app", "reviewer-gpt", "-reviewer",
    ]
    if services.contains(where: normalized.contains) { return true }
    let patterns = ["bot$", "\\bbot\\b", "automation", "actions", "renovate", "dependabot"]
    return patterns.contains { login.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
  }
}

/// Comments as the timeline shows them: a conversation comment alone, or a review thread with its replies.
public enum PullRequestCommentGroup: Sendable, Equatable, Identifiable {
  case standalone(PullRequestComment)
  case thread(id: String, root: PullRequestComment, replies: [PullRequestComment])

  public var id: String {
    switch self {
    case .standalone(let comment): "comment:\(comment.id)"
    case .thread(let id, _, _): "thread:\(id)"
    }
  }

  public var root: PullRequestComment {
    switch self {
    case .standalone(let comment): comment
    case .thread(_, let root, _): root
    }
  }

  public var isThread: Bool { if case .thread = self { true } else { false } }
  public var isResolved: Bool { root.isResolved == true }
  public var isUnresolvedThread: Bool { isThread && !isResolved }

  /// Groups in upstream order; a thread sits where its first comment did (pr-comment-groups.ts).
  public static func group(_ comments: [PullRequestComment]) -> [PullRequestCommentGroup] {
    var groups: [PullRequestCommentGroup] = []
    var threadIndex: [String: Int] = [:]
    for comment in comments {
      guard let threadId = comment.threadId else {
        groups.append(.standalone(comment))
        continue
      }
      if let index = threadIndex[threadId], case .thread(let id, let root, let replies) = groups[index] {
        groups[index] = .thread(id: id, root: root, replies: replies + [comment])
      } else {
        threadIndex[threadId] = groups.count
        groups.append(.thread(id: threadId, root: comment, replies: []))
      }
    }
    return groups
  }
}

public struct PullRequestUser: Sendable, Equatable {
  public var login: String
  public var name: String?

  init?(_ json: JSONValue) {
    guard let login = json["login"]?.stringValue else { return nil }
    self.login = login
    name = json["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
  }
}

/// A reviewer's latest review: `APPROVED`, `CHANGES_REQUESTED`, `COMMENTED`, `DISMISSED`, `PENDING`.
public struct PullRequestReview: Sendable, Equatable {
  public var login: String
  public var state: String?

  init?(_ json: JSONValue) {
    // Desktop sends a top-level login; raw gh sends author.login.
    guard let login = json["login"]?.stringValue ?? json["author"]?["login"]?.stringValue else { return nil }
    self.login = login
    state = json["state"]?.stringValue
  }
}

/// One file the PR changes, with whether the viewer marked it viewed.
public struct PullRequestFile: Sendable, Equatable {
  public var path: String
  public var additions: Int
  public var deletions: Int
  public var viewed: Bool

  init?(_ json: JSONValue) {
    guard let path = json["path"]?.stringValue, !path.isEmpty else { return nil }
    self.path = path
    additions = json["additions"]?.intValue ?? 0
    deletions = json["deletions"]?.intValue ?? 0
    viewed = json["viewerViewedState"]?.stringValue == "VIEWED"
  }
}

/// `github.workItemDetails` for a PR: the body, reviewers, comments and files the PR tab reads.
public struct PullRequestDetails: Sendable, Equatable {
  public var title: String
  public var author: String?
  public var updatedAt: String?
  public var branchName: String?
  public var baseRefName: String?
  public var reviewDecision: String?
  public var reviewRequests: [PullRequestUser]
  public var latestReviews: [PullRequestReview]
  public var body: String
  public var comments: [PullRequestComment]
  /// Nil from a host that sends no file list, or could not list them; the changes card then stays hidden.
  public var files: [PullRequestFile]?

  init?(_ json: JSONValue) {
    guard let item = json["item"], item["number"]?.intValue != nil else { return nil }
    title = item["title"]?.stringValue ?? ""
    author = item["author"]?.stringValue
    updatedAt = item["updatedAt"]?.stringValue
    branchName = item["branchName"]?.stringValue
    baseRefName = item["baseRefName"]?.stringValue
    reviewDecision = item["reviewDecision"]?.stringValue
    reviewRequests = (item["reviewRequests"]?.arrayValue ?? []).compactMap(PullRequestUser.init)
    latestReviews = (item["latestReviews"]?.arrayValue ?? []).compactMap(PullRequestReview.init)
    body = json["body"]?.stringValue ?? ""
    comments = (json["comments"]?.arrayValue ?? []).compactMap(PullRequestComment.init)
    files =
      json["filesUnavailable"]?.boolValue == true
      ? nil : json["files"]?.arrayValue.map { $0.compactMap(PullRequestFile.init) }
  }

  /// Requested reviewers, then everyone who reviewed, once each (pr-reviewer-display.ts).
  public var reviewerLogins: [String] {
    var seen = Set<String>()
    return (reviewRequests.map(\.login) + latestReviews.map(\.login)).filter { seen.insert($0.lowercased()).inserted }
  }
}

/// Where a PR stands toward merging (pull-request-merge-state.ts).
public struct PullRequestMergeState: Sendable, Equatable {
  /// `merged`, `closed`, `draft`, `review_required`, `changes_requested`, `conflicts`, `merge_queue`,
  /// `merge_queue_auto_merge_on`, `merge_status_unavailable`, `behind`, `blocked`, `mergeable_checks_failed`,
  /// `mergeable_checks_pending`, `mergeable_checks_passed`, `mergeable`, `checks_passed`, `checking`.
  public var kind: String
  public var directMergeAvailable: Bool
  /// `disable_auto_merge`, `merge_when_ready`, `enable_auto_merge`, or nil when auto-merge doesn't apply.
  public var autoMergeAction: String?

  public init(_ pr: PullRequestInfo) {
    kind = Self.kind(pr)
    directMergeAvailable = [
      "mergeable_checks_failed", "mergeable_checks_pending", "mergeable_checks_passed", "mergeable", "checks_passed",
    ].contains(kind)
    autoMergeAction = Self.autoMergeAction(pr)
  }

  private static func checksState(_ pr: PullRequestInfo) -> String {
    guard let summary = pr.checksSummary else { return pr.checksStatus }
    let outcome = summary.state == pr.checksStatus || summary.state == "none" ? summary.outcome : pr.checksStatus
    return outcome == "cancelled" ? "failure" : outcome
  }

  private static func kind(_ pr: PullRequestInfo) -> String {
    if pr.state == "merged" { return "merged" }
    if pr.state == "closed" { return "closed" }
    if pr.state == "draft" { return "draft" }
    if pr.reviewDecision == "REVIEW_REQUIRED" { return "review_required" }
    if pr.reviewDecision == "CHANGES_REQUESTED" { return "changes_requested" }
    if pr.hasConflicts { return "conflicts" }
    if pr.mergeQueueRequired == true { return pr.autoMergeEnabled == true ? "merge_queue_auto_merge_on" : "merge_queue" }
    // An unknown mergeable still counts as metadata, as the official client reads it; checks then decide.
    let checks = checksState(pr)
    if pr.mergeStateStatus == "BEHIND" { return "behind" }
    if pr.mergeStateStatus == "BLOCKED" { return "blocked" }
    if pr.mergeable == "MERGEABLE" || ["CLEAN", "UNSTABLE", "HAS_HOOKS"].contains(pr.mergeStateStatus ?? "") {
      switch checks {
      case "failure": return "mergeable_checks_failed"
      case "pending": return "mergeable_checks_pending"
      case "success": return "mergeable_checks_passed"
      default: return "mergeable"
      }
    }
    return checks == "success" ? "checks_passed" : "checking"
  }

  private static func autoMergeAction(_ pr: PullRequestInfo) -> String? {
    guard pr.state == "open" else { return nil }
    if pr.autoMergeEnabled == true { return "disable_auto_merge" }
    if pr.hasConflicts { return nil }
    if pr.mergeQueueRequired == true { return "merge_when_ready" }
    let waiting =
      pr.reviewDecision == "REVIEW_REQUIRED" || pr.reviewDecision == "CHANGES_REQUESTED"
      || pr.mergeStateStatus == "BLOCKED" || pr.mergeStateStatus == "BEHIND"
    return pr.mergeStateStatus != "UNSTABLE" && pr.autoMergeAllowed != false && waiting ? "enable_auto_merge" : nil
  }
}

/// The one next action for a branch (source-control-next-step-decision.ts): local conflicts, the commit box,
/// push or pull, create a review, then the review's own steps toward merge.
public enum SourceControlNextStep: Sendable, Equatable {
  /// Desktop's commit-area decision, reduced to what the next step reads.
  public enum Local: Sendable, Equatable {
    /// Nothing local to do (the commit area's idle commit).
    case idle
    case commit, stage
    /// Push, publish, pull, sync or force push; `pushOrPublish` and `ready` say whether Create can ride on it.
    case remote(pushOrPublish: Bool, ready: Bool)
  }

  public enum Review: Sendable, Equatable {
    case loading, none
    case github(PullRequestInfo, failedChecks: Int, pendingChecks: Int)
  }

  /// What the branch's review creation offers: `unavailable`, `create`, or push first then create.
  public enum Creation: Sendable, Equatable { case unavailable, create, pushAndCreate }

  case commit, remote, completeMerge
  case resolveConflicts(review: Bool)
  case createReview(pushFirst: Bool)
  case fixChecks(failed: Int)
  case mergeWhenReady(mergeState: String, pendingChecks: Int)
  case autoMergeOn, merge
  case mergeBlocked(mergeState: String)
  case merged, none

  public static func resolve(
    local: Local, conflictOperation: String?, hasUnresolvedConflicts: Bool, hasChangesToCommit: Bool,
    creation: Creation, review: Review
  ) -> SourceControlNextStep {
    if hasUnresolvedConflicts { return .resolveConflicts(review: false) }
    if conflictOperation == "merge" { return .completeMerge }
    if hasChangesToCommit, local == .stage || local == .commit { return .commit }
    if case .remote(let pushOrPublish, let ready) = local {
      return pushOrPublish && ready && review == .none && creation == .pushAndCreate ? .createReview(pushFirst: true) : .remote
    }
    if local != .idle && local != .commit { return .remote }
    switch review {
    case .loading:
      return .none
    case .none:
      return creation == .unavailable ? .none : .createReview(pushFirst: creation == .pushAndCreate)
    case .github(let pr, let failed, let pending):
      let state = PullRequestMergeState(pr)
      if state.kind == "merged" { return .merged }
      if state.kind == "closed" {
        return creation == .unavailable ? .none : .createReview(pushFirst: creation == .pushAndCreate)
      }
      // Desktop's label ranks review requirements above conflicts; the next step must not.
      if pr.hasConflicts { return .resolveConflicts(review: true) }
      if failed > 0 { return .fixChecks(failed: failed) }
      if pr.autoMergeEnabled == true { return .autoMergeOn }
      if state.directMergeAvailable { return pr.isStacked ? .mergeBlocked(mergeState: state.kind) : .merge }
      if state.autoMergeAction != nil, !pr.isStacked {
        return .mergeWhenReady(mergeState: state.kind, pendingChecks: pending)
      }
      return .mergeBlocked(mergeState: state.kind)
    }
  }
}

/// `hostedReview.getCreationEligibility`: whether the branch can open a review, and the host's prefill.
public struct HostedReviewEligibility: Sendable, Equatable {
  /// `github`, `gitlab`, … or a newer host's token, sent back as is on create.
  public var provider: String
  public var canCreate: Bool
  /// `needs_push`, `detached_head`, `default_branch`, … ; `needs_push` makes Create push first.
  public var blockedReason: String?
  public var defaultBaseRef: String?
  public var title: String?
  public var body: String?

  init?(_ json: JSONValue) {
    guard let provider = json["provider"]?.stringValue else { return nil }
    self.provider = provider
    canCreate = json["canCreate"]?.boolValue ?? false
    blockedReason = json["blockedReason"]?.stringValue
    defaultBaseRef = json["defaultBaseRef"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    title = json["title"]?.stringValue
    body = json["body"]?.stringValue
  }

  public var needsPush: Bool { blockedReason == "needs_push" }
  public var isSupported: Bool { ["github", "gitlab", "bitbucket", "azure-devops", "gitea"].contains(provider) }
}

extension HostAPI {
  /// Hosted-review RPCs take the repo and the worktree as separate selectors; a worktree id is `repoId::path`.
  static func repoSelector(worktreeId: String) -> JSONValue {
    let repoId = worktreeId.range(of: "::").map { String(worktreeId[..<$0.lowerBound]) } ?? worktreeId
    return .string("id:\(repoId)")
  }

  private func prParams(_ worktreeId: String, _ extra: [String: JSONValue], prRepo: GitHubRepoSlug? = nil) -> JSONValue {
    var params = extra
    params["repo"] = Self.repoSelector(worktreeId: worktreeId)
    if let prRepo { params["prRepo"] = prRepo.json }
    return .object(params)
  }

  /// A PR write: `{ok: false, error}` is the host declining with its reason; any other reply is success.
  private func prMutation(_ method: String, _ params: JSONValue) async throws {
    let reply = try await connection.request(method, params, timeout: .seconds(60))
    guard let ok = reply["ok"] else { return }
    guard ok.boolValue == true else {
      let error = reply["error"]?.stringValue ?? reply["error"]?["message"]?.stringValue ?? "Request failed: \(method)"
      throw PullRequestReplyError.refused(error)
    }
  }

  /// A write that answers true or false.
  private func prConfirmation(_ method: String, _ params: JSONValue, unconfirmed: String) async throws {
    let reply = try await connection.request(method, params, timeout: .seconds(60))
    guard reply.boolValue == true else { throw PullRequestReplyError.refused(unconfirmed) }
  }

  /// `github.prForBranch`: the PR the workspace links, else the branch's own.
  public func pullRequestForBranch(
    worktreeId: String, branch: String, linkedPR: Int?, headSha: String?, refresh: Bool = false
  ) async throws -> PullRequestLookup {
    var params: [String: JSONValue] = [
      "branch": .string(branch), "linkedPRNumber": linkedPR.map { .number(Double($0)) } ?? .null,
      "currentHeadOid": headSha.map(JSONValue.string) ?? .null,
    ]
    if refresh {
      params["userRefresh"] = true
      params["reason"] = "manual"
    }
    return try PullRequestLookup(try await connection.request("github.prForBranch", prParams(worktreeId, params)))
  }

  /// `github.workItemDetails` for the PR: body, reviewers, comments, files.
  public func pullRequestDetails(worktreeId: String, number: Int, prRepo: GitHubRepoSlug?) async throws
    -> PullRequestDetails?
  {
    var params: [String: JSONValue] = ["number": .number(Double(number)), "type": "pr"]
    if let prRepo { params["ownerRepo"] = prRepo.json }
    return PullRequestDetails(try await connection.request("github.workItemDetails", prParams(worktreeId, params)))
  }

  /// `github.prChecks` on the PR's head.
  public func pullRequestChecks(
    worktreeId: String, number: Int, headSha: String?, prRepo: GitHubRepoSlug?, refresh: Bool = false
  ) async throws -> [PullRequestCheck] {
    var params: [String: JSONValue] = ["prNumber": .number(Double(number))]
    if let headSha { params["headSha"] = .string(headSha) }
    if refresh {
      params["noCache"] = true
      params["userRefresh"] = true
    }
    let reply = try await connection.request("github.prChecks", prParams(worktreeId, params, prRepo: prRepo))
    return (reply.arrayValue ?? []).compactMap(PullRequestCheck.init)
  }

  /// The failed jobs' log tails for one check (`github.prCheckDetails`), for the Fix prompt.
  public func pullRequestCheckLogTail(worktreeId: String, check: PullRequestCheck, prRepo: GitHubRepoSlug?) async
    -> String?
  {
    var params: [String: JSONValue] = ["checkName": .string(check.name)]
    if let id = check.checkRunId { params["checkRunId"] = .number(Double(id)) }
    if let id = check.workflowRunId { params["workflowRunId"] = .number(Double(id)) }
    if let url = check.url { params["url"] = .string(url) }
    guard let reply = try? await connection.request("github.prCheckDetails", prParams(worktreeId, params, prRepo: prRepo))
    else { return nil }
    let tails = (reply["jobs"]?.arrayValue ?? []).filter { $0["logState"]?.stringValue != "error" }
      .compactMap { $0["logTail"]?.stringValue }.filter { !$0.isEmpty }
    guard !tails.isEmpty else { return nil }
    // The last 150 lines, as desktop bounds them.
    let lines = tails.joined(separator: "\n\n").replacingOccurrences(of: "\r\n", with: "\n").split(
      separator: "\n", omittingEmptySubsequences: false)
    return lines.suffix(150).joined(separator: "\n")
  }

  /// `github.mergePR` with the head the user reviewed, so a push since then isn't merged unseen.
  public func mergePullRequest(worktreeId: String, pr: PullRequestInfo, method: String) async throws {
    var params: [String: JSONValue] = ["prNumber": .number(Double(pr.number)), "method": .string(method)]
    if let head = pr.headSha, head.count == 40 { params["expectedHeadSha"] = .string(head.lowercased()) }
    try await prMutation("github.mergePR", prParams(worktreeId, params, prRepo: pr.prRepo))
  }

  public func setPullRequestAutoMerge(worktreeId: String, pr: PullRequestInfo, enabled: Bool) async throws {
    var params: [String: JSONValue] = ["prNumber": .number(Double(pr.number)), "enabled": .bool(enabled)]
    if enabled { params["method"] = .string(pr.mergeMethods.defaultMethod) }
    try await prMutation("github.setPRAutoMerge", prParams(worktreeId, params, prRepo: pr.prRepo))
  }

  /// Closes or reopens the PR (`github.updatePRState`).
  public func setPullRequestState(worktreeId: String, pr: PullRequestInfo, open: Bool) async throws {
    let params: [String: JSONValue] = [
      "prNumber": .number(Double(pr.number)), "updates": ["state": open ? "open" : "closed"],
    ]
    try await prMutation("github.updatePRState", prParams(worktreeId, params, prRepo: pr.prRepo))
  }

  /// `github.markPRReadyForReview`, or `github.markPRDraft` to turn it back into a draft.
  public func setPullRequestDraft(worktreeId: String, pr: PullRequestInfo, draft: Bool) async throws {
    try await prMutation(
      draft ? "github.markPRDraft" : "github.markPRReadyForReview",
      prParams(worktreeId, ["prNumber": .number(Double(pr.number))], prRepo: pr.prRepo))
  }

  public func updatePullRequestTitle(worktreeId: String, pr: PullRequestInfo, title: String) async throws {
    try await prConfirmation(
      "github.updatePRTitle",
      prParams(worktreeId, ["prNumber": .number(Double(pr.number)), "title": .string(title)], prRepo: pr.prRepo),
      unconfirmed: "Failed to update title.")
  }

  public func updatePullRequestBody(worktreeId: String, pr: PullRequestInfo, body: String) async throws {
    try await prMutation(
      "github.updatePR",
      prParams(worktreeId, ["prNumber": .number(Double(pr.number)), "updates": ["body": .string(body)]], prRepo: pr.prRepo))
  }

  /// `github.requestPRReviewers`, or `github.removePRReviewers` to take the request back.
  public func setPullRequestReviewer(worktreeId: String, pr: PullRequestInfo, login: String, requested: Bool) async throws {
    try await prMutation(
      requested ? "github.requestPRReviewers" : "github.removePRReviewers",
      prParams(worktreeId, ["prNumber": .number(Double(pr.number)), "reviewers": [.string(login)]], prRepo: pr.prRepo))
  }

  /// People who can review in the PR's repository (`github.listAssignableUsers`).
  public func pullRequestAssignableUsers(worktreeId: String, prRepo: GitHubRepoSlug?) async throws -> [PullRequestUser] {
    var params: [String: JSONValue] = [:]
    if let prRepo { params["ownerRepo"] = prRepo.json }
    let reply = try await connection.request("github.listAssignableUsers", prParams(worktreeId, params))
    return (reply.arrayValue ?? []).compactMap(PullRequestUser.init)
  }

  public func rerunFailedChecks(worktreeId: String, pr: PullRequestInfo) async throws {
    var params: [String: JSONValue] = ["prNumber": .number(Double(pr.number)), "failedOnly": true]
    if let head = pr.headSha { params["headSha"] = .string(head) }
    try await prMutation("github.rerunPRChecks", prParams(worktreeId, params, prRepo: pr.prRepo))
  }

  /// A conversation comment on the PR (`github.addIssueComment`).
  public func addPullRequestComment(worktreeId: String, pr: PullRequestInfo, body: String) async throws {
    try await prMutation(
      "github.addIssueComment",
      prParams(worktreeId, ["number": .number(Double(pr.number)), "body": .string(body), "type": "pr"], prRepo: pr.prRepo))
  }

  /// A reply in a review thread (`github.addPRReviewCommentReply`).
  public func replyToReviewThread(
    worktreeId: String, pr: PullRequestInfo, to comment: PullRequestComment, body: String
  ) async throws {
    var params: [String: JSONValue] = [
      "prNumber": .number(Double(pr.number)), "commentId": .number(Double(comment.id)), "body": .string(body),
    ]
    if let threadId = comment.threadId { params["threadId"] = .string(threadId) }
    if let path = comment.path { params["path"] = .string(path) }
    if let line = comment.line, line > 0 { params["line"] = .number(Double(line)) }
    try await prMutation("github.addPRReviewCommentReply", prParams(worktreeId, params, prRepo: pr.prRepo))
  }

  public func resolveReviewThread(worktreeId: String, pr: PullRequestInfo, threadId: String, resolve: Bool) async throws {
    try await prConfirmation(
      "github.resolveReviewThread",
      prParams(worktreeId, ["threadId": .string(threadId), "resolve": .bool(resolve)], prRepo: pr.prRepo),
      unconfirmed: "Failed to update review thread.")
  }

  /// `worktree.show`'s review link and base branch.
  public func worktreeReviewLink(worktreeId: String) async throws -> (linkedPR: Int?, baseRef: String?) {
    let worktree = try await connection.request("worktree.show", ["worktree": .string("id:\(worktreeId)")])["worktree"]
    return (worktree?["linkedPR"]?.intValue, worktree?["baseRef"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 })
  }

  /// Links a PR to the workspace; nil unlinks `suppressing` so branch discovery doesn't bring it straight back.
  public func setLinkedPullRequest(worktreeId: String, number: Int?, suppressing: Int? = nil) async throws {
    var params: [String: JSONValue] = [
      "worktree": .string("id:\(worktreeId)"), "linkedPR": number.map { .number(Double($0)) } ?? .null,
    ]
    if let suppressing { params["suppressedGitHubPR"] = .number(Double(suppressing)) }
    _ = try await connection.request("worktree.set", .object(params))
  }

  public func hostedReviewEligibility(
    worktreeId: String, branch: String, hasUncommittedChanges: Bool, upstream: GitUpstreamStatus?, linkedPR: Int?
  ) async throws -> HostedReviewEligibility? {
    var params: [String: JSONValue] = [
      "repo": Self.repoSelector(worktreeId: worktreeId), "worktree": .string("id:\(worktreeId)"),
      "branch": .string(branch), "base": .null, "hasUncommittedChanges": .bool(hasUncommittedChanges),
      "linkedGitHubPR": linkedPR.map { .number(Double($0)) } ?? .null, "linkedGitLabMR": .null,
    ]
    if let upstream {
      params["hasUpstream"] = .bool(upstream.hasUpstream)
      params["ahead"] = .number(Double(upstream.ahead))
      params["behind"] = .number(Double(upstream.behind))
    }
    return HostedReviewEligibility(
      try await connection.request("hostedReview.getCreationEligibility", .object(params)))
  }

  /// `hostedReview.create`; answers the new review's number and URL, or throws the host's reason.
  public func createHostedReview(
    worktreeId: String, provider: String, base: String, title: String, body: String, draft: Bool
  ) async throws -> (number: Int, url: String) {
    var params: [String: JSONValue] = [
      "repo": Self.repoSelector(worktreeId: worktreeId), "worktree": .string("id:\(worktreeId)"),
      "provider": .string(provider), "base": .string(base.trimmingCharacters(in: .whitespaces)),
      "title": .string(title.trimmingCharacters(in: .whitespacesAndNewlines)), "draft": .bool(draft),
    ]
    let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
    if !body.isEmpty { params["body"] = .string(body) }
    let reply = try await connection.request("hostedReview.create", .object(params), timeout: .seconds(120))
    if reply["ok"]?.boolValue == true, let number = reply["number"]?.intValue {
      return (number, reply["url"]?.stringValue ?? "")
    }
    throw PullRequestReplyError.refused(reply["error"]?.stringValue ?? "Create PR failed")
  }

  /// `git.generatePullRequestFields`: a title and description written by the host's agent.
  public func generatePullRequestFields(
    worktreeId: String, provider: String, base: String, title: String, body: String, draft: Bool
  ) async throws -> (title: String, body: String) {
    var params: [String: JSONValue] = [
      "worktree": .string("id:\(worktreeId)"), "base": .string(base), "title": .string(title), "body": .string(body),
      "draft": .bool(draft),
    ]
    if ["github", "gitlab", "bitbucket", "azure-devops", "gitea"].contains(provider) { params["provider"] = .string(provider) }
    let reply = try await connection.request("git.generatePullRequestFields", .object(params), timeout: .seconds(300))
    guard reply["success"]?.boolValue == true, let fields = reply["fields"] else {
      throw PullRequestReplyError.refused(reply["error"]?.stringValue ?? "No pull request description generated")
    }
    return (fields["title"]?.stringValue ?? title, fields["body"]?.stringValue ?? body)
  }

  public func cancelGeneratePullRequestFields(worktreeId: String) async {
    _ = try? await connection.request("git.cancelGeneratePullRequestFields", ["worktree": .string("id:\(worktreeId)")])
  }
}
