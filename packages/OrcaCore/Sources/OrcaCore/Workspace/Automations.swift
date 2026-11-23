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

  init?(_ json: JSONValue, owner: JSONValue?) {
    guard let id = json["id"]?.stringValue, !id.isEmpty else { return nil }
    self.id = id
    name = json["name"]?.stringValue ?? ""
    prompt = json["prompt"]?.stringValue ?? ""
    agentId = json["agentId"]?.stringValue ?? ""
    enabled = json["enabled"]?.boolValue ?? false
    rrule = json["rrule"]?.stringValue ?? ""
    nextRunAt = json["nextRunAt"]?.doubleValue
    self.owner = owner?["selector"]
    lastRunAt = owner?["usageSummary"]?["lastRunAt"]?.doubleValue
    lastRunStatus = owner?["usageSummary"]?["lastRunStatus"]?.stringValue
  }
}

extension HostAPI {
  /// This host's automations. A row whose owner is missing or listed twice is left out, as the official client does.
  public func automations() async throws -> [Automation] {
    let result = try await connection.request("automation.list", [:])
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

  /// Turns an automation on or off.
  public func setAutomation(_ automation: Automation, enabled: Bool) async throws {
    var params: [String: JSONValue] = ["id": .string(automation.id), "updates": ["enabled": .bool(enabled)]]
    if let owner = automation.owner { params["expectedOwner"] = owner }
    _ = try await connection.request("automation.update", .object(params))
  }
}
