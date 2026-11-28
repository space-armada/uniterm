import AppKit
import AppletKit
import Theme

#if DEBUG
  /// A pane that publishes the run-end marker, so a UI test can capture the slashed gears. Nothing
  /// in the app publishes that kind yet. The fixture holds one tab, which carries the marker and
  /// shows it at the pane level, or two tabs under a tab bar, the second of which carries it.
  ///
  /// The payload's `tabs` is 1 or 2. It takes no commands, so no controller can mark it. It takes
  /// the keyboard itself, so a stray key never lands on the bar's close button and closes a tab.
  @MainActor
  public final class MarkedFixture: Applet {
    public nonisolated static let typeID = "fixture-marked"

    public var typeID: String { Self.typeID }
    public let view: NSView
    public let segments: [AppletSegment] = []
    public let isRunningSomething = false
    public weak var host: (any AppletHost)?
    public let publishedTabs: AppletTabList
    public let title = "Marked fixture"

    private let bar = AppletTabBar()
    private let tabCount: Int
    private let container = MarkedFixtureView()

    public init(tabs: Int = 1) {
      tabCount = tabs >= 2 ? 2 : 1

      let marker = AppletMarker(kind: .runEnded, actions: [.rebuildTab])
      let marked = AppletTab(id: .make(), title: "Spared run", markers: AppletMarkerSet([marker]))

      if tabCount == 2 {
        publishedTabs = AppletTabList(
          first: AppletTab(id: .make(), title: "Shell"), rest: [marked])
      } else {
        publishedTabs = AppletTabList(first: marked)
      }

      view = container
      container.bar = bar
      bar.update(tabs: publishedTabs.all, selected: 0, canOpenTab: false)
      container.addSubview(bar)
    }

    public convenience init(restoring description: AppletDescription) throws {
      guard description.type == Self.typeID else {
        throw AppletRestoreError.wrongType(expected: Self.typeID, found: description.type)
      }

      var tabs = 1

      if case .object(let fields) = description.payload, case .number(let count)? = fields["tabs"] {
        tabs = Int(count)
      }

      self.init(tabs: tabs)
    }

    public func start(origin: StartOrigin) {}

    public func close() {}

    public func focus() {
      container.window?.makeFirstResponder(container)
    }

    public func describe() -> AppletDescription {
      AppletDescription(
        type: Self.typeID, version: 1, payload: .object(["tabs": .number(Double(tabCount))]))
    }

    public func apply(_ palette: ThemePalette) {
      bar.apply(palette)
      view.wantsLayer = true
      view.layer?.backgroundColor = palette[.base].cgColor
    }
  }

  /// Puts the fixture's bar along the top, while it shows.
  @MainActor
  private final class MarkedFixtureView: NSView {
    var bar: AppletTabBar?

    override func layout() {
      super.layout()

      bar?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: AppletTabBar.height)
    }

    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { true }
  }
#endif
