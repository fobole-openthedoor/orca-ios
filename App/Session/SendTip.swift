import TipKit
import UIKit

/// Shown once, pointing at send the first time a chat opens: holding send queues a message for after the
/// running turn, and Settings › Chat UI changes what a tap does.
struct SendHoldTip: Tip {
  var title: Text { Text(String(localized: "orcaios.tip.sendTitle", defaultValue: "Hold to queue")) }

  var message: Text? {
    Text(
      String(
        localized: "orcaios.tip.sendMessage",
        defaultValue: "While the agent works, hold send to queue your message for after this turn. Prefer the other way? Change it in Settings."))
  }

  var image: Image? { Image(systemName: "list.bullet.indent") }

  var actions: [Action] {
    [Action(id: "settings", title: String(localized: "orcaios.tip.openSettings", defaultValue: "Settings"))]
  }

  /// Shown already; cleared from Settings › Orca iOS to show it again.
  static var seen: Bool {
    get { UserDefaults.standard.bool(forKey: "orca.tip.sendHold") }
    set { UserDefaults.standard.set(newValue, forKey: "orca.tip.sendHold") }
  }
}
