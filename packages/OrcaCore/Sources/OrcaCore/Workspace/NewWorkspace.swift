import CryptoKit
import Foundation

/// What the New workspace form sends to `worktree.create`: a project, a name, and where the workspace starts.
public struct WorkspaceCreateRequest: Sendable, Equatable {
  public enum Source: Sendable, Equatable {
    /// A fresh branch off the project's base.
    case none
    /// A GitHub issue or pull request, linked to the workspace as the desktop links one.
    case workItem(GitHubWorkItem)
    /// A GitLab issue or merge request (`.pr`), as `gitlab.listWorkItems` lists it.
    case gitlab(GitHubWorkItem)
    /// A Linear issue: linked by identifier, routed to its workspace.
    case linear(TrackerIssue)
    /// A Jira issue: linked as a work item.
    case jira(TrackerIssue)
    /// An existing branch to start from.
    case branch(refName: String)
    /// A branch made under the typed name; retries suffix the branch with the folder.
    case newBranch
  }

  /// Where a pull or merge request's workspace starts (`worktree.resolvePrBase` / `resolveMrBase`): its head, the
  /// branch to compare against, and where pushes go.
  public struct HostedBase: Sendable, Equatable {
    public var baseBranch: String
    public var compareBaseRef: String?
    public var branchNameOverride: String?
    /// Sent back as the host gave it.
    public var pushTarget: JSONValue?

    public init?(_ json: JSONValue) {
      guard let baseBranch = json["baseBranch"]?.stringValue, !baseBranch.isEmpty else { return nil }
      self.baseBranch = baseBranch
      compareBaseRef = json["compareBaseRef"]?.stringValue
      branchNameOverride = json["branchNameOverride"]?.stringValue
      pushTarget = json["pushTarget"].flatMap { $0.objectValue == nil ? nil : $0 }
    }
  }

  public var repoId: String
  /// The folder and branch seed.
  public var name: String
  /// Shown in the list; nil leaves it to the host.
  public var displayName: String?
  /// The name was made up by the client (a sea creature, or a work item's title) rather than typed.
  public var nameWasGenerated: Bool
  public var source: Source
  public var branchName: String?
  public var agent: String?
  public var note: String?
  /// `run`, `skip` or `inherit` (the project's policy).
  public var setupDecision: String
  /// Pins setup to the content the user approved; repo-wide trust sends none.
  public var approvedSetupHash: String?
  /// A pull or merge request's resolved start point.
  public var base: HostedBase?

  public init(
    repoId: String, name: String, displayName: String?, nameWasGenerated: Bool, source: Source = .none,
    branchName: String? = nil, agent: String? = nil, note: String? = nil, setupDecision: String = "inherit",
    approvedSetupHash: String? = nil, base: HostedBase? = nil
  ) {
    self.repoId = repoId
    self.name = name
    self.displayName = displayName
    self.nameWasGenerated = nameWasGenerated
    self.source = source
    self.branchName = branchName
    self.agent = agent
    self.note = note
    self.setupDecision = setupDecision
    self.approvedSetupHash = approvedSetupHash
    self.base = base
  }

  /// The params for the first try.
  public var params: JSONValue { params(attempt: 0) }

  /// The params, as the official form builds them (blank-workspace-create.ts, workspace-create-params.ts,
  /// source-workspace-create.ts), with the name suffixed for a retry after a collision.
  public func params(attempt: Int) -> JSONValue {
    let candidate = WorkspaceCreateRetry.candidate(name, attempt: attempt, generated: nameWasGenerated && source == .none)
    var params: [String: JSONValue] = [
      "repo": .string("id:\(repoId)"), "name": .string(candidate), "activate": .bool(true),
      "displayNameKind": .string(nameWasGenerated ? "generated" : "user"), "setupDecision": .string(setupDecision),
    ]
    if let displayName, !displayName.isEmpty { params["displayName"] = .string(displayName) }
    if nameWasGenerated, case .none = source { params["nameWasGenerated"] = .bool(true) }
    if let approvedSetupHash { params["approvedSetupHash"] = .string(approvedSetupHash) }
    // An agent starts on the item it was made for.
    let draftURL: String?
    switch source {
    case .none, .newBranch, .branch: draftURL = nil
    case .workItem(let item), .gitlab(let item): draftURL = item.url
    case .linear(let issue), .jira(let issue): draftURL = issue.url
    }
    if agent != nil, let draftURL, !draftURL.isEmpty { params["startupDraft"] = .string(draftURL) }
    switch source {
    case .none: break
    case .workItem(let item):
      params[item.kind == .pr ? "linkedPR" : "linkedIssue"] = .number(Double(item.number))
    case .gitlab(let item):
      params[item.kind == .pr ? "linkedGitLabMR" : "linkedGitLabIssue"] = .number(Double(item.number))
    case .linear(let issue):
      params["linkedLinearIssue"] = .string(issue.identifier)
      if let workspaceId = issue.workspaceId { params["linkedLinearIssueWorkspaceId"] = .string(workspaceId) }
      if let key = WorkspaceSourceLink.linearOrganization(issue.url) {
        params["linkedLinearIssueOrganizationUrlKey"] = .string(key)
      }
    case .jira(let issue):
      params["linkedWorkItem"] = [
        "provider": "jira", "type": "issue", "number": 0, "title": .string(issue.title), "url": .string(issue.url),
        "jiraIdentifier": .string(issue.identifier),
      ]
    case .branch(let refName):
      params["baseBranch"] = .string(refName)
    case .newBranch:
      // The typed branch name is kept as written; a collision suffixes it with the folder.
      params["branchNameOverride"] = .string(candidate)
    }
    if let base {
      params["baseBranch"] = .string(base.baseBranch)
      if let compareBaseRef = base.compareBaseRef { params["compareBaseRef"] = .string(compareBaseRef) }
      if let pushTarget = base.pushTarget { params["pushTarget"] = pushTarget }
      if let override = base.branchNameOverride, !override.isEmpty { params["branchNameOverride"] = .string(override) }
    }
    if let branchName, !branchName.isEmpty {
      params["branchNameOverride"] = .string(WorkspaceCreateRetry.candidate(branchName, attempt: attempt, generated: false))
    }
    if let agent {
      params["startupAgent"] = .string(agent)
      params["createdWithAgent"] = .string(agent)
    }
    if let note, !note.isEmpty { params["comment"] = .string(note) }
    return .object(params)
  }
}

/// Names tried after the host refuses one that is taken (shared/new-workspace/worktree-create-retry-policy.ts).
public enum WorkspaceCreateRetry {
  public static let maxAttempts = 25

  /// `name`, then `name-2`, `name-3`…; a generated sea creature climbs its own tier (`nautilus-3` → `nautilus-4`).
  public static func candidate(_ value: String, attempt: Int, generated: Bool) -> String {
    guard attempt > 0 else { return value }
    if generated, let dash = value.lastIndex(of: "-"), let tier = Int(value[value.index(after: dash)...]), tier >= 2 {
      return "\(value[..<dash])-\(tier + attempt)"
    }
    return "\(value)-\(attempt + 1)"
  }

  /// Older hosts refuse a taken name rather than suffixing it themselves.
  public static func isRetryableConflict(_ message: String) -> Bool {
    let patterns = [
      #"already exists locally"#, #"already exists on a remote"#, #"^Branch ".+" already exists\."#,
      #"already has pr #\d+"#,
    ]
    return patterns.contains { message.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
  }
}

/// What `worktree.create` made.
public struct WorkspaceCreateResult: Sendable, Equatable {
  public var worktreeId: String
  public var name: String
  public var warning: String?
  /// The host skipped setup because the created branch's differs from the one approved.
  public var setupMismatch: SetupHookScript?
}

/// A setup script and its trust hash.
public struct SetupHookScript: Sendable, Equatable {
  public var contentHash: String
  public var scriptContent: String

  public init(contentHash: String, scriptContent: String) {
    self.contentHash = contentHash
    self.scriptContent = scriptContent
  }

  init?(_ json: JSONValue?) {
    guard let hash = json?["contentHash"]?.stringValue, !hash.isEmpty,
      let script = json?["scriptContent"]?.stringValue, !script.isEmpty
    else { return nil }
    self.init(contentHash: hash, scriptContent: script)
  }
}

/// A project's setup as `repo.hooks` reports it (setup-hook-trust.ts, use-new-workspace-setup-script.ts).
public struct RepoSetupHooks: Sendable, Equatable {
  /// The command a create runs; nil when there is none.
  public var command: String?
  /// `orca.yaml` when the script comes from the repository.
  public var source: String?
  /// `ask`, `run-by-default` or `skip-by-default`.
  public var runPolicy: String
  /// The script to approve before it runs; nil when there is no shared setup.
  public var trust: SetupHookScript?
  /// The host read the hooks itself (newer hosts); an approval with no shared setup then pins empty content.
  public var readsSetupConfig: Bool

  public init(_ json: JSONValue) {
    if let config = json.objectValue?["setupConfig"] {
      readsSetupConfig = true
      let command = config["command"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      self.command = command.isEmpty ? nil : command
    } else {
      readsSetupConfig = false
      let command = json["hooks"]?["scripts"]?["setup"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      self.command = command.isEmpty ? nil : command
    }
    source = json["source"]?.stringValue
    let policy = json["setupRunPolicy"]?.stringValue ?? ""
    runPolicy = ["ask", "run-by-default", "skip-by-default"].contains(policy) ? policy : "run-by-default"
    trust = SetupHookScript(json["setupTrust"])
  }
}

/// The ref a create checks out, so `repo.hooks` reports that ref's setup (shared/worktree/setup-hooks-create-source.ts).
public enum SetupCreateSource: Sendable, Equatable {
  /// A new branch off the project's base, or off `baseBranch`.
  case base(baseBranch: String?)
  /// An existing branch reused as it is.
  case branch(ref: String, baseBranch: String?)

  var json: JSONValue {
    switch self {
    case .base(let baseBranch):
      return baseBranch.map { ["kind": "base", "baseBranch": .string($0)] } ?? ["kind": "base"]
    case .branch(let ref, let baseBranch):
      var object: [String: JSONValue] = ["kind": "branch", "ref": .string(ref)]
      if let baseBranch { object["baseBranch"] = .string(baseBranch) }
      return .object(object)
    }
  }
}

/// The desktop's record of approved hook scripts (`ui.trustedOrcaHooks`), read and written whole
/// (shared/workspace-setup/hooks/orca-hook-trust-entries.ts).
public struct OrcaHookTrust: Sendable, Equatable {
  public var entries: [String: JSONValue]

  public init(_ json: JSONValue?) { entries = json?.objectValue ?? [:] }

  /// SHA-256 of the empty script: pins "no shared setup", so a create skips setup the created branch adds.
  public static let emptyContentHash = hash("")

  /// A script's trust hash, as hosts compute it: SHA-256 hex of its trimmed text.
  public static func hash(_ content: String) -> String {
    SHA256.hash(data: Data(content.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
      .map { String(format: "%02x", $0) }.joined()
  }

  private static let kinds = ["setup", "archive", "issueCommand", "vmRecipe"]

  /// Every approved hash for one kind of script, newest first.
  public func approvedHashes(repoId: String, kind: String) -> [String] {
    guard let entry = entries[repoId]?[kind], entry.objectValue != nil else { return [] }
    var hashes: [String] = []
    for value in [entry["contentHash"]] + (entry["previousContentHashes"]?.arrayValue ?? []).map(Optional.some) {
      if let hash = value?.stringValue, !hash.isEmpty, hash.count <= 128, !hashes.contains(hash) { hashes.append(hash) }
    }
    return Array(hashes.prefix(20))
  }

  /// Repo-wide trust; with the id on one host only, an approval of any kind also trusts the repo.
  public func isRepoTrusted(repoId: String, hostsWithRepo: Int) -> Bool {
    guard hostsWithRepo <= 1 else { return false }
    if entries[repoId]?["all"]?.objectValue != nil { return true }
    return Self.kinds.contains { !approvedHashes(repoId: repoId, kind: $0).isEmpty }
  }

  public func isApproved(repoId: String, kind: String = "setup", contentHash: String) -> Bool {
    approvedHashes(repoId: repoId, kind: kind).contains(contentHash)
  }

  public func wasPreviouslyApproved(repoId: String, kind: String = "setup") -> Bool {
    entries[repoId]?[kind]?["contentHash"]?.stringValue?.isEmpty == false
  }

  /// This version recorded as the latest approval, the others kept behind it.
  public func confirming(repoId: String, kind: String = "setup", contentHash: String, at date: Date = Date()) -> Self {
    var repo = entries[repoId]?.objectValue ?? [:]
    if repo[kind]?["contentHash"]?.stringValue == contentHash { return self }
    let previous = approvedHashes(repoId: repoId, kind: kind).filter { $0 != contentHash }.prefix(19)
    var approval: [String: JSONValue] = [
      "contentHash": .string(contentHash), "approvedAt": .number((date.timeIntervalSince1970 * 1000).rounded()),
    ]
    if !previous.isEmpty { approval["previousContentHashes"] = .array(previous.map(JSONValue.string)) }
    repo[kind] = .object(approval)
    var next = self
    next.entries[repoId] = .object(repo)
    return next
  }

  /// The repository trusted for any future script.
  public func alwaysTrusting(repoId: String, at date: Date = Date()) -> Self {
    var repo = entries[repoId]?.objectValue ?? [:]
    if repo["all"]?.objectValue != nil { return self }
    repo["all"] = ["approvedAt": .number((date.timeIntervalSince1970 * 1000).rounded())]
    var next = self
    next.entries[repoId] = .object(repo)
    return next
  }
}

/// A link or number pasted into Start from, found as the official source picker finds one
/// (source-selection/smart-source-paste-intent.ts, shared/github/repositories/links.ts, shared/new-workspace/gitlab-links.ts).
public enum WorkspaceSourceLink: Sendable, Equatable {
  case github(owner: String, repo: String, host: String, number: Int, isPR: Bool)
  /// `12` or `#12`: an issue or pull request in the picked project.
  case githubNumber(Int)
  case gitlab(host: String, path: String, iid: Int, isMR: Bool)

  /// Pasted text bigger than this is never searched or looked up.
  public static let maxQueryBytes = 2048

  public static func parse(_ query: String) -> WorkspaceSourceLink? {
    guard query.utf8.count <= maxQueryBytes else { return nil }
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let url = httpURL(trimmed) {
      var path = url.path
      while path.hasSuffix("/") { path.removeLast() }
      let host = url.port.map { "\(url.host ?? ""):\($0)" } ?? (url.host ?? "")
      if let match = firstMatch(#"^/([^/]+)/([^/]+)/(issues|pull)/(\d+)(?:/.*)?$"#, path),
        let number = Int(match[4]), number > 0
      {
        return .github(owner: match[1], repo: match[2], host: host, number: number, isPR: match[3].lowercased() == "pull")
      }
      if let match = firstMatch(#"^/(.+)/-/(issues|work_items|merge_requests)/(\d+)(?:/.*)?$"#, url.path),
        match[1].contains("/"), let iid = Int(match[3])
      {
        return .gitlab(host: host, path: match[1], iid: iid, isMR: match[2].lowercased() == "merge_requests")
      }
      return nil
    }
    let digits = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
    if !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(digits), number > 0 {
      return .githubNumber(number)
    }
    return nil
  }

  /// A Jira issue link (`…/browse/ABC-12`): its key and the site it belongs to (shared/jira/jira-issue-url.ts).
  public struct Jira: Sendable, Equatable {
    public var issueKey: String
    public var origin: String
    public var sitePath: String

    public init?(_ value: String) {
      guard let url = Self.siteURL(value), url.user == nil, url.password == nil,
        let match = firstMatch(#"^(.*)/browse/([^/]+)$"#, url.path),
        match[2].range(of: #"^[A-Za-z][A-Za-z0-9_]*-\d+$"#, options: .regularExpression) != nil
      else { return nil }
      issueKey = match[2].uppercased()
      origin = Self.siteOrigin(url)
      sitePath = Self.normalize(match[1])
    }

    /// The connected site this link points into.
    public func matches(siteUrl: String) -> Bool {
      guard let url = Self.siteURL(siteUrl), url.user == nil, url.query == nil, url.fragment == nil else { return false }
      return Self.siteOrigin(url) == origin && Self.normalize(url.path) == sitePath
    }

    private static func siteURL(_ value: String) -> URL? {
      guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
        let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil
      else { return nil }
      return url
    }

    private static func siteOrigin(_ url: URL) -> String {
      let scheme = url.scheme?.lowercased() ?? "https"
      let host = url.host?.lowercased() ?? ""
      let defaultPort = scheme == "https" ? 443 : 80
      return url.port.map { $0 == defaultPort ? "\(scheme)://\(host)" : "\(scheme)://\(host):\($0)" }
        ?? "\(scheme)://\(host)"
    }

    private static func normalize(_ path: String) -> String {
      var trimmed = path
      while trimmed.hasSuffix("/") { trimmed.removeLast() }
      return trimmed
    }
  }

  /// The Linear workspace slug in an issue URL (`linear.app/<org>/issue/…`).
  public static func linearOrganization(_ url: String) -> String? {
    guard let parsed = URL(string: url), parsed.host?.lowercased().hasSuffix("linear.app") == true else { return nil }
    let parts = parsed.path.split(separator: "/").map(String.init)
    guard parts.count >= 2, parts[1] == "issue" else { return nil }
    return parts[0]
  }

  private static func httpURL(_ text: String) -> URL? {
    guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
      url.host != nil
    else { return nil }
    return url
  }
}

private func firstMatch(_ pattern: String, _ text: String) -> [String]? {
  guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
    let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
  else { return nil }
  return (0..<match.numberOfRanges).map { index in
    Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
  }
}

/// How a picked source names its workspace (shared/workspace/naming/workspace-name.ts).
public enum WorkspaceSourceName {
  /// A title made branch-safe the way the desktop seeds names from one (slugifyForWorkspaceName).
  public static func slug(_ input: String) -> String {
    var text = input.replacingOccurrences(of: "'", with: "").trimmingCharacters(in: .whitespaces).lowercased()
    text = text.replacingOccurrences(of: "[\\\\/\\s]+", with: "-", options: .regularExpression)
    text = text.replacingOccurrences(of: "[^a-z0-9._-]+", with: "-", options: .regularExpression)
    text = text.replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
    text = text.replacingOccurrences(of: "\\.{2,}", with: ".", options: .regularExpression)
    text = text.replacingOccurrences(of: "^[.-]+|[.-]+$", with: "", options: .regularExpression)
    text = String(text.prefix(48))
    return text.replacingOccurrences(of: "[-._]+$", with: "", options: .regularExpression)
  }

  /// The title without its `Issue #12:` style prefix or `(#12)` references.
  static func subject(_ title: String) -> String {
    var text = title.trimmingCharacters(in: .whitespaces)
    text = text.replacingOccurrences(
      of: #"^(?:issue|pr|pull request|mr|merge request)\s*[#!]?\d+\s*[:-]\s*"#, with: "",
      options: [.regularExpression, .caseInsensitive])
    text = text.replacingOccurrences(of: #"^#\d+\s*[:-]\s*"#, with: "", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\([#!]?\d+\)"#, with: "", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\b#\d+\b"#, with: "", options: .regularExpression)
    return text.trimmingCharacters(in: .whitespaces)
  }

  /// A GitHub or GitLab item: the subject as the list shows it, and its slug (falling back to `pr-12`).
  public static func hosted(title: String, number: Int, kind: String) -> (seed: String, display: String) {
    let subject = subject(title).isEmpty ? title.trimmingCharacters(in: .whitespaces) : subject(title)
    let seed = slug(subject)
    let identity = kind == "pr" ? "PR \(number)" : kind == "mr" ? "MR \(number)" : "Issue \(number)"
    return (seed.isEmpty ? "\(kind)-\(number)" : seed, subject.isEmpty ? identity : subject)
  }

  /// A Linear or Jira issue: `ABC-12 Subject`, slugged.
  public static func identified(identifier: String, title: String) -> (seed: String, display: String) {
    var subject = subject(title).isEmpty ? title.trimmingCharacters(in: .whitespaces) : subject(title)
    let escaped = NSRegularExpression.escapedPattern(for: identifier)
    subject = subject.replacingOccurrences(
      of: "^\(escaped)\\s*[:-]?\\s*", with: "", options: [.regularExpression, .caseInsensitive]
    ).trimmingCharacters(in: .whitespaces)
    let display = [identifier, subject].filter { !$0.isEmpty }.joined(separator: " ")
    let seed = slug(display)
    return (seed.isEmpty ? identifier.lowercased() : seed, display.isEmpty ? identifier.uppercased() : display)
  }
}

/// A branch `repo.searchRefs` found.
public struct BranchRef: Sendable, Equatable, Identifiable {
  public var refName: String
  public var localBranchName: String
  public var id: String { refName }

  /// The ref without its `refs/heads/` or `refs/remotes/` prefix.
  public var label: String {
    for prefix in ["refs/heads/", "refs/remotes/"] where refName.hasPrefix(prefix) {
      return String(refName.dropFirst(prefix.count))
    }
    return refName
  }
}

/// An SSH target's connection as `ssh.getState` and `ssh.connect` report it.
public struct SSHConnectionState: Sendable, Equatable {
  /// `connected`, `connecting`, `deploying-relay`, `reconnecting`, `auth-failed`, `reconnection-failed`, `error` or
  /// `disconnected`.
  public var status: String
  public var error: String?

  public init(status: String, error: String? = nil) {
    self.status = status
    self.error = error
  }

  init?(_ json: JSONValue, targetId: String) {
    guard let status = json["status"]?.stringValue else { return nil }
    if let target = json["targetId"]?.stringValue, target != targetId { return nil }
    self.status = status
    error = json["error"]?.stringValue
  }

  public var isConnected: Bool { status == "connected" }
  public var inProgress: Bool { ["connecting", "deploying-relay", "reconnecting"].contains(status) }
}

extension HostAPI {
  /// Makes a workspace from the New workspace form, trying the next name when the host says one is taken
  /// (worktree-create-retry.ts).
  public func createWorkspace(_ request: WorkspaceCreateRequest) async throws -> WorkspaceCreateResult {
    var lastError: Error?
    for attempt in 0..<WorkspaceCreateRetry.maxAttempts {
      let params = request.params(attempt: attempt)
      do {
        let reply = try await connection.request("worktree.create", params, timeout: .seconds(60))
        guard let id = reply["worktree"]?["id"]?.stringValue else {
          throw RPCError(code: "create_failed", message: "Failed to create workspace", data: nil)
        }
        let displayName = reply["worktree"]?["displayName"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
        let warning = reply["warning"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return WorkspaceCreateResult(
          worktreeId: id, name: displayName.isEmpty ? (params["name"]?.stringValue ?? request.name) : displayName,
          warning: warning.isEmpty ? nil : warning, setupMismatch: SetupHookScript(reply["setupTrustMismatch"]))
      } catch let error as RPCError where WorkspaceCreateRetry.isRetryableConflict(error.message) {
        lastError = error
      }
    }
    throw lastError ?? RPCError(code: "create_failed", message: "Failed to create workspace", data: nil)
  }

  /// A project's branches matching a search (`repo.searchRefs`); an empty query lists recent ones.
  public func searchBranches(repoId: String, query: String, limit: Int = 20) async throws -> [BranchRef] {
    let reply = try await connection.request(
      "repo.searchRefs",
      ["repo": .string("id:\(repoId)"), "query": .string(query), "limit": .number(Double(limit))],
      timeout: .seconds(30))
    if let details = reply["refDetails"]?.arrayValue {
      return details.compactMap { json in
        guard let refName = json["refName"]?.stringValue else { return nil }
        return BranchRef(refName: refName, localBranchName: json["localBranchName"]?.stringValue ?? refName)
      }
    }
    // Older hosts answer with bare ref names.
    return (reply["refs"]?.arrayValue ?? []).compactMap(\.stringValue).map { refName in
      var ref = BranchRef(refName: refName, localBranchName: refName)
      ref.localBranchName = ref.label
      return ref
    }
  }

  /// A project's issues and pull requests matching the typed text, as the source picker searches them: the text as
  /// written, so an empty search lists both kinds.
  public func searchWorkItems(repoId: String, repoName: String, query: String) async throws -> [GitHubWorkItem] {
    guard let repo = TaskRepo(["id": .string(repoId), "displayName": .string(repoName)]) else { return [] }
    let reply = try await connection.request(
      "github.listWorkItems",
      ["repo": .string("id:\(repoId)"), "limit": 36, "query": .string(query.trimmingCharacters(in: .whitespaces))])
    return (reply["items"]?.arrayValue ?? []).compactMap { GitHubWorkItem($0, repo: repo) }
  }

  /// One issue or pull request by number in a project (`github.workItem`).
  public func githubWorkItem(repoId: String, repoName: String, number: Int) async throws -> GitHubWorkItem? {
    guard let repo = TaskRepo(["id": .string(repoId), "displayName": .string(repoName)]) else { return nil }
    let reply = try await connection.request(
      "github.workItem", ["repo": .string("id:\(repoId)"), "number": .number(Double(number))])
    return GitHubWorkItem(reply, repo: repo)
  }

  /// A pasted link's issue or pull request, read through a project (`github.workItemByOwnerRepo`).
  public func githubWorkItem(
    repoId: String, repoName: String, owner: String, ownerRepo: String, host: String?, number: Int, isPR: Bool
  ) async throws -> GitHubWorkItem? {
    guard let repo = TaskRepo(["id": .string(repoId), "displayName": .string(repoName)]) else { return nil }
    var params: [String: JSONValue] = [
      "repo": .string("id:\(repoId)"), "owner": .string(owner), "ownerRepo": .string(ownerRepo),
      "number": .number(Double(number)), "type": .string(isPR ? "pr" : "issue"),
    ]
    if let host, !host.isEmpty { params["host"] = .string(host) }
    return GitHubWorkItem(try await connection.request("github.workItemByOwnerRepo", .object(params)), repo: repo)
  }

  /// A project's GitLab issues and merge requests matching the text, in one state (`gitlab.listWorkItems`).
  public func searchGitLabItems(repoId: String, repoName: String, query: String, state: String) async throws
    -> [GitHubWorkItem]
  {
    guard let repo = TaskRepo(["id": .string(repoId), "displayName": .string(repoName)]) else { return [] }
    let found = try await gitlabWorkItems(in: repo, state: state, query: query)
    if let error = found.error {
      throw RPCError(code: "gitlab_search_failed", message: error, data: nil)
    }
    return found.items
  }

  /// A pasted GitLab link's issue or merge request (`gitlab.workItemByPath`); merge requests read as `.pr`.
  public func gitlabWorkItem(repoId: String, repoName: String, host: String, path: String, iid: Int, isMR: Bool)
    async throws -> GitHubWorkItem?
  {
    guard let repo = TaskRepo(["id": .string(repoId), "displayName": .string(repoName)]) else { return nil }
    let reply = try await connection.request(
      "gitlab.workItemByPath",
      [
        "repo": .string("id:\(repoId)"), "host": .string(host), "path": .string(path), "iid": .number(Double(iid)),
        "type": .string(isMR ? "mr" : "issue"),
      ])
    guard case .object(var fields) = reply else { return nil }
    if fields["type"]?.stringValue == "mr" { fields["type"] = "pr" }
    return GitHubWorkItem(.object(fields), repo: repo)
  }

  /// Linear issues matching the text, or the ones assigned to the user when there is none (smart-source-search-requests.ts).
  public func searchLinearSource(query: String, workspaceId: String?) async throws -> [TrackerIssue] {
    try await linearIssues(filter: "assigned", query: query, limit: 50, workspaceId: workspaceId)
  }

  /// Where a pull request's workspace starts: its head, compare base and push target (`worktree.resolvePrBase`).
  public func resolvePullRequestBase(repoId: String, number: Int) async throws -> WorkspaceCreateRequest.HostedBase? {
    let reply = try await connection.request(
      "worktree.resolvePrBase", ["repo": .string("id:\(repoId)"), "prNumber": .number(Double(number))],
      timeout: .seconds(30))
    if let error = reply["error"]?.stringValue { throw RPCError(code: "resolve_failed", message: error, data: nil) }
    return WorkspaceCreateRequest.HostedBase(reply)
  }

  /// Where a merge request's workspace starts (`worktree.resolveMrBase`).
  public func resolveMergeRequestBase(repoId: String, iid: Int) async throws -> WorkspaceCreateRequest.HostedBase? {
    let reply = try await connection.request(
      "worktree.resolveMrBase", ["repo": .string("id:\(repoId)"), "mrIid": .number(Double(iid))], timeout: .seconds(30))
    if let error = reply["error"]?.stringValue { throw RPCError(code: "resolve_failed", message: error, data: nil) }
    return WorkspaceCreateRequest.HostedBase(reply)
  }

  /// A project's setup script (`repo.hooks`); with a create's start point, the setup a create from it would run.
  public func setupHooks(repoId: String, createSource: SetupCreateSource? = nil) async throws -> RepoSetupHooks {
    var params: [String: JSONValue] = ["repo": .string("id:\(repoId)")]
    if let createSource { params["createSource"] = createSource.json }
    return RepoSetupHooks(try await connection.request("repo.hooks", .object(params), timeout: .seconds(30)))
  }

  /// The approved hook scripts (`ui.get` `trustedOrcaHooks`); none when the read fails.
  public func orcaHookTrust() async -> OrcaHookTrust {
    OrcaHookTrust((try? await connection.request("ui.get", [:]))?["ui"]?["trustedOrcaHooks"])
  }

  public func saveOrcaHookTrust(_ trust: OrcaHookTrust) async throws {
    _ = try await connection.request("ui.set", ["trustedOrcaHooks": .object(trust.entries)])
  }

  /// Runs setup the user reviewed in a workspace that was made without it (`worktree.runApprovedSetup`); false when
  /// its `orca.yaml` changed again.
  public func runApprovedSetup(worktreeId: String, contentHash: String) async throws -> Bool {
    let reply = try await connection.request(
      "worktree.runApprovedSetup", ["worktree": .string("id:\(worktreeId)"), "approvedSetupHash": .string(contentHash)])
    return reply["status"]?.stringValue != "mismatch"
  }

  /// An SSH target's connection (`ssh.getState`).
  public func sshState(targetId: String) async throws -> SSHConnectionState {
    let reply = try await connection.request("ssh.getState", ["targetId": .string(targetId)])
    return SSHConnectionState(reply, targetId: targetId) ?? SSHConnectionState(status: "disconnected")
  }

  /// Connects an SSH target (`ssh.connect`); it may take a while to deploy the relay.
  public func connectSSH(targetId: String) async throws -> SSHConnectionState {
    let reply = try await connection.request("ssh.connect", ["targetId": .string(targetId)], timeout: .seconds(120))
    return SSHConnectionState(reply, targetId: targetId) ?? SSHConnectionState(status: "connected")
  }

  /// Whether `glab` is installed, so GitLab can be searched (`preflight.check`).
  public func gitlabAvailable() async -> Bool {
    (try? await connection.request("preflight.check", [:]))?["glab"]?["installed"]?.boolValue ?? false
  }

  /// The names of this desktop's SSH targets by id (`ssh.listTargetSummaries`), for naming where a project runs.
  public func sshTargetLabels() async -> [String: String] {
    guard let reply = try? await connection.request("ssh.listTargetSummaries", [:]) else { return [:] }
    var labels: [String: String] = [:]
    for target in reply["targets"]?.arrayValue ?? [] {
      guard let id = target["id"]?.stringValue, let label = target["label"]?.stringValue,
        !label.trimmingCharacters(in: .whitespaces).isEmpty
      else { continue }
      labels[id] = label
    }
    return labels
  }
}
