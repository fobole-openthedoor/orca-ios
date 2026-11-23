import UIKit

/// The app's touch feedback: a light tick when a row or chip is picked, as iOS lists give.
@MainActor
enum Haptics {
  private static let selection = UISelectionFeedbackGenerator()

  static func select() {
    selection.selectionChanged()
    selection.prepare()
  }
}
