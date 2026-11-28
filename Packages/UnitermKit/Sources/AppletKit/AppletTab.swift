import Foundation

/// Names one tab of an applet for as long as the process runs.
///
/// An ID is never reused. It pairs a random number picked once per launch with a counter that only
/// grows, so an ID from an earlier launch never names a tab of this one. IDs are not saved. A
/// restored tab gets a new ID, and an old ID resolves to nothing.
public struct AppletTabID: Hashable, Sendable, CustomStringConvertible {
  public let epoch: UInt64
  public let serial: UInt64

  public init(epoch: UInt64, serial: UInt64) {
    self.epoch = epoch
    self.serial = serial
  }

  public var description: String { "\(String(epoch, radix: 16))-\(serial)" }

  /// The next ID of this launch.
  @MainActor
  public static func make() -> AppletTabID {
    shared.next()
  }

  @MainActor private static var shared = AppletTabIDSource(epoch: .random(in: .min ... .max))
}

/// Hands out IDs under one epoch. Tests use their own source to stand for a second launch.
public struct AppletTabIDSource: Sendable {
  public let epoch: UInt64
  private var counter: UInt64 = 0

  public init(epoch: UInt64) {
    self.epoch = epoch
  }

  public mutating func next() -> AppletTabID {
    counter += 1
    return AppletTabID(epoch: epoch, serial: counter)
  }
}

/// What an applet tells the host about one of its tabs.
public struct AppletTab: Sendable, Equatable, Identifiable {
  public var id: AppletTabID

  /// The tab's name. A program may set it, so the host treats it as untrusted text.
  public var title: String

  /// Extra text the tab is found by, such as a working directory. Also untrusted text.
  public var details: [String]

  /// What the tab shows beside its title: at most one marker of each kind. A tab without markers
  /// draws as a plain tab.
  public var markers: AppletMarkerSet

  public init(
    id: AppletTabID, title: String, details: [String] = [], markers: AppletMarkerSet = .init()
  ) {
    self.id = id
    self.title = title
    self.details = details
    self.markers = markers
  }
}

/// The tabs an applet publishes. It always holds at least one tab, so an applet cannot be left out
/// of the palette. An applet with nothing to switch between publishes one tab that stands for its
/// whole session.
public struct AppletTabList: Sendable, Equatable {
  public let first: AppletTab
  public let rest: [AppletTab]

  /// The selected tab's ID. It names a tab of this list.
  public let selected: AppletTabID

  /// `selected` that names no tab of the list falls back to the first tab.
  public init(first: AppletTab, rest: [AppletTab] = [], selected: AppletTabID? = nil) {
    self.first = first
    self.rest = rest

    if let selected, ([first] + rest).contains(where: { $0.id == selected }) {
      self.selected = selected
    } else {
      self.selected = first.id
    }
  }

  public var all: [AppletTab] { [first] + rest }

  /// True when a tab bar shows for this many tabs. Every applet with a bar follows it, and the host
  /// reads it to know whether the pane's one tab shows its markers at the pane level.
  public static func barShows(forTabCount count: Int) -> Bool {
    count >= 2
  }

  /// True when the applet's tab bar shows.
  public var showsBar: Bool { Self.barShows(forTabCount: all.count) }

  /// The tab that stands for the pane when no bar shows. Nil while a bar shows.
  public var paneLevelTab: AppletTab? { showsBar ? nil : first }

  public func contains(_ id: AppletTabID) -> Bool {
    all.contains { $0.id == id }
  }
}
