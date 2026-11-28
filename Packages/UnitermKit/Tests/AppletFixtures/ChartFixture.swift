import AppKit
import AppletKit

#if DEBUG
  /// A chart of one series. A driver sets the series and selects a point. The user's button selects
  /// the next point, and every selection is an event.
  @MainActor
  public final class ChartFixture: FixtureApplet, AppletCommandHandling {
    public nonisolated static let typeID = "fixture-chart"

    public nonisolated static let schema = AppletCommandSchema(
      appletType: typeID, version: AppletSchemaVersion(0, 0),
      commands: [
        AppletMessageSchema(
          name: "set-series", summary: "Replaces the series.",
          arguments: AppletObjectSchema([
            "values": .init(.array(of: .number(minimum: -1e9, maximum: 1e9), maxCount: 1000))
          ]),
          example: .object(["values": .array([.number(1.5), .number(-2), .number(4)])])),
        AppletMessageSchema(
          name: "select-point", summary: "Selects the point at an index of the series.",
          arguments: AppletObjectSchema(["index": .init(.integer(minimum: 0, maximum: 999))]),
          example: .object(["index": .number(0)])),
      ],
      events: [
        AppletMessageSchema(
          name: "point-selected", summary: "A point is now selected.",
          arguments: AppletObjectSchema([
            "index": .init(.integer(minimum: 0, maximum: 999)),
            "value": .init(.number(minimum: -1e9, maximum: 1e9)),
          ]))
      ])

    public private(set) var values: [Double] = []
    public private(set) var selected: Int?
    private var summaryLabel: NSTextField!

    public init() {
      super.init(typeID: Self.typeID, title: "Chart fixture", buttonTitle: "Next Point")
      configure()
    }

    public init(restoring description: AppletDescription) throws {
      let fields = try Self.object(of: description, type: Self.typeID)

      super.init(typeID: Self.typeID, title: "Chart fixture", buttonTitle: "Next Point")

      if case .array(let saved)? = fields["values"] {
        values = saved.compactMap { if case .number(let number) = $0 { number } else { nil } }
      }

      configure()
    }

    private func configure() {
      summaryLabel = label("summary")
      addButton()
      refresh()
    }

    public var commandSchema: AppletCommandSchema { Self.schema }

    public func perform(_ command: ValidatedAppletCommand) throws(AppletCommandError)
      -> AppletCommandReply
    {
      switch command.name {
      case "set-series":
        guard case .array(let numbers)? = command.arguments["values"] else {
          throw AppletCommandError(.badArgument, "the values are missing")
        }

        values = numbers.compactMap { if case .number(let number) = $0 { number } else { nil } }
        selected = nil
        refresh()

        return .immediate(
          .object([
            "count": .number(Double(values.count)),
            "minimum": values.min().map(JSONValue.number) ?? .null,
            "maximum": values.max().map(JSONValue.number) ?? .null,
          ]))

      case "select-point":
        let wanted = command.arguments["index"]?.integerValue ?? -1

        guard values.indices.contains(wanted) else {
          throw AppletCommandError(
            .badArgument, "the series has \(values.count) points, so there is no point \(wanted)")
        }

        select(wanted)

        return .immediate(
          .object(["index": .number(Double(wanted)), "value": .number(values[wanted])]))

      default:
        throw AppletCommandError(.unknownCommand, "the chart fixture has no \(command.name)")
      }
    }

    override func userPressedButton() {
      guard !values.isEmpty else { return }

      select(((selected ?? -1) + 1) % values.count)
    }

    private func select(_ index: Int) {
      selected = index
      refresh()
      events.emit(
        "point-selected",
        .object(["index": .number(Double(index)), "value": .number(values[index])]))
    }

    private func refresh() {
      let selection = selected.map { ", point \($0 + 1) selected" } ?? ""
      summaryLabel.stringValue = "\(values.count) points\(selection)"
    }

    override var payload: JSONValue { .object(["values": .array(values.map(JSONValue.number))]) }
  }
#endif
