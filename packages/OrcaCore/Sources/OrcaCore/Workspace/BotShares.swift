import Foundation

/// A live bot link the desktop's Orca account published (shared/bots/bot-share-status.ts BotOwnedShare).
public struct BotOwnedShare: Sendable, Equatable, Identifiable {
  public var id: String
  public var url: String
  /// The package name, `bot-<id>`.
  public var name: String
  public var createdAt: Date?
  /// The link the desktop shows for its bot; older builds' links stay listed after it.
  public var canonical: Bool
  public var pinnedVersionId: String?
  /// For a link whose bot isn't on this desktop: the bot's name as the link serves it.
  public var displayName: String?

  init?(_ json: JSONValue) {
    guard let id = json["id"]?.stringValue, let url = json["url"]?.stringValue, let name = json["name"]?.stringValue else {
      return nil
    }
    self.id = id
    self.url = url
    self.name = name
    createdAt = json["createdAt"]?.stringValue.flatMap(Self.parseDate)
    canonical = json["canonical"]?.boolValue ?? false
    pinnedVersionId = json["pinnedVersionId"]?.stringValue
    displayName = json["displayName"]?.stringValue
  }

  /// The link without its scheme, as the desktop shows it.
  public var urlText: String {
    url.hasPrefix("https://") ? String(url.dropFirst("https://".count)) : url
  }

  /// The package name a bot's links carry (botPackageName).
  public static func packageName(botId: String) -> String {
    "bot-" + botId.replacingOccurrences(of: "-", with: "").lowercased()
  }

  private static func parseDate(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text)
  }
}

/// Why sharing failed, by the codes the desktop throws (shared/bots/bot-share-errors.ts).
public enum BotShareError: String, Error, Sendable, CaseIterable {
  case blocked = "bot_share_secret_found"
  case noteSecret = "bot_share_note_secret"
  case expired = "bot_share_preview_expired"
  case prepareAgain = "bot_share_prepare_again"
  case stopped = "bot_share_link_stopped"
  case moved = "bot_share_link_moved"
  case unavailable = "bot_share_unavailable"
  case avatarRefused = "bot_share_avatar_refused"
  case tooLarge = "bot_share_too_large"
  /// The desktop is signed out of Orca.
  case signIn = "bot_share_sign_in"
  /// The desktop's Orca sign-in needs renewing.
  case reconnect = "bot_share_reconnect"

  /// The code a failure carries, whichever wrapper it came through (botShareErrorCode).
  public static func code(of error: Error) -> BotShareError? {
    let message: String =
      switch error {
      case let error as BotShareError: error.rawValue
      case let error as RPCError: error.message + " " + error.code
      default: "\(error)"
      }
    return allCases.first { message.contains($0.rawValue) }
  }
}

extension HostAPI {
  /// Every live bot link the desktop's account has (`bots.share.status`, oldest builds' links included).
  public func botShares() async throws -> [BotOwnedShare] {
    try Self.botShares(from: try await connection.request("bots.share.status", [:]))
  }

  /// Orca Cloud's answer: the links, or why the desktop's account can't list them.
  static func botShares(from reply: JSONValue) throws -> [BotOwnedShare] {
    // One malformed link is dropped, not the rest (salvagingArray).
    try cloudValue(reply).arrayValue?.compactMap(BotOwnedShare.init) ?? []
  }

  /// Stops a link (`bots.share.stop`); with `botId`, the desktop forgets that bot's last published picks too.
  public func stopBotShare(_ shareId: String, botId: String?) async throws {
    var params: [String: JSONValue] = ["shareId": .string(shareId)]
    if let botId { params["botId"] = .string(botId) }
    _ = try Self.cloudValue(try await connection.request("bots.share.stop", .object(params)))
  }

  /// Update link: builds the bot again from the picks and note it was last published with
  /// (`bots.share.prepare` with `last`), then publishes that over the same link (`bots.share.publish` with `link`).
  public func updateBotShare(_ share: BotOwnedShare, botId: String) async throws {
    guard let versionId = share.pinnedVersionId else { throw BotShareError.moved }
    let prepared = try await connection.request("bots.share.prepare", ["botId": .string(botId), "last": true])
    guard let candidate = prepared["candidate"], let candidateId = candidate["candidateId"]?.stringValue else {
      throw BotShareError.expired
    }
    if candidate["blocked"]?.boolValue == true { throw BotShareError.blocked }
    let note = prepared["last"]?["setupNote"]?.stringValue ?? candidate["bot"]?["setupNote"]?.stringValue ?? ""
    let published = try await connection.request(
      "bots.share.publish",
      [
        "botId": .string(botId), "candidateId": .string(candidateId), "setupNote": .string(note),
        "link": ["shareId": .string(share.id), "expectedVersionId": .string(versionId)],
      ])
    _ = try Self.cloudValue(published)
  }

  /// `{ status: 'ok', value }`, else the sign-in code a signed-out desktop stands for.
  private static func cloudValue(_ reply: JSONValue) throws -> JSONValue {
    switch reply["status"]?.stringValue {
    case "ok": return reply["value"] ?? .null
    case "reconnect-required": throw BotShareError.reconnect
    default: throw BotShareError.signIn
    }
  }
}
