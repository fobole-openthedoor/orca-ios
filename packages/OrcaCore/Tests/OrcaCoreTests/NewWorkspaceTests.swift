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

  @Test func providerSourcesLinkAsTheDesktopDoes() throws {
    let linear = try #require(
      TrackerIssue(linear: [
        "id": "u1", "identifier": "ENG-4", "title": "Fix login", "url": "https://linear.app/acme/issue/ENG-4/fix-login",
        "workspaceId": "w1",
      ]))
    let linearParams = WorkspaceCreateRequest(
      repoId: "r1", name: "eng-4-fix-login", displayName: "ENG-4 Fix login", nameWasGenerated: true,
      source: .linear(linear), agent: "claude"
    ).params
    #expect(linearParams["linkedLinearIssue"] == "ENG-4")
    #expect(linearParams["linkedLinearIssueWorkspaceId"] == "w1")
    #expect(linearParams["linkedLinearIssueOrganizationUrlKey"] == "acme")
    #expect(linearParams["startupDraft"] == "https://linear.app/acme/issue/ENG-4/fix-login")
    #expect(linearParams["setupDecision"] == "inherit")

    let jira = try #require(TrackerIssue(jira: ["key": "ABC-2", "title": "B", "url": "https://x.atlassian.net/browse/ABC-2"]))
    let jiraParams = WorkspaceCreateRequest(
      repoId: "r1", name: "abc-2-b", displayName: nil, nameWasGenerated: true, source: .jira(jira)
    ).params
    #expect(jiraParams["linkedWorkItem"]?["provider"] == "jira")
    #expect(jiraParams["linkedWorkItem"]?["jiraIdentifier"] == "ABC-2")
    #expect(jiraParams["startupDraft"] == nil)

    let repo = try #require(TaskRepo(["id": "r1", "displayName": "orca"]))
    let mr = try #require(GitHubWorkItem(["number": 7, "title": "MR", "type": "pr", "url": "u"], repo: repo))
    let base = try #require(
      WorkspaceCreateRequest.HostedBase([
        "baseBranch": "abc123", "compareBaseRef": "origin/main", "branchNameOverride": "feature",
        "pushTarget": ["remoteName": "origin", "branchName": "feature"],
      ]))
    let gitlab = WorkspaceCreateRequest(
      repoId: "r1", name: "mr", displayName: nil, nameWasGenerated: true, source: .gitlab(mr), setupDecision: "run",
      approvedSetupHash: "h", base: base
    ).params
    #expect(gitlab["linkedGitLabMR"] == 7)
    #expect(gitlab["baseBranch"] == "abc123")
    #expect(gitlab["compareBaseRef"] == "origin/main")
    #expect(gitlab["branchNameOverride"] == "feature")
    #expect(gitlab["pushTarget"]?["remoteName"] == "origin")
    #expect(gitlab["setupDecision"] == "run")
    #expect(gitlab["approvedSetupHash"] == "h")
  }

  @Test func retriesSuffixTheNameAndNewBranch() {
    let request = WorkspaceCreateRequest(
      repoId: "r1", name: "feature/x", displayName: "feature/x", nameWasGenerated: false, source: .newBranch)
    #expect(request.params(attempt: 0)["branchNameOverride"] == "feature/x")
    #expect(request.params(attempt: 2)["name"] == "feature/x-3")
    #expect(request.params(attempt: 2)["branchNameOverride"] == "feature/x-3")
    #expect(WorkspaceCreateRetry.candidate("nautilus", attempt: 1, generated: true) == "nautilus-2")
    #expect(WorkspaceCreateRetry.candidate("nautilus-3", attempt: 1, generated: true) == "nautilus-4")
    #expect(WorkspaceCreateRetry.candidate("fix-3", attempt: 1, generated: false) == "fix-3-2")
    #expect(WorkspaceCreateRetry.isRetryableConflict("Branch \"x\" already exists. Pick another"))
    #expect(WorkspaceCreateRetry.isRetryableConflict("Worktree folder already exists locally"))
    #expect(!WorkspaceCreateRetry.isRetryableConflict("Permission denied"))
  }

  @Test func pastedLinksAreRecognised() {
    #expect(
      WorkspaceSourceLink.parse(" https://github.com/acme/orca/pull/12/files ")
        == .github(owner: "acme", repo: "orca", host: "github.com", number: 12, isPR: true))
    #expect(
      WorkspaceSourceLink.parse("https://ghe.corp:8443/a/b/issues/3")
        == .github(owner: "a", repo: "b", host: "ghe.corp:8443", number: 3, isPR: false))
    #expect(WorkspaceSourceLink.parse("#42") == .githubNumber(42))
    #expect(WorkspaceSourceLink.parse("0") == nil)
    #expect(WorkspaceSourceLink.parse("fix login") == nil)
    #expect(
      WorkspaceSourceLink.parse("https://gitlab.example.com/group/sub/proj/-/merge_requests/9")
        == .gitlab(host: "gitlab.example.com", path: "group/sub/proj", iid: 9, isMR: true))
    let jira = WorkspaceSourceLink.Jira("https://acme.atlassian.net/browse/abc-12")
    #expect(jira?.issueKey == "ABC-12")
    #expect(jira?.matches(siteUrl: "https://ACME.atlassian.net/") == true)
    #expect(jira?.matches(siteUrl: "https://other.atlassian.net") == false)
    #expect(WorkspaceSourceLink.Jira("https://acme.atlassian.net/browse/nope") == nil)
  }

  @Test func sourcesNameTheirWorkspace() {
    #expect(WorkspaceSourceName.hosted(title: "Issue #12: Fix the login (#3)", number: 12, kind: "issue").seed == "fix-the-login")
    #expect(WorkspaceSourceName.hosted(title: "!!!", number: 5, kind: "pr").seed == "pr-5")
    let linear = WorkspaceSourceName.identified(identifier: "ENG-4", title: "ENG-4: Fix login")
    #expect(linear.display == "ENG-4 Fix login")
    #expect(linear.seed == "eng-4-fix-login")
  }

  @Test func setupHooksAndTrust() {
    let hooks = RepoSetupHooks([
      "setupConfig": ["command": " pnpm i "], "source": "orca.yaml", "setupRunPolicy": "ask",
      "setupTrust": ["contentHash": "abc", "scriptContent": "pnpm i"],
    ])
    #expect(hooks.command == "pnpm i")
    #expect(hooks.runPolicy == "ask")
    #expect(hooks.trust?.contentHash == "abc")
    #expect(hooks.readsSetupConfig)
    let legacy = RepoSetupHooks(["hooks": ["scripts": ["setup": "make"]], "source": .null, "setupRunPolicy": "weird"])
    #expect(legacy.command == "make")
    #expect(legacy.runPolicy == "run-by-default")
    #expect(!legacy.readsSetupConfig)

    #expect(OrcaHookTrust.emptyContentHash == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    var trust = OrcaHookTrust(["r1": ["archive": ["contentHash": "x", "approvedAt": 1]]])
    #expect(trust.isRepoTrusted(repoId: "r1", hostsWithRepo: 1))
    #expect(!trust.isRepoTrusted(repoId: "r1", hostsWithRepo: 2))
    #expect(!trust.isApproved(repoId: "r1", contentHash: "a"))
    trust = trust.confirming(repoId: "r1", contentHash: "a").confirming(repoId: "r1", contentHash: "b")
    #expect(trust.approvedHashes(repoId: "r1", kind: "setup") == ["b", "a"])
    #expect(trust.entries["r1"]?["archive"]?["contentHash"] == "x")
    #expect(trust.wasPreviouslyApproved(repoId: "r1"))
    trust = trust.alwaysTrusting(repoId: "r2")
    #expect(trust.isRepoTrusted(repoId: "r2", hostsWithRepo: 1))
  }
}
