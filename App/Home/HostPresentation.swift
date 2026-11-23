import OrcaCore
import UIKit

/// How a desktop's connection reads on Home and in headers (transport/connection/connection-health.ts and
/// components/feedback/StatusDot.tsx): a label, its colour, and the dot's colour.
struct HostConnectionPresentation {
  let label: String
  let dot: UIColor
  /// The words take the dot's colour only for problems, so a healthy desktop's line stays muted.
  let labelColor: UIColor
  let connected: Bool

  init(_ state: ConnectionState) {
    switch state {
    case .connected:
      label = String(localized: "connection.connectionHealth.connected", defaultValue: "Connected")
      dot = Palette.statusGreen
      labelColor = Palette.textMuted
      connected = true
    case .connecting, .handshaking:
      label = String(localized: "connection.connectionHealth.connecting", defaultValue: "Connecting…")
      dot = Palette.statusAmber
      labelColor = Palette.textMuted
      connected = false
    case .reconnecting(let attempt) where attempt >= 3:
      label = String(localized: "connection.connectionHealth.desktopUnreachable", defaultValue: "Can't reach desktop")
      dot = Palette.statusRed
      labelColor = Palette.statusRed
      connected = false
    case .reconnecting:
      label = String(localized: "connection.connectionHealth.reconnecting", defaultValue: "Reconnecting…")
      dot = Palette.statusAmber
      labelColor = Palette.statusAmber
      connected = false
    case .authFailed:
      label = String(localized: "components.hostCard.pairingInvalid", defaultValue: "Pairing invalid")
      dot = Palette.statusRed
      labelColor = Palette.statusRed
      connected = false
    case .disconnected:
      label = String(localized: "connection.connectionHealth.disconnected", defaultValue: "Disconnected")
      dot = Palette.textMuted
      labelColor = Palette.textMuted
      connected = false
    }
  }
}

/// The official worktree count line: "3 worktrees · 1 active".
@MainActor
enum HostWorktreeSummary {
  static func text(for session: HostSession) -> String? {
    guard !session.isLoading else { return nil }
    // A bot's home is listed with the bots, not counted as a worktree.
    let botHomes = Set(session.bots.bots.map(\.homeWorktreeId))
    let visible = session.worktrees.filter { !$0.isArchived && !botHomes.contains($0.id) }
    // Active: something is running in it, a terminal or an agent.
    let active = visible.filter { $0.liveTerminalCount > 0 || !$0.agents.isEmpty }.count
    return "\(visible.count) worktree\(visible.count == 1 ? "" : "s")" + (active > 0 ? " · \(active) active" : "")
  }

  /// Agents on this desktop waiting on the user.
  static func needsYou(in session: HostSession) -> Int {
    session.worktrees.filter { !$0.isArchived && $0.needsAttention }.count
  }
}

extension HostStatus {
  /// The machine line under a desktop's name: "Mac mini · macOS".
  var machineLine: String? {
    let platform: String? =
      switch hostPlatform {
      case "darwin": "macOS"
      case "win32": "Windows"
      case "linux": "Linux"
      default: hostPlatform
      }
    // shared/execution-host/host-machine-line.ts: the model, else the kind's label, then the OS.
    let kindLabel: String? =
      switch hostKind {
      case "laptop": "Laptop"
      case "desktop": "Desktop"
      case "server": "Server"
      default: nil
      }
    let machine = hostModel.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? kindLabel
    let parts = [machine, platform].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }
}
