import Foundation

/// Something a bot has taken on for its owner (`bots.items.owner.list` / `.show` rows).
public struct BotItem: Sendable, Equatable, Identifiable {
  public enum Status: String, Sendable, CaseIterable {
    case planned, working, waiting
    case needsYou = "needs_you"
    case done, canceled

    public var isOpen: Bool { self != .done && self != .canceled }
  }

  /// A link the item carries: a worker it dispatched, a pull request, a URL, a file or an automation.
  public struct Link: Sendable, Equatable {
    public var kind: String
    public var ref: String
    /// A worker's or issue's title, an automation's name.
    public var title: String?
    /// A worker's state (`working`, `completed`, `failed`…), a PR's (`open`, `merged`…) or an issue's.
    public var state: String?
    /// A PR's page, when the link reached one.
    public var url: String?
    public var prNumber: Int?
  }

  public var uid: String
  public var id: String { uid }
  public var number: Int
  public var ownerBotId: String
  public var ownerName: String?
  public var title: String
  public var description: String?
  public var doneMeans: String?
  public var status: Status
  public var chatId: String
  public var chatKind: String
  public var chatTitle: String?
  public var madeByBotId: String?
  public var madeByName: String?
  public var question: String?
  public var closeNote: String?
  public var waitText: String?
  public var links: [Link]
  public var othersLastEventId: String
  /// Epoch milliseconds.
  public var snoozedUntil: Double?
  public var lastActivityAt: Double
  public var createdAt: Double
  public var closedAt: Double?

  init?(_ json: JSONValue) {
    guard let uid = json["uid"]?.stringValue, let number = json["number"]?.intValue,
      let title = json["title"]?.stringValue,
      let status = json["status"]?.stringValue.flatMap(Status.init(rawValue:))
    else { return nil }
    self.uid = uid
    self.number = number
    self.title = title
    self.status = status
    ownerBotId = json["owner"]?["botId"]?.stringValue ?? ""
    ownerName = json["owner"]?["name"]?.stringValue
    description = json["description"]?.stringValue
    doneMeans = json["doneMeans"]?.stringValue
    chatId = json["chat"]?["id"]?.stringValue ?? ""
    chatKind = json["chat"]?["kind"]?.stringValue ?? "chat"
    chatTitle = json["chat"]?["title"]?.stringValue
    madeByBotId = json["madeBy"]?["botId"]?.stringValue
    madeByName = json["madeBy"]?["name"]?.stringValue
    question = json["question"]?["text"]?.stringValue
    closeNote = json["closeNote"]?.stringValue
    waitText = json["wait"]?["text"]?.stringValue
    links = (json["links"]?.arrayValue ?? []).compactMap { link in
      guard let kind = link["kind"]?.stringValue, let ref = link["ref"]?.stringValue else { return nil }
      let pr = link["pr"]
      let shownPr = pr?["shown"]?.boolValue == true ? pr : nil
      return Link(
        kind: kind, ref: ref,
        title: link["title"]?.stringValue ?? link["name"]?.stringValue ?? link["issue"]?["title"]?.stringValue
          ?? shownPr?["title"]?.stringValue,
        state: link["state"]?.stringValue ?? shownPr?["state"]?.stringValue ?? link["issue"]?["state"]?.stringValue
          ?? link["active"]?.boolValue.map { $0 ? "active" : "ended" },
        url: shownPr?["url"]?.stringValue ?? (kind == "url" ? ref : nil),
        prNumber: shownPr?["number"]?.intValue)
    }
    othersLastEventId = json["othersLastEventId"]?.stringValue ?? ""
    snoozedUntil = json["snoozedUntil"]?.doubleValue
    lastActivityAt = json["lastActivityAt"]?.doubleValue ?? 0
    createdAt = json["createdAt"]?.doubleValue ?? 0
    closedAt = json["closedAt"]?.doubleValue
  }

  /// An open item whose wake time hasn't come.
  public func isSnoozed(now: Double) -> Bool {
    status.isOpen && (snoozedUntil ?? 0) > now
  }

  /// Its last activity, or when it came back from a snooze if that is later.
  public func activityAt(now: Double) -> Double {
    if let snoozedUntil, snoozedUntil <= now { return max(lastActivityAt, snoozedUntil) }
    return lastActivityAt
  }

  /// Untouched for the bot's stale days (Planned: three times that), with no live worker for In progress
  /// and Waiting, and not snoozed.
  public func isStale(days: Double?, now: Double) -> Bool {
    guard let days, !isSnoozed(now: now) else { return false }
    let idle = now - activityAt(now: now)
    let day = 86_400_000.0
    switch status {
    case .needsYou: return idle >= days * day
    case .working, .waiting:
      let liveWorker = links.contains { $0.kind == "dispatch" && ($0.state == "working" || $0.state == "unknown") }
      return idle >= days * day && !liveWorker
    case .planned: return idle >= days * 3 * day
    case .done, .canceled: return false
    }
  }
}

/// One entry of an item's Activity: a comment, a status move, an edit, a link…
public struct BotItemEvent: Sendable, Equatable, Identifiable {
  public enum Actor: Sendable, Equatable {
    case owner
    case orca
    case bot(id: String)
  }

  public var id: String
  /// `made`, `edited`, `status`, `commented`, `linked`, `snoozed`, `unsnoozed`.
  public var kind: String
  public var actor: Actor
  public var data: JSONValue
  /// Epoch milliseconds.
  public var at: Double

  init?(_ json: JSONValue) {
    guard let id = json["id"]?.stringValue, let kind = json["kind"]?.stringValue else { return nil }
    self.id = id
    self.kind = kind
    switch json["actor"]?["kind"]?.stringValue {
    case "owner": actor = .owner
    case "bot": actor = .bot(id: json["actor"]?["botId"]?.stringValue ?? "")
    default: actor = .orca
    }
    data = json["data"] ?? [:]
    at = json["at"]?.doubleValue ?? 0
  }
}

/// A bot's items as its Items tab reads them: every open one and the newest page of closed ones.
public struct BotItemsListing: Sendable, Equatable {
  public var items: [BotItem]
  public var counts: [BotItem.Status: Int]
  public var seenEventId: String
  public var nextClosedCursor: String?
}

/// One item with its newest page of Activity.
public struct BotItemPage: Sendable, Equatable {
  public var item: BotItem
  public var events: [BotItemEvent]
  /// Passed as `before` to read the page before this one.
  public var earlierCursor: String?
}

extension HostAPI {
  /// The bot's items (`bots.items.owner.list`); with `closedCursor`, the next page of closed ones.
  public func botItems(botId: String, closedCursor: String? = nil) async throws -> BotItemsListing {
    var params: [String: JSONValue] = ["botId": .string(botId)]
    if let closedCursor { params["closedCursor"] = .string(closedCursor) }
    let reply = try await connection.request("bots.items.owner.list", .object(params))
    var counts: [BotItem.Status: Int] = [:]
    for (key, value) in reply["counts"]?.objectValue ?? [:] {
      if let status = BotItem.Status(rawValue: key), let count = value.intValue { counts[status] = count }
    }
    return BotItemsListing(
      items: (reply["items"]?.arrayValue ?? []).compactMap(BotItem.init),
      counts: counts,
      seenEventId: reply["seenEventId"]?.stringValue ?? "",
      nextClosedCursor: reply["nextClosedCursor"]?.stringValue)
  }

  /// One item and its newest Activity page (`bots.items.owner.show`), or the page before `before`.
  public func botItem(uid: String, before: String? = nil) async throws -> BotItemPage? {
    var params: [String: JSONValue] = ["item": .string(uid), "newest": true]
    if let before { params["before"] = .string(before) }
    let reply = try await connection.request("bots.items.owner.show", .object(params))
    guard let item = reply["item"].flatMap(BotItem.init) else { return nil }
    return BotItemPage(
      item: item, events: (reply["events"]?.arrayValue ?? []).compactMap(BotItemEvent.init),
      earlierCursor: reply["earlierCursor"]?.stringValue)
  }

  /// Moves the owner's seen mark, so the desktop and the phone agree on what is new.
  public func markBotItemsOpened(botId: String) async {
    _ = try? await connection.request("bots.items.owner.opened", ["botId": .string(botId)])
  }

  /// Hosts that dedupe item comments by `requestId`; an older host refuses the field.
  public static let botItemCommentRequestIdCapability = "bots.item-comment-request-id.v1"

  /// The owner's comment on an item (`bots.items.owner.comment`). A request id (only to a host advertising
  /// `botItemCommentRequestIdCapability`) makes a retry after a lost reply land once: resend the same id.
  public func commentOnBotItem(uid: String, text: String, requestId: String?) async throws {
    var params: [String: JSONValue] = ["item": .string(uid), "text": .string(text)]
    if let requestId { params["requestId"] = .string(requestId) }
    _ = try await connection.request("bots.items.owner.comment", .object(params))
  }

  /// Moves items to a status (`bots.items.owner.status`), one turn for the bot. Cancel needs a `reason`, which
  /// the bot sees. Waiting needs a note and only some hosts take it, so it isn't offered here.
  public func setBotItems(_ uids: [String], status: BotItem.Status, reason: String? = nil) async throws {
    var params: [String: JSONValue] = [
      "items": .array(uids.map(JSONValue.string)), "status": .string(status.rawValue),
    ]
    if let reason, !reason.isEmpty { params["reason"] = .string(reason) }
    _ = try await connection.request("bots.items.owner.status", .object(params))
  }
}
