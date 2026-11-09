import AppletKit
import TextViewerModel

extension TextViewerApplet {
  /// The text viewer opens PDF, RTF, Word, and Markdown documents and is the default for all of
  /// them.
  public nonisolated static let typeDeclaration = AppletTypeDeclaration(
    typeID: TextViewerDescription.typeID, displayName: "Text Viewer", symbolName: "doc.text",
    opens: [
      OpenedType("com.adobe.pdf", rank: .owner),
      OpenedType("public.rtf", rank: .owner),
      OpenedType(TextFormatRule.word97Identifier, rank: .owner),
      OpenedType(TextFormatRule.wordXMLIdentifier, rank: .owner),
      OpenedType(TextFormatRule.markdownIdentifier, rank: .owner),
    ])

  /// The text viewer's own commands. Open has no key, since Cmd-O belongs to the window's File >
  /// Open, which routes by type.
  ///
  /// Reload reads the file again and keeps the reader's place. It takes Cmd-R, the key the browser
  /// uses for its reload, since each applet's keys apply only while its pane has focus.
  public static let commandSet = AppletCommandSet(
    typeID: TextViewerDescription.typeID, menuTitle: "Text Viewer",
    commands: [
      .openSource(section: 1),
      AppletCommand(
        name: "reload", title: "Reload", key: KeyChord("r"), home: .view,
        isAvailable: { ($0 as? TextViewerApplet)?.canReload ?? false },
        run: { ($0 as? TextViewerApplet)?.reload() }),
    ])
}
