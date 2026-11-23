import Foundation

/// A bot as `bots.list` lists it: the parts a phone draws and opens.
public struct Bot: Sendable, Equatable, Identifiable {
  public var id: String
  public var name: String
  /// Its handle, as people type it: `@Orca <folder>`.
  public var folder: String
  /// The folder workspace the bot lives in.
  public var folderWorkspaceId: String
  /// `mascot:<id>`, an uploaded picture's version, or an emoji or letter; nil draws the initial.
  public var avatar: String?
  /// The mascot's tile colour, `#rrggbb`.
  public var avatarColor: String?
  public var paused: Bool
  public var agent: String
  /// The bot's Home Chat session, when it has one.
  public var chatSessionId: String?
  public var createdAt: Double?

  init?(_ json: JSONValue) {
    guard let id = json["id"]?.stringValue, !id.isEmpty, let workspace = json["folderWorkspaceId"]?.stringValue else {
      return nil
    }
    self.id = id
    name = json["name"]?.stringValue ?? ""
    folder = json["folder"]?.stringValue ?? ""
    folderWorkspaceId = workspace
    avatar = json["avatar"]?.stringValue
    avatarColor = json["avatarColor"]?.stringValue
    paused = json["paused"]?.boolValue ?? false
    agent = json["agent"]?.stringValue ?? ""
    chatSessionId = json["chatSessionId"]?.stringValue
    createdAt = json["createdAt"]?.doubleValue
  }

  /// The bot's home as the workspace list names it: folder workspaces are listed as `folder:<id>`.
  public var homeWorktreeId: String { "folder:\(folderWorkspaceId)" }

  /// The bundled mascot's id, when the avatar is one.
  public var mascotId: String? {
    guard let avatar, avatar.hasPrefix("mascot:") else { return nil }
    return String(avatar.dropFirst("mascot:".count))
  }
}

/// The host's bots and their open asks.
public struct BotsListing: Sendable, Equatable {
  /// False when the host has bots turned off; its bot homes then list as ordinary folders.
  public var enabled: Bool
  public var bots: [Bot]
  /// Each bot's Needs you items that are not stale.
  public var needsYou: [String: Int]

  public init() {
    enabled = false
    bots = []
    needsYou = [:]
  }

  init(_ json: JSONValue) {
    enabled = json["botsEnabled"]?.boolValue ?? false
    // One malformed bot is dropped, not the rest.
    bots = enabled ? (json["bots"]?.arrayValue ?? []).compactMap(Bot.init) : []
    var counts: [String: Int] = [:]
    if case .object(let entries)? = json["needsYou"] {
      for (key, value) in entries { if let count = value.intValue, count >= 0 { counts[key] = count } }
    }
    needsYou = counts
  }
}

extension HostAPI {
  /// `bots.list`; an empty listing from a host without bots.
  public func bots() async throws -> BotsListing {
    BotsListing(try await connection.request("bots.list", [:]))
  }
}

extension HostAPI {
  /// Makes a bot (`bots.create`); the host speaks first in its Home Chat.
  /// `extra` carries a template's fields (`seed`, `fromTemplate`, `templateNameShown`).
  public func createBot(name: String, agent: String, mascotId: String?, extra: [String: JSONValue] = [:]) async throws -> Bot? {
    var params: [String: JSONValue] = extra.merging(["name": .string(name), "agent": .string(agent)]) { $1 }
    if let mascotId { params["avatar"] = .string("mascot:\(mascotId)") }
    let result = try await connection.request("bots.create", .object(params))
    return Bot(result["bot"] ?? result)
  }
}

/// Another app's bots found on the desktop (`bots.import.sources`): OpenClaw, Hermes, OpenBot.
public struct BotImportSource: Sendable, Equatable {
  public struct Candidate: Sendable, Equatable {
    /// The old bot's id in its app.
    public var agent: String
    public var name: String
    /// Its folder, with the home folder as `~`.
    public var path: String
    /// The folder as the host reads it.
    public var absolutePath: String
    /// The Orca bot an earlier import made from it.
    public var importedAs: String?
  }

  public var app: String
  public var bots: [Candidate]

  public static let appNames = ["openclaw": "OpenClaw", "hermes": "Hermes", "openbot": "OpenBot"]
}

extension HostAPI {
  public func botImportSources() async throws -> [BotImportSource] {
    let result = try await connection.request("bots.import.sources", [:])
    return (result["sources"]?.arrayValue ?? []).compactMap { source in
      // A newer host's app this build can't name is left out.
      guard let app = source["app"]?.stringValue, BotImportSource.appNames[app] != nil else { return nil }
      let bots = (source["bots"]?.arrayValue ?? []).compactMap { bot -> BotImportSource.Candidate? in
        guard let agent = bot["agent"]?.stringValue, let absolute = bot["absolutePath"]?.stringValue else { return nil }
        return .init(
          agent: agent, name: bot["name"]?.stringValue ?? agent, path: bot["path"]?.stringValue ?? absolute,
          absolutePath: absolute, importedAs: bot["importedAs"]?["name"]?.stringValue)
      }
      return BotImportSource(app: app, bots: bots)
    }
  }
}

/// A shared bot as its link serves it now (`bots.share.review`), read on the desktop it will live on.
public struct BotShareReview: Sendable, Equatable {
  public var reviewId: String
  public var publisher: String?
  public var name: String
  public var purpose: String
  public var mascot: String?
  public var skills: [String]
  /// Tools it calls out to: each is ticked or not by the owner before Create.
  public var tools: [(id: String, name: String, url: String)]
  public var connectors: [String]
  public var schedules: [String]
  public var memory: [String]
  public var setupNote: String?

  public static func == (a: BotShareReview, b: BotShareReview) -> Bool { a.reviewId == b.reviewId }

  init?(_ json: JSONValue) {
    guard let reviewId = json["reviewId"]?.stringValue, let bot = json["bot"] else { return nil }
    self.reviewId = reviewId
    publisher = json["publisher"]?.stringValue
    name = bot["name"]?.stringValue ?? ""
    purpose = bot["purpose"]?.stringValue ?? ""
    mascot = bot["avatar"]?["mascot"]?.stringValue
    skills = (bot["skills"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
    tools = (bot["tools"]?.arrayValue ?? []).compactMap { tool in
      guard let id = tool["id"]?.stringValue else { return nil }
      return (id, tool["name"]?.stringValue ?? id, tool["url"]?.stringValue ?? "")
    }
    connectors = (bot["connectors"]?.arrayValue ?? []).compactMap { $0["kind"]?.stringValue }
    schedules = (bot["schedules"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
    memory = (bot["memory"]?.arrayValue ?? []).compactMap { $0["topic"]?.stringValue }
    setupNote = bot["setupNote"]?.stringValue
  }

  /// A link's share id: a bare id, `orca://bots/share/<id>`, or an Orca share page (skill-share-link.ts).
  public static func shareId(in text: String) -> String? {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let idPattern = "^[A-Za-z0-9_-]{1,128}$"
    if value.range(of: idPattern, options: .regularExpression) != nil { return value }
    guard let url = URL(string: value), let scheme = url.scheme else { return nil }
    var path: String
    switch scheme {
    case "orca": path = (url.host ?? "") + url.path
    case "https" where ["app.orca.dev", "share.orca.dev", "share.onorca.dev"].contains(url.host ?? ""): path = url.path
    default: return nil
    }
    if path.hasPrefix("/") { path.removeFirst() }
    if path.hasSuffix("/") { path.removeLast() }
    let parts = path.split(separator: "/").map(String.init)
    guard parts.count == 3, parts[0] == "bots", parts[1] == "share",
      parts[2].range(of: idPattern, options: .regularExpression) != nil
    else { return nil }
    return parts[2]
  }
}

extension HostAPI {
  /// The version a share link serves now; nil once its sharer stopped it.
  public func botShareReview(shareId: String) async throws -> BotShareReview? {
    let result = try await connection.request("bots.share.review", ["shareId": .string(shareId)])
    return result["review"].flatMap(BotShareReview.init)
  }
}

/// One folder on the desktop (`files.browseServerDir`); `~` is the home folder there.
public struct HostDirectory: Sendable, Equatable {
  public var path: String
  public var folders: [String]
  /// Everything in it that isn't hidden.
  public var itemCount: Int
  public var windows: Bool

  public func child(_ name: String) -> String {
    let separator = windows ? "\\" : "/"
    return path.hasSuffix(separator) ? path + name : path + separator + name
  }
}

extension HostAPI {
  public func browseDirectory(_ path: String) async throws -> HostDirectory {
    let result = try await connection.request("files.browseServerDir", ["path": .string(path)])
    let entries = (result["entries"]?.arrayValue ?? []).compactMap { entry -> (String, Bool)? in
      guard let name = entry["name"]?.stringValue, !name.hasPrefix(".") else { return nil }
      return (name, entry["isDirectory"]?.boolValue ?? false)
    }
    return HostDirectory(
      path: result["resolvedPath"]?.stringValue ?? path,
      folders: entries.filter(\.1).map(\.0).sorted { $0.localizedStandardCompare($1) == .orderedAscending },
      itemCount: entries.count, windows: result["pathFlavor"]?.stringValue == "win32")
  }
}
