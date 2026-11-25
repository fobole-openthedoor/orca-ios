import Foundation

/// The project sections and checkout membership published by the paired desktop.
public struct WorkspaceProjectCatalog: Sendable, Equatable {
  public struct Project: Sendable, Equatable {
    public let id: String
    public let name: String
    public let order: Int?
    public let isHidden: Bool
  }

  private struct Repository: Sendable, Hashable {
    let hostId: String
    let repoId: String

    var sectionId: String { "repo:\(hostId)|\(repoId)" }
  }

  private struct Surface: Hashable {
    let projectId: String
    let hostId: String
    let executionHostId: String
    let filesystem: String
  }

  private struct Setup {
    let repository: Repository
    let surface: Surface
    let path: String
    let isCheckout: Bool

    init?(_ json: JSONValue) {
      guard let projectId = json["projectId"]?.stringValue, let hostId = json["hostId"]?.stringValue,
        let repoId = json["repoId"]?.stringValue
      else { return nil }
      repository = Repository(hostId: hostId, repoId: repoId)
      isCheckout = json["setupMethod"]?.stringValue != "provisioned" && json["kind"]?.stringValue != "folder"
      let rawPath = json["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let slashPath = rawPath.replacingOccurrences(of: "\\", with: "/")
      let pathParts = slashPath.split(separator: "/")
      let isWSL = slashPath.hasPrefix("//") && pathParts.count > 1
        && ["wsl$", "wsl.localhost"].contains(pathParts[0].lowercased())
      let isWindows = slashPath.dropFirst().hasPrefix(":/") || slashPath.hasPrefix("//")
      let filesystem = isWSL ? "wsl:\(pathParts[1].lowercased())" : (isWindows ? "windows" : "default")
      path = rawPath.isEmpty ? repoId : (isWindows ? slashPath.lowercased() : rawPath)
      surface = Surface(
        projectId: projectId, hostId: hostId,
        executionHostId: WorkspaceProjectCatalog.sshHostId(json["connectionId"]?.stringValue)
          ?? json["executionHostId"]?.stringValue ?? hostId,
        filesystem: filesystem)
    }
  }

  private var projects: [Repository: Project] = [:]

  public init() {}

  init?(_ json: JSONValue) {
    guard let repos = json["repos"]?.arrayValue, let projects = json["projects"]?.arrayValue,
      let setups = json["setups"]?.arrayValue
    else { return nil }
    let names = Dictionary(projects.compactMap { project -> (String, String)? in
      guard let id = project["id"]?.stringValue, let name = project["displayName"]?.stringValue else { return nil }
      return (id, name)
    }, uniquingKeysWith: { first, _ in first })
    let checkouts = setups.compactMap(Setup.init)
    let pathsBySurface = Dictionary(grouping: checkouts.filter(\.isCheckout), by: \.surface).mapValues { Set($0.map(\.path)) }
    let setupByRepo = Dictionary(checkouts.map { ($0.repository, $0) }, uniquingKeysWith: { first, _ in first })
    for (index, repo) in repos.enumerated() {
      guard let id = repo["id"]?.stringValue, let name = repo["displayName"]?.stringValue else { continue }
      let host = repo["executionHostId"]?.stringValue ?? Self.sshHostId(repo["connectionId"]?.stringValue) ?? "local"
      let key = Repository(hostId: host, repoId: id)
      let hidden = repo["hiddenAt"]?.doubleValue != nil
      if let setup = setupByRepo[key], let projectName = names[setup.surface.projectId],
        !setup.isCheckout || (pathsBySurface[setup.surface]?.count ?? 0) <= 1
      {
        self.projects[key] = Project(id: "project:\(setup.surface.projectId)", name: projectName, order: index, isHidden: hidden)
      } else {
        self.projects[key] = Project(id: key.sectionId, name: name, order: index, isHidden: hidden)
      }
    }
  }

  public func project(hostId: String, repoId: String, fallbackName: String) -> Project {
    let key = Repository(hostId: hostId, repoId: repoId)
    return projects[key] ?? Project(id: key.sectionId, name: fallbackName, order: nil, isHidden: false)
  }

  static func sshHostId(_ connectionId: String?) -> String? {
    guard let connectionId, !connectionId.isEmpty,
      let encoded = connectionId.addingPercentEncoding(withAllowedCharacters: CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"))
    else { return nil }
    return "ssh:\(encoded)"
  }
}

extension HostAPI {
  func workspaceProjects() async throws -> WorkspaceProjectCatalog? {
    let reply = try await connection.request("mobileRelay.projectSections", timeout: .seconds(8))
    return reply["catalog"].flatMap(WorkspaceProjectCatalog.init)
  }
}
