import UIKit

/// The composer's + as ChatGPT's: a glass card of rows that grows up from the button and sits over the
/// chat, leaving the composer in view. A tap anywhere else closes it.
final class ChatAttachMenu: UIView {
  private let card = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
  private var closing = false

  init(choices: [ChatComposerView.AttachChoice]) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    let backdrop = UIControl()
    backdrop.translatesAutoresizingMaskIntoConstraints = false
    backdrop.addAction(UIAction { [weak self] _ in self?.close() }, for: .touchDown)
    addSubview(backdrop)
    backdrop.pin(to: self)

    card.cornerConfiguration = .uniformCorners(radius: 26)
    card.translatesAutoresizingMaskIntoConstraints = false
    addSubview(card)
    let column = UIStackView()
    column.axis = .vertical
    column.translatesAutoresizingMaskIntoConstraints = false
    card.contentView.addSubview(column)
    for choice in choices {
      var configuration = UIButton.Configuration.plain()
      configuration.image = choice.image.map { Self.boxed($0) }
      configuration.imagePadding = 14
      configuration.title = choice.title
      configuration.baseForegroundColor = Palette.textPrimary
      configuration.contentInsets = .init(top: 14, leading: 18, bottom: 14, trailing: 28)
      configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
        var attributes = attributes
        attributes.font = .systemFont(ofSize: 17)
        return attributes
      }
      let row = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
        if choice.morphs { self?.handOff(choice.run) } else { self?.close { choice.run() } }
      })
      row.contentHorizontalAlignment = .leading
      column.addArrangedSubview(row)
    }
    NSLayoutConstraint.activate([
      column.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor),
      column.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor),
      column.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: 6),
      column.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -6),
      card.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// A symbol centred in a 24 pt square, so every row's words start at the same place.
  private static func boxed(_ symbol: UIImage) -> UIImage {
    let glyph = symbol.withConfiguration(UIImage.SymbolConfiguration(pointSize: 17, weight: .regular))
    let box = CGSize(width: 24, height: 24)
    return UIGraphicsImageRenderer(size: box).image { _ in
      let size = glyph.size
      glyph.draw(in: CGRect(x: (box.width - size.width) / 2, y: (box.height - size.height) / 2, width: size.width, height: size.height))
    }.withRenderingMode(.alwaysTemplate)
  }

  /// Covers `host`; the card lines up with `anchor` (the +) and sits just above `floor` (the composer).
  func show(in host: UIView, from anchor: UIView, above floor: UIView) {
    host.addSubview(self)
    pin(to: host)
    NSLayoutConstraint.activate([
      card.leadingAnchor.constraint(equalTo: anchor.leadingAnchor),
      card.bottomAnchor.constraint(equalTo: floor.topAnchor, constant: -8),
    ])
    host.layoutIfNeeded()
    // Grows out of the +.
    let origin = convert(CGPoint(x: anchor.bounds.midX, y: anchor.bounds.minY), from: anchor)
    card.layer.anchorPoint = CGPoint(x: (origin.x - card.frame.minX) / max(card.bounds.width, 1), y: 1)
    card.layer.position = CGPoint(x: origin.x, y: card.frame.maxY)
    card.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
    card.alpha = 0
    UIView.animate(withDuration: 0.38, delay: 0, usingSpringWithDamping: 0.78, initialSpringVelocity: 0.3) {
      self.card.transform = .identity
      self.card.alpha = 1
    }
  }

  /// Where the card sat, in the host's coordinates, for what grows out of it.
  static var lastFrame: CGRect?

  /// Leaves at once so the next view can grow out of where the card was.
  private func handOff(_ action: @escaping () -> Void) {
    guard !closing else { return }
    closing = true
    Self.lastFrame = superview.map { card.convert(card.bounds, to: $0) }
    action()
    UIView.animate(withDuration: 0.15) { self.card.alpha = 0 } completion: { _ in self.removeFromSuperview() }
  }

  func close(then action: (() -> Void)? = nil) {
    guard !closing else { return }
    closing = true
    UIView.animate(withDuration: 0.18, delay: 0, options: .curveEaseIn) {
      self.card.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
      self.card.alpha = 0
    } completion: { _ in
      self.removeFromSuperview()
      action?()
    }
  }
}
