import Foundation

/// An applet that opens another tab when the host asks. The terminal in shell mode and the browser
/// adopt it. The host never switches on a concrete applet type to find them.
@MainActor
public protocol TabOpening: Applet {
  /// False when the applet has tabs but cannot open another now, as a terminal that runs one
  /// program cannot.
  var canOpenTab: Bool { get }

  /// True when a tab starts in a directory. A browser tab has none, so a directory the caller
  /// names is refused for it instead of dropped.
  var tabsStartInDirectory: Bool { get }

  /// Opens a tab after the selected one and selects it. The directory is where the tab starts. Nil
  /// leaves the choice to the applet, which uses the directory the selected tab reports. Returns
  /// the new tab's ID, or nil when the tab did not open.
  @discardableResult
  func openTab(startingIn directory: String?) -> AppletTabID?
}
