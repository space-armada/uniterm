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
  public static let commandSet = AppletCommandSet(
    typeID: TextViewerDescription.typeID, menuTitle: "Text Viewer",
    commands: [.openSource(section: 1)])
}
