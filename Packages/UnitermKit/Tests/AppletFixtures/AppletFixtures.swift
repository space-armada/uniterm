import AppletKit

// The fixtures build only in debug, so a release app that links this target carries none of
// their code. The app's registration is compiled out of release builds too.
#if DEBUG
  /// The hosted fixture applets, as the tests and a debug build register them. A release build never
  /// registers them, so no shipped applet gains exec support through them.
  public enum AppletFixtures {
    /// Each fixture supports both access modes, with and without an exec driver.
    public static let declarations: [AppletTypeDeclaration] = [
      AppletTypeDeclaration(
        typeID: SlidesFixture.typeID, displayName: "Slides fixture",
        symbolName: "rectangle.on.rectangle",
        opens: [], controlSupport: ControlCombination.all),
      AppletTypeDeclaration(
        typeID: NotesFixture.typeID, displayName: "Notes fixture", symbolName: "note.text",
        opens: [], controlSupport: ControlCombination.all),
      AppletTypeDeclaration(
        typeID: ChartFixture.typeID, displayName: "Chart fixture", symbolName: "chart.xyaxis.line",
        opens: [], controlSupport: ControlCombination.all),
      AppletTypeDeclaration(
        typeID: PathsFixture.typeID, displayName: "Paths fixture", symbolName: "doc.text",
        opens: [], controlSupport: ControlCombination.all),
      AppletTypeDeclaration(
        typeID: PoweredFixture.typeID, displayName: "Powered fixture", symbolName: "bolt",
        opens: [], controlSupport: ControlCombination.all),
      AppletTypeDeclaration(
        typeID: MarkedFixture.typeID, displayName: "Marked fixture", symbolName: "gearshape.2",
        opens: [], controlSupport: ControlCombination.all),
    ]

    public static let typeIDs: Set<String> = Set(declarations.map(\.typeID))

    /// A fresh fixture of the type, or nil for a type that is not a fixture.
    @MainActor
    public static func make(typeID: String) -> (any Applet)? {
      switch typeID {
      case SlidesFixture.typeID: return SlidesFixture()
      case NotesFixture.typeID: return NotesFixture()
      case ChartFixture.typeID: return ChartFixture()
      case PathsFixture.typeID: return PathsFixture()
      case PoweredFixture.typeID: return PoweredFixture()
      case MarkedFixture.typeID: return MarkedFixture()
      default: return nil
      }
    }

    /// Restores a fixture from its description. It throws for a type that is not a fixture.
    @MainActor
    public static func restore(_ description: AppletDescription) throws -> any Applet {
      switch description.type {
      case SlidesFixture.typeID: return try SlidesFixture(restoring: description)
      case NotesFixture.typeID: return try NotesFixture(restoring: description)
      case ChartFixture.typeID: return try ChartFixture(restoring: description)
      case PathsFixture.typeID: return PathsFixture()
      case PoweredFixture.typeID: return PoweredFixture()
      case MarkedFixture.typeID: return try MarkedFixture(restoring: description)
      default:
        throw AppletRestoreError.unsupported("the applet type \"\(description.type)\" is unknown")
      }
    }
  }
#endif
