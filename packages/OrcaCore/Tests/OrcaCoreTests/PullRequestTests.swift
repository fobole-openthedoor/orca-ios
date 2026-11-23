import Foundation
import Testing

@testable import OrcaCore

@Suite struct PullRequestTests {
  private func pr(_ fields: [String: JSONValue] = [:]) throws -> PullRequestInfo {
    var json: [String: JSONValue] = ["number": 7, "state": "open", "title": "Add it", "url": "https://github.com/o/r/pull/7"]
    json.merge(fields) { $1 }
    return try #require(PullRequestInfo(.object(json)))
  }

  @Test func lookupReadsEveryOutcome() throws {
    guard case .found(let found) = try PullRequestLookup(["kind": "found", "pr": ["number": 3, "state": "draft"]]) else {
      Issue.record("expected found")
      return
    }
    #expect(found.number == 3)
    #expect(found.mergeable == "UNKNOWN")
    #expect(try PullRequestLookup(.null) == .none(retryAfter: nil))
    #expect(try PullRequestLookup(["kind": "no-pr", "revalidation": ["retryAfterMs": 2000]]) == .none(retryAfter: 2))
    #expect(try PullRequestLookup(["kind": "upstream-error", "message": "rate limited"]) == .upstreamError("rate limited"))
    #expect(try PullRequestLookup(["revalidation": ["invalidated": true, "retryAfterMs": 500]]) == .revalidating(retryAfter: 0.5))
    // Older hosts answer with the bare PR.
    guard case .found(let bare) = try PullRequestLookup(["number": 9, "state": "merged"]) else {
      Issue.record("expected bare PR")
      return
    }
    #expect(bare.state == "merged")
    #expect(throws: PullRequestReplyError.self) { try PullRequestLookup(["kind": "found", "pr": ["state": "open"]]) }
  }

  @Test func prKeepsForkIdentityAndMergeSettings() throws {
    let info = try pr([
      "prRepo": ["owner": "fork", "repo": "orca", "host": "ghe.example.com"],
      "mergeMethodSettings": ["defaultMethod": "rebase", "allowedMethods": ["merge": true, "squash": false, "rebase": false]],
      "conflictSummary": ["baseRef": "main", "files": ["a.swift", ["path": "b.swift"]]],
    ])
    #expect(info.prRepo?.json == ["owner": "fork", "repo": "orca", "host": "ghe.example.com"])
    // A disallowed default falls to the first allowed method.
    #expect(info.mergeMethods.defaultMethod == "merge")
    #expect(info.mergeMethods.methods == ["merge"])
    #expect(info.baseRefName == "main")
    #expect(info.conflictFiles == ["a.swift", "b.swift"])
    #expect(try pr().mergeMethods.methods == ["squash", "merge", "rebase"])
  }

  @Test func checksClassifyAndSummarize() {
    let checks = [
      PullRequestCheck(name: "build", status: "completed", conclusion: "failure"),
      PullRequestCheck(name: "lint", status: "completed", conclusion: "cancelled"),
      PullRequestCheck(name: "e2e", status: "in_progress", conclusion: nil),
      PullRequestCheck(name: "approve", status: "completed", conclusion: "action_required"),
      PullRequestCheck(name: "unit", status: "completed", conclusion: "success"),
      PullRequestCheck(name: "docs", status: "completed", conclusion: "skipped"),
      PullRequestCheck(name: "info", status: "completed", conclusion: "neutral"),
    ]
    #expect(checks.map(\.outcome) == [.failed, .failed, .pending, .pending, .passed, .passed, .neutral])
    let summary = PullRequestCheck.summarize(checks)
    #expect(summary.state == "failure")
    #expect(summary.failed == 2)
    #expect(summary.cancelled == 1)
    #expect(summary.pending == 2)
    #expect(summary.passed == 2)
    #expect(checks.filter(\.isBroken).map(\.name) == ["build", "lint"])
    #expect(PullRequestCheck.sortedBySeverity(checks).map(\.name).prefix(3) == ["build", "approve", "lint"])
    let onlyCancelled = PullRequestCheck.summarize([PullRequestCheck(name: "a", status: "completed", conclusion: "cancelled")])
    #expect(onlyCancelled.outcome == "cancelled")
  }

  @Test func detailsReadReviewersCommentsAndFiles() throws {
    let details = try #require(
      PullRequestDetails([
        "item": [
          "number": 7, "title": "Add it", "author": "ann", "baseRefName": "main",
          "reviewRequests": [["login": "bob", "name": "Bob"]],
          "latestReviews": [["author": ["login": "cy"], "state": "APPROVED"], ["login": "Bob", "state": "COMMENTED"]],
        ],
        "body": "Body",
        "comments": [
          ["id": 1, "author": "ann", "body": "hi"],
          ["id": 2, "author": "coderabbitai[bot]", "body": "nit", "threadId": "T1", "path": "a.swift", "isResolved": false],
          ["id": 3, "author": "ann", "body": "fixed", "threadId": "T1"],
          ["id": 4, "author": "dee", "body": "ok", "threadId": "T2", "isResolved": true],
          ["author": "no id"],
        ],
        "files": [["path": "a.swift", "additions": 3, "deletions": 1, "viewerViewedState": "VIEWED"], ["path": ""]],
      ]))
    #expect(details.reviewerLogins == ["bob", "cy"])
    #expect(details.latestReviews.first?.state == "APPROVED")
    #expect(details.comments.count == 4)
    #expect(details.files?.count == 1)
    #expect(details.files?.first?.viewed == true)
    let groups = PullRequestCommentGroup.group(details.comments)
    #expect(groups.map(\.id) == ["comment:1", "thread:T1", "thread:T2"])
    guard case .thread(_, let root, let replies) = groups[1] else {
      Issue.record("expected a thread")
      return
    }
    #expect(root.isBotAuthored)
    #expect(replies.map(\.id) == [3])
    #expect(groups.filter(\.isUnresolvedThread).count == 1)
    #expect(PullRequestDetails(["item": ["number": 1], "files": [], "filesUnavailable": true])?.files == nil)
  }

  @Test func mergeStateFollowsDesktop() throws {
    #expect(PullRequestMergeState(try pr(["mergeable": "MERGEABLE", "checksStatus": "success"])).kind == "mergeable_checks_passed")
    #expect(PullRequestMergeState(try pr(["mergeable": "MERGEABLE"])).directMergeAvailable)
    #expect(PullRequestMergeState(try pr(["mergeStateStatus": "DIRTY"])).kind == "conflicts")
    #expect(PullRequestMergeState(try pr(["mergeStateStatus": "DIRTY"])).autoMergeAction == nil)
    let blocked = PullRequestMergeState(try pr(["reviewDecision": "REVIEW_REQUIRED", "mergeStateStatus": "BLOCKED"]))
    #expect(blocked.kind == "review_required")
    #expect(!blocked.directMergeAvailable)
    #expect(blocked.autoMergeAction == "enable_auto_merge")
    #expect(PullRequestMergeState(try pr(["state": "draft"])).autoMergeAction == nil)
    #expect(PullRequestMergeState(try pr(["autoMergeEnabled": true])).autoMergeAction == "disable_auto_merge")
  }

  @Test func nextStepOrdersLocalThenReview() throws {
    let resolve = { (local: SourceControlNextStep.Local, review: SourceControlNextStep.Review) in
      SourceControlNextStep.resolve(
        local: local, conflictOperation: nil, hasUnresolvedConflicts: false, hasChangesToCommit: local == .commit,
        creation: .pushAndCreate, review: review)
    }
    #expect(
      SourceControlNextStep.resolve(
        local: .commit, conflictOperation: "rebase", hasUnresolvedConflicts: true, hasChangesToCommit: true,
        creation: .create, review: .none) == .resolveConflicts(review: false))
    #expect(resolve(.commit, .none) == .commit)
    #expect(resolve(.remote(pushOrPublish: true, ready: true), .none) == .createReview(pushFirst: true))
    #expect(resolve(.remote(pushOrPublish: false, ready: true), .none) == .remote)
    #expect(resolve(.idle, .loading) == .none)
    #expect(resolve(.idle, .none) == .createReview(pushFirst: true))
    let failing = try pr(["mergeable": "MERGEABLE"])
    #expect(resolve(.idle, .github(failing, failedChecks: 2, pendingChecks: 0)) == .fixChecks(failed: 2))
    #expect(resolve(.idle, .github(failing, failedChecks: 0, pendingChecks: 0)) == .merge)
    let conflicted = try pr(["mergeable": "CONFLICTING"])
    #expect(resolve(.idle, .github(conflicted, failedChecks: 1, pendingChecks: 0)) == .resolveConflicts(review: true))
    let waiting = try pr(["reviewDecision": "REVIEW_REQUIRED", "mergeStateStatus": "BLOCKED"])
    #expect(
      resolve(.idle, .github(waiting, failedChecks: 0, pendingChecks: 1))
        == .mergeWhenReady(mergeState: "review_required", pendingChecks: 1))
    #expect(resolve(.idle, .github(try pr(["state": "merged"]), failedChecks: 0, pendingChecks: 0)) == .merged)
    #expect(resolve(.idle, .github(try pr(["autoMergeEnabled": true]), failedChecks: 0, pendingChecks: 0)) == .autoMergeOn)
  }

  @Test func historyPagesAndCommitBodies() throws {
    let page = GitHistoryPage([
      "items": [
        [
          "id": "abcdef1234", "parentIds": ["p1"], "subject": "Fix", "author": "ann", "timestamp": 1000,
          "message": "Fix\n\nWhy it broke.\nCo-authored-by: Claude <noreply@anthropic.com>",
          "statistics": ["files": 1, "insertions": 4, "deletions": 2], "pushed": false,
        ],
        ["id": "no parents"],
      ],
      "hasMore": true, "skip": 0,
      "branch": ["baseRef": ["name": "origin/main", "category": "remote branches"], "ahead": 3, "behind": 2, "unpushed": 1],
    ])
    #expect(page.items.count == 1)
    let item = try #require(page.items.first)
    #expect(item.shortId == "abcdef1")
    #expect(item.insertions == 4)
    #expect(item.pushed == false)
    #expect(item.bodyAndCoAuthors.body == "Why it broke.")
    #expect(item.bodyAndCoAuthors.coAuthors == ["Claude"])
    #expect(page.canPage)
    #expect(page.branch?.canUpdateFromBase == true)
    #expect(page.branch?.unpushed == 1)
    // An older host that ignores skip can't page.
    #expect(!GitHistoryPage(["items": [], "hasMore": true]).canPage)
  }

  @Test func eligibilityAndPrompts() throws {
    let eligibility = try #require(
      HostedReviewEligibility(["provider": "github", "canCreate": false, "blockedReason": "needs_push", "defaultBaseRef": ""]))
    #expect(eligibility.needsPush)
    #expect(eligibility.defaultBaseRef == nil)
    #expect(HostAPI.repoSelector(worktreeId: "repo1::/Users/me/wt") == "id:repo1")

    let conflicts = SourceControlPrompts.resolveConflicts(
      operation: "rebase", entries: [("src/a.swift", "both_modified")], worktreePath: "/w")
    #expect(conflicts.hasPrefix("Resolve the current rebase conflicts"))
    #expect(conflicts.contains("- \"src/a.swift\" (Both modified)"))
    #expect(conflicts.contains("- Skip command: git rebase --skip"))
    #expect(
      SourceControlPrompts.resolveConflicts(operation: "merge", entries: [], worktreePath: nil)
        .hasPrefix("Finish the paused merge in this worktree."))
    let review = SourceControlPrompts.resolvePullRequestConflicts(baseRef: "main", files: [], worktreePath: "/w")
    #expect(review.contains("usually with git fetch origin main."))
    let fix = SourceControlPrompts.fixChecks(
      number: 7, title: "Add it", url: "u",
      checks: [PullRequestCheck(name: "build", status: "completed", conclusion: "failure")], logTails: ["build": "boom"])
    #expect(fix.hasPrefix("Investigate the broken checks for PR #7"))
    #expect(fix.contains("\"logTail\" : \"boom\""))
  }
}
