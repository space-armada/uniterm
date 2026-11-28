import AppKit
import AppletKit
import Theme

/// The pane's view: the tab bar above the selected tab's form, while two or more questions are
/// open. With one question the form takes the whole pane. With none, the pane says why it is
/// empty. It never sits blank.
@MainActor
final class QuestionsView: NSView {
  let tabBar = AppletTabBar()
  private var tabBarHeight: NSLayoutConstraint?

  private let emptyTitle = NSTextField(wrappingLabelWithString: "No questions are open")
  private let emptyDetail = NSTextField(
    wrappingLabelWithString:
      "When a program asks you a question, it appears here, in a tab of its own.")
  private let emptyState = NSStackView()
  private var panel: NSView?
  private var palette = ThemePalette.latte

  /// How far in from the trailing edge the host's control badge reaches. The tab bar stays clear.
  var badgeReach: CGFloat = 0 {
    didSet { tabBar.trailingReserve = badgeReach }
  }

  override var acceptsFirstResponder: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)

    wantsLayer = true

    tabBar.translatesAutoresizingMaskIntoConstraints = false
    addSubview(tabBar)

    emptyTitle.font = NSFont.preferredFont(forTextStyle: .title3)
    emptyTitle.alignment = .center
    emptyTitle.setAccessibilityIdentifier("questions-empty-title")
    emptyDetail.font = NSFont.preferredFont(forTextStyle: .callout)
    emptyDetail.alignment = .center
    emptyDetail.setAccessibilityIdentifier("questions-empty-detail")

    emptyState.orientation = .vertical
    emptyState.alignment = .centerX
    emptyState.spacing = 6
    emptyState.addArrangedSubview(emptyTitle)
    emptyState.addArrangedSubview(emptyDetail)
    emptyState.translatesAutoresizingMaskIntoConstraints = false
    addSubview(emptyState)

    let barHeight = tabBar.heightAnchor.constraint(equalToConstant: 0)
    tabBarHeight = barHeight

    NSLayoutConstraint.activate([
      barHeight,
      tabBar.topAnchor.constraint(equalTo: topAnchor),
      tabBar.leadingAnchor.constraint(equalTo: leadingAnchor),
      tabBar.trailingAnchor.constraint(equalTo: trailingAnchor),
      emptyState.centerXAnchor.constraint(equalTo: centerXAnchor),
      emptyState.centerYAnchor.constraint(equalTo: centerYAnchor),
      emptyState.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
      emptyState.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
    ])

    setAccessibilityIdentifier("questions-applet")
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Questions")

    apply(palette)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  /// Shows the tabs, and the selected tab's form below them. The bar takes no room while the
  /// shared rule hides it. A nil form shows the empty state.
  func show(tabs: [AppletTab], selected: Int, panel newPanel: NSView?) {
    tabBar.update(tabs: tabs, selected: selected, canOpenTab: false)
    tabBarHeight?.constant =
      AppletTabList.barShows(forTabCount: tabs.count) ? AppletTabBar.height : 0

    if panel !== newPanel {
      panel?.removeFromSuperview()
      panel = newPanel

      if let newPanel {
        newPanel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(newPanel, positioned: .below, relativeTo: tabBar)

        NSLayoutConstraint.activate([
          newPanel.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
          newPanel.leadingAnchor.constraint(equalTo: leadingAnchor),
          newPanel.trailingAnchor.constraint(equalTo: trailingAnchor),
          newPanel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
      }
    }

    emptyState.isHidden = newPanel != nil
  }

  func apply(_ palette: ThemePalette) {
    self.palette = palette

    appearance = NSAppearance(named: palette.flavor.isDark ? .darkAqua : .aqua)
    layer?.backgroundColor = palette[.base].cgColor
    emptyTitle.textColor = palette[.text].nsColor
    emptyDetail.textColor = palette[.subtext1].nsColor
    tabBar.apply(palette)
  }
}
