import UIKit

/// Hand-off from the composer's + menu to what opens from it.
enum ChatAttachMenu {
  /// Where the + sat, in window coordinates, when Photos was chosen at rest: the photo panel grows out of it.
  static var lastFrame: CGRect?
}
