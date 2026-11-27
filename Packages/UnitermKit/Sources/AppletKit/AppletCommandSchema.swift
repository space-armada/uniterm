import Foundation

/// The shape of one value an applet command or event carries. Shared dispatch checks a command's
/// arguments against it before the applet sees them, so an applet never handles a value it did not
/// declare.
public indirect enum AppletValueSchema: Sendable, Equatable {
  /// A string of at most `maxBytes` UTF-8 bytes.
  case string(maxBytes: Int)

  /// An absolute path of at most `maxBytes` UTF-8 bytes that a caller names and the host opens.
  ///
  /// The host opens the path inside the caller's read scope before the applet sees the command.
  /// The applet receives the opened file or folder in `ValidatedAppletCommand.opened`, never the
  /// path, and the argument itself reads as null. A caller with no path-reading power, or a path
  /// outside its scope, is refused before the applet runs.
  case path(maxBytes: Int)

  /// A whole number from `minimum` to `maximum`, both included.
  case integer(minimum: Int, maximum: Int)

  /// A finite number from `minimum` to `maximum`, both included.
  case number(minimum: Double, maximum: Double)

  case boolean

  /// A string that is one of the names listed.
  case choice([String])

  /// At most `maxCount` values of one shape.
  case array(of: AppletValueSchema, maxCount: Int)

  case object(AppletObjectSchema)
}

/// The fields of an object value. A field the schema does not name is refused, so a newer caller's
/// extra field is never silently ignored.
public struct AppletObjectSchema: Sendable, Equatable {
  public struct Field: Sendable, Equatable {
    public let schema: AppletValueSchema
    public let isRequired: Bool

    /// The minor version that added this field. An event field newer than a driver's minor is
    /// left out of the event the driver receives. A field added after the first minor is always
    /// optional, since an older driver never sends or reads it.
    public let addedInMinor: Int

    public init(_ schema: AppletValueSchema, required: Bool = true, since minor: Int = 0) {
      precondition(minor >= 0, "a field cannot be added before minor 0")
      precondition(!(required && minor > 0), "a field added after minor 0 must be optional")

      self.schema = schema
      isRequired = required
      addedInMinor = minor
    }
  }

  public let fields: [String: Field]

  public init(_ fields: [String: Field] = [:]) {
    self.fields = fields
  }

  public static let empty = AppletObjectSchema()
}

/// One command or event: its name, what it carries, and an example a driver author can copy.
public struct AppletMessageSchema: Sendable, Equatable {
  public let name: String
  public let summary: String
  public let arguments: AppletObjectSchema
  public let example: JSONValue

  /// True for a command that may answer with a pending reply. Only a command with no effect may
  /// wait, since a failed pending reply tells the caller that nothing ran. Dispatch fails a
  /// pending reply from any other command.
  public let mayWait: Bool

  /// The power a caller must hold for this command, on top of its control of the pane. Shared
  /// dispatch refuses the command without it, at submission and again at delivery. Nil needs
  /// none.
  public let permission: AppletCommandPermission?

  /// The minor version that added this command or event. An event newer than a driver's minor is
  /// never sent to that driver, since the driver could not know to ignore it.
  public let addedInMinor: Int

  public init(
    name: String, summary: String, arguments: AppletObjectSchema = .empty,
    example: JSONValue = .object([:]), mayWait: Bool = false,
    requires permission: AppletCommandPermission? = nil, since minor: Int = 0
  ) {
    precondition(minor >= 0, "a message cannot be added before minor 0")

    self.name = name
    self.summary = summary
    self.arguments = arguments
    self.example = example
    self.mayWait = mayWait
    self.permission = permission
    addedInMinor = minor
  }

  /// The event `data` as a caller written for `version` may receive it. Nil when the event came
  /// after that version's minor, so the caller never sees a message it cannot ignore. A field that
  /// came after it is dropped, and the rest of the event is kept.
  ///
  /// A caller written for another major is never sent anything, since a change of meaning is what
  /// bumps the major.
  public func event(
    _ data: [String: JSONValue], deliveredTo version: AppletSchemaVersion,
    of schema: AppletCommandSchema
  ) -> [String: JSONValue]? {
    guard version.major == schema.version.major, addedInMinor <= version.minor else { return nil }

    var kept = data

    for (name, field) in arguments.fields where field.addedInMinor > version.minor {
      kept.removeValue(forKey: name)
    }

    return kept
  }
}

/// A command schema version, as a major and a minor.
///
/// A schema is an external version. It is 0.0 and stays 0.0 until uniterm's maintainers declare it
/// 1.0. At 0.0 nothing bumps. A change lands in place, and a caller written for an older shape is
/// either read with its old meaning or refused, never read under a new meaning.
///
/// From 1.0 on, a new command or a new optional reply field bumps the minor. A change in meaning
/// or a removed command bumps the major. An applet accepts a caller written for its own major and
/// any minor up to its own, since a caller never uses what a later minor added.
public struct AppletSchemaVersion: Sendable, Hashable, CustomStringConvertible {
  public let major: Int
  public let minor: Int

  public init(_ major: Int, _ minor: Int = 0) {
    self.major = major
    self.minor = minor
  }

  /// True when an applet at this version takes a caller written for `requested`.
  public func accepts(_ requested: AppletSchemaVersion) -> Bool {
    requested.major == major && requested.minor <= minor
  }

  public var description: String { "\(major).\(minor)" }
}

/// The commands an applet type takes and the events it emits, under one schema version. A caller
/// names the type and the version it was written for, and a version the applet does not accept is
/// refused before any effect.
public struct AppletCommandSchema: Sendable, Equatable {
  public let appletType: String
  public let version: AppletSchemaVersion
  public let commands: [AppletMessageSchema]
  public let events: [AppletMessageSchema]

  public init(
    appletType: String, version: AppletSchemaVersion, commands: [AppletMessageSchema],
    events: [AppletMessageSchema]
  ) {
    self.appletType = appletType
    self.version = version
    self.commands = commands
    self.events = events
  }

  public func command(named name: String) -> AppletMessageSchema? {
    commands.first { $0.name == name }
  }

  public func event(named name: String) -> AppletMessageSchema? {
    events.first { $0.name == name }
  }
}

/// Why a command did not run. The code lets a caller tell its own mistake from a refusal. The
/// message is for a person, and never names a pane other than the target.
public struct AppletCommandError: Error, Sendable, Equatable {
  public enum Code: String, Sendable, Equatable, CaseIterable {
    /// The target pane runs another applet type than the command names.
    case unsupportedApplet = "unsupported-applet"

    /// The target applet does not speak the schema version the command names.
    case unsupportedVersion = "unsupported-version"

    case unknownCommand = "unknown-command"
    case badArgument = "bad-argument"

    /// The caller may not command the target now, or the target takes no commands.
    case refused

    /// The target is not open.
    case notFound = "not-found"

    /// Too many commands wait for the target. Nothing was dropped: this one was refused whole.
    case busy

    /// The applet failed while it ran the command, and changed nothing.
    case failed

    /// The caller does not hold the power the command needs.
    case permissionMissing = "permission-missing"

    /// The command names a tab the caller did not open.
    case notOwned = "not-owned"
  }

  public let code: Code
  public let message: String

  public init(_ code: Code, _ message: String) {
    self.code = code
    self.message = message
  }
}

extension AppletValueSchema {
  /// Throws a bad-argument error that names the path to the first value that does not fit.
  public func validate(_ value: JSONValue, at path: String) throws(AppletCommandError) {
    switch (self, value) {
    case (.string(let maxBytes), .string(let text)):
      guard text.utf8.count <= maxBytes else {
        throw AppletCommandError(
          .badArgument, "\(path) is \(text.utf8.count) bytes, and the most is \(maxBytes)")
      }

    case (.integer(let minimum, let maximum), .number(let number)):
      guard number.isFinite, number == number.rounded(), number >= Double(minimum),
        number <= Double(maximum)
      else {
        throw AppletCommandError(
          .badArgument, "\(path) must be a whole number from \(minimum) to \(maximum)")
      }

    case (.number(let minimum, let maximum), .number(let number)):
      guard number.isFinite, number >= minimum, number <= maximum else {
        throw AppletCommandError(
          .badArgument, "\(path) must be a number from \(minimum) to \(maximum)")
      }

    case (.path(let maxBytes), .string(let text)):
      guard text.utf8.count <= maxBytes else {
        throw AppletCommandError(
          .badArgument, "\(path) is \(text.utf8.count) bytes, and the most is \(maxBytes)")
      }

      guard text.hasPrefix("/"), !text.utf8.contains(0) else {
        throw AppletCommandError(.badArgument, "\(path) must be an absolute path")
      }

    case (.boolean, .bool):
      return

    case (.choice(let names), .string(let text)):
      guard names.contains(text) else {
        throw AppletCommandError(
          .badArgument, "\(path) must be one of \(names.joined(separator: ", "))")
      }

    case (.array(let element, let maxCount), .array(let values)):
      guard values.count <= maxCount else {
        throw AppletCommandError(
          .badArgument, "\(path) holds \(values.count) values, and the most is \(maxCount)")
      }

      for (index, value) in values.enumerated() {
        try element.validate(value, at: "\(path)[\(index)]")
      }

    case (.object(let schema), .object(let fields)):
      try schema.validate(fields, at: path)

    default:
      throw AppletCommandError(.badArgument, "\(path) must be \(kindName)")
    }
  }

  private var kindName: String {
    switch self {
    case .string: return "a string"
    case .path: return "a path"
    case .integer: return "a whole number"
    case .number: return "a number"
    case .boolean: return "true or false"
    case .choice: return "a string"
    case .array: return "an array"
    case .object: return "an object"
    }
  }
}

extension AppletValueSchema {
  /// Every path-typed value in `value`, by the name of the argument it sits at. A value that does
  /// not fit the schema is left to `validate`, so this lists only what fits.
  func collectPaths(
    in value: JSONValue, at name: String, into found: inout [(name: String, path: String)]
  ) {
    switch (self, value) {
    case (.path, .string(let text)):
      found.append((name, text))

    case (.array(let element, _), .array(let values)):
      for (index, value) in values.enumerated() {
        element.collectPaths(in: value, at: "\(name)[\(index)]", into: &found)
      }

    case (.object(let schema), .object(let fields)):
      schema.collectPaths(in: fields, at: name, into: &found)

    default:
      return
    }
  }

  /// `value` with every path-typed value replaced by null. The applet never sees a raw path.
  func strippingPaths(from value: JSONValue) -> JSONValue {
    switch (self, value) {
    case (.path, .string):
      return .null

    case (.array(let element, _), .array(let values)):
      return .array(values.map { element.strippingPaths(from: $0) })

    case (.object(let schema), .object(let fields)):
      return .object(schema.strippingPaths(from: fields))

    default:
      return value
    }
  }
}

extension AppletObjectSchema {
  func collectPaths(
    in value: [String: JSONValue], at name: String,
    into found: inout [(name: String, path: String)]
  ) {
    for (key, field) in fields.sorted(by: { $0.key < $1.key }) {
      guard let fieldValue = value[key] else { continue }

      field.schema.collectPaths(
        in: fieldValue, at: name.isEmpty ? key : "\(name).\(key)", into: &found)
    }
  }

  func strippingPaths(from value: [String: JSONValue]) -> [String: JSONValue] {
    var result = value

    for (key, field) in fields {
      guard let fieldValue = value[key] else { continue }

      result[key] = field.schema.strippingPaths(from: fieldValue)
    }

    return result
  }

  /// Checks every field. A field the schema does not name, or a required one that is missing, is a
  /// bad argument.
  public func validate(_ value: [String: JSONValue], at path: String) throws(AppletCommandError) {
    for key in value.keys.sorted() where fields[key] == nil {
      throw AppletCommandError(.badArgument, "\(path) has no field \"\(key)\"")
    }

    for (key, field) in fields.sorted(by: { $0.key < $1.key }) {
      guard let fieldValue = value[key] else {
        if field.isRequired {
          throw AppletCommandError(.badArgument, "\(path) needs the field \"\(key)\"")
        }

        continue
      }

      try field.schema.validate(fieldValue, at: "\(path).\(key)")
    }
  }
}
