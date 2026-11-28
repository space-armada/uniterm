import AppKit
import AppletKit

#if DEBUG
  /// Speaker notes. A driver sets or clears them, and each change is an event.
  @MainActor
  public final class NotesFixture: FixtureApplet, AppletCommandHandling {
    public nonisolated static let typeID = "fixture-notes"

    public nonisolated static let schema = AppletCommandSchema(
      appletType: typeID, version: AppletSchemaVersion(0, 0),
      commands: [
        AppletMessageSchema(
          name: "set-notes", summary: "Replaces the notes.",
          arguments: AppletObjectSchema(["text": .init(.string(maxBytes: 4096))]),
          example: .object(["text": .string("Mention the deadline.")])),
        AppletMessageSchema(name: "clear", summary: "Removes the notes."),
        AppletMessageSchema(
          name: "wait-for-notes",
          summary: "Replies once the notes contain the text. It changes nothing, so it may wait.",
          arguments: AppletObjectSchema(["contains": .init(.string(maxBytes: 4096))]),
          example: .object(["contains": .string("deadline")]), mayWait: true),
      ],
      events: [
        AppletMessageSchema(
          name: "notes-shown", summary: "The notes changed.",
          arguments: AppletObjectSchema([
            "length": .init(.integer(minimum: 0, maximum: 4096)),
            "empty": .init(.boolean, required: false, since: 1),
          ])),
        AppletMessageSchema(name: "notes-acknowledged", summary: "The user pressed Done."),
        AppletMessageSchema(
          name: "notes-cleared", summary: "The notes were removed. Added in minor 1.",
          arguments: AppletObjectSchema([
            "length": .init(.integer(minimum: 0, maximum: 4096)),
            "previous-length": .init(
              .integer(minimum: 0, maximum: 4096), required: false, since: 1),
          ]),
          since: 1),
      ])

    public private(set) var text = ""
    private var previousLength = 0

    /// The replies still waiting for the notes to contain their text.
    private var waiters: [(contains: String, reply: PendingReply)] = []

    /// How many waiting commands the dispatcher failed before the notes held their text.
    public private(set) var cancelledWaits = 0

    public var waitingCount: Int { waiters.count }
    private var textLabel: NSTextField!

    public init() {
      super.init(typeID: Self.typeID, title: "Notes fixture", buttonTitle: "Done")
      configure()
    }

    public init(restoring description: AppletDescription) throws {
      let fields = try Self.object(of: description, type: Self.typeID)

      super.init(typeID: Self.typeID, title: "Notes fixture", buttonTitle: "Done")

      if case .string(let saved)? = fields["text"] { text = saved }

      configure()
    }

    private func configure() {
      textLabel = label("text")
      addButton()
      refresh()
    }

    /// The version the fixture claims, so a test can stand in for a later minor of the same major.
    public var schemaVersion = NotesFixture.schema.version

    /// False stands in for an applet that forgot to mark its waiting command.
    public var declaresWaits = true

    public var commandSchema: AppletCommandSchema {
      let commands = Self.schema.commands.map { command in
        AppletMessageSchema(
          name: command.name, summary: command.summary, arguments: command.arguments,
          example: command.example, mayWait: declaresWaits && command.mayWait)
      }

      return AppletCommandSchema(
        appletType: Self.typeID, version: schemaVersion, commands: commands,
        events: Self.schema.events)
    }

    public func perform(_ command: ValidatedAppletCommand) throws(AppletCommandError)
      -> AppletCommandReply
    {
      switch command.name {
      case "wait-for-notes":
        guard case .string(let wanted)? = command.arguments["contains"] else {
          throw AppletCommandError(.badArgument, "the text to wait for is missing")
        }

        let answer: JSONValue = .object(["length": .number(Double(text.utf8.count))])

        guard !text.contains(wanted) else { return .immediate(answer) }

        let reply = PendingReply()

        waiters.append((wanted, reply))
        reply.onCancel = { [weak self, weak reply] in
          guard let self, let reply else { return }

          waiters.removeAll { $0.reply === reply }
          cancelledWaits += 1
        }

        return .pending(reply)

      case "set-notes":
        guard case .string(let value)? = command.arguments["text"] else {
          throw AppletCommandError(.badArgument, "the text is missing")
        }

        text = value

      case "clear":
        previousLength = text.utf8.count
        text = ""

      default:
        throw AppletCommandError(.unknownCommand, "the notes fixture has no \(command.name)")
      }

      refresh()
      events.emit(
        "notes-shown",
        .object(["length": .number(Double(text.utf8.count)), "empty": .bool(text.isEmpty)]))

      if command.name == "clear" {
        events.emit(
          "notes-cleared",
          .object(["length": .number(0), "previous-length": .number(Double(previousLength))]))
      }

      let answer: JSONValue = .object(["length": .number(Double(text.utf8.count))])
      let ready = waiters.filter { text.contains($0.contains) }

      waiters.removeAll { waiter in ready.contains { $0.reply === waiter.reply } }

      for waiter in ready { waiter.reply.complete(answer) }

      return .immediate(answer)
    }

    override func userPressedButton() {
      events.emit("notes-acknowledged")
    }

    private func refresh() {
      textLabel.stringValue = text.isEmpty ? "No notes" : text
    }

    override var payload: JSONValue { .object(["text": .string(text)]) }
  }
#endif
