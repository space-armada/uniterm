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

  /// The tabs a controller acts for, each with the names the host gives its controllers. A tab is
  /// here while a controller bound to its session passes the checks its commands pass. The owner
  /// set and this travel in one value, so a change of control never shows one current and the other
  /// stale.
  public var controlling: [AppletTabID: [String]]

  /// The names of the exec drivers attached to the pane. A driver is bound to the pane, not to a
  /// tab, so a one-tab applet shows its chip on its one tab, and the host draws it at the pane
  /// level when a bar shows.
  public var drivers: [String]

  public init(
    owners: Set<AppletCaller> = [], controlling: [AppletTabID: [String]] = [:],
    drivers: [String] = []
  ) {
    self.owners = owners
    self.controlling = controlling
    self.drivers = drivers
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

  /// The chip for the tab, or nil when no controller acts for it.
  public func chip(forTab id: AppletTabID) -> AppletMarker? {
    guard let names = controlling[id], !names.isEmpty else { return nil }

    return AppletMarker(kind: .chip, controllers: names)
  }

  /// The tab with its chip set or cleared. An applet whose tabs hold sessions applies it to each.
  public func applyingChip(to tab: AppletTab) -> AppletTab {
    var tab = tab

    if let marker = chip(forTab: tab.id) {
      tab.markers.insert(marker)
    } else {
      tab.markers.remove(.chip)
    }

    return tab
  }

  /// The tab with its authority marker and its chip set or cleared for a one-tab applet. The chip
  /// names the controllers bound to the tab and the pane's drivers.
  public func applyingOneTabMarker(to tab: AppletTab) -> AppletTab {
    var tab = tab

    let names = (controlling[tab.id] ?? []) + drivers

    if names.isEmpty {
      tab.markers.remove(.chip)
    } else {
      tab.markers.insert(AppletMarker(kind: .chip, controllers: names))
    }

    if let marker = oneTabMarker {
      tab.markers.insert(marker)
    } else {
      tab.markers.remove(.authority)
    }

    return tab
  }
}
