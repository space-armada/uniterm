import AppKit
import AppletKit

/// Reads and moves a shared tab bar from an applet's own tests. The bar keeps its scroll and its
/// geometry internal, and each applet's tests need the same two facts: where a tab sits against
/// the visible part of the bar, and a scroll the user makes.
@MainActor
public enum TabBarProbe {
  /// The first tab bar found at or under the view.
  public static func bar(in view: NSView) -> AppletTabBar? {
    if let bar = view as? AppletTabBar { return bar }

    for subview in view.subviews {
      if let found = bar(in: subview) { return found }
    }

    return nil
  }

  /// Scrolls the tabs by this much, as a wheel does, without selecting anything.
  public static func scroll(_ bar: AppletTabBar, by delta: CGFloat) {
    bar.scroll(by: delta)
  }

  /// How far the tabs are scrolled in from the leading edge.
  public static func offset(of bar: AppletTabBar) -> CGFloat {
    bar.layoutSubtreeIfNeeded()

    return bar.scrollOffset
  }

  /// Whether the tab lies fully inside the part of the bar that shows tabs.
  public static func isFullyInView(_ bar: AppletTabBar, tab index: Int) -> Bool {
    bar.layoutSubtreeIfNeeded()

    let frame = bar.frame(ofTab: index)

    return frame.minX >= bar.viewport.minX - 0.5 && frame.maxX <= bar.viewport.maxX + 0.5
  }
}
