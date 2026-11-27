import AppKit
import AppletKit

#if DEBUG
  /// A slide deck. A driver sets the deck and shows a slide. The user's Next button asks the driver
  /// to advance, and every slide shown is an event.
  @MainActor
  public final class SlidesFixture: FixtureApplet, AppletCommandHandling {
    public nonisolated static let typeID = "fixture-slides"

    public nonisolated static let schema = AppletCommandSchema(
      appletType: typeID, version: AppletSchemaVersion(0, 0),
      commands: [
        AppletMessageSchema(
          name: "set-deck", summary: "Replaces the deck and shows its first slide.",
          arguments: AppletObjectSchema([
            "titles": .init(.array(of: .string(maxBytes: 200), maxCount: 100))
          ]),
          example: .object(["titles": .array([.string("Intro"), .string("Results")])])),
        AppletMessageSchema(
          name: "show-slide", summary: "Shows the slide at an index of the deck.",
          arguments: AppletObjectSchema(["index": .init(.integer(minimum: 0, maximum: 99))]),
          example: .object(["index": .number(1)])),
        AppletMessageSchema(name: "status", summary: "Reports the slide shown and the deck size."),
      ],
      events: [
        AppletMessageSchema(
          name: "slide-shown", summary: "A slide is now shown.",
          arguments: AppletObjectSchema([
            "index": .init(.integer(minimum: 0, maximum: 99)),
            "title": .init(.string(maxBytes: 200)),
          ])),
        AppletMessageSchema(
          name: "advance-requested", summary: "The user pressed Next.",
          arguments: AppletObjectSchema(["from": .init(.integer(minimum: -1, maximum: 99))])),
      ])

    public private(set) var titles: [String] = []
    public private(set) var index = -1

    private var titleLabel: NSTextField!
    private var positionLabel: NSTextField!

    public init() {
      super.init(typeID: Self.typeID, title: "Slides fixture", buttonTitle: "Next")
      configure()
    }

    public init(restoring description: AppletDescription) throws {
      let fields = try Self.object(of: description, type: Self.typeID)

      super.init(typeID: Self.typeID, title: "Slides fixture", buttonTitle: "Next")

      if case .array(let saved)? = fields["titles"] {
        titles = saved.compactMap { if case .string(let text) = $0 { text } else { nil } }
      }

      if let saved = fields["index"]?.integerValue, titles.indices.contains(saved) {
        index = saved
      }

      configure()
    }

    private func configure() {
      titleLabel = label("title")
      positionLabel = label("position")
      addButton()
      refresh()
    }

    public var commandSchema: AppletCommandSchema { Self.schema }

    public func perform(_ command: ValidatedAppletCommand) throws(AppletCommandError)
      -> AppletCommandReply
    {
      switch command.name {
      case "set-deck":
        guard case .array(let values)? = command.arguments["titles"] else {
          throw AppletCommandError(.badArgument, "the titles are missing")
        }

        titles = values.compactMap { if case .string(let text) = $0 { text } else { nil } }
        index = titles.isEmpty ? -1 : 0
        refresh()
        emitShown()

        return .immediate(.object(["count": .number(Double(titles.count))]))

      case "show-slide":
        let wanted = command.arguments["index"]?.integerValue ?? -1

        guard titles.indices.contains(wanted) else {
          throw AppletCommandError(
            .badArgument, "the deck has \(titles.count) slides, so there is no slide \(wanted)")
        }

        index = wanted
        refresh()
        emitShown()

        return .immediate(
          .object(["index": .number(Double(index)), "title": .string(titles[index])]))

      case "status":
        return .immediate(
          .object(["index": .number(Double(index)), "count": .number(Double(titles.count))]))

      default:
        throw AppletCommandError(.unknownCommand, "the slides fixture has no \(command.name)")
      }
    }

    override func userPressedButton() {
      events.emit("advance-requested", .object(["from": .number(Double(index))]))
    }

    private func emitShown() {
      guard titles.indices.contains(index) else { return }

      events.emit(
        "slide-shown", .object(["index": .number(Double(index)), "title": .string(titles[index])]))
    }

    private func refresh() {
      titleLabel.stringValue = titles.indices.contains(index) ? titles[index] : "No slide"
      positionLabel.stringValue =
        titles.isEmpty ? "Empty deck" : "Slide \(index + 1) of \(titles.count)"
    }

    override var payload: JSONValue {
      .object([
        "titles": .array(titles.map(JSONValue.string)), "index": .number(Double(index)),
      ])
    }
  }
#endif
