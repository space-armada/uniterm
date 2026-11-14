import AppKit
import XCTest

/// Drives the browser in the launched app. Each test proves a contract that needs the real window
/// server: the launcher entry, a pane restored from a saved layout by its description type, and the
/// keys that reach the browser's tabs through the menu.
///
/// The tab bar exposes each tab as `tab-N` with the value `selected` or `unselected`, as the
/// terminal's does.
///
/// No test loads a page from the network. A restored `about:blank` is the one address that loads
/// without a server.
@MainActor
final class BrowserUITests: UnitermUITestCase {
  private func plantBrowser(payload: String, version: Int = 1) throws {
    try plantLayout(
      """
      {"version":1,"windows":[{"frame":{"x":100,"y":100,"width":900,"height":600},"highWaterMark":1,
      "tree":{"kind":"pane","id":1,"applet":{"type":"browser","version":\(version),
      "payload":\(payload)}}}]}
      """)
  }

  private func browser(in window: XCUIElement) -> XCUIElement {
    window.descendants(matching: .any)["browser"]
  }

  private func addressField(in window: XCUIElement) -> XCUIElement {
    window.descendants(matching: .any)["browser-address"]
  }

  private func tab(_ index: Int, in window: XCUIElement) -> XCUIElement {
    window.descendants(matching: .any)["tab-\(index)"]
  }

  private func waitForGone(_ element: XCUIElement, timeout: TimeInterval = 15) -> Bool {
    let gone = NSPredicate(format: "exists == false")
    return XCTWaiter().wait(
      for: [XCTNSPredicateExpectation(predicate: gone, object: element)], timeout: timeout)
      == .completed
  }

  private func isSelected(_ element: XCUIElement) -> Bool {
    waitFor(element, timeout: 10) { $0 == "selected" }
  }

  /// Opens a browser pane from the launcher and waits for it.
  private func openBrowser(in app: XCUIApplication) -> XCUIElement {
    let window = mainWindow(in: app)
    _ = waitForTerminal(in: app)

    app.typeKey("d", modifierFlags: .command)
    XCTAssertTrue(launcher(in: window).waitForExistence(timeout: 5))

    app.typeKey("5", modifierFlags: .command)
    app.typeKey(.return, modifierFlags: [])

    XCTAssertTrue(waitUntilGone(launcher(in: window)))
    XCTAssertTrue(browser(in: window).waitForExistence(timeout: 10), "no browser pane")

    return window
  }

  /// Catches a launcher without the browser, a row that opens something else, and a new browser
  /// pane with no toolbar. Cmd-D shows the launcher, Cmd-5 picks the browser, and Return opens it.
  /// The pane shows its buttons and an empty address bar, with back and forward off.
  func testLauncherOpensABrowserWithItsToolbar() throws {
    let app = launchApp()
    let window = mainWindow(in: app)
    _ = waitForTerminal(in: app)

    app.typeKey("d", modifierFlags: .command)
    XCTAssertTrue(launcher(in: window).waitForExistence(timeout: 5))
    XCTAssertTrue(
      window.descendants(matching: .any)["launcher-browser"].waitForExistence(timeout: 5),
      "the launcher has no browser row")

    app.typeKey("5", modifierFlags: .command)
    app.typeKey(.return, modifierFlags: [])

    XCTAssertTrue(waitUntilGone(launcher(in: window)))
    XCTAssertTrue(browser(in: window).waitForExistence(timeout: 10), "no browser pane")

    let toolbar = browser(in: window)

    XCTAssertTrue(toolbar.buttons["browser-back"].exists)
    XCTAssertTrue(toolbar.buttons["browser-forward"].exists)
    XCTAssertTrue(toolbar.buttons["browser-reload"].exists)
    XCTAssertFalse(toolbar.buttons["browser-back"].isEnabled)
    XCTAssertFalse(toolbar.buttons["browser-forward"].isEnabled)
    XCTAssertEqual(addressField(in: window).value as? String ?? "", "")
  }

  /// Catches a restore that does not pick the browser by its description type, which would show a
  /// placeholder. A planted layout holds a browser at `about:blank`, and the pane comes back as a
  /// browser with an empty address bar. Only this layer proves that the host's restorer maps the
  /// type to the browser applet. The package tests build the applet directly and never reach it.
  func testALayoutWithABrowserRestoresABrowserPane() throws {
    try plantBrowser(payload: #"{"tabs":[{"url":"about:blank","title":"Notes"}],"selected":0}"#)

    let app = launchApp()
    let window = mainWindow(in: app)

    XCTAssertTrue(browser(in: window).waitForExistence(timeout: 15), "no browser pane restored")
    XCTAssertTrue(addressField(in: window).exists)
    XCTAssertEqual(addressField(in: window).value as? String ?? "", "")
  }

  /// Catches a description from a newer build restored as a browser, which would drop its fields.
  /// The window opens and holds no browser pane. Whether the layout keeps the bytes is the layout
  /// tests' to prove.
  func testADescriptionFromANewerVersionIsNotRestoredAsABrowser() throws {
    try plantBrowser(payload: #"{"tabs":[{"url":"about:blank"}],"selected":0}"#, version: 2)

    let app = launchApp()
    let window = mainWindow(in: app)

    XCTAssertTrue(window.waitForExistence(timeout: 15))
    XCTAssertFalse(browser(in: window).waitForExistence(timeout: 3))
  }

  /// Catches a tab bar that shows for one tab, and tab keys that do not reach the browser through
  /// the menu. A new pane has no bar. Cmd-T adds a tab and selects it. Ctrl-Shift-Tab and Ctrl-Tab
  /// step through the tabs, Cmd-1 and Cmd-2 pick one, and Cmd-9 picks the last.
  func testTheTabKeysOpenAndSwitchBrowserTabs() {
    let app = launchApp()
    let window = openBrowser(in: app)

    XCTAssertFalse(tab(0, in: window).exists, "a single tab showed the bar")

    app.typeKey("t", modifierFlags: .command)

    XCTAssertTrue(tab(1, in: window).waitForExistence(timeout: 10), "Cmd-T opened no tab")
    XCTAssertTrue(isSelected(tab(1, in: window)))

    app.typeKey(.tab, modifierFlags: [.control, .shift])
    XCTAssertTrue(isSelected(tab(0, in: window)), "Ctrl-Shift-Tab did not go back")

    app.typeKey(.tab, modifierFlags: .control)
    XCTAssertTrue(isSelected(tab(1, in: window)), "Ctrl-Tab did not go forward")

    app.typeKey("1", modifierFlags: .command)
    XCTAssertTrue(isSelected(tab(0, in: window)), "Cmd-1 did not pick the first tab")

    app.typeKey("9", modifierFlags: .command)
    XCTAssertTrue(isSelected(tab(1, in: window)), "Cmd-9 did not pick the last tab")
  }

  /// Catches Cmd-W that closes the pane while the browser has several tabs, and a reopen that loses
  /// the tab. Cmd-W closes the current tab and hides the bar again. Cmd-Shift-T brings the tab back.
  func testCommandWClosesTheTabAndCommandShiftTReopensIt() {
    let app = launchApp()
    let window = openBrowser(in: app)

    app.typeKey("t", modifierFlags: .command)
    XCTAssertTrue(tab(1, in: window).waitForExistence(timeout: 10))

    app.typeKey("w", modifierFlags: .command)

    XCTAssertTrue(waitForGone(tab(1, in: window)), "Cmd-W left the second tab")
    XCTAssertTrue(waitForGone(tab(0, in: window)), "the bar stayed with one tab")
    XCTAssertTrue(browser(in: window).exists, "Cmd-W closed the pane")

    app.typeKey("t", modifierFlags: [.command, .shift])

    XCTAssertTrue(tab(1, in: window).waitForExistence(timeout: 10), "Cmd-Shift-T brought no tab")
    XCTAssertTrue(isSelected(tab(1, in: window)))
  }

  /// Catches Cmd-L that does not reach the address bar. After Cmd-T moves the keyboard to the new
  /// tab's bar, Cmd-L still focuses it, and typed text lands there.
  func testCommandLFocusesTheAddressBar() {
    let app = launchApp()
    let window = openBrowser(in: app)

    app.typeKey("t", modifierFlags: .command)
    XCTAssertTrue(tab(1, in: window).waitForExistence(timeout: 10))

    app.typeKey("l", modifierFlags: .command)
    app.typeText("about:blank")

    XCTAssertTrue(
      waitFor(addressField(in: window), timeout: 10) { $0 == "about:blank" },
      "Cmd-L did not focus the address bar")
  }

  /// Catches a Settings window with no search engine row, or a stored engine that left the list
  /// showing as the default with no word about it. The seeded value is not an engine. The row
  /// selects DuckDuckGo and says the stored one was replaced, and choosing an engine clears that.
  func testSettingsShowsAStoredSearchEngineThatLeftTheListAsReplaced() {
    let app = launchApp(settings: ["searchEngine": "altavista"])
    XCTAssertTrue(app.windows["main-window"].waitForExistence(timeout: 10))

    app.typeKey(",", modifierFlags: .command)
    let settings = app.windows["settings-window"]
    XCTAssertTrue(settings.waitForExistence(timeout: 5))

    let control = settings.radioGroups["search-engine-control"]
    XCTAssertTrue(control.waitForExistence(timeout: 5))
    XCTAssertEqual(control.radioButtons.count, 5)
    XCTAssertEqual(control.radioButtons["DuckDuckGo"].value as? Int, 1)

    let note = settings.staticTexts["search-engine-control-note"]
    XCTAssertTrue(note.waitForExistence(timeout: 5), "no note about the replaced engine")
    XCTAssertTrue((note.value as? String ?? "").contains("altavista"))
    XCTAssertTrue((note.value as? String ?? "").contains("DuckDuckGo"))

    control.radioButtons["Kagi"].click()

    XCTAssertTrue(waitForGone(note), "the note stayed after a valid choice")
    XCTAssertEqual(control.radioButtons["Kagi"].value as? Int, 1)
  }

  /// Catches a browser pane that hides which profile it uses. Every pane shows a profile button at
  /// the end of its toolbar. Clicking it shows a popover that names the default profile, and Escape
  /// dismisses it. The user confirms where the button sits in a hands-on review.
  func testEveryBrowserPaneShowsItsProfile() {
    let app = launchApp()
    let window = openBrowser(in: app)
    let button = window.descendants(matching: .any)["browser-profile"]
    let name = app.descendants(matching: .any)["browser-profile-name"]

    XCTAssertTrue(button.waitForExistence(timeout: 10), "the pane shows no profile button")
    XCTAssertEqual(button.label, "Profile: Default Profile")
    XCTAssertFalse(name.exists, "the profile popover shows before the click")

    button.click()

    XCTAssertTrue(name.waitForExistence(timeout: 5), "the click shows no profile name")
    XCTAssertEqual(name.value as? String, "Default Profile")

    app.typeKey(.escape, modifierFlags: [])

    XCTAssertTrue(waitForGone(name, timeout: 5), "Escape does not dismiss the profile popover")
  }

  /// Catches a toolbar that crowds its address field. The real window shows the toolbar at its full
  /// height with the field inside it and the page starting below. The test attaches a screenshot of
  /// the window, named "browser-toolbar", so the rendering can be read from the result bundle.
  func testTheToolbarKeepsItsPaddingAndTheFieldIsNotClipped() {
    let app = launchApp()
    let window = openBrowser(in: app)
    let toolbar = window.descendants(matching: .any)["browser-toolbar"]
    let field = addressField(in: window)

    XCTAssertTrue(toolbar.waitForExistence(timeout: 10), "the pane has no toolbar")

    let attachment = XCTAttachment(screenshot: window.screenshot())

    attachment.name = "browser-toolbar"
    attachment.lifetime = .keepAlways
    add(attachment)

    let bar = toolbar.frame
    let entry = field.frame

    // Accessibility reports the field a point larger than its layout frame. `BrowserToolbarLayoutTests`
    // owns the exact padding, and the clipped toolbar this catches measured 0.
    XCTAssertGreaterThanOrEqual(entry.minY - bar.minY, 4, "no padding above the field")
    XCTAssertGreaterThanOrEqual(bar.maxY - entry.maxY, 4, "no padding below the field")
  }

  /// Catches a layout that restores every tab as the first one, or a selection that is lost. Three
  /// tabs are planted with the second selected. The bar shows all three and selects the second. No
  /// page loads from the network.
  func testALayoutWithSeveralTabsRestoresThemAndTheSelectedOne() throws {
    try plantBrowser(
      payload: """
        {"tabs":[{"url":"about:blank","title":"One"},{"url":"about:blank","title":"Two"},
        {"url":"about:blank","title":"Three"}],"selected":1}
        """)

    let app = launchApp()
    let window = mainWindow(in: app)

    XCTAssertTrue(browser(in: window).waitForExistence(timeout: 15), "no browser pane restored")
    XCTAssertTrue(tab(2, in: window).waitForExistence(timeout: 10), "the third tab is missing")
    XCTAssertTrue(isSelected(tab(1, in: window)), "the saved selection was lost")
    XCTAssertFalse(waitFor(tab(0, in: window), timeout: 1) { $0 == "selected" })
  }

  /// Catches a Settings window with no Clear Website Data action, a click that does nothing or
  /// reports nothing, and a note that leaves out what open tabs keep. The in-memory store of the UI
  /// tests makes the click safe. The status line says it cleared. Only this layer proves that the
  /// Settings window is wired to the browser's own store and to the window's status line. The
  /// package tests prove what clearing removes.
  func testSettingsClearsWebsiteDataAndSaysOpenTabsKeepTheirSession() {
    let app = launchApp()
    XCTAssertTrue(app.windows["main-window"].waitForExistence(timeout: 10))

    app.typeKey(",", modifierFlags: .command)
    let settings = app.windows["settings-window"]
    XCTAssertTrue(settings.waitForExistence(timeout: 5))

    let button = settings.buttons["clear-website-data-button"]
    XCTAssertTrue(button.waitForExistence(timeout: 5), "no Clear Website Data button")

    let note = settings.staticTexts["clear-website-data-note"]
    XCTAssertTrue(note.waitForExistence(timeout: 5))
    XCTAssertTrue((note.value as? String ?? "").contains("keep their current session"))

    button.click()

    let status = settings.staticTexts["clear-website-data-status"]

    XCTAssertTrue(status.waitForExistence(timeout: 10), "the click reported nothing")
    XCTAssertTrue(
      waitFor(status, timeout: 10) { $0.contains("Cleared") }, "the status never said cleared")
    XCTAssertTrue(button.isEnabled)
  }

  /// Catches a Browser menu with no Reveal Latest Download, and one that offers it with nothing
  /// downloaded. A new pane has no finished download, so the item is there and disabled. No UI test
  /// downloads a file, since that would write to the user's Downloads folder. The enabled case, the
  /// reveal, and a moved file are proved by the package tests with an injected folder and reveal.
  func testRevealLatestDownloadIsInTheBrowserMenuAndDisabledWithNoDownload() {
    let app = launchApp()
    _ = openBrowser(in: app)

    app.menuBars.menuBarItems["Browser"].click()

    let reveal = app.menuBars.menuItems["Reveal Latest Download"]

    XCTAssertTrue(reveal.waitForExistence(timeout: 5), "the Browser menu has no Reveal item")
    XCTAssertFalse(reveal.isEnabled, "Reveal was offered with nothing downloaded")

    app.typeKey(.escape, modifierFlags: [])
  }
}
