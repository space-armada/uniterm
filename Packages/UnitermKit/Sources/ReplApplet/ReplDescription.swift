import AppletKit
import Foundation

/// The restorable state of a REPL applet.
///
/// It is inert. It holds the history as text for the line editor to recall, and nothing that
/// starts or evaluates anything. Restoring it starts a fresh helper, which is not the user's
/// program, and never runs a saved line.
public struct ReplDescription: Codable, Equatable, Sendable {
  /// The lines entered, oldest first. It is bounded as `ReplHistory` bounds it.
  public var history: [String]

  public init(history: [String]) {
    self.history = history
  }

  public static let typeID = "repl"

  /// The version of the payload this build reads and writes.
  public static let currentVersion = 1

  public func appletDescription() throws -> AppletDescription {
    AppletDescription(
      type: Self.typeID, version: Self.currentVersion, payload: try JSONValue(encoding: self))
  }

  /// Reads a description. A description of another type, a newer version, or a shape that does not
  /// decode is refused, and the caller keeps the original.
  public static func decode(_ description: AppletDescription) throws -> ReplDescription {
    guard description.type == typeID else {
      throw AppletRestoreError.wrongType(expected: typeID, found: description.type)
    }

    guard description.version <= currentVersion else {
      throw AppletRestoreError.newerVersion(found: description.version, supported: currentVersion)
    }

    do {
      return try description.payload.decoded(as: ReplDescription.self)
    } catch {
      throw AppletRestoreError.corrupt("REPL description: \(error)")
    }
  }
}
