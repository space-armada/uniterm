import Foundation
import GeoData

/// What the user asked a new pane to run.
public enum AppletChoice: Sendable, Equatable {
  /// A terminal that starts the user's login shell.
  case terminalShell

  /// A terminal that runs one program, given as a command line.
  case terminalProgram(command: String)

  /// A data viewer with nothing open, started in the pane's directory.
  case dataViewer

  /// A map viewer, started in the pane's directory. It shows `region` when the user picked a place,
  /// and its own default view otherwise.
  case mapViewer(region: GeoRegion?)

  /// An image viewer with nothing open, started in the pane's directory.
  case imageViewer

  /// A text viewer with nothing open, started in the pane's directory.
  case textViewer

  /// A browser with no page loaded. It has no directory, so the pane's directory goes unused.
  case browser
}
