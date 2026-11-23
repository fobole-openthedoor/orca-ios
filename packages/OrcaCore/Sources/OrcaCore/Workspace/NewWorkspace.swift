import Foundation

/// What the New workspace form sends to `worktree.create`: a project, a name, and where the workspace starts.
public struct WorkspaceCreateRequest: Sendable, Equatable {
  public enum Source: Sendable, Equatable {
    /// A fresh branch off the project's base.
    case none
    /// A GitHub issue or pull request, linked to the workspace as the desktop links one.
    case workItem(GitHubWorkItem)
    /// An existing branch to start from.
    case branch(refName: String)
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

  public init(
    repoId: String, name: String, displayName: String?, nameWasGenerated: Bool, source: Source = .none,
    branchName: String? = nil, agent: String? = nil, note: String? = nil
  ) {
    self.repoId = repoId
    self.name = name
    self.displayName = displayName
    self.nameWasGenerated = nameWasGenerated
    self.source = source
    self.branchName = branchName
    self.agent = agent
    self.note = note
  }

  /// The params, as the official form builds them (blank-workspace-create.ts, workspace-create-params.ts).
  public var params: JSONValue {
    var params: [String: JSONValue] = [
      "repo": .string("id:\(repoId)"), "name": .string(name), "activate": .bool(true),
      "displayNameKind": .string(nameWasGenerated ? "generated" : "user"),
    ]
    if let displayName, !displayName.isEmpty { params["displayName"] = .string(displayName) }
    if nameWasGenerated, case .none = source { params["nameWasGenerated"] = .bool(true) }
    switch source {
    case .none: break
    case .workItem(let item):
      params[item.kind == .pr ? "linkedPR" : "linkedIssue"] = .number(Double(item.number))
      // An agent starts on the item it was made for.
      if agent != nil, !item.url.isEmpty { params["startupDraft"] = .string(item.url) }
    case .branch(let refName):
      params["baseBranch"] = .string(refName)
    }
    if let branchName, !branchName.isEmpty { params["branchNameOverride"] = .string(branchName) }
    if let agent {
      params["startupAgent"] = .string(agent)
      params["createdWithAgent"] = .string(agent)
    }
    if let note, !note.isEmpty { params["comment"] = .string(note) }
    return .object(params)
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

extension HostAPI {
  /// Makes a workspace from the New workspace form and returns its id.
  public func createWorkspace(_ request: WorkspaceCreateRequest) async throws -> String? {
    let result = try await connection.request("worktree.create", request.params, timeout: .seconds(60))
    return result["worktree"]?["id"]?.stringValue
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
