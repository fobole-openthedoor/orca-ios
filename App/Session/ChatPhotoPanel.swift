import PhotosUI
import UIKit

/// Photos picked in place, as ChatGPT's composer does: the system's picker embedded in a card where the
/// composer was, three across, numbered as they're chosen, videos with their length. Back and "Add N" sit
/// on glass at its foot; "All Photos" (or a swipe up) opens the full picker with the same choices.
final class ChatPhotoPanel: UIViewController, PHPickerViewControllerDelegate {
  /// The chosen items, in the order picked.
  var onAdd: (([PHPickerResult]) -> Void)?
  var onClose: (() -> Void)?
  /// Wants the full picker, starting from these choices.
  var onExpand: (([String]) -> Void)?

  private var picker: PHPickerViewController!
  private var picked: [PHPickerResult] = []
  private let add = UIButton(configuration: .prominentGlass())

  static func configuration(preselected: [String] = []) -> PHPickerConfiguration {
    var configuration = PHPickerConfiguration(photoLibrary: .shared())
    configuration.filter = .any(of: [.images, .videos])
    configuration.selectionLimit = 10
    configuration.selection = .ordered
    configuration.preferredAssetRepresentationMode = .current
    configuration.preselectedAssetIdentifiers = preselected
    return configuration
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = Palette.bgRaised
    view.layer.cornerRadius = 34
    view.layer.cornerCurve = .continuous
    view.clipsToBounds = true

    var configuration = Self.configuration()
    configuration.selection = .continuousAndOrdered
    configuration.mode = .default
    configuration.disabledCapabilities = [.search, .collectionNavigation, .stagingArea, .selectionActions]
    configuration.edgesWithoutContentMargins = .all
    picker = PHPickerViewController(configuration: configuration)
    picker.delegate = self
    addChild(picker)
    picker.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(picker.view)
    picker.view.pin(to: view)
    picker.didMove(toParent: self)

    let back = Self.glassButton(image: Lucide.chevronLeft.image(size: 20, strokeWidth: 2.2)) { [weak self] in self?.onClose?() }
    back.accessibilityLabel = String(localized: "common.back", defaultValue: "Back")
    var all = UIButton.Configuration.glass()
    all.title = String(localized: "orcaios.photos.all", defaultValue: "All Photos")
    all.baseForegroundColor = Palette.textPrimary
    all.cornerStyle = .capsule
    all.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
      var attributes = attributes
      attributes.font = .systemFont(ofSize: 14, weight: .semibold)
      return attributes
    }
    let expand = UIButton(configuration: all, primaryAction: UIAction { [weak self] _ in self?.expandPicker() })
    add.configuration?.baseBackgroundColor = Palette.accentBlue
    add.configuration?.baseForegroundColor = .white
    add.configuration?.cornerStyle = .capsule
    add.configuration?.contentInsets = .init(top: 12, leading: 20, bottom: 12, trailing: 20)
    add.addAction(UIAction { [weak self] _ in self?.finish() }, for: .primaryActionTriggered)
    for control in [back, expand, add] as [UIView] {
      control.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(control)
    }
    NSLayoutConstraint.activate([
      back.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Spacing.md),
      back.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Spacing.md),
      back.widthAnchor.constraint(equalToConstant: 48),
      back.heightAnchor.constraint(equalToConstant: 48),
      expand.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Spacing.md),
      expand.topAnchor.constraint(equalTo: view.topAnchor, constant: Spacing.md),
      add.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Spacing.md),
      add.centerYAnchor.constraint(equalTo: back.centerYAnchor),
    ])
    let swipe = UISwipeGestureRecognizer(target: self, action: #selector(expandPicker))
    swipe.direction = .up
    view.addGestureRecognizer(swipe)
    updateAdd()
  }

  private static func glassButton(image: UIImage?, action: @escaping () -> Void) -> UIButton {
    var configuration = UIButton.Configuration.glass()
    configuration.image = image
    configuration.baseForegroundColor = Palette.textPrimary
    configuration.cornerStyle = .capsule
    return UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    // Continuous: called on every change with the whole choice so far.
    if results.count != picked.count { Haptics.select() }
    picked = results
    updateAdd()
  }

  private func updateAdd() {
    let videos = picked.filter { $0.itemProvider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) }.count
    let title: String =
      if videos == picked.count {
        String(format: String(localized: "orcaios.photos.addVideos", defaultValue: "Add %1$lld videos"), picked.count)
      } else if videos == 0 {
        String(format: String(localized: "orcaios.photos.addPhotos", defaultValue: "Add %1$lld photos"), picked.count)
      } else {
        String(format: String(localized: "orcaios.photos.addItems", defaultValue: "Add %1$lld items"), picked.count)
      }
    add.configuration?.title = title
    UIView.animate(withDuration: 0.2) {
      self.add.alpha = self.picked.isEmpty ? 0 : 1
      self.add.transform = self.picked.isEmpty ? CGAffineTransform(scaleX: 0.8, y: 0.8) : .identity
    }
  }

  private func finish() {
    guard !picked.isEmpty else { return }
    onAdd?(picked)
  }

  @objc private func expandPicker() {
    onExpand?(picked.compactMap(\.assetIdentifier))
  }
}
