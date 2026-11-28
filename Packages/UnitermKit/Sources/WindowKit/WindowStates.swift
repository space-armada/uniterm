import Foundation

/// A kind of state that belongs to the window, not to the focused pane. The cases are in the order
/// the status bar shows them, and that order is fixed.
///
/// The window shows one slot for each active kind, after the message area and before the focused
/// applet's segments. A feature that owns one of these conditions fills its kind when the
/// condition starts and clears it when the condition ends.
public enum WindowStateKind: Int, CaseIterable, Comparable, Sendable {
  /// Another instance owns the layout, so this window's panes are not saved.
  case layoutNotSaved

  /// A program asked for permissions that the user has not answered.
  case pendingPermissions

  /// uniterm has suspended at least one controller. A click lists them, each with Resume.
  case suspendedControllers

  /// Work that outlives a closed pane is still running, as the applet lifecycle requires to be
  /// visible.
  case survivingWork

  public static func < (lhs: WindowStateKind, rhs: WindowStateKind) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  /// The compact symbol the slot shows.
  var symbolName: String {
    switch self {
    case .layoutNotSaved: return "externaldrive.badge.xmark"
    case .pendingPermissions: return "lock.shield"
    case .suspendedControllers: return "pause.circle"
    case .survivingWork: return "hourglass"
    }
  }

  /// The name of the kind, for the accessibility identifier.
  var identifier: String {
    switch self {
    case .layoutNotSaved: return "layout-not-saved"
    case .pendingPermissions: return "pending-permissions"
    case .suspendedControllers: return "suspended-controllers"
    case .survivingWork: return "surviving-work"
    }
  }

  /// The command a click on the slot runs. A slot without one leaves the click to the bar, which
  /// toggles the history.
  var command: CommandID? {
    switch self {
    case .pendingPermissions: return .showPendingRequests
    case .suspendedControllers: return .showSuspendedControllers
    case .layoutNotSaved, .survivingWork: return nil
    }
  }
}

/// The window states that hold now. Each has the full sentence that its slot shows as a tooltip
/// and reads aloud. A state may also carry a short label that the slot shows beside its icon.
///
/// This is runtime state of the app. It never enters the layout file.
public struct WindowStates: Sendable, Equatable {
  private struct Entry: Sendable, Equatable {
    var text: String
    var label: String?
  }

  private var entries: [WindowStateKind: Entry] = [:]

  public init() {}

  /// The kinds that hold, in the fixed order, with their sentences and labels.
  public var active: [(kind: WindowStateKind, text: String, label: String?)] {
    WindowStateKind.allCases.compactMap { kind in
      entries[kind].map { (kind, $0.text, $0.label) }
    }
  }

  public var isEmpty: Bool { entries.isEmpty }

  /// Marks `kind` as holding, described by `text`. A `label` shows beside the slot's icon. Without
  /// one, the slot is an icon alone. A second call replaces both.
  public mutating func set(_ kind: WindowStateKind, text: String, label: String? = nil) {
    entries[kind] = Entry(text: text, label: label)
  }

  public mutating func clear(_ kind: WindowStateKind) {
    entries[kind] = nil
  }

  public func text(of kind: WindowStateKind) -> String? {
    entries[kind]?.text
  }

  public func label(of kind: WindowStateKind) -> String? {
    entries[kind]?.label
  }
}
