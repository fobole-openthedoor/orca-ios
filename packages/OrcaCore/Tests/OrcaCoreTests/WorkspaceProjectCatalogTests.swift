import Testing

@testable import OrcaCore

@Suite struct WorkspaceProjectCatalogTests {
  @Test func usesDesktopProjectMembershipAcrossHostsAndKeepsOtherCheckoutsDistinct() throws {
    let catalog = try #require(WorkspaceProjectCatalog([
      "repos": [
        repo("desktop", host: "local"), repo("server", host: "runtime:build"),
        repo("other-a", host: "runtime:other"), repo("other-b", host: "runtime:other"),
        repo("unrelated", host: "runtime:other"),
      ],
      "projects": [["id": "shared", "displayName": "Shared Project"]],
      "setups": [
        setup("desktop", host: "local", path: "/source/code"), setup("server", host: "runtime:build", path: "/source/code"),
        setup("other-a", host: "runtime:other", path: "/source/code"), setup("other-b", host: "runtime:other", path: "/source/copy"),
      ],
    ]))
    let local = catalog.project(hostId: "local", repoId: "desktop", fallbackName: "Code")
    let remote = catalog.project(hostId: "runtime:build", repoId: "server", fallbackName: "Code")
    #expect(local.id == remote.id)
    #expect(remote.name == "Shared Project")
    #expect(local.order == 0)
    #expect(remote.order == 1)
    let distinct = ["other-a", "other-b", "unrelated"].map {
      catalog.project(hostId: "runtime:other", repoId: $0, fallbackName: "Code").id
    }
    #expect(Set(distinct + [local.id]).count == 4)
  }

  @Test func fallbackDoesNotMergeIdenticalRepoIDsOnDifferentHosts() {
    let catalog = WorkspaceProjectCatalog()
    let local = catalog.project(hostId: "local", repoId: "repo", fallbackName: "Code")
    let remote = catalog.project(hostId: "runtime:build", repoId: "repo", fallbackName: "Code")
    #expect(local.id != remote.id)
    #expect(local.name == remote.name)
  }

  private func repo(_ id: String, host: String) -> JSONValue {
    ["id": .string(id), "executionHostId": .string(host), "displayName": "Code"]
  }

  private func setup(_ id: String, host: String, path: String) -> JSONValue {
    ["repoId": .string(id), "hostId": .string(host), "projectId": "shared", "path": .string(path)]
  }
}
