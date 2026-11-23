import ObjectiveC
import UIKit

/// Every scroll view's edges fade softly under the glass bars (`UIScrollEdgeEffect.Style.soft`), the
/// system's own lists, sheets and pickers included: they are set as each scroll view reaches a window, so
/// no screen has to remember to.
enum ScrollEdges {
  static func install() {
    let cls: AnyClass = UIScrollView.self
    let originalSelector = #selector(UIScrollView.didMoveToWindow)
    let replacementSelector = #selector(UIScrollView.orca_didMoveToWindow)
    guard
      let original = class_getInstanceMethod(cls, originalSelector),
      let replacement = class_getInstanceMethod(cls, replacementSelector)
    else { return }
    // didMoveToWindow is UIView's: give UIScrollView its own copy first, so only scroll views are changed.
    if class_addMethod(cls, originalSelector, method_getImplementation(replacement), method_getTypeEncoding(replacement)) {
      class_replaceMethod(cls, replacementSelector, method_getImplementation(original), method_getTypeEncoding(original))
    } else {
      method_exchangeImplementations(original, replacement)
    }
  }
}

extension UIScrollView {
  @objc fileprivate func orca_didMoveToWindow() {
    orca_didMoveToWindow()  // The original, after the exchange.
    guard window != nil else { return }
    topEdgeEffect.style = .soft
    bottomEdgeEffect.style = .soft
  }
}
