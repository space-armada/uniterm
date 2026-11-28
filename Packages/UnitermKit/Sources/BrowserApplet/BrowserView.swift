import AppKit
import AppletKit
import Theme
import WebKit

/// The browser pane's own view: a toolbar with back, forward, and reload buttons and an address
/// bar, above the page.
///
/// The view holds no browsing state. The applet tells it what to show, and it reports what the user
/// did.
@MainActor
final class BrowserView: NSView, NSTextFieldDelegate {
  let backButton = BrowserView.makeButton(
    symbol: "chevron.left", label: "Back", identifier: "browser-back")
  let forwardButton = BrowserView.makeButton(
    symbol: "chevron.right", label: "Forward", identifier: "browser-forward")
  let reloadButton = BrowserView.makeButton(
    symbol: "arrow.clockwise", label: "Reload", identifier: "browser-reload")
  let addressField = NSTextField()

  /// Warns that the page is not fully secure. While hidden it takes no room in the toolbar.
  let securityIcon = NSImageView()

  /// The profile every browser pane shows. There is one store, so every pane shows the default
  /// profile. The button opens a popover that names it. The popover has no controls, since a second
  /// profile is a decision for the user.
  static let profileName = "Default Profile"
  let profileButton = BrowserView.makeButton(
    symbol: "person.crop.circle", label: "Profile: \(BrowserView.profileName)",
    identifier: "browser-profile")
  let profilePopover = ProfilePopover(profileName: BrowserView.profileName)

  var onBack: () -> Void = {}
  var onForward: () -> Void = {}
  var onReload: () -> Void = {}

  /// The user pressed Return in the address bar with this text.
  var onSubmit: (String) -> Void = { _ in }

  /// Covers the page when the tab could not load one. It sits above whichever web view shows.
  let errorPage = BrowserErrorView()

  /// Shows one JavaScript dialog over the page, inside the pane.
  let dialogView = BrowserDialogView()

  /// The user chose Load over HTTP on the error page.
  var onLoadOverHTTP: () -> Void = {}

  /// The strip of tabs above the toolbar. The applet hides it while it has one tab.
  let tabBar = AppletTabBar()

  /// The strip that holds the controls. It is a plain view around the stack, since a stack view's own
  /// vertical edge insets sit at a priority just under its hugging priority, so the stack ignores
  /// them and shrinks to the field's height. Here the padding is a required constraint.
  let toolbar = NSView()
  private static let verticalPadding: CGFloat = 6
  private static let horizontalPadding: CGFloat = 8
  private let controls = NSStackView()
  private var tabBarHeight: NSLayoutConstraint?
  private var controlsTrailing: NSLayoutConstraint?

  /// How far in from the trailing edge the host's control badge reaches. The tab bar and the
  /// toolbar's trailing button stay clear of it.
  var badgeReach: CGFloat = 0 {
    didSet {
      tabBar.trailingReserve = badgeReach
      controlsTrailing?.constant = -(Self.horizontalPadding + badgeReach)
    }
  }

  private var page: NSView?
  private var palette = ThemePalette.latte
  private(set) var addressIsInvalid = false

  /// What the address bar shows when the user is not editing it.
  private var shownAddress = ""

  override init(frame: NSRect) {
    super.init(frame: frame)

    wantsLayer = true

    addressField.placeholderString = "Enter address"
    addressField.bezelStyle = .roundedBezel
    addressField.lineBreakMode = .byTruncatingTail
    addressField.usesSingleLineMode = true
    addressField.delegate = self
    addressField.setAccessibilityIdentifier("browser-address")
    addressField.setAccessibilityLabel("Address")
    addressField.setContentHuggingPriority(.defaultLow, for: .horizontal)

    securityIcon.image = NSImage(
      systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Not secure")
    securityIcon.setAccessibilityIdentifier("browser-security")
    securityIcon.setAccessibilityLabel("Not secure")
    securityIcon.setAccessibilityHelp("This page is not fully secure.")
    securityIcon.setAccessibilityElement(true)
    securityIcon.setAccessibilityRole(.image)
    securityIcon.toolTip = "Not secure"
    securityIcon.isHidden = true
    securityIcon.setContentHuggingPriority(.required, for: .horizontal)

    profileButton.target = self
    profileButton.action = #selector(showProfile)
    profileButton.setContentHuggingPriority(.required, for: .horizontal)

    backButton.target = self
    backButton.action = #selector(back)
    forwardButton.target = self
    forwardButton.action = #selector(forward)
    reloadButton.target = self
    reloadButton.action = #selector(reload)

    controls.orientation = .horizontal
    controls.alignment = .centerY
    controls.spacing = 6
    controls.setViews(
      [backButton, forwardButton, reloadButton, securityIcon, addressField, profileButton],
      in: .leading)
    controls.setHuggingPriority(.required, for: .vertical)
    controls.setClippingResistancePriority(.required, for: .vertical)
    controls.translatesAutoresizingMaskIntoConstraints = false

    toolbar.addSubview(controls)
    toolbar.translatesAutoresizingMaskIntoConstraints = false
    toolbar.setAccessibilityElement(true)
    toolbar.setAccessibilityRole(.group)
    toolbar.setAccessibilityIdentifier("browser-toolbar")

    tabBar.translatesAutoresizingMaskIntoConstraints = false
    tabBar.isHidden = true

    dialogView.translatesAutoresizingMaskIntoConstraints = false

    errorPage.translatesAutoresizingMaskIntoConstraints = false
    errorPage.onLoadOverHTTP = { [weak self] in self?.onLoadOverHTTP() }
    errorPage.onReload = { [weak self] in self?.onReload() }

    addSubview(tabBar)
    addSubview(toolbar)

    let height = tabBar.heightAnchor.constraint(equalToConstant: 0)
    tabBarHeight = height

    let controlsEdge = controls.trailingAnchor.constraint(
      equalTo: toolbar.trailingAnchor, constant: -Self.horizontalPadding)

    controlsTrailing = controlsEdge

    NSLayoutConstraint.activate([
      tabBar.topAnchor.constraint(equalTo: topAnchor),
      tabBar.leadingAnchor.constraint(equalTo: leadingAnchor),
      tabBar.trailingAnchor.constraint(equalTo: trailingAnchor),
      height,
      toolbar.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
      toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
      toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
      controls.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: Self.verticalPadding),
      controls.bottomAnchor.constraint(
        equalTo: toolbar.bottomAnchor, constant: -Self.verticalPadding),
      controls.leadingAnchor.constraint(
        equalTo: toolbar.leadingAnchor, constant: Self.horizontalPadding),
      controlsEdge,
    ])

    setAccessibilityIdentifier("browser")
    setAccessibilityElement(true)
    setAccessibilityRole(.group)

    apply(palette)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }

  /// A pane too short for the toolbar keeps the toolbar whole and lets the page run off the bottom.
  /// The page's bottom edge yields for that reason, and the toolbar's padding never does.
  private static func yielding(_ constraint: NSLayoutConstraint) -> NSLayoutConstraint {
    constraint.priority = NSLayoutConstraint.Priority(999)
    return constraint
  }

  /// Puts `webView` below the toolbar.
  func show(page webView: NSView) {
    page?.removeFromSuperview()
    page = webView

    webView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(webView)

    NSLayoutConstraint.activate([
      webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
      webView.leadingAnchor.constraint(equalTo: leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: trailingAnchor),
      webView.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
      Self.yielding(webView.bottomAnchor.constraint(equalTo: bottomAnchor)),
    ])

    errorPage.removeFromSuperview()
    addSubview(errorPage, positioned: .above, relativeTo: webView)

    NSLayoutConstraint.activate([
      errorPage.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
      errorPage.leadingAnchor.constraint(equalTo: leadingAnchor),
      errorPage.trailingAnchor.constraint(equalTo: trailingAnchor),
      errorPage.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
      Self.yielding(errorPage.bottomAnchor.constraint(equalTo: bottomAnchor)),
    ])

    dialogView.removeFromSuperview()
    addSubview(dialogView, positioned: .above, relativeTo: errorPage)

    NSLayoutConstraint.activate([
      dialogView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
      dialogView.leadingAnchor.constraint(equalTo: leadingAnchor),
      dialogView.trailingAnchor.constraint(equalTo: trailingAnchor),
      dialogView.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
      Self.yielding(dialogView.bottomAnchor.constraint(equalTo: bottomAnchor)),
    ])
  }

  /// Covers the page with what went wrong, or uncovers it.
  func show(error: LoadErrorPage?) {
    errorPage.show(error)
  }

  /// Shows one item for each tab. The bar takes no room while the shared rule hides it.
  func show(tabs: [AppletTab], selected: Int) {
    tabBar.update(tabs: tabs, selected: selected, canOpenTab: true)
    tabBarHeight?.constant =
      AppletTabList.barShows(forTabCount: tabs.count) ? AppletTabBar.height : 0
  }

  func show(canGoBack: Bool, canGoForward: Bool, isLoading: Bool) {
    backButton.isEnabled = canGoBack
    forwardButton.isEnabled = canGoForward

    reloadButton.toolTip = isLoading ? "Reload, loading" : "Reload"
  }

  func show(securityWarning: Bool) {
    securityIcon.isHidden = !securityWarning
  }

  /// Shows `address` unless the user is typing in the bar. A page that finishes loading while the
  /// user edits must not overwrite the edit. A switch to another tab drops the edit, since the
  /// text belonged to the tab the user left.
  func show(address: String, replacingEdit: Bool = false) {
    shownAddress = address

    guard replacingEdit || !isEditingAddress else { return }

    addressField.stringValue = address

    if replacingEdit { markAddress(invalid: false) }
  }

  func focusAddress() {
    window?.makeFirstResponder(addressField)
    addressField.selectText(nil)
  }

  /// Marks the typed text as an address the browser refused. Any edit clears the mark.
  func markAddress(invalid: Bool) {
    addressIsInvalid = invalid

    addressField.textColor = invalid ? palette[.red].nsColor : palette[.text].nsColor
    addressField.setAccessibilityLabel(invalid ? "Address, invalid" : "Address")
    addressField.setAccessibilityHelp(invalid ? "This address cannot be loaded." : nil)
  }

  func apply(_ palette: ThemePalette) {
    self.palette = palette

    appearance = NSAppearance(named: palette.flavor.isDark ? .darkAqua : .aqua)
    layer?.backgroundColor = palette[.base].cgColor
    tabBar.apply(palette)
    errorPage.apply(palette)
    dialogView.apply(palette)
    addressField.textColor = addressIsInvalid ? palette[.red].nsColor : palette[.text].nsColor
    securityIcon.contentTintColor = palette[.yellow].nsColor
    profileButton.contentTintColor = palette[.subtext0].nsColor
    profilePopover.apply(palette)
  }

  var isEditingAddress: Bool {
    guard let editor = addressField.currentEditor() else { return false }

    return window?.firstResponder === editor
  }

  // MARK: Actions

  @objc private func back() { onBack() }
  @objc private func forward() { onForward() }
  @objc private func reload() { onReload() }
  @objc private func showProfile() { profilePopover.toggle(relativeTo: profileButton) }

  func control(
    _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
  ) -> Bool {
    switch selector {
    case #selector(NSResponder.insertNewline(_:)):
      onSubmit(addressField.stringValue)
      return true

    case #selector(NSResponder.cancelOperation(_:)):
      addressField.stringValue = shownAddress
      markAddress(invalid: false)
      window?.makeFirstResponder(page)
      return true

    default:
      return false
    }
  }

  func controlTextDidChange(_ notification: Notification) {
    if addressIsInvalid { markAddress(invalid: false) }
  }

  private static func makeButton(symbol: String, label: String, identifier: String) -> NSButton {
    let button = NSButton(
      image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(),
      target: nil, action: nil)

    button.bezelStyle = .texturedRounded
    button.isBordered = false
    button.toolTip = label
    button.setAccessibilityLabel(label)
    button.setAccessibilityIdentifier(identifier)
    button.refusesFirstResponder = true

    return button
  }
}
