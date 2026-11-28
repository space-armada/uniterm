import ProcessInspection

/// An applet that hosts a controller process uniterm started, which the user can suspend and
/// resume as Ctrl-Z and `fg` do for a program in a shell.
///
/// The applet reports a change through `appletDidChange`, so the window can show the badge, the
/// slot, and the menus again.
@MainActor
public protocol ControllerSuspending: Applet {
  /// The state of the controller's process, or nil while the applet has none to suspend. A
  /// controller that has not yet attached has none, so suspend never stops one that is still
  /// inside its declaration window.
  var controllerSuspension: SuspensionState? { get }

  /// What the window calls the controller.
  var controllerName: String { get }

  /// Stops the controller's whole process group. It does nothing without a controller.
  func suspendController()

  /// Continues it. It works on a stop that something outside uniterm made.
  func resumeController()

  /// Ends a controller as the app quits. Its group is continued first, whatever the record says.
  /// A suspended one is killed with its whole group at once, so nothing it started stays frozen
  /// with no one left to continue it.
  func endControllerForQuit()
}

/// The words every place that shows a suspension uses, so the menu, the palette, the badge, the
/// pane, and the slot agree.
public enum SuspensionWording {
  /// Said wherever a suspension shows. A page a controller loaded keeps running, and so does
  /// JavaScript it injected, so a suspension is not a safety measure.
  public static let pageCodeNote =
    "Page code it loaded keeps running. Closing the tab stops it."

  /// The line for a controller that uniterm or the user stopped.
  public static func suspended(_ name: String) -> String {
    "\(name) is suspended. \(pageCodeNote)"
  }

  /// The line for a local controller its shell stopped. uniterm cannot continue it.
  public static func stoppedByShell(_ name: String) -> String {
    "\(name): Stopped by its shell. Resume it with fg in its terminal."
  }
}
