import Foundation
import Testing

@testable import OrcaCore

@Suite struct TaskSourcesTests {
  @Test func hydrationResolvesSourcesAndTheDefaultPreset() {
    let settings: JSONValue = [
      "defaultTaskSource": "linear", "visibleTaskProviders": ["github", "gitlab", "linear", "jira"],
      "defaultTaskViewPreset": "my-prs", "defaultRepoSelection": ["r1"], "defaultLinearTeamSelection": nil,
    ]
    let offline = TaskHydration(settings: settings, ui: nil, glabInstalled: false, linearConnected: false)
    // GitLab needs glab; a chosen Linear stays so it can be connected.
    #expect(offline.availableProviders == [.github, .jira, .linear])
    #expect(offline.initialProvider == .linear)
    #expect(offline.githubPreset == .myPRs)
    #expect(offline.githubQuery == "author:@me is:pr is:open")
    #expect(offline.defaultRepoSelection == ["r1"])
    #expect(offline.defaultLinearTeamSelection == nil)

    let resumed = TaskHydration(
      settings: settings, ui: ["taskResumeState": ["githubItemsPreset": nil, "githubItemsQuery": "is:issue bug", "githubMode": "project"]],
      glabInstalled: true, linearConnected: true)
    #expect(resumed.availableProviders == [.github, .gitlab, .linear, .jira])
    #expect(resumed.githubQuery == "is:issue bug")
    #expect(resumed.githubProjectMode)
    #expect(TaskHydration(settings: nil, ui: nil, glabInstalled: false, linearConnected: false).initialProvider == .github)
  }

  @Test func linearAndJiraAccountsPickTheirScope() {
    let linear = LinearAccount([
      "connected": true, "workspaces": [["id": "w1", "organizationName": "Acme"], ["id": "w2", "displayName": "Side"]],
      "activeWorkspaceId": "w2",
    ])
    #expect(linear.workspaces.map(\.name) == ["Acme", "Side"])
    #expect(linear.selectedWorkspaceId == "w2")

    let jira = JiraAccount([
      "connected": true, "selectedSiteId": "gone", "activeSiteId": "s2",
      "sites": [["id": "s1", "siteUrl": "https://a.atlassian.net/", "displayName": " "], ["id": "s2", "siteUrl": "https://b", "displayName": "B"]],
    ])
    #expect(jira.selection == "s2")
    #expect(jira.sites.first?.label == "a.atlassian.net")
    #expect(JiraAccount(["connected": true, "selectedSiteId": "all", "sites": []]).selection == "all")
    #expect(JiraAccount(["connected": false, "sites": [["id": "s1", "siteUrl": "x"]]]).sites.isEmpty)
  }

  @Test func jiraSearchInputReadsAsJqlKeyOrText() {
    #expect(JiraSearchInput.mayBeJql("project = ABC"))
    #expect(JiraSearchInput.mayBeJql("status in (Done)"))
    #expect(JiraSearchInput.mayBeJql("order by created"))
    #expect(!JiraSearchInput.mayBeJql("login is slow"))
    #expect(!JiraSearchInput.mayBeJql("sign-in broken"))
    #expect(JiraSearchInput.keyJql("abc-12") == "key = \"ABC-12\"")
    #expect(JiraSearchInput.keyJql("abc 12") == nil)
    #expect(JiraSearchInput.textJql("Login (broken)") == "text ~ \"login broken*\"")
    #expect(JiraSearchInput.textJql("c#") == "text ~ \"c#\"")
    #expect(JiraSearchInput.textJql("???") == "")
    let refused = RPCError(code: "x", message: "Error invoking: Error 400: Field 'foo' does not exist", data: nil)
    #expect(JiraSearchInput.badRequestReason(refused) == "Field 'foo' does not exist")
    #expect(JiraSearchInput.badRequestReason(RPCError(code: "x", message: "Error 401: nope", data: nil)) == nil)
  }

  @Test func linearIssuesSortAndGroup() {
    func issue(_ id: String, priority: Int, updated: String, state: String) -> TrackerIssue {
      TrackerIssue(linear: [
        "id": .string(id), "identifier": .string(id), "title": "t", "priority": .number(Double(priority)),
        "updatedAt": .string(updated), "state": ["name": .string(state), "type": "started", "color": "#fff"],
        "team": ["id": "t1", "name": "Eng", "key": "ENG"], "labels": ["bug"], "assignee": ["displayName": "Ann"],
      ])!
    }
    let issues = [
      issue("ENG-10", priority: 0, updated: "2026-01-03T00:00:00Z", state: "Todo"),
      issue("ENG-2", priority: 3, updated: "2026-01-01T00:00:00Z", state: "Done"),
      issue("ENG-3", priority: 1, updated: "2026-01-02T00:00:00Z", state: "Todo"),
    ]
    #expect(TrackerIssue.sorted(issues, by: .priority).map(\.id) == ["ENG-3", "ENG-2", "ENG-10"])
    #expect(TrackerIssue.sorted(issues, by: .updated).map(\.id) == ["ENG-10", "ENG-3", "ENG-2"])
    #expect(TrackerIssue.sorted(issues, by: .identifier).map(\.id) == ["ENG-2", "ENG-3", "ENG-10"])
    let groups = TrackerIssue.grouped(TrackerIssue.sorted(issues, by: .priority), by: .status)
    #expect(groups.map(\.key) == ["status:Todo", "status:Done"])
    #expect(groups.first?.issues.map(\.id) == ["ENG-3", "ENG-10"])
    #expect(issues[0].teamName == "Eng")
    #expect(issues[0].assignee == "Ann")
  }

  @Test func gitHubSourcesAndPaging() {
    let sources = GitHubIssueSources([
      "issues": ["owner": "up", "repo": "orca"], "prs": ["owner": "me", "repo": "orca"],
      "upstreamCandidate": ["owner": "up", "repo": "orca"],
    ])
    #expect(sources?.hasChoice == true)
    #expect(GitHubIssueSources(["prs": ["owner": "me", "repo": "orca"]])?.hasChoice == false)
    #expect(GitHubTaskPaging.perRepoLimit(repoCount: 1) == 36)
    #expect(GitHubTaskPaging.perRepoLimit(repoCount: 4) == 25)
    #expect(GitHubTaskPaging.countedTotalPages([10, 80], perRepoLimit: 25) == 4)
    #expect(GitHubTaskPaging.countedTotalPages([5000], perRepoLimit: 25) == 40)
  }

  @Test func gitLabTodosRead() {
    let todo = GitLabTodo([
      "id": 4, "actionName": "review_requested", "targetType": "MergeRequest", "targetIid": 12,
      "targetUrl": "https://gl/x/-/merge_requests/12", "projectPath": "g/x", "updatedAt": "2026-01-01T00:00:00Z",
    ])
    #expect(todo?.targetRef == "!12")
  }

  @Test func projectReferencesAndSettings() {
    #expect(GitHubProjectRef.parseInput("acme/7")?.number == 7)
    let url = GitHubProjectRef.parseInput("https://github.com/orgs/acme/projects/7/views/3")
    #expect(url?.owner == "acme")
    #expect(url?.viewNumber == 3)
    #expect(url?.host == "github.com")
    #expect(GitHubProjectRef.parseInput("https://github.com/acme/repo/issues/7") == nil)
    let ref = GitHubProjectRef(owner: "Acme", ownerType: "organization", number: 7, host: "github.com")
    #expect(ref.host == nil)
    #expect(ref.key == "organization:acme:7")
    let settings = GitHubProjectSettings(nil).opening(ref, viewId: "v1")
    #expect(settings.activeProject == ref)
    #expect(settings.lastViewByProject[ref.key] == "v1")
    let roundTrip = GitHubProjectSettings(settings.json)
    #expect(roundTrip == settings)
    #expect(settings.json["activeProject"]?["host"] == nil)
  }

  @Test func projectTablesSortAndGroup() throws {
    let table = try #require(
      GitHubProjectTable([
        "project": ["id": "p1", "title": "Roadmap"],
        "selectedView": [
          "id": "v1", "number": 1, "name": "Table", "layout": "TABLE_LAYOUT", "filter": "is:open",
          "fields": [
            ["id": "f-title", "name": "Title", "dataType": "TITLE"],
            [
              "id": "f-status", "name": "Status", "dataType": "SINGLE_SELECT",
              "options": [["id": "o-todo", "name": "Todo"], ["id": "o-done", "name": "Done"]],
            ],
            ["id": "f-size", "name": "Size", "dataType": "NUMBER"],
          ],
          "groupByFields": [["id": "f-status", "name": "Status", "dataType": "SINGLE_SELECT", "options": [["id": "o-todo", "name": "Todo"], ["id": "o-done", "name": "Done"]]]],
        ],
        "rows": [
          ["id": "a", "itemType": "ISSUE", "content": ["title": "A", "number": 1], "fieldValuesByFieldId": ["f-status": ["kind": "single-select", "optionId": "o-done", "name": "Done"], "f-size": ["kind": "number", "number": 3]]],
          ["id": "b", "itemType": "ISSUE", "content": ["title": "B"], "fieldValuesByFieldId": ["f-size": ["kind": "number", "number": 1]]],
          ["id": "c", "itemType": "PULL_REQUEST", "content": ["title": "C"], "fieldValuesByFieldId": ["f-status": ["kind": "single-select", "optionId": "o-todo", "name": "Todo"]]],
        ],
      ]))
    #expect(table.summaryFields.map(\.id) == ["f-status", "f-size"])
    #expect(table.sortedRows().map(\.id) == ["a", "b", "c"])
    #expect(table.sortedRows(by: ("f-size", false)).map(\.id) == ["b", "a", "c"])
    #expect(table.sortedRows(by: ("f-size", true)).map(\.id) == ["a", "b", "c"])
    let groups = table.groups(table.sortedRows())
    #expect(groups.map(\.label) == ["Todo", "Done", "No Status"])
    #expect(table.rows[0].value(for: table.fields[2]) == "3")
  }
}
