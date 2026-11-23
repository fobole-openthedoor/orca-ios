import OrcaCore
import UIKit

/// The words an automation page shows for runs, dates and owners (automation-run-presentation.ts,
/// automation-orphan-issue-copy.ts, automation-run-row-words.ts).
enum AutomationPresentation {
  static func status(_ status: String) -> String {
    switch status {
    case "pending": String(localized: "automations.mobile.pending", defaultValue: "Pending")
    case "dispatching": String(localized: "automations.mobile.starting", defaultValue: "Starting")
    case "dispatched": String(localized: "automations.mobile.dispatched", defaultValue: "Dispatched")
    case "completed": String(localized: "automations.mobile.completed", defaultValue: "Completed")
    case "skipped_precheck": String(localized: "automations.mobile.skippedPrecheck", defaultValue: "Skipped · precheck")
    case "skipped_missed":
      String(localized: "automations.mobile.skippedMissedSchedule", defaultValue: "Skipped · missed schedule")
    case "skipped_unavailable":
      String(localized: "automations.mobile.skippedHostUnavailable", defaultValue: "Skipped · host unavailable")
    case "skipped_needs_interactive_auth":
      String(localized: "automations.mobile.skippedSignInNeeded", defaultValue: "Skipped · sign-in needed")
    case "dispatch_failed": String(localized: "automations.mobile.couldNotStart", defaultValue: "Could not start")
    default: String(localized: "automations.mobile.unknownResult", defaultValue: "Unknown result")
    }
  }

  /// Medium date, short time, in the automation's own zone when it names one.
  static func date(_ milliseconds: Double?, timezone: String? = nil) -> String {
    guard let milliseconds else { return String(localized: "automations.mobile.notReported", defaultValue: "Not reported") }
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    if let timezone, let zone = TimeZone(identifier: timezone) { formatter.timeZone = zone }
    return formatter.string(from: Date(timeIntervalSince1970: milliseconds / 1000))
  }

  /// "Daily at 9:00 AM · Asia/Shanghai".
  static func schedule(_ automation: Automation) -> String {
    "\(AutomationEditorViewController.scheduleLabel(automation.rrule)) · \(automation.timezone)"
  }

  /// "Next: <date>", or that a paused one has none (automation-next-run-label.ts).
  static func nextRun(_ automation: Automation) -> String {
    automation.enabled
      ? String(
        format: String(localized: "automations.mobile.nextDate", defaultValue: "Next: %1$@"),
        date(automation.nextRunAt, timezone: automation.timezone))
      : String(localized: "automations.mobile.noNextScheduledRun", defaultValue: "No next scheduled run")
  }

  /// What fired a run: Run now, the event's source (in English, as the official row words), or `scheduled`.
  static func trigger(_ run: AutomationRun, scheduled: String) -> String {
    switch run.trigger {
    case "manual": String(localized: "automations.mobile.runNow", defaultValue: "Run now")
    case "event":
      switch run.eventSource {
      case "github": "GitHub"
      case "slack": "Slack"
      case "linear": "Linear"
      case "webhook": "Webhook"
      case "gmail": "Gmail"
      case "calendar": "Calendar"
      default: "Event"
      }
    default: scheduled
    }
  }

  /// A run matches the Runs page's Outcome choice.
  static func matches(_ run: AutomationRun, outcome: String) -> Bool {
    switch outcome {
    case "all": true
    case "skipped": run.status.hasPrefix("skipped_")
    case "active": ["pending", "dispatching", "dispatched"].contains(run.status)
    default: run.status == outcome
    }
  }

  /// Why the owner can't run it, in this language when the host's English is one the official app translates.
  static func orphanIssue(_ issue: String) -> String {
    switch issue {
    case "Its SSH host is no longer registered.":
      String(localized: "automations.orphanIssues.targetMissing", defaultValue: "Its SSH host is no longer registered.")
    case "Its SSH host was removed and re-added, so it must be re-adopted.":
      String(
        localized: "automations.orphanIssues.targetReplaced",
        defaultValue: "Its SSH host was removed and re-added, so it must be re-adopted.")
    case "It is stored here but scheduled against a remote runtime.":
      String(
        localized: "automations.orphanIssues.scheduledElsewhere",
        defaultValue: "It is stored here but scheduled against a remote runtime.")
    case "Its project no longer exists, so its host cannot be resolved.":
      String(
        localized: "automations.orphanIssues.projectMissing",
        defaultValue: "Its project no longer exists, so its host cannot be resolved.")
    case "Its project could not be checked from here, so its host is unconfirmed.":
      String(
        localized: "automations.orphanIssues.projectUnverified",
        defaultValue: "Its project could not be checked from here, so its host is unconfirmed.")
    case "Its workspace spans more than one host, so it has no single owner.":
      String(
        localized: "automations.orphanIssues.workspaceHostAmbiguous",
        defaultValue: "Its workspace spans more than one host, so it has no single owner.")
    case "Its stored host record is incomplete.":
      String(localized: "automations.orphanIssues.malformed", defaultValue: "Its stored host record is incomplete.")
    case "Edit this automation and reselect its host before running it.":
      String(
        localized: "automations.orphanIssues.hostReselection",
        defaultValue: "Edit this automation and reselect its host before running it.")
    default: issue
    }
  }

  /// A failed run's reason by its code; an unknown code, or params it can't use, keeps the host's English.
  static func runError(_ run: AutomationRun) -> String? {
    guard let error = run.error, let code = run.errorCode else { return run.error }
    let params = run.errorParams
    switch code {
    case "noDispatchHost":
      return String(
        localized: "automations.runFailures.noDispatchHost", defaultValue: "No Orca window was available to launch the automation.")
    case "unevaluableSchedule":
      return String(
        localized: "automations.runFailures.unevaluableSchedule",
        defaultValue: "Orca could not evaluate this automation and skipped the occurrence.")
    case "noRunnableHost":
      return String(localized: "automations.runFailures.noRunnableHost", defaultValue: "This automation has no host to run on.")
    case "wslMoveInProgress":
      return String(
        localized: "automations.runFailures.wslMoveInProgress",
        defaultValue:
          "This automation's project is moving to its WSL host, so Orca skipped this run. Runs resume when the move finishes.")
    case "wslMoveOwnedByHost":
      return String(
        localized: "automations.runFailures.wslMoveOwnedByHost",
        defaultValue:
          "This automation's project now runs on its WSL host, which runs this automation there. Orca no longer runs this local copy."
      )
    case "managedHostServer":
      guard let host = params["host"] else { return error }
      return String(
        format: String(localized: "automations.runFailures.managedHostServer", defaultValue: "Needs migration to %1$@"), host)
    case "missedGraceWindow":
      return String(
        localized: "automations.runFailures.missedGraceWindow",
        defaultValue: "This run was past its missed-run grace window when Orca next checked.")
    case "targetMissing":
      return String(
        localized: "automations.runFailures.targetMissing",
        defaultValue: "The automation host is no longer registered, so this automation has nowhere to run.")
    case "targetReplaced":
      return String(
        localized: "automations.runFailures.targetReplaced",
        defaultValue:
          "The automation host was removed and re-registered, so this automation must be re-adopted before it can run.")
    case "workspaceHostAmbiguous":
      return String(
        localized: "automations.runFailures.workspaceHostAmbiguous",
        defaultValue: "The automation workspace spans more than one host, so Orca cannot tell which one to run it on.")
    case "legacyTwinHosts":
      return String(
        localized: "automations.runFailures.legacyTwinHosts",
        defaultValue:
          "This automation was saved before Orca tracked which host it runs on, and its project is on more than one host. Open the automation and pick the host it should run on."
      )
    case "targetUnavailable":
      return String(
        localized: "automations.runFailures.targetUnavailable", defaultValue: "Automation run target is no longer available.")
    case "remoteSchedulingUnavailable":
      return String(
        localized: "automations.runFailures.remoteSchedulingUnavailable",
        defaultValue:
          "Remote-server automation scheduling is not available from this Orca client yet. Run this automation on the remote server or update Orca when durable remote scheduling is available."
      )
    case "projectSetupMissing":
      return String(
        localized: "automations.runFailures.projectSetupMissing",
        defaultValue: "Project is not set up on the selected automation host anymore.")
    case "projectSetupNotReady":
      switch params["setupState"] {
      case "not-set-up":
        return String(
          localized: "automations.runFailures.projectSetupState.notSetUp",
          defaultValue: "The project is not set up on the selected automation host.")
      case "setting-up":
        return String(
          localized: "automations.runFailures.projectSetupState.settingUp",
          defaultValue: "The project is still being set up on the selected automation host.")
      case "error":
        return String(
          localized: "automations.runFailures.projectSetupState.error",
          defaultValue: "Project setup failed on the selected automation host.")
      case "unsupported":
        return String(
          localized: "automations.runFailures.projectSetupState.unsupported",
          defaultValue: "The selected automation host does not support this project.")
      default: return error
      }
    case "targetSetupMismatch":
      return String(
        localized: "automations.runFailures.targetSetupMismatch",
        defaultValue: "Automation run target no longer matches the selected project host setup.")
    case "repoUnavailable":
      return String(
        localized: "automations.runFailures.repoUnavailable",
        defaultValue: "Repository for the selected automation host is no longer available.")
    case "repoDetached":
      return String(
        localized: "automations.runFailures.repoDetached",
        defaultValue: "Repository is no longer attached to the selected automation host.")
    case "projectPathChanged":
      return String(
        localized: "automations.runFailures.projectPathChanged",
        defaultValue: "Project path for the selected automation host has changed.")
    case "automationChanged":
      return String(
        localized: "automations.runFailures.automationChanged", defaultValue: "The automation changed before this run could launch.")
    case "destinationChanged":
      return String(
        localized: "automations.runFailures.destinationChanged",
        defaultValue: "The automation destination changed before this run could launch.")
    case "hooksReviewBlocked":
      return String(
        localized: "automations.runFailures.hooksReviewBlocked",
        defaultValue:
          "The agent is waiting for someone to review new or changed hooks (\"Hooks need review\"). Open this run and trust them, or remove them. Scheduled runs keep going and succeed once nothing needs review."
      )
    case "agentNeverStarted":
      return String(
        localized: "automations.runFailures.agentNeverStarted",
        defaultValue: "Automation agent never started after the prompt was submitted.")
    case "agentNoCompletion":
      return String(
        localized: "automations.runFailures.agentNoCompletion", defaultValue: "Automation agent did not report completion.")
    case "agentInterrupted":
      return String(
        localized: "automations.runFailures.agentInterrupted",
        defaultValue: "The agent was interrupted before it finished this run.")
    case "watchTimedOut":
      return String(
        localized: "automations.runFailures.watchTimedOut",
        defaultValue: "Orca stopped watching this run after 6h without a completion signal.")
    case "wslDistroStopped":
      guard let distro = params["distro"] else { return error }
      return String(
        format: String(
          localized: "automations.runFailures.wslDistroStopped",
          defaultValue:
            "The WSL distro %1$@ is stopped, so this scheduled run did not start it. Start the distro or use Run now; later runs go ahead while it runs."
        ), distro)
    case "botsOff":
      return String(
        localized: "automations.runFailures.botsOff", defaultValue: "Bots are turned off in Settings, so Orca skipped this run.")
    case "botsOffByTeam":
      return String(
        localized: "automations.runFailures.botsOffByTeam", defaultValue: "Bots are turned off by your team, so Orca skipped this run.")
    case "botMissing":
      return String(
        localized: "automations.runFailures.botMissing", defaultValue: "The bot this automation runs as no longer exists.")
    case "botFolderMissing":
      return String(localized: "automations.runFailures.botFolderMissing", defaultValue: "The bot's folder is no longer available.")
    case "botPaused":
      guard let bot = params["bot"] else { return error }
      return String(
        format: String(localized: "automations.runFailures.botPaused", defaultValue: "%1$@ is paused, so Orca skipped this run."), bot)
    default: return error
    }
  }
}
