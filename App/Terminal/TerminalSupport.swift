import UIKit

/// A Liquid Glass surface that materialises and dematerialises by animating its effect, which is how
/// UIKit expects glass to appear and disappear.
final class GlassSurface: UIVisualEffectView {
  private let interactive: Bool

  init(interactive: Bool = false, visible: Bool = true) {
    self.interactive = interactive
    super.init(effect: visible ? Self.glass(interactive: interactive) : nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  func setVisible(_ visible: Bool, animated: Bool) {
    let change = {
      self.effect = visible ? Self.glass(interactive: self.interactive) : nil
      self.contentView.alpha = visible ? 1 : 0
    }
    isUserInteractionEnabled = visible
    if animated, !UIAccessibility.isReduceMotionEnabled {
      UIView.animate(withDuration: 0.3, animations: change)
    } else {
      change()
    }
  }

  private static func glass(interactive: Bool) -> UIGlassEffect {
    let effect = UIGlassEffect(style: .regular)
    effect.isInteractive = interactive
    return effect
  }
}

/// A tab's controller that holds a stream it must let go of when the tab goes away.
protocol WorkspaceContent: AnyObject {
  func close()
}

/// A short note over the current screen: a blurred pill near the top that fades after a moment.
@MainActor
final class Toast {
  enum Kind { case info, error }
  static let shared = Toast()

  func show(_ text: String, kind: Kind = .info) {
    guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first
    else { return }
    if kind == .error { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    let pill = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    pill.layer.cornerRadius = 20
    pill.clipsToBounds = true
    pill.translatesAutoresizingMaskIntoConstraints = false
    let label = TextLabel(text, size: 15, color: kind == .error ? Palette.statusRed : Palette.textPrimary, lines: 2)
    pill.contentView.addSubview(label)
    label.pin(to: pill.contentView, insets: UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16))
    window.addSubview(pill)
    NSLayoutConstraint.activate([
      pill.centerXAnchor.constraint(equalTo: window.centerXAnchor),
      pill.topAnchor.constraint(equalTo: window.safeAreaLayoutGuide.topAnchor, constant: 8),
      pill.widthAnchor.constraint(lessThanOrEqualTo: window.widthAnchor, constant: -48),
    ])
    pill.alpha = 0
    UIView.animate(withDuration: 0.2) { pill.alpha = 1 }
    UIView.animate(withDuration: 0.3, delay: 2.2, options: []) { pill.alpha = 0 } completion: { _ in pill.removeFromSuperview() }
  }
}

/// A string looked up by its English text, for copy the official catalog has no key for.
func L(_ english: String) -> String {
  Bundle.main.localizedString(forKey: english, value: english, table: nil)
}

extension UIFont {
  /// A system font at `size` points; the terminal's own controls do not scale with Dynamic Type.
  static func dynamic(_ size: CGFloat, weight: UIFont.Weight = .regular, monospaced: Bool = false) -> UIFont {
    monospaced ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
  }
}

extension UIButton.Configuration {
  /// The app's primary button: prominent glass on the accent.
  static func orcaProminent() -> UIButton.Configuration {
    var configuration = UIButton.Configuration.prominentGlass()
    configuration.baseBackgroundColor = Palette.accentBlue
    configuration.baseForegroundColor = Palette.onAccent
    return configuration
  }
}
