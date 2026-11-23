import Foundation
import Testing

@testable import OrcaCore

@Suite struct AutomationPageTests {
  @Test func readsListRowsWithTheirTargetAndOwner() throws {
    let reply: JSONValue = [
      "automations": [
        [
          "id": "a1", "name": "Nightly", "prompt": "p", "agentId": "claude", "enabled": true, "rrule": "0 9 * * 1-5",
          "timezone": "Asia/Shanghai", "projectId": "r1", "workspaceMode": "existing", "workspaceId": "w1",
          "nextRunAt": 1_700_000_000_000,
          "runContext": [
            "kind": "workspace-run", "projectId": "p1", "hostId": "ssh:box", "projectHostSetupId": "s1", "repoId": "r1",
            "path": "/srv/app",
          ],
        ],
        ["id": "a2", "name": "Twice"],
        ["id": "a3", "name": "Orphan"],
      ],
      "items": [
        [
          "automationId": "a1", "selector": ["kind": "ssh", "targetId": "box", "targetGeneration": 2],
          "usageSummary": ["lastRunStatus": "completed", "lastRunAt": 5],
        ],
        ["automationId": "a2", "selector": ["kind": "self"]],
        ["automationId": "a2", "selector": ["kind": "self"]],
        ["automationId": "a3", "selector": ["kind": "orphan", "issue": "Its stored host record is incomplete."]],
      ],
    ]
    let rows = HostAPI.automations(reply)
    // A row with two owners is left out.
    #expect(rows.map(\.id) == ["a1", "a3"])
    let first = try #require(rows.first)
    #expect(first.timezone == "Asia/Shanghai")
    #expect(first.workspaceMode == "existing")
    #expect(first.runContext?.path == "/srv/app")
    #expect(first.runContext?.hostId == "ssh:box")
    #expect(first.sshTargetId == "box")
    #expect(first.lastRunStatus == "completed")
    #expect(first.orphanIssue == nil)
    #expect(rows[1].orphanIssue == "Its stored host record is incomplete.")
    #expect(rows[1].expectedOwner == ["selector": ["kind": "orphan"]])
  }

  @Test func readsARunAndWhatItLeftToRead() throws {
    let json: JSONValue = [
      "id": "run1", "automationId": "a1", "title": "Nightly", "status": "dispatch_failed", "trigger": "event",
      "scheduledFor": 10, "createdAt": 10, "startedAt": .null, "dispatchedAt": .null, "workspaceId": .null,
      "terminalPaneKey": .null, "terminalPtyId": .null, "error": "Needs migration", "errorCode": "managedHostServer",
      "errorParams": ["host": "box", "count": 3], "outputSnapshot": .null,
      "precheckResult": ["stdout": "ok\n", "stderr": "", "command": "true"], "usage": .null,
      "event": ["source": "slack"], "triggeredBy": ["source": "github"],
      "runContext": ["hostId": "local", "repoId": "r1", "path": "/p"],
    ]
    let run = try #require(AutomationRun(json))
    #expect(run.errorParams == ["host": "box", "count": "3"])
    // triggeredBy names the source over an older record's latest event.
    #expect(run.eventSource == "github")
    #expect(run.runContextPath == "/p")
    #expect(run.content(error: run.error, noOutput: "none") == "ok")

    var withOutput = run
    withOutput.output = .init(content: "done", capturedAt: 1, truncated: true)
    #expect(withOutput.content(error: nil, noOutput: "none") == "done")
    withOutput.output = .init(content: "  ", capturedAt: 1, truncated: false)
    withOutput.precheck = nil
    #expect(withOutput.content(error: nil, noOutput: "none") == "none")

    let page = AutomationRunsPage(["runs": [json, ["id": "bad"]], "nextCursor": "c2"])
    #expect(page.runs.map(\.id) == ["run1"])
    #expect(page.nextCursor == "c2")
  }

  @Test func readsAccountsWithInactiveUsageTargetsAndOtherAgents() {
    let window: JSONValue = ["usedPercent": 41, "windowMinutes": 300, "resetsAt": 100, "resetDescription": .null]
    let snapshot = AccountsSnapshot([
      "claude": ["accounts": [["id": "c1", "email": "a@b.c", "displayName": " Work "]], "activeAccountId": .null],
      "codex": [
        "accounts": [["id": "x1", "email": "x@y.z", "workspaceLabel": "Team", "updatedAt": 1]],
        "activeAccountId": "x1",
        "activeAccountIdsByRuntime": ["host": .null, "wsl": ["Ubuntu": "x1"]],
      ],
      "rateLimits": [
        "claude": ["provider": "claude", "session": window, "weekly": .null, "updatedAt": 1, "error": .null, "status": "ok"],
        "codex": .null,
        "codexTarget": ["runtime": "wsl", "wslDistro": "Ubuntu"],
        "inactiveClaudeAccounts": [
          [
            "accountId": "c1", "isFetching": true, "updatedAt": 1,
            "rateLimits": ["provider": "claude", "session": .null, "weekly": window, "updatedAt": 1, "error": .null, "status": "ok"],
          ]
        ],
        "inactiveCodexAccounts": [],
        "gemini": ["provider": "gemini", "session": .null, "weekly": .null, "updatedAt": 1, "error": .null, "status": "idle"],
        "antigravity": [
          "provider": "antigravity", "session": .null, "weekly": .null, "updatedAt": 1, "error": .null, "status": "ok",
          "buckets": [["name": "Pro", "usedPercent": 10, "windowMinutes": 0, "resetsAt": .null, "resetDescription": .null]],
        ],
      ],
    ])
    #expect(snapshot.claude.accounts.first?.primaryLabel == "Work")
    #expect(snapshot.claude.selectedAccountId == nil)
    #expect(snapshot.claude.usage?.session?.usedPercent == 41)
    #expect(snapshot.claude.inactiveUsage("c1")?.isFetching == true)
    #expect(snapshot.claude.inactiveUsage("c1")?.usage?.weekly?.windowMinutes == 300)
    // Codex's selection follows the WSL distro its limits are read for.
    #expect(snapshot.codex.target.runtime == "wsl")
    #expect(snapshot.codex.selectedAccountId == "x1")
    #expect(snapshot.codex.accounts.first?.workspaceLabel == "Team")
    // A provider with nothing to draw is left out.
    #expect(snapshot.others.map(\.provider) == ["antigravity"])
    #expect(snapshot.others.first?.buckets.first?.name == "Pro")
  }
}
