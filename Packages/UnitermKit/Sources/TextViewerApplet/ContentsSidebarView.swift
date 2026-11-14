import AppKit
import TextViewerModel
import Theme

/// The contents list beside the document. Each row is one structural entry, indented by its level.
/// A document with no entries says so, and a list that was cut at a cap says that too.
@MainActor
final class ContentsSidebarView: NSView, NSTableViewDataSource, NSTableViewDelegate {
  static let width: CGFloat = 240

  private let scroll = NSScrollView()
  private var scrollBottomToEdge: NSLayoutConstraint?
  private var scrollBottomToCut: NSLayoutConstraint?
  let table = NSTableView()
  private let emptyLabel = NSTextField(wrappingLabelWithString: "")
  private let cutLabel = NSTextField(wrappingLabelWithString: "")
  private var contents = Contents.empty
  private var palette = ThemePalette.latte

  /// The reader picked an entry.
  var onSelect: ((ContentsEntry) -> Void)?

  /// False until the document is ready to list. A page that is still rendering has no headings
  /// yet, and the sidebar then says nothing instead of "No contents".
  var isReady = false {
    didSet { refresh() }
  }

  init() {
    super.init(frame: .zero)

    setAccessibilityIdentifier("text-viewer-contents-sidebar")

    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
    column.resizingMask = .autoresizingMask
    table.addTableColumn(column)
    table.headerView = nil
    table.rowSizeStyle = .medium
    table.style = .sourceList
    table.allowsEmptySelection = true
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.action = #selector(rowClicked)
    table.setAccessibilityIdentifier("text-viewer-contents")

    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    scroll.translatesAutoresizingMaskIntoConstraints = false

    emptyLabel.alignment = .center
    emptyLabel.maximumNumberOfLines = 0
    emptyLabel.stringValue = "No contents"
    emptyLabel.setAccessibilityIdentifier("text-viewer-contents-empty")
    emptyLabel.translatesAutoresizingMaskIntoConstraints = false

    cutLabel.maximumNumberOfLines = 0
    cutLabel.font = .systemFont(ofSize: 11)
    cutLabel.setAccessibilityIdentifier("text-viewer-contents-cut")
    cutLabel.translatesAutoresizingMaskIntoConstraints = false

    addSubview(scroll)
    addSubview(emptyLabel)
    addSubview(cutLabel)

    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: Self.width),
      scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
      scroll.topAnchor.constraint(equalTo: topAnchor),
      cutLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      cutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      cutLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
      emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
      emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      emptyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
    ])

    scrollBottomToEdge = scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
    scrollBottomToCut = scroll.bottomAnchor.constraint(equalTo: cutLabel.topAnchor, constant: -4)
    refresh()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  func show(_ contents: Contents) {
    self.contents = contents
    table.reloadData()
    refresh()
  }

  var entryCount: Int { contents.entries.count }

  /// Whether the "No contents" message shows, for tests.
  var showsEmptyMessage: Bool { !emptyLabel.isHidden }

  /// Whether the "list was cut" message shows, for tests.
  var showsCutMessage: Bool { !cutLabel.isHidden }

  private func refresh() {
    emptyLabel.isHidden = !isReady || !contents.isEmpty
    scroll.isHidden = contents.isEmpty
    cutLabel.isHidden = !contents.wasCut
    cutLabel.stringValue = contents.cutMessage ?? ""

    // A hidden label still takes its height, so the list ends at the edge unless a cut needs room.
    scrollBottomToEdge?.isActive = !contents.wasCut
    scrollBottomToCut?.isActive = contents.wasCut
  }

  func apply(_ palette: ThemePalette) {
    self.palette = palette
    wantsLayer = true
    layer?.backgroundColor = palette[.mantle].cgColor
    emptyLabel.textColor = palette.secondaryText.nsColor
    cutLabel.textColor = palette.secondaryText.nsColor
    appearance = NSAppearance(named: palette.flavor.isDark ? .darkAqua : .aqua)
    table.reloadData()
  }

  /// Picks the entry at `row`, as a click does.
  func select(row: Int) {
    guard contents.entries.indices.contains(row) else { return }

    table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    onSelect?(contents.entries[row])
  }

  @objc private func rowClicked() {
    select(row: table.clickedRow)
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    contents.entries.count
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    guard contents.entries.indices.contains(row) else { return nil }

    let entry = contents.entries[row]
    let label = NSTextField(labelWithString: entry.title)
    label.lineBreakMode = .byTruncatingTail
    label.textColor = palette[.text].nsColor
    label.font = entry.level <= 1 ? .boldSystemFont(ofSize: 12) : .systemFont(ofSize: 12)
    label.translatesAutoresizingMaskIntoConstraints = false

    let cell = ContentsCellView()
    cell.normalColor = palette[.text].nsColor
    cell.addSubview(label)
    cell.textField = label
    cell.setAccessibilityIdentifier("text-viewer-contents-entry-\(row)")
    cell.setAccessibilityLabel(entry.title)

    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(
        equalTo: cell.leadingAnchor, constant: 4 + CGFloat(min(entry.level - 1, 6)) * 12),
      label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
      label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])

    return cell
  }
}

/// A cell whose title follows the row's selection. A selected row is drawn in the system selection
/// color, so its text takes the matching text color, and any other row uses the theme's text.
final class ContentsCellView: NSTableCellView {
  var normalColor = NSColor.labelColor {
    didSet { updateTextColor() }
  }

  override var backgroundStyle: NSView.BackgroundStyle {
    didSet { updateTextColor() }
  }

  private func updateTextColor() {
    textField?.textColor =
      backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : normalColor
  }

  override var textField: NSTextField? {
    didSet { updateTextColor() }
  }
}
