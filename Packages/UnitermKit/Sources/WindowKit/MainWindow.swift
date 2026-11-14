import AppKit
import AppletKit

/// The window of one main window controller.
///
/// AppKit's own window answers the standard undo action by asking its undo manager, which is how a
/// text control being edited undoes its edit. That answer comes before the window controller in the
/// responder chain, so a controller method named for undo would never be reached. This window
/// answers the action itself. While a text control is being edited, it undoes the edit. Otherwise
/// a focused view that keeps its own undo manager, as a map does for its pin edits, undoes its own
/// last change. With neither, it does nothing, and the item is off.
///
/// The window is also uniterm's one key route. A key that matches a key equivalent in the live
/// menu goes to that menu item before any view in the window sees it. The menu is read live, so a
/// user's remap of an item in System Settings > Keyboard > App Shortcuts applies. A remap onto a
/// Control or Option chord therefore wins over a terminal that would take the key as input.
public final class MainWindow: NSWindow {
  /// Whether AppKit keeps the window on the screen it is shown on. Tests turn it off. Their frames
  /// come from screens they inject, and the display of the machine running them must not move a
  /// window that the injected screens place correctly.
  var constrainsFrameToScreen = true

  public override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    constrainsFrameToScreen ? super.constrainFrameRect(frameRect, to: screen) : frameRect
  }

  private var isEditingText: Bool {
    firstResponder is NSText
  }

  /// The undo manager of the field being edited. A field editor can keep its own, apart from the
  /// window's, and its edits are recorded there.
  private var editingUndoManager: UndoManager? {
    (firstResponder as? NSTextView)?.undoManager ?? undoManager
  }

  /// The undo manager a focused view keeps apart from the window's. A view that keeps none reports
  /// the window's own, which holds nothing undo should reach, so that counts as none.
  private var focusedViewUndoManager: UndoManager? {
    guard let manager = firstResponder?.undoManager, manager !== undoManager else { return nil }

    return manager
  }

  /// The undo manager Edit > Undo and Redo act on: the field being edited, else the focused
  /// view's own.
  private var activeUndoManager: UndoManager? {
    isEditingText ? editingUndoManager : focusedViewUndoManager
  }

  /// The target of Edit > Undo. The selector is the standard `undo:`, so the menu item keeps its
  /// place in the Edit menu and a text control gets the key when it has focus. It undoes a text
  /// edit, or a focused view's own edit. Reopening a closed tab or pane is a window command.
  @objc(undo:) public func undoEdit(_ sender: Any?) {
    activeUndoManager?.undo()
  }

  /// The target of Edit > Redo. Redo repeats an undone edit. Pane closes have no redo.
  @objc(redo:) public func redoEdit(_ sender: Any?) {
    activeUndoManager?.redo()
  }

  public override func validateMenuItem(_ item: NSMenuItem) -> Bool {
    switch item.action {
    case #selector(redoEdit(_:)):
      guard let manager = activeUndoManager else {
        item.title = "Redo"
        return false
      }

      item.title = manager.redoMenuItemTitle
      return manager.canRedo

    case #selector(undoEdit(_:)):
      guard let manager = activeUndoManager else {
        item.title = "Undo"
        return false
      }

      item.title = manager.undoMenuItemTitle
      return manager.canUndo

    default:
      return super.validateMenuItem(item)
    }
  }

  // MARK: Key route

  public override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if routeToMenu(event) {
      return true
    }

    return super.performKeyEquivalent(with: event)
  }

  /// Looks for a live menu item with the key, before any view in the window sees it. The menu is
  /// read live, so a user's remap applies, and a window command's key reaches the menu in every
  /// applet.
  ///
  /// The candidates go in order: a remapped item, then uniterm's own items, then an applet's. The
  /// first enabled one runs. A disabled item that is a remap or uniterm's own consumes the key, so
  /// the view never gets a key that is reserved. A disabled item of an applet lets the key go on,
  /// since an applet's key is not reserved.
  private func routeToMenu(_ event: NSEvent) -> Bool {
    guard event.type == .keyDown, let menu = NSApp.mainMenu else { return false }

    (windowController as? MainWindowController)?.commands.menu?.sync()

    for item in MenuKeyMatch.items(for: event, in: menu) {
      guard let parent = item.menu else { continue }

      parent.update()

      if item.isEnabled {
        parent.performActionForItem(at: parent.index(of: item))
        return true
      }

      if MenuKeyMatch.consumesWhenDisabled(item) {
        return true
      }
    }

    return false
  }

  // MARK: Mouse

  /// A press outside the floating palette hides it, and then goes to whatever it hit.
  public override func sendEvent(_ event: NSEvent) {
    switch event.type {
    case .leftMouseDown, .rightMouseDown, .otherMouseDown:
      let controller = windowController as? MainWindowController
      let hidPalette = controller?.paletteWillHandleMouseDown(event) ?? false

      super.sendEvent(event)

      if hidPalette {
        controller?.paletteDidHandleMouseDown()
      }

    default:
      super.sendEvent(event)
    }
  }
}

/// Finds the live menu items that a key event triggers.
enum MenuKeyMatch {
  /// The items whose key equivalent matches the event, best first. A user's remap goes before a
  /// default, so it wins whatever the menu order. Two remaps on one key resolve by one rule: a
  /// uniterm item before an applet's, then the one that comes first in the menu bar.
  @MainActor
  static func items(for event: NSEvent, in menu: NSMenu) -> [NSMenuItem] {
    var matches: [NSMenuItem] = []
    collect(event, in: menu, into: &matches)

    return matches.enumerated().sorted { lhs, rhs in
      let (left, right) = (rank(lhs.element), rank(rhs.element))

      return left == right ? lhs.offset < rhs.offset : left < right
    }.map(\.element)
  }

  /// Whether a user's App Shortcuts remap put the item's key there. AppKit owns the flag, so a test
  /// replaces this to stand in for a remap.
  @MainActor
  static var isRemapped: @MainActor (NSMenuItem) -> Bool = hasUserKeyEquivalent

  @MainActor
  static func hasUserKeyEquivalent(_ item: NSMenuItem) -> Bool {
    !item.userKeyEquivalent.isEmpty
  }

  @MainActor
  private static func rank(_ item: NSMenuItem) -> Int {
    (isRemapped(item) ? 0 : 2)
      + ((item as? CommandMenuItem)?.isAppletItem == true ? 1 : 0)
  }

  /// Whether the key stops at a disabled item. A remap always wins, and a key that is not an
  /// applet's default is reserved.
  @MainActor
  static func consumesWhenDisabled(_ item: NSMenuItem) -> Bool {
    isRemapped(item) || (item as? CommandMenuItem)?.isAppletItem != true
  }

  @MainActor
  private static func collect(_ event: NSEvent, in menu: NSMenu, into matches: inout [NSMenuItem]) {
    for item in menu.items {
      if let submenu = item.submenu {
        collect(event, in: submenu, into: &matches)
      }

      if triggers(item, event) {
        matches.append(item)
      }
    }
  }

  /// Whether a menu item's key equivalent matches a key event.
  @MainActor
  static func triggers(_ item: NSMenuItem, _ event: NSEvent) -> Bool {
    guard !item.isHidden, !item.keyEquivalent.isEmpty, !item.isSeparatorItem else { return false }

    return match(
      itemKey: item.keyEquivalent, itemMask: item.keyEquivalentModifierMask,
      eventChars: event.charactersIgnoringModifiers ?? "", eventMods: event.modifierFlags)
  }

  /// A key equivalent is compared by the key it types, in the canonical form of `KeyChord`. So
  /// Cmd-Shift-= matches an item whose key is "+", and Cmd-} matches Cmd-Shift-]. The Delete key
  /// sends 0x7F, and menus spell it 0x08.
  ///
  /// The `.function` flag has special handling. When the item's mask contains it, the event must
  /// contain it too. When the item's mask lacks it, the event's `.function` is ignored. This keeps
  /// window tiling items (Center is fn-Ctrl-C) from stealing plain Ctrl-C, while arrow keys and
  /// function keys, which always carry `.function`, still match items without it.
  @MainActor
  static func match(
    itemKey: String, itemMask: NSEvent.ModifierFlags, eventChars: String,
    eventMods: NSEvent.ModifierFlags
  ) -> Bool {
    if itemMask.contains(.function), !eventMods.contains(.function) {
      return false
    }

    return KeyChord(itemKey, itemMask) == KeyChord(eventChars, eventMods)
  }
}
