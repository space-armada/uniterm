import AppKit
import AppletKit
import Darwin
import SourceAccess

#if DEBUG
  /// A viewer that reads files a controller names. A file command takes a path and answers with
  /// the file's text. A folder command takes a folder and opens every member through the host's
  /// checked open, as a slideshow source does. The applet never sees a path, only what the host
  /// opened for it.
  @MainActor
  public final class PathsFixture: FixtureApplet, AppletCommandHandling, UserFileSourcing {
    public nonisolated static let typeID = "fixture-paths"

    public nonisolated static let schema = AppletCommandSchema(
      appletType: typeID, version: AppletSchemaVersion(0, 0),
      commands: [
        AppletMessageSchema(
          name: "read-file", summary: "Reads a file and answers with its text.",
          arguments: AppletObjectSchema(["path": .init(.path(maxBytes: 1024))]),
          example: .object(["path": .string("/Users/me/notes/a.txt")])),
        AppletMessageSchema(
          name: "read-files", summary: "Reads several files, in order.",
          arguments: AppletObjectSchema([
            "paths": .init(.array(of: .path(maxBytes: 1024), maxCount: 8))
          ]),
          example: .object(["paths": .array([.string("/Users/me/notes/a.txt")])])),
        AppletMessageSchema(
          name: "read-folder",
          summary: "Reads every member of a folder. It changes nothing, so it may wait.",
          arguments: AppletObjectSchema(["path": .init(.path(maxBytes: 1024))]),
          example: .object(["path": .string("/Users/me/notes")]), mayWait: true),
        AppletMessageSchema(
          name: "seen", summary: "Answers with what the last command carried."),
      ],
      events: [])

    /// The arguments the last command carried, which never hold a path.
    public private(set) var lastArguments: [String: JSONValue] = [:]

    /// The path the pane shows, which a test sets to stand for a source the user opened.
    public var userFileSource: String?

    public init() {
      super.init(typeID: Self.typeID, title: "Paths fixture", buttonTitle: "Go")
    }

    public var commandSchema: AppletCommandSchema { Self.schema }

    public func perform(_ command: ValidatedAppletCommand) throws(AppletCommandError)
      -> AppletCommandReply
    {
      lastArguments = command.arguments

      switch command.name {
      case "read-file":
        guard let opened = command.opened["path"] else {
          throw AppletCommandError(.failed, "the host opened no file")
        }

        return .immediate(.object(["text": .string(try text(of: opened))]))

      case "read-files":
        let names = command.opened.keys.sorted { Self.index($0) < Self.index($1) }

        var texts: [JSONValue] = []

        for name in names { texts.append(.string(try text(of: command.opened[name]!))) }

        return .immediate(.object(["texts": .array(texts)]))

      case "read-folder":
        guard let folder = command.opened["path"], case .folder = folder.kind else {
          throw AppletCommandError(.badArgument, "that is not a folder")
        }

        // Listing and opening members read the disk, so they run off the main thread and the
        // reply waits for them.
        let reply = PendingReply()

        Task { @MainActor in
          var read: [JSONValue] = []
          var refused: [JSONValue] = []

          for name in await folder.memberNames() {
            switch await folder.openMember(named: name) {
            case .success(let member):
              if case .file = member.kind { read.append(.string(name)) }

            case .failure:
              refused.append(.string(name))
            }
          }

          reply.complete(.object(["read": .array(read), "refused": .array(refused)]))
        }

        return .pending(reply)

      case "seen":
        return .immediate(.object(["arguments": .object(lastArguments)]))

      default:
        throw AppletCommandError(.unknownCommand, "the paths fixture has no \(command.name)")
      }
    }

    private static func index(_ name: String) -> Int {
      Int(name.dropFirst("paths[".count).dropLast()) ?? 0
    }

    private func text(of opened: OpenedPath) throws(AppletCommandError) -> String {
      guard case .file(let info) = opened.kind else {
        throw AppletCommandError(.badArgument, "that is not a file")
      }

      switch RegularFile.read(
        descriptor: opened.fileDescriptor, path: "file", size: info.size, limit: 1 << 20)
      {
      case .success(let data): return String(decoding: data, as: UTF8.self)
      case .failure: throw AppletCommandError(.failed, "the file could not be read")
      }
    }
  }
#endif
