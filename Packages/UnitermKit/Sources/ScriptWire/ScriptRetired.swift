import Foundation

/// The message tags and call tags that ScriptWire retired while it stays at version 0.
///
/// A change of meaning never reuses a tag. The changed message or call takes a new tag, and its old
/// tag is added here with its old name. A decoder then refuses the old tag by name, and a program
/// that still sends it is told it is out of date.
///
/// A positional field has no name, so a field whose meaning changes cannot be retired by name. Its
/// message takes a new tag instead, and the old tag is retired.
public struct ScriptRetiredNames: Equatable, Sendable {
  public enum Sender: Equatable, Sendable {
    case helper
    case app
  }

  public struct Message: Equatable, Sendable {
    public let sender: Sender
    public let tag: UInt8
    public let name: String

    public init(sender: Sender, tag: UInt8, name: String) {
      self.sender = sender
      self.tag = tag
      self.name = name
    }
  }

  public struct Call: Equatable, Sendable {
    public let tag: UInt16
    public let name: String

    public init(tag: UInt16, name: String) {
      self.tag = tag
      self.name = name
    }
  }

  public var messages: [Message]
  public var calls: [Call]

  public init(messages: [Message] = [], calls: [Call] = []) {
    self.messages = messages
    self.calls = calls
  }

  /// The names this build retired. The list starts empty.
  public static let current = ScriptRetiredNames()

  /// What to do when a program and this uniterm disagree. It never picks a side by comparing
  /// numbers, since a program from before the reset names a version above this one.
  public static let advice =
    "Rebuild the program against this uniterm, or update uniterm if the program is the newer one."

  func refusal(messageTag tag: UInt8, from sender: Sender) -> WireError {
    let sentBy = sender == .helper ? "program" : "uniterm"

    if let retired = messages.first(where: { $0.sender == sender && $0.tag == tag }) {
      return .notRecognized(
        "The \(sentBy) sent the message \"\(retired.name)\" (tag \(tag)), which this ScriptWire "
          + "retired. \(Self.advice)")
    }

    return .notRecognized(
      "The \(sentBy) sent a message with tag \(tag), which this ScriptWire does not know. "
        + Self.advice)
  }

  func refusal(callTag tag: UInt16) -> WireError {
    if let retired = calls.first(where: { $0.tag == tag }) {
      return .notRecognized(
        "The program sent the call \"\(retired.name)\" (tag \(tag)), which this ScriptWire "
          + "retired. \(Self.advice)")
    }

    return .notRecognized(
      "The program sent a call with tag \(tag), which this ScriptWire does not know. "
        + Self.advice)
  }

  /// A fixed-form field that holds a value this build does not know, such as an enumerated byte.
  static func unknownValue(
    _ what: String, _ value: some CustomStringConvertible, from sender: Sender = .helper
  ) -> WireError {
    let sentBy = sender == .helper ? "program" : "uniterm"

    return .notRecognized(
      "The \(sentBy) sent \(what) \(value), which this ScriptWire does not know. \(advice)")
  }

  static func trailingBytes(in message: String, from sender: Sender) -> WireError {
    let sentBy = sender == .helper ? "program" : "uniterm"

    return .notRecognized(
      "The \(sentBy) sent a \(message) message with bytes after its last field, which this "
        + "ScriptWire does not read. \(advice)")
  }
}

/// What to show for a failed read. A message or value this build does not know carries its own
/// text, which names it and says what to do. Any other failure is named by its case.
public func scriptWireText(_ error: any Error) -> String {
  if case WireError.notRecognized(let text) = error { return text }

  return "\(error)"
}
