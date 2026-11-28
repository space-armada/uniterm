import Foundation

/// What the host tells an applet about who can act on its pane.
///
/// The host computes it with the checks the command path runs, so a marker never states authority
/// the commands would refuse. It is a value, so a later kind of host knowledge joins it without a
/// new call.
public struct PaneAuthority: Sendable, Equatable {
  /// The grants whose commands the pane would accept now. It is empty while remote control is off,
  /// while no controller is connected, and for an applet that takes neither commands nor sent
  /// content.
  public var owners: Set<AppletCaller>

  public init(owners: Set<AppletCaller> = []) {
    self.owners = owners
  }

  public static let none = PaneAuthority()

  /// The authority marker for a one-tab applet, or nil when no grant can act on it. An applet whose
  /// tabs belong to grants marks a tab with `marker(forTabOwnedBy:)` instead.
  public var oneTabMarker: AppletMarker? {
    owners.isEmpty ? nil : AppletMarker(kind: .authority, owners: owners)
  }

  /// The authority marker for a tab owned by this grant, or nil when the grant cannot act on the
  /// pane now.
  public func marker(forTabOwnedBy owner: AppletCaller?) -> AppletMarker? {
    guard let owner, owners.contains(owner) else { return nil }

    return AppletMarker(kind: .authority, owners: [owner])
  }

  /// The tab with its authority marker set or cleared for a one-tab applet.
  public func applyingOneTabMarker(to tab: AppletTab) -> AppletTab {
    var tab = tab

    if let marker = oneTabMarker {
      tab.markers.insert(marker)
    } else {
      tab.markers.remove(.authority)
    }

    return tab
  }
}
