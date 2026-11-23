import Foundation

/// One run of an automation, as `automation.runs` lists it (automation-reply-schema.ts runSchema).
public struct AutomationRun: Sendable, Equatable, Identifiable {
  public var id: String
  public var automationId: String
  public var title: String
  /// `pending`, `dispatching`, `dispatched`, `completed`, `skipped_*`, `dispatch_failed`, or a newer host's own.
  public var status: String
  /// `schedule`, `manual` or `event`.
  public var trigger: String
  /// Epoch milliseconds.
  public var scheduledFor: Double
  public var startedAt: Double?
  public var workspaceId: String?
  public var workspaceDisplayName: String?
  /// `<tabId>:<leafId>` of the agent's pane.
  public var terminalPaneKey: String?
  public var terminalPtyId: String?
  /// The host's English, shown when `errorCode` is unknown here.
  public var error: String?
  public var errorCode: String?
  /// Values for the error's sentence, numbers as text.
  public var errorParams: [String: String]
  public var output: Output?
  public var precheck: Precheck?
  public var usageUnavailableMessage: String?
  /// What fired an event run (`github`, `slack` …): `triggeredBy`, or an older host's `event`.
  public var eventSource: String?
  public var runContextHostId: String?
  public var runContextPath: String?

  public struct Output: Sendable, Equatable {
    public var content: String
    public var capturedAt: Double
    /// Cut by the host: a list preview, or past its own limit.
    public var truncated: Bool
  }

  public struct Precheck: Sendable, Equatable {
    public var stdout: String
    public var stderr: String
  }

  init?(_ json: JSONValue) {
    guard let id = json["id"]?.stringValue, !id.isEmpty, let automationId = json["automationId"]?.stringValue,
      let status = json["status"]?.stringValue, let scheduledFor = json["scheduledFor"]?.doubleValue
    else { return nil }
    self.id = id
    self.automationId = automationId
    self.status = status
    self.scheduledFor = scheduledFor
    title = json["title"]?.stringValue ?? ""
    trigger = json["trigger"]?.stringValue ?? "schedule"
    startedAt = json["startedAt"]?.doubleValue
    workspaceId = json["workspaceId"]?.stringValue
    workspaceDisplayName = json["workspaceDisplayName"]?.stringValue
    terminalPaneKey = json["terminalPaneKey"]?.stringValue
    terminalPtyId = json["terminalPtyId"]?.stringValue
    error = json["error"]?.stringValue
    errorCode = json["errorCode"]?.stringValue
    var params: [String: String] = [:]
    for (key, value) in json["errorParams"]?.objectValue ?? [:] {
      if let text = value.stringValue {
        params[key] = text
      } else if let number = value.doubleValue {
        params[key] = number == number.rounded() ? String(Int(number)) : String(number)
      }
    }
    errorParams = params
    if let snapshot = json["outputSnapshot"], let content = snapshot["content"]?.stringValue {
      output = Output(
        content: content, capturedAt: snapshot["capturedAt"]?.doubleValue ?? 0,
        truncated: snapshot["truncated"]?.boolValue ?? false)
    }
    if let result = json["precheckResult"], result.objectValue != nil {
      precheck = Precheck(stdout: result["stdout"]?.stringValue ?? "", stderr: result["stderr"]?.stringValue ?? "")
    }
    usageUnavailableMessage = json["usage"]?["unavailableMessage"]?.stringValue
    eventSource = (json["triggeredBy"]?["source"] ?? json["event"]?["source"])?.stringValue
    runContextHostId = json["runContext"]?["hostId"]?.stringValue
    runContextPath = json["runContext"]?["path"]?.stringValue
  }

  /// What the run left to read (automation-run-content.ts getAutomationRunContent): its output, else the precheck's,
  /// else why it has none.
  public func content(error: String?, noOutput: String) -> String {
    if let output, !output.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return output.content }
    if let precheck {
      let text = [precheck.stderr, precheck.stdout].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }.joined(separator: "\n\n")
      if !text.isEmpty { return text }
    }
    return error ?? usageUnavailableMessage ?? noOutput
  }
}

/// A page of run history, newest first.
public struct AutomationRunsPage: Sendable, Equatable {
  public var runs: [AutomationRun]
  /// Where the next page starts; nil at the end of retained history.
  public var nextCursor: String?

  init(_ json: JSONValue) {
    runs = (json["runs"]?.arrayValue ?? []).compactMap(AutomationRun.init)
    nextCursor = json["nextCursor"]?.stringValue
  }
}

extension HostAPI {
  /// A page of runs, previews only: every automation's, or one automation's under its owner.
  public func automationRuns(of automation: Automation?, cursor: String? = nil, limit: Int = 30) async throws
    -> AutomationRunsPage
  {
    var params: [String: JSONValue] = ["limit": .number(Double(limit)), "preview": true]
    if let automation {
      params["automationId"] = .string(automation.id)
      if let owner = automation.expectedOwner { params["expectedOwner"] = owner }
    }
    if let cursor { params["cursor"] = .string(cursor) }
    return AutomationRunsPage(try await connection.request("automation.runs", .object(params)))
  }

  /// One run's full row, for output a list preview cut. Nil when it has left history, or from an old host that
  /// lists instead.
  public func automationRun(_ run: AutomationRun, of automation: Automation?) async throws -> AutomationRun? {
    var params: [String: JSONValue] = [
      "automationId": .string(run.automationId), "runId": .string(run.id),
      // An old host ignores `runId` and lists; one row keeps that answer small.
      "limit": 1,
    ]
    if let automation, automation.id == run.automationId, let owner = automation.expectedOwner {
      params["expectedOwner"] = owner
    }
    let read = try await connection.request("automation.runs", .object(params))["run"].flatMap(AutomationRun.init)
    return read?.id == run.id ? read : nil
  }
}
