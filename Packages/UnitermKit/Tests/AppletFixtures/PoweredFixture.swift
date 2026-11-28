import AppKit
import AppletKit

#if DEBUG
  /// A pane whose commands need a power beyond control of the pane, as the browser's do. It keeps
  /// the caller and the tab each command carried, so a test sees what the host handed it.
  @MainActor
  public final class PoweredFixture: FixtureApplet, AppletCommandHandling {
    public nonisolated static let typeID = "fixture-powered"

    public nonisolated static let schema = AppletCommandSchema(
      appletType: typeID, version: AppletSchemaVersion(0, 0),
      commands: [
        AppletMessageSchema(
          name: "go", summary: "Needs browser navigation and answers with the tab.",
          requires: .browserNavigation),
        AppletMessageSchema(
          name: "look", summary: "Needs browser read and answers with the tab.",
          requires: .browserRead),
        AppletMessageSchema(name: "free", summary: "Needs no power beyond control."),
        AppletMessageSchema(
          name: "fail", summary: "Refuses with the code it is given.",
          arguments: AppletObjectSchema([
            "code": .init(.choice(AppletCommandError.Code.allCases.map(\.rawValue)))
          ]),
          example: .object(["code": .string("refused")])),
      ],
      events: [])

    /// How many commands reached the applet. A refused command never counts.
    public private(set) var performed = 0

    /// The caller and tab the last command carried.
    public private(set) var lastCaller: AppletCaller?
    public private(set) var lastTab: AppletTabID?

    public init() {
      super.init(typeID: Self.typeID, title: "Powered fixture", buttonTitle: "Go")
    }

    public var commandSchema: AppletCommandSchema { Self.schema }

    public func perform(_ command: ValidatedAppletCommand) throws(AppletCommandError)
      -> AppletCommandReply
    {
      performed += 1
      lastCaller = command.caller
      lastTab = command.tab

      if command.name == "fail", case .string(let raw)? = command.arguments["code"],
        let code = AppletCommandError.Code(rawValue: raw)
      {
        throw AppletCommandError(code, "the fixture refused with \(raw)")
      }

      return .immediate(.object([:]))
    }
  }
#endif
