import AppletKit
import BrowserApplet
import DataViewerApplet
import ImageViewerApplet
import MapViewerApplet
import TerminalApplet
import TextViewerApplet

/// The applet types this build ships, with the content types each opens. A new applet type adds
/// its declaration here, beside the code that declares it. Tests read this list, and so does the
/// router.
public enum BuiltInApplets {
  public static let declarations: [AppletTypeDeclaration] = [
    TerminalApplet.typeDeclaration,
    DataViewerApplet.typeDeclaration,
    MapViewerApplet.typeDeclaration,
    BrowserApplet.typeDeclaration,
    ImageViewerApplet.typeDeclaration,
    TextViewerApplet.typeDeclaration,
  ]

  /// The commands each built-in applet type registers. The app registers exactly this list, so a
  /// test over it covers every applet the app ships.
  @MainActor
  public static var commandSets: [AppletCommandSet] {
    [
      TerminalApplet.commandSet, DataViewerApplet.commandSet, MapViewerApplet.commandSet,
      BrowserApplet.commandSet, ImageViewerApplet.commandSet, TextViewerApplet.commandSet,
    ]
  }
}
