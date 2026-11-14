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
  /// The find commands sit in Edit > Find and are off until a document is showing. The pane owns one
  /// find bar, and its query never reaches the system find pasteboard. Show Contents has no key and
  /// toggles the sidebar.
  ///
  /// Reload reads the file again and keeps the reader's place. It takes Cmd-R, the key the browser
  /// uses for its reload, since each applet's keys apply only while its pane has focus.
  public static let commandSet = AppletCommandSet(
    typeID: TextViewerDescription.typeID, menuTitle: "Text Viewer",
    commands: [
      .openSource(section: 1),
      .find(name: "find", title: "Find\u{2026}", key: KeyChord("f")) { $0.showFind() },
      .find(name: "find-next", title: "Find Next", key: KeyChord("g")) {
        $0.stepFind(forward: true)
      },
      .find(
        name: "find-previous", title: "Find Previous", key: KeyChord("g", [.command, .shift])
      ) { $0.stepFind(forward: false) },
      .find(
        name: "use-selection-for-find", title: "Use Selection for Find", key: KeyChord("e"),
        section: 1
      ) {
        $0.useSelectionForFind()
      },
      AppletCommand(
        name: "show-contents", title: "Show Contents", key: nil, home: .view, section: 1,
        isAvailable: { ($0 as? TextViewerApplet)?.canShowContents ?? false },
        run: { ($0 as? TextViewerApplet)?.toggleContents() }),
      AppletCommand(
        name: "reload", title: "Reload", key: KeyChord("r"), home: .view,
        isAvailable: { ($0 as? TextViewerApplet)?.canReload ?? false },
        run: { ($0 as? TextViewerApplet)?.reload() }),
    ])
}

extension AppletCommand {
  fileprivate static func find(
    name: String, title: String, key: KeyChord?, section: Int = 0,
    run: @escaping @MainActor (TextViewerApplet) -> Void
  ) -> AppletCommand {
    AppletCommand(
      name: name, title: title, key: key, home: .editFind, section: section,
      isAvailable: { ($0 as? TextViewerApplet)?.canFind ?? false },
      run: { applet in
        guard let viewer = applet as? TextViewerApplet else { return }

        run(viewer)
      })
  }
}
