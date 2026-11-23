import Foundation

/// A project set up on a host, where an automation can run (`projectHostSetup.list`, ready rows only).
public struct AutomationSetup: Sendable, Equatable, Identifiable {
  public var id: String
  public var projectId: String
  /// `local`, `ssh:<target>` or `runtime:<id>`.
  public var hostId: String
  public var repoId: String
  public var path: String
  public var displayName: String
  /// The project's name when `project.list` has it, else the setup's.
  public var label: String
  /// `folder` for a plain folder, which can only run in an existing workspace.
  public var kind: String?

  public var isFolder: Bool { kind == "folder" }
  public var isSSH: Bool { hostId.hasPrefix("ssh:") }
  /// The SSH target id an `ssh:` host id names (URI-encoded on the wire).
  public var sshTargetId: String? {
    isSSH ? String(hostId.dropFirst(4)).removingPercentEncoding : nil
  }

  init?(_ json: JSONValue, projects: [String: String]) {
    guard let id = json["id"]?.stringValue, let projectId = json["projectId"]?.stringValue,
      let hostId = json["hostId"]?.stringValue, let repoId = json["repoId"]?.stringValue,
      let path = json["path"]?.stringValue, json["setupState"]?.stringValue == "ready"
    else { return nil }
    self.id = id
    self.projectId = projectId
    self.hostId = hostId
    self.repoId = repoId
    self.path = path
    displayName = json["displayName"]?.stringValue ?? path
    label = projects[projectId] ?? displayName
    kind = json["kind"]?.stringValue
  }
}

/// Where automations on this host can run, as the official editor loads them.
public struct AutomationTargets: Sendable, Equatable {
  public var setups: [AutomationSetup]
  /// SSH target id → generation, which a write to an SSH-hosted automation must name.
  public var sshGenerations: [String: Int]
  /// SSH targets that run their own Orca server; their automations live there, not here.
  public var managedSSHTargets: Set<String>
}

/// The fields of a saved automation the editor needs beyond the list row (`automation.show`).
public struct AutomationDetail: Sendable, Equatable {
  public var projectId: String
  public var workspaceMode: String
  public var workspaceId: String?
  public var timezone: String
  /// The setup it runs in; nil for an automation saved before run contexts.
  public var setupId: String?
  public var hostId: String?
  public var repoId: String?
  public var path: String?
}

/// What the editor saves: the fields the phone writes.
public struct AutomationDraft: Sendable, Equatable {
  public var name: String
  public var prompt: String
  public var agentId: String
  public var rrule: String
  public var timezone: String
  public var enabled: Bool
  public var setup: AutomationSetup?
  /// `new_per_run` or `existing`.
  public var workspaceMode: String
  public var workspaceId: String?

  public init(
    name: String, prompt: String, agentId: String, rrule: String, timezone: String, enabled: Bool,
    setup: AutomationSetup?, workspaceMode: String, workspaceId: String?
  ) {
    self.name = name
    self.prompt = prompt
    self.agentId = agentId
    self.rrule = rrule
    self.timezone = timezone
    self.enabled = enabled
    self.setup = setup
    self.workspaceMode = workspaceMode
    self.workspaceId = workspaceId
  }
}

public enum AutomationEditError: Error, Sendable, Equatable {
  /// The SSH host the project lives on isn't known here, so a write can't name it.
  case unknownDestination
}

extension Automation {
  /// The owner precondition a write echoes: `{ selector }`, without the orphan's display-only `issue`.
  public var expectedOwner: JSONValue? {
    guard let owner, let kind = owner["kind"]?.stringValue else { return nil }
    if kind == "ssh", let targetId = owner["targetId"]?.stringValue, let generation = owner["targetGeneration"] {
      return ["selector": ["kind": "ssh", "targetId": .string(targetId), "targetGeneration": generation]]
    }
    return ["selector": ["kind": .string(kind)]]
  }
}

extension HostAPI {
  /// Projects set up on this host, for an automation's "where it runs".
  public func automationTargets() async throws -> AutomationTargets {
    async let projectsReply = connection.request("project.list", [:])
    async let setupsReply = connection.request("projectHostSetup.list", [:])
    async let sshReply = connection.request("ssh.listTargetSummaries", [:])
    var projects: [String: String] = [:]
    for project in try await projectsReply["projects"]?.arrayValue ?? [] {
      if let id = project["id"]?.stringValue, let name = project["displayName"]?.stringValue { projects[id] = name }
    }
    var generations: [String: Int] = [:]
    var managed: Set<String> = []
    // An old host without SSH summaries has no SSH projects to name.
    for target in (try? await sshReply)?["targets"]?.arrayValue ?? [] {
      guard let id = target["id"]?.stringValue else { continue }
      if let generation = target["generation"]?.intValue { generations[id] = generation }
      if target["managedServer"]?.boolValue == true { managed.insert(id) }
    }
    let setups = (try await setupsReply["setups"]?.arrayValue ?? []).compactMap { AutomationSetup($0, projects: projects) }
      .filter { setup in
        // A managed SSH host's automations live on its own Orca server.
        !(setup.sshTargetId.map(managed.contains) ?? false)
      }
    return AutomationTargets(setups: setups, sshGenerations: generations, managedSSHTargets: managed)
  }

  /// Agents found on this host for a project (`preflight.detectAgents`), in the host's reply order.
  public func automationAgents(repoId: String) async throws -> [String] {
    let reply = try await connection.request("preflight.detectAgents", ["repoId": .string(repoId)])
    let list = reply.arrayValue ?? reply["agents"]?.arrayValue ?? []
    return list.compactMap(\.stringValue)
  }

  /// The host's default agent and the ones turned off (`settings.getAgentLaunch`); nil from an old host.
  public func agentLaunchPolicy() async -> (defaultAgent: String?, disabled: Set<String>)? {
    guard let reply = try? await connection.request("settings.getAgentLaunch", [:]) else { return nil }
    let settings = reply["settings"]
    let disabled = Set((settings?["disabledTuiAgents"]?.arrayValue ?? []).compactMap(\.stringValue))
    return (settings?["defaultTuiAgent"]?.stringValue, disabled)
  }

  /// The saved automation's run target and time zone.
  public func automationDetail(_ automation: Automation) async throws -> AutomationDetail {
    var params: [String: JSONValue] = ["id": .string(automation.id)]
    if let owner = automation.expectedOwner { params["expectedOwner"] = owner }
    let json = try await connection.request("automation.show", .object(params))["automation"] ?? .null
    let context = json["runContext"]
    return AutomationDetail(
      projectId: json["projectId"]?.stringValue ?? "",
      workspaceMode: json["workspaceMode"]?.stringValue ?? "new_per_run",
      workspaceId: json["workspaceId"]?.stringValue,
      timezone: json["timezone"]?.stringValue ?? TimeZone.current.identifier,
      setupId: context?["projectHostSetupId"]?.stringValue,
      hostId: context?["hostId"]?.stringValue,
      repoId: context?["repoId"]?.stringValue,
      path: context?["path"]?.stringValue)
  }

  /// Creates an automation and returns its id.
  @discardableResult
  public func createAutomation(_ draft: AutomationDraft, targets: AutomationTargets) async throws -> String? {
    guard let setup = draft.setup else { throw AutomationEditError.unknownDestination }
    var params = editableFields(draft)
    for (key, value) in try target(draft, setup: setup, targets: targets) { params[key] = value }
    params["dtstart"] = .number((Date().timeIntervalSince1970 * 1000).rounded())
    params["enabled"] = .bool(draft.enabled)
    params["creationKey"] = .string(UUID().uuidString.lowercased())
    let reply = try await connection.request("automation.create", .object(params))
    return reply["automation"]?["id"]?.stringValue
  }

  /// Writes the fields that differ from `original`, and the target when it moved.
  public func updateAutomation(
    _ automation: Automation, draft: AutomationDraft, original: AutomationDraft, targets: AutomationTargets
  ) async throws {
    let fields = editableFields(draft)
    let before = editableFields(original)
    var updates = fields.filter { before[$0.key] != $0.value }
    if draft.enabled != original.enabled { updates["enabled"] = .bool(draft.enabled) }
    var params: [String: JSONValue] = ["id": .string(automation.id)]
    if let owner = automation.expectedOwner { params["expectedOwner"] = owner }
    let moved =
      draft.setup?.id != original.setup?.id || draft.setup?.hostId != original.setup?.hostId
      || draft.workspaceMode != original.workspaceMode || draft.workspaceId != original.workspaceId
    if moved, let setup = draft.setup {
      var target = try target(draft, setup: setup, targets: targets)
      params["destination"] = target.removeValue(forKey: "destination")
      for (key, value) in target { updates[key] = value }
    }
    guard !updates.isEmpty else { return }
    params["updates"] = .object(updates)
    _ = try await connection.request("automation.update", .object(params))
  }

  public func deleteAutomation(_ automation: Automation) async throws {
    var params: [String: JSONValue] = ["id": .string(automation.id)]
    if let owner = automation.expectedOwner { params["expectedOwner"] = owner }
    _ = try await connection.request("automation.delete", .object(params))
  }

  /// Starts a run now, outside the schedule.
  public func runAutomationNow(_ automation: Automation) async throws {
    var params: [String: JSONValue] = ["id": .string(automation.id)]
    if let owner = automation.expectedOwner { params["expectedOwner"] = owner }
    _ = try await connection.request("automation.runNow", .object(params))
  }

  private func editableFields(_ draft: AutomationDraft) -> [String: JSONValue] {
    [
      "name": .string(draft.name.trimmingCharacters(in: .whitespacesAndNewlines)),
      "prompt": .string(draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)),
      "agentId": .string(draft.agentId),
      "rrule": .string(draft.rrule),
      "timezone": .string(draft.timezone),
    ]
  }

  /// `repo`, `workspaceMode`, `workspace`, `runContext` and `destination`, as automation-draft.ts builds them.
  private func target(_ draft: AutomationDraft, setup: AutomationSetup, targets: AutomationTargets) throws
    -> [String: JSONValue]
  {
    var fields: [String: JSONValue] = [
      "repo": .string("id:\(setup.repoId)"),
      "workspaceMode": .string(draft.workspaceMode),
      "runContext": [
        "kind": "workspace-run", "projectId": .string(setup.projectId), "hostId": .string(setup.hostId),
        "projectHostSetupId": .string(setup.id), "repoId": .string(setup.repoId), "path": .string(setup.path),
      ],
    ]
    if draft.workspaceMode == "existing", let workspaceId = draft.workspaceId {
      fields["workspace"] = .string("id:\(workspaceId)")
    }
    if setup.hostId == "local" {
      fields["destination"] = ["selector": ["kind": "self"]]
    } else if let targetId = setup.sshTargetId {
      guard let generation = targets.sshGenerations[targetId] else { throw AutomationEditError.unknownDestination }
      fields["destination"] = [
        "selector": ["kind": "ssh", "targetId": .string(targetId), "targetGeneration": .number(Double(generation))]
      ]
    } else {
      throw AutomationEditError.unknownDestination
    }
    return fields
  }
}
