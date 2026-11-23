import Foundation

/// A scheduled agent run, as `automation.list` lists it on this host.
public struct Automation: Sendable, Equatable, Identifiable {
  public var id: String
  public var name: String
  public var prompt: String
  public var agentId: String
  public var enabled: Bool
  /// An RFC 5545 rule, `FREQ=DAILY;BYHOUR=9…`.
  public var rrule: String
  /// Epoch milliseconds.
  public var nextRunAt: Double?
  public var lastRunAt: Double?
  public var lastRunStatus: String?
  /// The owner selector writes must echo, so a host refuses an edit meant for another owner's row.
  public var owner: JSONValue?
  /// The IANA zone the schedule runs in.
  public var timezone: String
  public var projectId: String
  /// `new_per_run` or `existing`.
  public var workspaceMode: String
  public var workspaceId: String?
  /// Where it runs (`runContext`); nil for one saved before run contexts.
  public var runContext: RunContext?

  /// An automation's saved run target: the project setup on one execution host.
  public struct RunContext: Sendable, Equatable {
    public var projectId: String
    public var hostId: String
    public var setupId: String
    public var repoId: String
    public var path: String
  }

  /// `self`, `ssh` or `orphan`: whose automation this is on this host.
  public var ownerKind: String? { owner?["kind"]?.stringValue }
  /// The SSH host an `ssh` owner names.
  public var sshTargetId: String? { ownerKind == "ssh" ? owner?["targetId"]?.stringValue : nil }
  /// Why an orphan has no usable host, in the host's English (automation-list-scope.ts AUTOMATION_ORPHAN_ISSUES).
  public var orphanIssue: String? { ownerKind == "orphan" ? owner?["issue"]?.stringValue ?? "" : nil }

  init?(_ json: JSONValue, owner: JSONValue?) {
    guard let id = json["id"]?.stringValue, !id.isEmpty else { return nil }
    self.id = id
    name = json["name"]?.stringValue ?? ""
    prompt = json["prompt"]?.stringValue ?? ""
    agentId = json["agentId"]?.stringValue ?? ""
    enabled = json["enabled"]?.boolValue ?? false
    rrule = json["rrule"]?.stringValue ?? ""
    nextRunAt = json["nextRunAt"]?.doubleValue
    timezone = json["timezone"]?.stringValue ?? ""
    projectId = json["projectId"]?.stringValue ?? ""
    workspaceMode = json["workspaceMode"]?.stringValue ?? "new_per_run"
    workspaceId = json["workspaceId"]?.stringValue
    if let context = json["runContext"], let hostId = context["hostId"]?.stringValue,
      let setupId = context["projectHostSetupId"]?.stringValue, let path = context["path"]?.stringValue
    {
      runContext = RunContext(
        projectId: context["projectId"]?.stringValue ?? "", hostId: hostId, setupId: setupId,
        repoId: context["repoId"]?.stringValue ?? "", path: path)
    }
    self.owner = owner?["selector"]
    lastRunAt = owner?["usageSummary"]?["lastRunAt"]?.doubleValue
    lastRunStatus = owner?["usageSummary"]?["lastRunStatus"]?.stringValue
  }
}

extension HostAPI {
  /// This host's automations. A row whose owner is missing or listed twice is left out, as the official client does.
  public func automations() async throws -> [Automation] {
    Self.automations(try await connection.request("automation.list", [:]))
  }

  static func automations(_ result: JSONValue) -> [Automation] {
    var owners: [String: JSONValue?] = [:]
    for item in result["items"]?.arrayValue ?? [] {
      guard let id = item["automationId"]?.stringValue else { continue }
      owners[id] = owners[id] == nil ? item : .some(nil)
    }
    return (result["automations"]?.arrayValue ?? []).compactMap { json in
      guard let id = json["id"]?.stringValue, let owner = owners[id], let owner else { return nil }
      return Automation(json, owner: owner)
    }
  }

  /// Turns an automation on or off; the host's updated row when it sends one back.
  @discardableResult
  public func setAutomation(_ automation: Automation, enabled: Bool) async throws -> Automation? {
    var params: [String: JSONValue] = ["id": .string(automation.id), "updates": ["enabled": .bool(enabled)]]
    // The host wants `{ selector }`, not the bare selector.
    if let owner = automation.expectedOwner { params["expectedOwner"] = owner }
    let reply = try await connection.request("automation.update", .object(params))
    guard let json = reply["automation"], var updated = Automation(json, owner: nil) else { return nil }
    // The reply carries the automation only; its owner and last result stay the list's.
    updated.owner = automation.owner
    updated.lastRunAt = automation.lastRunAt
    updated.lastRunStatus = automation.lastRunStatus
    return updated
  }
}
