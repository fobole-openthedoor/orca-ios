import Testing

@testable import OrcaCore

@Suite struct WorktreeLineageTests {
  @Test func placesChildAndGrandchildBelowTheirParentsRegardlessOfSortOrder() throws {
    let rows = try [
      workspace("grandchild", parent: "relay-admin-pr"),
      workspace("relay-admin-pr", parent: "development-base"),
      workspace("history"),
      workspace("development-base"),
      workspace("sibling", parent: "development-base"),
    ]
    let roots = Worktree.lineage(rows)
    #expect(roots.map(\.entry.id) == ["history", "development-base"])
    #expect(roots.last?.children.map(\.entry.id) == ["relay-admin-pr", "sibling"])
    #expect(roots.last?.children.first?.children.map(\.entry.id) == ["grandchild"])
    #expect(Worktree.lineage([rows[1]]).map(\.entry.id) == ["relay-admin-pr"])
  }

  @Test func verifiesBothInstancesAndKeepsAnExplicitlyPinnedChildVisible() throws {
    let rows = try [
      workspace("parent", fields: ["worktreeInstanceId": "current-parent", "hostId": "local"]),
      workspace("valid", parent: "parent", fields: ["worktreeInstanceId": "valid-instance",
        "lineageWorktreeInstanceId": "valid-instance", "parentWorktreeInstanceId": "current-parent"]),
      workspace("replaced-parent", parent: "parent", fields: ["parentWorktreeInstanceId": "old-parent"]),
      workspace("replaced-child", parent: "parent", fields: ["worktreeInstanceId": "current-child",
        "lineageWorktreeInstanceId": "old-child", "parentWorktreeInstanceId": "current-parent"]),
      workspace("pinned", parent: "parent", fields: ["isPinned": true]),
      workspace("remote", parent: "parent", fields: ["hostId": "runtime:another-host"]),
      workspace("pinned-child", parent: "pinned"),
    ]
    let roots = Worktree.lineage(rows)
    #expect(roots.map(\.entry.id) == ["parent", "replaced-parent", "replaced-child", "pinned", "remote"])
    #expect(roots.first?.children.map(\.entry.id) == ["valid"])
    #expect(roots.first { $0.entry.isPinned }?.children.map(\.entry.id) == ["pinned-child"])
  }

  @Test func keepsOrphansAndCyclesAccessible() throws {
    let rows = try [
      workspace("a", parent: "b"), workspace("b", parent: "a"), workspace("self", parent: "self"),
      workspace("archived", fields: ["isArchived": true]), workspace("orphan", parent: "archived"),
    ]
    let roots = Worktree.lineage(rows)
    #expect(Set(roots.map(\.entry.id)) == ["a", "b", "self", "orphan"])
    #expect(roots.allSatisfy { $0.children.isEmpty })
  }

  private func workspace(_ id: String, parent: String? = nil, fields: [String: JSONValue] = [:]) throws -> Worktree {
    var row = fields
    row["worktreeId"] = .string(id)
    row["repoId"] = "sms"
    if let parent { row["parentWorktreeId"] = .string(parent) }
    return try #require(Worktree(.object(row)))
  }
}
