import Foundation
import Testing

@testable import OrcaCore

@Suite struct NewWorkspaceTests {
  @Test func blankCreateMarksAGeneratedName() {
    let request = WorkspaceCreateRequest(
      repoId: "r1", name: "nautilus", displayName: nil, nameWasGenerated: true, agent: "claude", note: " ")
    let params = request.params
    #expect(params["repo"] == "id:r1")
    #expect(params["name"] == "nautilus")
    #expect(params["displayNameKind"] == "generated")
    #expect(params["nameWasGenerated"] == true)
    #expect(params["displayName"] == nil)
    #expect(params["startupAgent"] == "claude")
    #expect(params["createdWithAgent"] == "claude")
    #expect(params["comment"] == " ")
  }

  @Test func sourcesLinkTheItemOrBranch() throws {
    let repo = try #require(TaskRepo(["id": "r1", "displayName": "orca"]))
    let item = try #require(
      GitHubWorkItem(["number": 12, "title": "Fix it", "type": "pr", "url": "https://x/pull/12"], repo: repo))
    let linked = WorkspaceCreateRequest(
      repoId: "r1", name: "fix-it", displayName: "Fix it", nameWasGenerated: true, source: .workItem(item),
      agent: "codex"
    ).params
    #expect(linked["linkedPR"] == 12)
    #expect(linked["linkedIssue"] == nil)
    #expect(linked["nameWasGenerated"] == nil)
    #expect(linked["startupDraft"] == "https://x/pull/12")

    let branch = WorkspaceCreateRequest(
      repoId: "r1", name: "feature", displayName: "feature", nameWasGenerated: false,
      source: .branch(refName: "refs/remotes/origin/feature"), branchName: "mine"
    ).params
    #expect(branch["baseBranch"] == "refs/remotes/origin/feature")
    #expect(branch["branchNameOverride"] == "mine")
    #expect(branch["displayNameKind"] == "user")
    #expect(branch["startupAgent"] == nil)
  }

  @Test func reposKnowTheirProjectAndKind() throws {
    let twin = try #require(
      Repo(["id": "r2", "displayName": "orca", "connectionId": "box", "gitRemoteIdentity": ["canonicalKey": "github.com/a/orca"]]))
    #expect(twin.projectKey == "remote:github.com/a/orca")
    #expect(!twin.isFolder)
    let folder = try #require(Repo(["id": "f1", "displayName": "notes", "kind": "folder"]))
    #expect(folder.projectKey == "repo:f1")
    #expect(folder.isFolder)
    #expect(BranchRef(refName: "refs/heads/main", localBranchName: "main").label == "main")
  }

  @Test func trackerRowsReadEveryListShape() {
    let linear: JSONValue = ["items": [["id": "1", "identifier": "ENG-1", "title": "A", "state": ["name": "Todo"], "team": ["key": "ENG"]]]]
    let rows = TrackerIssue.rows(linear).compactMap(TrackerIssue.init(linear:))
    #expect(rows.map(\.identifier) == ["ENG-1"])
    #expect(rows.first?.state == "Todo")
    let jira: JSONValue = [["key": "ABC-2", "title": "B", "status": ["name": "Open"], "project": ["key": "ABC"]]]
    #expect(TrackerIssue.rows(jira).compactMap(TrackerIssue.init(jira:)).map(\.group) == ["ABC"])
  }
}
