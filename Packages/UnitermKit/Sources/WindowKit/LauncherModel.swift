import Foundation

/// One applet the launcher offers.
struct LauncherEntry: Equatable {
  enum Kind: Equatable {
    case terminal
    case program
    case dataViewer
    case mapViewer
    case browser
    case imageViewer
    case textViewer
  }

  let kind: Kind
  let name: String
  let detail: String

  /// An SF Symbol name.
  let symbol: String

  static let all: [LauncherEntry] = [
    LauncherEntry(
      kind: .terminal, name: "Terminal",
      detail: "Your login shell",
      symbol: "terminal"),
    LauncherEntry(
      kind: .program, name: "Terminal running a program",
      detail: "Runs one command, such as htop", symbol: "play.fill"),
    LauncherEntry(
      kind: .dataViewer, name: "Data viewer",
      detail: "Shows a CSV, JSON, or Excel file as a table", symbol: "tablecells"),
    LauncherEntry(
      kind: .mapViewer, name: "Map viewer",
      detail: "Shows a map you can pan and zoom", symbol: "map"),
    LauncherEntry(
      kind: .browser, name: "Browser",
      detail: "Shows web pages", symbol: "safari"),
    LauncherEntry(
      kind: .imageViewer, name: "Image viewer",
      detail: "Shows an image, or the first image of a folder", symbol: "photo"),
    LauncherEntry(
      kind: .textViewer, name: "Text viewer",
      detail: "Shows a PDF, RTF, or Word document", symbol: "doc.text"),
  ]
}

/// Why the launcher declined to open the selected applet. The text is shown to the user.
struct LauncherRefusal: Error, Equatable {
  let reason: String
}

/// The state of the launcher, apart from its views.
///
/// The filter narrows the entries by name. The selection is always one of the visible entries, and
/// the keyboard belongs to the filter or to the command field, depending on the selection.
struct LauncherModel: Equatable {
  /// Where the keyboard goes.
  enum Focus: Equatable {
    case filter
    case command
    case place
  }

  var filter = "" {
    didSet { refusal = nil }
  }

  var command = "" {
    didSet { refusal = nil }
  }

  private var preferred: LauncherEntry.Kind = .terminal

  /// True when the launcher can search for a place to open a map at. Without it the map viewer
  /// opens at its own default view, and the keyboard stays in the filter.
  var offersPlace = false

  /// Set by an attempt to open that failed, and cleared by any edit or move.
  var refusal: LauncherRefusal?

  /// The entries whose names contain the filter, ignoring case and surrounding space.
  var visible: [LauncherEntry] {
    let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !needle.isEmpty else { return LauncherEntry.all }

    return LauncherEntry.all.filter { $0.name.localizedCaseInsensitiveContains(needle) }
  }

  /// The selected entry, or nil when the filter matches nothing. A selection the filter hides
  /// falls to the first visible entry.
  var selection: LauncherEntry? {
    let entries = visible
    return entries.first { $0.kind == preferred } ?? entries.first
  }

  var showsCommand: Bool { selection?.kind == .program }

  var showsPlace: Bool { offersPlace && selection?.kind == .mapViewer }

  var focus: Focus { showsCommand ? .command : showsPlace ? .place : .filter }

  /// Selects an entry that is visible. Anything else is ignored.
  mutating func select(_ kind: LauncherEntry.Kind) {
    guard visible.contains(where: { $0.kind == kind }) else { return }

    preferred = kind
    refusal = nil
  }

  /// Moves the selection by `step` entries and wraps at both ends, as a menu does.
  mutating func move(by step: Int) {
    let entries = visible

    guard !entries.isEmpty else { return }

    let at = entries.firstIndex { $0.kind == selection?.kind } ?? 0
    let next = ((at + step) % entries.count + entries.count) % entries.count
    select(entries[next].kind)
  }

  /// Selects the Nth visible entry, counting from 1. Returns false when there is no such entry.
  @discardableResult
  mutating func pick(number: Int) -> Bool {
    let entries = visible

    guard entries.indices.contains(number - 1) else { return false }

    select(entries[number - 1].kind)
    return true
  }

  /// Leaves the command field for the plain terminal choice.
  mutating func backToTerminal() {
    preferred = .terminal
    refusal = nil
  }

  /// The choice the selection makes. A program needs a command, which is trimmed. Whether the
  /// command parses is for the code that starts it to say.
  func choice() -> Result<AppletChoice, LauncherRefusal> {
    switch selection?.kind {
    case .terminal:
      return .success(.terminalShell)

    case .program:
      let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)

      guard !trimmed.isEmpty else {
        return .failure(LauncherRefusal(reason: "The command is empty."))
      }

      return .success(.terminalProgram(command: trimmed))

    case .dataViewer:
      return .success(.dataViewer)

    case .mapViewer:
      return .success(.mapViewer(region: nil))

    case .browser:
      return .success(.browser)

    case .imageViewer:
      return .success(.imageViewer)

    case .textViewer:
      return .success(.textViewer)

    case nil:
      return .failure(LauncherRefusal(reason: "No applet matches."))
    }
  }
}

extension LauncherEntry.Kind {
  var accessibilityIdentifier: String {
    switch self {
    case .terminal: return "launcher-terminal"
    case .program: return "launcher-program"
    case .dataViewer: return "launcher-data-viewer"
    case .mapViewer: return "launcher-map-viewer"
    case .browser: return "launcher-browser"
    case .imageViewer: return "launcher-image-viewer"
    case .textViewer: return "launcher-text-viewer"
    }
  }
}
