import AppKit
import AppletKit
import PaneModel
import StatusKit

/// Where the focus moves, from a given pane.
enum PaneFocusMove {
  case next
  case previous
  case toward(Direction)
}

// MARK: Dispatch

extension MainWindowController {
  /// The context for a command that nothing in particular aimed. While the palette shows, the
  /// target is the pane that had focus before it. Otherwise it is the focused pane. This is the
  /// one place where the focused pane is read to build a context.
  func commandContext() -> CommandContext {
    CommandContext(controller: self, pane: paletteTarget ?? paneArea.focusedPane)
  }

  /// Runs a command the way a key binding or a menu item asks for it. While the palette shows, the
  /// palette's rules apply: its toggle and Cmd-W only dismiss it, and any other command dismisses
  /// it first and then runs on the pane that had focus before it.
  public func dispatch(_ id: CommandID) {
    switch PaletteDispatch.rule(for: id, paletteShown: isPaletteVisible) {
    case .run:
      commands.run(id, in: commandContext())

    case .dismissOnly:
      hideCommandPalette(restoringFocus: true)

    case .dismissThenRun:
      let context = commandContext()
      hideCommandPalette(restoringFocus: true)
      commands.run(id, in: context)
    }
  }

  func postPaneGone(for title: String) {
    statusCenter.post(
      level: .warning,
      text:
        "\u{201C}\(title)\u{201D} did not run, because the pane it was aimed at has closed. "
        + "Focus a pane and try again."
    )
  }

  /// The command's own check gives no reason, so the message cannot give one either.
  func postCommandUnavailable(for title: String) {
    statusCenter.post(
      level: .warning,
      text: "\u{201C}\(title)\u{201D} did not run, because it is not available now.")
  }
}

// MARK: Actions

extension MainWindowController {
  /// The type of the applet the commands act on: the palette's target pane while it shows, else
  /// the focused pane. The menus show that applet's items.
  var activeAppletTypeID: String? {
    commandContext().pane.flatMap { paneArea.applet(for: $0)?.typeID }
  }

  func moveFocus(_ move: PaneFocusMove, from pane: NodeID?) {
    guard paneActionsEnabled, let pane else { return }

    let target: NodeID?

    switch move {
    case .next: target = paneArea.pane(after: pane)
    case .previous: target = paneArea.pane(before: pane)
    case .toward(let direction): target = paneArea.neighbor(of: pane, toward: direction)
    }

    if let target {
      paneArea.focus(target)
    }
  }

  /// Asks the pane's applet to close its current tab. Only an applet with no tab to close lets the
  /// pane close, and then the window asks as usual when something is running. A tab running
  /// something asks first, and the applet does the asking.
  ///
  /// The request starts at once and returns when the applet has to wait for an answer. The pane
  /// is looked up again after the answer, since it may have closed meanwhile.
  func closeTabOrPane(_ pane: NodeID?) {
    guard paneActionsEnabled, let pane, let applet = paneArea.applet(for: pane) else { return }

    Task.immediate { @MainActor [weak self, weak applet] in
      guard let applet, await applet.closeCurrentTab() == .nothingToClose, let self,
        paneArea.applet(for: pane) === applet
      else { return }

      closePane(pane, appletEnded: false)
    }
  }

  func toggleHistory() {
    setHistoryVisible(!historyVisible)
  }
}
