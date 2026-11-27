import AppKit
import AppletKit
import Theme

/// The command palette's search field and the list of results under it.
///
/// This view is the field. The results live in a separate panel that the window places beside it,
/// over the pane area. A floating palette and a docked one share both. The field sits in the window
/// either way, and the panel opens away from it, so showing results never resizes a pane.
///
/// The view holds no commands. The window gives it entries and learns what the user chose. While
/// active, the keyboard belongs to the field. The arrow keys, Return, and Escape reach the list
/// through the field's delegate, and a click on a row never takes the keyboard from the field. An
/// inactive docked palette takes no keyboard at all. A click on it asks the window to activate it.
@MainActor
final class CommandPaletteView: NSView, NSTextFieldDelegate, NSTableViewDataSource,
  NSTableViewDelegate
{
  static let width: CGFloat = 560
  static let rowHeight: CGFloat = 28
  static let maximumVisibleRows = 8

  /// The padding between the results panel's border and its rows.
  static let resultsPadding: CGFloat = 6

  /// The sizes of the field's box. The text centers in it at its own height, so a taller box adds
  /// room above and below the text and never moves the text to the top.
  struct Style: Equatable {
    var height: CGFloat
    var fontSize: CGFloat
    var cornerRadius: CGFloat
    var textInset: CGFloat

    /// The filter chip's height and text size. The chip leaves 2 points above and below it in the
    /// shortest field.
    var chipHeight: CGFloat
    var chipFontSize: CGFloat

    /// A floating palette is a card over the panes, so it has room for a larger field.
    static let floating = Style(
      height: 40, fontSize: 15, cornerRadius: 10, textInset: 14, chipHeight: 26, chipFontSize: 13)

    /// A palette docked at the bottom sits in a strip that costs the panes its height.
    static let docked = Style(
      height: 24, fontSize: 13, cornerRadius: 6, textInset: 10, chipHeight: 18, chipFontSize: 11)

    /// A palette docked at the top sits in the title bar row, beside the traffic lights.
    static let titleBar = Style(
      height: 22, fontSize: 13, cornerRadius: 6, textInset: 10, chipHeight: 18, chipFontSize: 11)
  }

  /// The gap between the chip and the text after it.
  static let chipGap: CGFloat = 6

  /// How the window presents the palette. A floating palette is hidden until it is active. A docked
  /// one is always on show.
  enum Presentation {
    case floating
    case docked
  }

  let field = PaletteField()

  /// The results, in a view of their own so a docked palette can open them over the panes.
  let results = PaletteResultsPanel()

  /// The filter in the field, drawn before the text.
  let chip = PaletteChipView()

  private let table = PaletteTableView()
  private var palette: ThemePalette = .latte
  private var resultsHeight: NSLayoutConstraint?
  private var textLeading: NSLayoutConstraint?
  private var textAfterChip: NSLayoutConstraint?
  private var textTrailing: NSLayoutConstraint?
  private var chipLeading: NSLayoutConstraint?
  private var chipHeight: NSLayoutConstraint?

  private(set) var style: Style = .floating

  private(set) var presentation: Presentation = .floating
  private(set) var isActive = false

  /// The key equivalent of the menu item that activates the palette, spelled for a person. A docked
  /// palette names it in its placeholder while it is inactive.
  private(set) var hotkeyHint: String?

  /// The entries on show, best first.
  private(set) var entries: [PaletteEntry] = []

  /// The entry Return would run. It is an ID, so a list that re-sorts keeps the same entry
  /// highlighted.
  private(set) var selection: PaletteEntryID? {
    didSet {
      if selection != nil { dimmedSelection = nil }
    }
  }

  /// The row that was selected when it dimmed in place. Nothing is selected then, and Up and Down
  /// move from where this row stands rather than from an end of the list.
  private var dimmedSelection: PaletteEntryID?

  /// What the chip narrows the list to. Like the text, it lasts until the palette hides.
  private(set) var filter: PaletteFilter?

  /// Runs when the search text changes, with the new text.
  var onQueryChange: ((String) -> Void)?

  /// Runs when the user chooses an enabled entry, with Return or a click.
  var onChoose: ((PaletteEntry) -> Void)?

  /// Runs when the user asks to hide the palette with Escape.
  var onDismiss: (() -> Void)?

  /// Runs when the user clicks an inactive docked palette.
  var onActivate: (() -> Void)?

  var query: String { field.stringValue }

  override var isFlipped: Bool { true }

  override var wantsUpdateLayer: Bool { true }

  override var mouseDownCanMoveWindow: Bool { false }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)

    wantsLayer = true
    layer?.borderWidth = 1

    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.delegate = self
    field.translatesAutoresizingMaskIntoConstraints = false
    field.setAccessibilityIdentifier("command-palette-field")
    field.onInactiveClick = { [weak self] in self?.onActivate?() }
    addSubview(field)

    chip.translatesAutoresizingMaskIntoConstraints = false
    chip.isHidden = true
    chip.onRemove = { [weak self] in self?.setFilter(nil) }
    addSubview(chip)

    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
    column.resizingMask = .autoresizingMask
    table.addTableColumn(column)
    table.style = .plain
    table.headerView = nil
    table.rowHeight = Self.rowHeight
    table.intercellSpacing = .zero
    table.selectionHighlightStyle = .none
    table.backgroundColor = .clear
    table.refusesFirstResponder = true
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.action = #selector(rowClicked(_:))
    table.setAccessibilityIdentifier("command-palette-list")

    results.install(table)
    results.translatesAutoresizingMaskIntoConstraints = false

    // The panel's height is a preference. The window bounds it to the content area.
    let height = results.heightAnchor.constraint(equalToConstant: 0)
    height.priority = .defaultHigh
    height.isActive = true
    resultsHeight = height

    // The field keeps its own height, so its text is centered in the box at any box height.
    let leading = field.leadingAnchor.constraint(equalTo: leadingAnchor)
    let trailing = field.trailingAnchor.constraint(equalTo: trailingAnchor)
    textLeading = leading
    textTrailing = trailing

    // With a chip, the text starts after it. The two leading constraints swap in `updateChip`.
    textAfterChip = field.leadingAnchor.constraint(
      equalTo: chip.trailingAnchor, constant: Self.chipGap)

    let chipStart = chip.leadingAnchor.constraint(equalTo: leadingAnchor)
    let chipTall = chip.heightAnchor.constraint(equalToConstant: Style.floating.chipHeight)
    chipLeading = chipStart
    chipHeight = chipTall

    NSLayoutConstraint.activate([
      field.centerYAnchor.constraint(equalTo: centerYAnchor),
      leading,
      trailing,
      chipStart,
      chipTall,
      chip.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])

    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityIdentifier("command-palette")
    apply(style: .floating)
    updatePresentation()
  }

  /// Sizes the field's font, corners, and text inset. The window sets the box's height to match.
  func apply(style: Style) {
    self.style = style
    field.font = .systemFont(ofSize: style.fontSize)
    layer?.cornerRadius = style.cornerRadius
    textLeading?.constant = style.textInset
    textTrailing?.constant = -style.textInset
    chipLeading?.constant = style.textInset
    chipHeight?.constant = style.chipHeight
    chip.apply(fontSize: style.chipFontSize)
  }

  // MARK: Presentation

  /// Chooses floating or docked. The caller keeps the palette inactive across the change.
  func present(as presentation: Presentation) {
    self.presentation = presentation
    updatePresentation()
  }

  /// Activates the palette, or deactivates it. An active palette takes the keyboard and shows its
  /// results. An inactive floating palette is hidden, and an inactive docked one shows its
  /// placeholder.
  func setActive(_ active: Bool) {
    isActive = active
    updatePresentation()
  }

  func setHotkeyHint(_ hint: String?) {
    guard hint != hotkeyHint else { return }

    hotkeyHint = hint
    updatePresentation()
  }

  private func updatePresentation() {
    isHidden = presentation == .floating && !isActive
    field.acceptsKeyboard = presentation == .floating || isActive
    results.isHidden = !isActive || entries.isEmpty

    field.placeholderString =
      filter?.placeholder
      ?? Self.placeholder(presentation: presentation, isActive: isActive, hint: hotkeyHint)
  }

  /// What the field says when it is empty. An inactive docked palette is the only place the user
  /// is told how to reach it, so it names the key.
  static func placeholder(presentation: Presentation, isActive: Bool, hint: String?) -> String {
    guard presentation == .docked, !isActive else { return "Search tabs and commands" }

    guard let hint else { return "Search tabs and commands" }

    return "Search tabs and commands (\(hint))"
  }

  /// Whether a point, in window coordinates, is on the field or on the results.
  func contains(windowPoint point: NSPoint) -> Bool {
    if bounds.contains(convert(point, from: nil)) { return true }

    return !results.isHidden && results.bounds.contains(results.convert(point, from: nil))
  }

  override func mouseDown(with event: NSEvent) {
    if isActive {
      super.mouseDown(with: event)
    } else {
      onActivate?()
    }
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func updateLayer() {
    layer?.backgroundColor = palette[.mantle].cgColor
    layer?.borderColor = palette[.surface1].cgColor
  }

  func apply(_ palette: ThemePalette) {
    self.palette = palette
    field.textColor = palette[.text].nsColor
    needsDisplay = true
    results.apply(palette)
    chip.apply(palette)
    table.reloadData()
  }

  // MARK: Filter

  /// Puts a filter in the field as a chip, or takes the chip away. The text clears, so what the
  /// user typed to find the filter does not search inside it.
  func setFilter(_ filter: PaletteFilter?) {
    self.filter = filter
    updateChip()
    setText("")
  }

  private func updateChip() {
    if let filter {
      chip.show(filter)
    }

    chip.isHidden = filter == nil

    // The leading constraint in use goes first, so the two are never active together.
    let (off, on) = filter == nil ? (textAfterChip, textLeading) : (textLeading, textAfterChip)
    off?.isActive = false
    on?.isActive = true
    updatePresentation()
  }

  /// Replaces the text with the caret at its end, and lists again for it.
  private func setText(_ text: String) {
    if let editor = field.currentEditor() {
      editor.string = text
      editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
    } else {
      field.stringValue = text
    }

    selection = nil
    onQueryChange?(field.stringValue)
  }

  /// The keys that fill in a category's keyword, such as Control-K for `kind:`. They belong to the
  /// palette only while its field holds the keyboard. Otherwise the key goes on, so a closed
  /// palette or an inactive docked one binds nothing.
  static let keywordKeys: [KeyChord: PaletteFilter.Category] = [
    KeyChord("a", .control): .applet,
    KeyChord("k", .control): .kind,
  ]

  /// Takes a key that belongs to the palette while its field holds the keyboard. The window asks
  /// before any view, so a terminal that takes Control chords as input never sees it.
  func handleKey(_ event: NSEvent) -> Bool {
    guard isActive, let editor = field.currentEditor(), window?.firstResponder === editor,
      let category = Self.keywordKeys[
        KeyChord(event.charactersIgnoringModifiers ?? "", event.modifierFlags)]
    else { return false }

    setText(category.keyword)
    return true
  }

  /// Tab completes a keyword hint, or turns the highlighted suggestion into the chip. It never
  /// moves the keyboard out of the field.
  private func completeWithTab() {
    if let hint = entries.first(where: { $0.kind == .filterKeyword }),
      case .filterKeyword(let category) = hint.id
    {
      setText(category.keyword)
    } else if let entry = selectedEntry, case .filter(let filter) = entry.id {
      setFilter(filter)
    }
  }

  // MARK: Entries

  /// Shows a fresh list. The selection stays on its entry when the entry is still there and can
  /// run. Otherwise it moves to the first entry that can run.
  ///
  /// With no query, the first choice is the most recent tab other than the current one, so Return
  /// goes back to where the user was. With no other tab it is the first other entry that can run.
  func setEntries(_ entries: [PaletteEntry]) {
    self.entries = entries
    dimmedSelection = nil

    // The same entry stays highlighted, wherever it sorted to.
    if selection.map({ id in !entries.contains { $0.id == id && $0.isSelectable } }) ?? true {
      selection = Self.firstChoice(in: entries, emptyQuery: PaletteRanking.isEmpty(query))
    }

    showRows()
    scrollToSelection()
  }

  /// Brings the rows on show up to date where they stand. The caller keeps every row in its
  /// place, and this never picks a row on its own.
  ///
  /// A selected row that dims loses the selection, and no row takes it, so Return runs nothing.
  /// Moving the selection to another row would make a second Return run a command the user never
  /// looked at.
  func updateEntriesInPlace(_ entries: [PaletteEntry]) {
    self.entries = entries

    if let id = selection, !entries.contains(where: { $0.id == id && $0.isSelectable }) {
      selection = nil
      dimmedSelection = id
    }

    showRows()
  }

  private func showRows() {
    let rows = min(entries.count, Self.maximumVisibleRows)
    resultsHeight?.constant = CGFloat(rows) * Self.rowHeight + 2 * Self.resultsPadding
    results.isHidden = !isActive || entries.isEmpty

    table.reloadData()
  }

  private static func firstChoice(in entries: [PaletteEntry], emptyQuery: Bool) -> PaletteEntryID? {
    let enabled = entries.filter(\.isSelectable)

    guard emptyQuery else { return enabled.first?.id }

    let others = enabled.filter { !$0.isCurrent }

    return (others.first { $0.kind == .tab } ?? others.first ?? enabled.first)?.id
  }

  /// Clears the text and the selection for the next time the palette shows.
  func reset() {
    field.stringValue = ""
    selection = nil
    dimmedSelection = nil
    filter = nil
    updateChip()
    entries = []
    results.isHidden = true
    table.reloadData()
  }

  var selectedEntry: PaletteEntry? {
    entries.first { $0.id == selection }
  }

  private func moveSelection(by step: Int) {
    if selection == nil, let dimmed = dimmedSelection,
      let row = entries.firstIndex(where: { $0.id == dimmed })
    {
      moveSelection(from: row, by: step)
      return
    }

    let enabled = entries.filter(\.isSelectable)

    guard !enabled.isEmpty else { return }

    let current = enabled.firstIndex { $0.id == selection } ?? (step > 0 ? -1 : enabled.count)
    let next = min(max(current + step, 0), enabled.count - 1)

    select(enabled[next].id)
  }

  /// Selects the first row that can run beyond `row` in the direction of `step`. With none on that
  /// side, nothing is selected, as Down on the last row moves nowhere.
  private func moveSelection(from row: Int, by step: Int) {
    let beyond = step > 0 ? Array(entries[(row + 1)...]) : Array(entries[..<row].reversed())

    guard let next = beyond.first(where: \.isSelectable) else { return }

    select(next.id)
  }

  private func select(_ id: PaletteEntryID) {
    selection = id
    table.reloadData()
    scrollToSelection()
  }

  private func scrollToSelection() {
    if let row = entries.firstIndex(where: { $0.id == selection }) {
      table.scrollRowToVisible(row)
    }
  }

  /// A suggestion becomes the chip. Anything else goes to the window to run.
  private func chooseSelection() {
    guard let entry = selectedEntry, entry.isSelectable else { return }

    if case .filter(let filter) = entry.id {
      setFilter(filter)
    } else {
      onChoose?(entry)
    }
  }

  @objc private func rowClicked(_ sender: Any?) {
    let row = table.clickedRow

    guard entries.indices.contains(row) else { return }

    if case .filterKeyword(let category) = entries[row].id {
      setText(category.keyword)
      return
    }

    guard entries[row].isSelectable else { return }

    selection = entries[row].id
    chooseSelection()
  }

  // MARK: Field delegate

  func controlTextDidChange(_ notification: Notification) {
    // New text picks the first choice again. Only a re-list from the tabs keeps the highlight.
    selection = nil
    onQueryChange?(field.stringValue)
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.moveDown(_:)):
      moveSelection(by: 1)

    case #selector(NSResponder.moveUp(_:)):
      moveSelection(by: -1)

    case #selector(NSResponder.insertNewline(_:)):
      chooseSelection()

    case #selector(NSResponder.cancelOperation(_:)):
      onDismiss?()

    case #selector(NSResponder.insertTab(_:)):
      completeWithTab()

    case #selector(NSResponder.insertBacktab(_:)):
      break

    case #selector(NSResponder.deleteBackward(_:)):
      // Backspace in an empty field takes the chip away. Otherwise it edits the text.
      guard textView.string.isEmpty, filter != nil else { return false }

      setFilter(nil)

    default:
      return false
    }

    return true
  }

  // MARK: Table

  func numberOfRows(in tableView: NSTableView) -> Int {
    entries.count
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
    -> NSView?
  {
    let view = PaletteRowView()
    view.configure(entries[row], selected: entries[row].id == selection, palette: palette)
    return view
  }
}

/// The search field. An inactive docked palette must not take the keyboard, not even from a click.
/// The click asks the window to activate the palette instead.
@MainActor
final class PaletteField: NSTextField {
  var acceptsKeyboard = true
  var onInactiveClick: (() -> Void)?

  override var acceptsFirstResponder: Bool { acceptsKeyboard && super.acceptsFirstResponder }

  override func mouseDown(with event: NSEvent) {
    if acceptsKeyboard {
      super.mouseDown(with: event)
    } else {
      onInactiveClick?()
    }
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The results list. It is a card of its own, placed beside the field and over the panes.
@MainActor
final class PaletteResultsPanel: NSView {
  private let scroll = NSScrollView()
  private var palette: ThemePalette = .latte

  override var isFlipped: Bool { true }

  override var wantsUpdateLayer: Bool { true }

  override var mouseDownCanMoveWindow: Bool { false }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)

    wantsLayer = true
    layer?.cornerRadius = 10
    layer?.borderWidth = 1
    layer?.masksToBounds = true

    scroll.hasVerticalScroller = true
    scroll.automaticallyAdjustsContentInsets = false
    scroll.contentInsets = NSEdgeInsetsZero
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.translatesAutoresizingMaskIntoConstraints = false
    addSubview(scroll)

    let padding = CommandPaletteView.resultsPadding

    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: topAnchor, constant: padding),
      scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),
      scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
      scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
    ])

    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityIdentifier("command-palette-results")
    isHidden = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  func install(_ table: NSTableView) {
    scroll.documentView = table
  }

  func apply(_ palette: ThemePalette) {
    self.palette = palette
    needsDisplay = true
  }

  override func updateLayer() {
    layer?.backgroundColor = palette[.mantle].cgColor
    layer?.borderColor = palette[.surface1].cgColor
  }
}

/// The filter in the palette's field: the filter's icon, its name, and a button that removes it.
/// Nothing in it takes the keyboard, so the field keeps it while the user clicks the button.
@MainActor
final class PaletteChipView: NSView {
  private let icon = NSImageView()
  private let label = NSTextField(labelWithString: "")
  let removeButton = NSButton()
  private var palette: ThemePalette = .latte

  var onRemove: (() -> Void)?

  override var isFlipped: Bool { true }

  override var wantsUpdateLayer: Bool { true }

  override var mouseDownCanMoveWindow: Bool { false }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)

    wantsLayer = true

    icon.imageScaling = .scaleProportionallyDown
    icon.translatesAutoresizingMaskIntoConstraints = false
    addSubview(icon)

    label.lineBreakMode = .byTruncatingTail
    label.translatesAutoresizingMaskIntoConstraints = false
    label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    addSubview(label)

    removeButton.isBordered = false
    removeButton.refusesFirstResponder = true
    removeButton.imagePosition = .imageOnly
    removeButton.image = NSImage(
      systemSymbolName: "xmark", accessibilityDescription: "Remove filter")
    removeButton.target = self
    removeButton.action = #selector(remove(_:))
    removeButton.translatesAutoresizingMaskIntoConstraints = false
    removeButton.setAccessibilityIdentifier("command-palette-chip-remove")
    removeButton.setAccessibilityLabel("Remove filter")
    addSubview(removeButton)

    NSLayoutConstraint.activate([
      icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
      icon.centerYAnchor.constraint(equalTo: centerYAnchor),
      label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
      removeButton.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 3),
      removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
      removeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      removeButton.widthAnchor.constraint(equalToConstant: 14),
      removeButton.heightAnchor.constraint(equalToConstant: 14),
    ])

    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityIdentifier("command-palette-chip")
    apply(fontSize: CommandPaletteView.Style.floating.chipFontSize)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  /// The filter's name, for a test or for accessibility to read.
  var text: String { label.stringValue }

  func show(_ filter: PaletteFilter) {
    label.stringValue = filter.name
    icon.image = NSImage(systemSymbolName: filter.symbolName, accessibilityDescription: nil)
    setAccessibilityLabel(filter.name)
  }

  /// Sizes the text, the icon, and the corners to the field's style.
  func apply(fontSize: CGFloat) {
    label.font = .systemFont(ofSize: fontSize)
    icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: fontSize - 1, weight: .medium)
    removeButton.symbolConfiguration = NSImage.SymbolConfiguration(
      pointSize: fontSize - 4, weight: .semibold)
    layer?.cornerRadius = fontSize >= 13 ? 6 : 4
  }

  func apply(_ palette: ThemePalette) {
    self.palette = palette
    label.textColor = palette[.text].nsColor
    icon.contentTintColor = palette[.blue].nsColor
    removeButton.contentTintColor = palette.secondaryText.nsColor
    needsDisplay = true
  }

  override func updateLayer() {
    layer?.backgroundColor = palette[.surface0].cgColor
  }

  @objc private func remove(_ sender: Any?) {
    onRemove?()
  }
}

/// A table that never takes the keyboard, so the field keeps it while the user clicks a row.
private final class PaletteTableView: NSTableView {
  override var acceptsFirstResponder: Bool { false }
}

/// One result row: an icon, the title, and on the right the applet's name or the kind.
private final class PaletteRowView: NSView {
  static let iconSize: CGFloat = 14

  private let icon = NSImageView()
  private let title = NSTextField(labelWithString: "")
  private let kind = NSTextField(labelWithString: "")

  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)

    wantsLayer = true
    layer?.cornerRadius = 6

    // The icon keeps its place when a row has none, so every title starts at the same edge.
    icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
    icon.imageScaling = .scaleProportionallyDown
    icon.translatesAutoresizingMaskIntoConstraints = false
    addSubview(icon)

    title.font = .systemFont(ofSize: 13)
    title.lineBreakMode = .byTruncatingTail
    title.translatesAutoresizingMaskIntoConstraints = false
    title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    addSubview(title)

    kind.font = .systemFont(ofSize: 11)
    kind.translatesAutoresizingMaskIntoConstraints = false
    kind.setContentHuggingPriority(.required, for: .horizontal)
    addSubview(kind)

    NSLayoutConstraint.activate([
      icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      icon.centerYAnchor.constraint(equalTo: centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: Self.iconSize),
      icon.heightAnchor.constraint(equalToConstant: Self.iconSize),
      title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
      title.centerYAnchor.constraint(equalTo: centerYAnchor),
      kind.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      kind.centerYAnchor.constraint(equalTo: centerYAnchor),
      title.trailingAnchor.constraint(lessThanOrEqualTo: kind.leadingAnchor, constant: -12),
    ])

    setAccessibilityElement(true)
    setAccessibilityRole(.row)
    setAccessibilityIdentifier("command-palette-row")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  func configure(_ entry: PaletteEntry, selected: Bool, palette: ThemePalette) {
    kind.stringValue = selected && entry.kind == .filter ? "Tab to filter" : entry.label
    icon.image = entry.symbolName.flatMap {
      NSImage(systemSymbolName: $0, accessibilityDescription: nil)
    }

    let onAccent = palette.onAccent

    let titleColor: NSColor
    let detailColor: NSColor

    if selected {
      layer?.backgroundColor = palette[.blue].cgColor
      titleColor = onAccent.nsColor
      detailColor = onAccent.nsColor
      kind.textColor = onAccent.nsColor
      icon.contentTintColor = onAccent.nsColor
    } else {
      layer?.backgroundColor = NSColor.clear.cgColor
      switch (entry.kind, entry.isEnabled) {
      case (.notice, _): titleColor = palette.secondaryText.nsColor
      case (_, true): titleColor = palette[.text].nsColor
      case (_, false): titleColor = palette[.overlay0].nsColor
      }

      detailColor = palette.secondaryText.nsColor
      kind.textColor = palette.secondaryText.nsColor
      icon.contentTintColor = palette.secondaryText.nsColor
    }

    let truncating = NSMutableParagraphStyle()
    truncating.lineBreakMode = .byTruncatingTail

    let text = NSMutableAttributedString(
      string: entry.title,
      attributes: [
        .foregroundColor: titleColor, .font: NSFont.systemFont(ofSize: 13),
        .paragraphStyle: truncating,
      ])

    if let detail = entry.detail, !detail.isEmpty {
      text.append(
        NSAttributedString(
          string: "  " + detail,
          attributes: [
            .foregroundColor: detailColor, .font: NSFont.systemFont(ofSize: 11),
            .paragraphStyle: truncating,
          ]))
    }

    title.attributedStringValue = text

    setAccessibilityLabel(entry.title)
    setAccessibilityValue("\(entry.spokenLabel), \(entry.isEnabled ? "enabled" : "disabled")")
    setAccessibilityHelp(entry.detail)
    setAccessibilitySelected(selected)
  }
}
