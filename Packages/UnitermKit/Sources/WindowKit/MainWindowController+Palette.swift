import AppKit
import AppletKit
import PaneModel

/// A tab in a pane of this window.
struct PaletteTabKey: Hashable {
  var pane: NodeID
  var tab: AppletTabID
}

// MARK: Command palette

extension MainWindowController {
  func wireCommandPalette() {
    let palette = contentController.commandPalette

    palette.onQueryChange = { [weak self] _ in self?.refreshCommandPalette() }
    palette.onChoose = { [weak self] entry in self?.choose(entry) }
    palette.onDismiss = { [weak self] in self?.hideCommandPalette(restoringFocus: true) }
    palette.onActivate = { [weak self] in self?.showCommandPalette() }
    refreshPaletteHotkeyHint()
  }

  /// Activates the palette and gives its field the keyboard. A floating palette shows first. A
  /// docked one is always on show and takes the keyboard only now. The pane that has focus now
  /// becomes the target of every command the palette runs.
  ///
  /// The empty-query order is read here, after the focused tab is recorded, so it reflects
  /// recency at this moment.
  func showCommandPalette() {
    guard !isPaletteVisible, paneActionsEnabled, let window else { return }

    let palette = contentController.commandPalette

    paletteTarget = paneArea.focusedPane
    recordFocusedTab()
    palette.reset()
    palette.setActive(true)
    refreshCommandPalette()

    window.makeFirstResponder(palette.field)

    // Cmd-Z in the field undoes the field's edit, never a pane close. The field editor only
    // records edits to undo when it is told to.
    (palette.field.currentEditor() as? NSTextView)?.allowsUndo = true
  }

  /// Hides a floating palette, or deactivates a docked one. A docked palette stays on show with an
  /// empty field. When `restoringFocus` is set, the keyboard returns to the pane that had it
  /// before the palette showed, or to the window's focused pane when that one is gone.
  ///
  /// The keyboard moves only when the palette still holds it. A sheet, the applet chooser, or a
  /// window that a command opened may have taken it, and hiding the palette never takes it back.
  func hideCommandPalette(restoringFocus: Bool) {
    guard let target = paletteTarget, let window else { return }

    let palette = contentController.commandPalette
    let holdsKeyboard = Self.holdsKeyboard(palette, in: window)

    paletteTarget = nil

    if holdsKeyboard {
      window.makeFirstResponder(nil)
    }

    palette.setActive(false)
    palette.reset()
    refreshPaletteHotkeyHint()

    guard restoringFocus, holdsKeyboard, window.attachedSheet == nil else { return }

    let pane = paneArea.applet(for: target) == nil ? paneArea.focusedPane : target
    paneArea.focus(pane)
  }

  private static func holdsKeyboard(_ palette: NSView, in window: NSWindow) -> Bool {
    guard let responder = window.firstResponder else { return true }

    if responder === window { return true }

    return (responder as? NSView)?.isDescendant(of: palette) == true
  }

  /// Sorts the list afresh for the current text and the current state of the window. Only the
  /// user's own edits call it: showing the palette, typing, and choosing a filter.
  func refreshCommandPalette() {
    guard let target = paletteTarget else { return }

    let palette = contentController.commandPalette

    palette.setEntries(
      PaletteListing.entries(
        paletteCandidates(target: target), query: palette.query, filter: palette.filter,
        appletTypes: appletTypes.map(PaletteAppletType.init)))
  }

  /// Brings the rows on show up to date without moving any of them. A change the user did not
  /// cause, such as a retitled tab, a pane that opens or closes, or a new layout, calls it.
  ///
  /// A row takes its entry's current title and state where it stands. A row whose tab or pane is
  /// gone stays, and choosing it says so. Nothing new is listed until the user types. A list that
  /// moved under the pointer would run whatever row slid there.
  func updateCommandPaletteInPlace() {
    guard let target = paletteTarget else { return }

    let palette = contentController.commandPalette
    let current = paletteCandidates(target: target).map(\.entry)

    palette.updateEntriesInPlace(PaletteListing.updatedInPlace(palette.entries, from: current))
  }

  /// Every tab and every command the palette can list, in their natural order, before any query
  /// or filter.
  private func paletteCandidates(target: NodeID) -> [PaletteCandidate] {
    let context = CommandContext(controller: self, pane: target)
    var candidates = tabCandidates(target: target)

    for command in commands.commands where command.listedInPalette {
      var appletName: String?

      if case .applet(let typeID) = command.owner {
        appletName = appletTypes.first { $0.typeID == typeID }?.displayName
      }

      let entry = PaletteEntry(
        id: .command(command.id), kind: .command, title: command.title, appletName: appletName,
        symbolName: PaletteEntry.commandSymbol, detail: nil,
        isEnabled: commands.isAvailable(command.id, in: context))

      candidates.append(
        PaletteCandidate(
          entry: entry, recencyRank: commands.recency.firstIndex(of: command.id),
          order: candidates.count))
    }

    return candidates
  }

  /// Moves the focused pane's selected tab to the front of the recent tabs.
  func recordFocusedTab() {
    let pane = paneArea.focusedPane

    guard let applet = paneArea.applet(for: pane) else { return }

    let key = PaletteTabKey(pane: pane, tab: applet.publishedTabs.selected)

    guard tabRecency.first != key else { return }

    tabRecency.removeAll { $0 == key }
    tabRecency.insert(key, at: 0)

    if tabRecency.count > Self.maximumRecentTabs {
      tabRecency.removeLast(tabRecency.count - Self.maximumRecentTabs)
    }
  }

  /// One entry for each tab of each pane, in tree order. The tree is the only source, so a pane
  /// that closed takes its tabs with it.
  private func tabCandidates(target: NodeID) -> [PaletteCandidate] {
    var entries: [(key: PaletteTabKey, entry: PaletteEntry)] = []

    for pane in paneArea.tree.paneIDs {
      guard let applet = paneArea.applet(for: pane) else { continue }

      let list = applet.publishedTabs
      let type = appletTypes.first { $0.typeID == applet.typeID }

      for tab in list.all {
        let title = PaletteText.neutralized(tab.title)
        let detail = PaletteText.neutralized(tab.details.joined(separator: " "))

        let entry = PaletteEntry(
          id: .tab(pane: pane, tab: tab.id), kind: .tab,
          title: title.isEmpty ? "Untitled" : title, appletName: type?.displayName,
          symbolName: type?.symbolName, appletTypeID: applet.typeID,
          detail: detail.isEmpty ? nil : detail,
          isEnabled: true, isCurrent: pane == target && tab.id == list.selected)

        entries.append((PaletteTabKey(pane: pane, tab: tab.id), entry))
      }
    }

    let live = Set(entries.map(\.key))
    tabRecency.removeAll { !live.contains($0) }

    return entries.enumerated().map { order, item in
      PaletteCandidate(
        entry: item.entry, recencyRank: tabRecency.firstIndex(of: item.key), order: order)
    }
  }

  /// Updates the rows in place after a short wait, so a burst of title changes costs one pass.
  func schedulePaletteRefresh() {
    guard isPaletteVisible, !paletteRefreshPending else { return }

    paletteRefreshPending = true

    paletteWake(Self.paletteRefreshInterval) { [weak self] in
      guard let self else { return }

      paletteRefreshPending = false
      updateCommandPaletteInPlace()
    }
  }

  /// Runs the entry the user chose. The palette hides and gives the keyboard back first, so a
  /// launcher, a sheet, or a window that the command opens ends up holding it.
  ///
  /// A command that can no longer run leaves the palette up with its row dimmed in place, and
  /// says so. That is checked before the palette hides, because hiding first would leave the user
  /// with nothing to retry from. A gone pane still hides, and the registry says why.
  private func choose(_ entry: PaletteEntry) {
    guard let target = paletteTarget else { return }

    switch entry.id {
    case .command(let id):
      let context = CommandContext(controller: self, pane: target)

      guard commands.isAvailable(id, in: context) else {
        updateCommandPaletteInPlace()
        postCommandUnavailable(for: entry.title)
        return
      }

      hideCommandPalette(restoringFocus: true)

      // Giving the keyboard back moves focus, which a command's check may read. A refusal here is
      // rare, but it is never silent.
      if commands.attempt(id, in: context) == .unavailable {
        postCommandUnavailable(for: entry.title)
      }

    case .tab(let pane, let tab):
      chooseTab(pane: pane, tab: tab, title: entry.title)

    // The palette view acts on its own filter rows, and a notice does nothing.
    case .filterKeyword, .filter, .notice:
      break
    }
  }

  /// Focuses the pane and selects the tab, both by ID. A tab that is gone, or that the applet
  /// refuses to select, leaves the palette up with its row in place, and says so. The palette hides
  /// without taking the keyboard back, so the chosen tab ends up holding it.
  private func chooseTab(pane: NodeID, tab: AppletTabID, title: String) {
    guard let applet = paneArea.applet(for: pane), applet.publishedTabs.contains(tab),
      applet.selectTab(id: tab)
    else {
      updateCommandPaletteInPlace()
      postTabGone(for: title)
      return
    }

    hideCommandPalette(restoringFocus: false)
    paneArea.focus(pane)
  }

  private func postTabGone(for title: String) {
    statusCenter.post(
      level: .warning,
      text: "\u{201C}\(title)\u{201D} has closed.")
  }

  /// A mouse press outside the palette's field and results hides it, or deactivates a docked one.
  /// The press then goes to what it hit, even a terminal that reports the mouse to its program. The
  /// window calls this before it handles the event.
  ///
  /// Returns whether the press hid the palette.
  func paletteWillHandleMouseDown(_ event: NSEvent) -> Bool {
    guard isPaletteVisible, event.window === window else { return false }

    let palette = contentController.commandPalette

    guard !palette.contains(windowPoint: event.locationInWindow) else { return false }

    hideCommandPalette(restoringFocus: false)
    return true
  }

  /// A press that hid the palette may land on something that takes no keyboard, such as the status
  /// bar. The keyboard then returns to the window's focused pane, so keys do not go nowhere.
  func paletteDidHandleMouseDown() {
    guard let window, !isPaletteVisible, window.attachedSheet == nil else { return }

    if window.firstResponder == nil || window.firstResponder === window {
      paneArea.focus(paneArea.focusedPane)
    }
  }
}

// MARK: Docking

extension MainWindowController {
  /// Applies a changed mode or edge. An active palette deactivates first and returns the keyboard
  /// to the pane that had it, so a switch never leaves the field holding a keyboard it was moved
  /// out from under. The palette starts the new placement inactive.
  func paletteSettingsDidChange(to value: PalettePlacement.Value) {
    if isPaletteVisible {
      hideCommandPalette(restoringFocus: true)
    }

    contentController.setPalette(value)
    refreshPaletteHotkeyHint()
  }

  /// Reads the key of the "Show Command Palette" menu item as it is now, so a user's App Shortcuts
  /// remap shows in the docked placeholder.
  func refreshPaletteHotkeyHint() {
    let live = commands.menu?.keyEquivalent(of: .showCommandPalette)

    contentController.commandPalette.setHotkeyHint(
      live.flatMap { KeyEquivalentText.spell(key: $0.key, modifiers: $0.modifiers) })
  }

  public func windowDidBecomeKey(_ notification: Notification) {
    onBecomeKey?(self)
    refreshPaletteHotkeyHint()
  }
}
