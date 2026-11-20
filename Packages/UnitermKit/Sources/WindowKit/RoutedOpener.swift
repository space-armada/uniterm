import AppKit
import AppletKit
import FileRouting
import Foundation
import PaneModel

/// The pane a request came from. A routed pane opens beside it.
public struct RouteAnchor {
  public let controller: MainWindowController
  public let pane: NodeID

  public init(controller: MainWindowController, pane: NodeID) {
    self.controller = controller
    self.pane = pane
  }
}

/// Where one routed file went.
public struct RoutedPane {
  public let file: URL
  public let controller: MainWindowController
  public let pane: NodeID
}

/// Shows the Open With chooser for a model and says what the user did. Tests inject their own.
public typealias OpenWithPresenter =
  @MainActor (_ model: OpenWithModel, _ window: NSWindow?) async -> OpenWithOutcome

/// What a caller's authority says about one open.
///
/// A program's open is the same open as the user's, and the new pane takes focus either way. The
/// default asks about a large batch itself.
public struct RoutedOpenOptions: Sendable, Equatable {
  /// The user already approved this many files, so the batch confirmation is skipped. The count
  /// the approval named is the count that opens.
  public var countApproved = false

  public init(countApproved: Bool = false) {
    self.countApproved = countApproved
  }

  /// An open the user approved by name and count, for a program that asked.
  public static let approvedProgram = RoutedOpenOptions(countApproved: true)
}

/// What an open did. The failures are already posted as one message.
public struct RoutedOpenReport {
  public var opened: [RoutedPane] = []
  public var failures: [String] = []
}

/// The one route from a path to a pane. It asks the router which applet type opens each file, off
/// the main thread, then makes the applet through that type's source-taking factory and places it.
///
/// A single file opens beside the anchor pane, and a file that finds no room, or whose window has
/// a sheet, opens in a new window instead. A batch opens in one new window. Each file splits the
/// largest pane, and a file that finds no room goes to a further new window. A routed pane starts
/// in its file's folder, wherever it lands.
@MainActor
public final class RoutedOpener {
  /// Asks the user which applet opens a file that several applets claim equally. Nil cancels.
  public typealias Chooser = @MainActor (_ choice: RouteChoice) async -> String?

  /// One file that several applets claim equally.
  public struct RouteChoice {
    public let file: URL
    public let type: String
    public let candidates: [AppletTypeDeclaration]
  }

  private typealias Ready = (file: URL, applet: any Applet)

  private let windows: WindowSet
  private let declarations: [AppletTypeDeclaration]
  private let factories: [String: AppletSourceFactory]
  private let types: any ContentTypeSystem
  private let store: SavedChoiceStore
  private let chooser: Chooser?
  private let confirmBatch: CloseConfirmer
  private let pathKind: PathKindReader

  /// A batch of more files than this asks for a confirmation before anything is placed.
  public static let confirmationThreshold = 10

  /// The most failure messages one summary names before it counts the rest.
  static let namedFailures = 3

  public init(
    windows: WindowSet, declarations: [AppletTypeDeclaration],
    factories: [String: AppletSourceFactory], types: any ContentTypeSystem = SystemContentTypes(),
    store: SavedChoiceStore, chooser: Chooser? = nil,
    confirmBatch: @escaping CloseConfirmer = CloseDialog.present,
    pathKind: @escaping PathKindReader = PathInspector.kind
  ) {
    self.windows = windows
    self.declarations = declarations
    self.factories = factories
    self.types = types
    self.store = store
    self.chooser = chooser
    self.confirmBatch = confirmBatch
    self.pathKind = pathKind
  }

  /// Routes the files. The router sees the saved choices as they are now.
  ///
  /// A batch above the confirmation threshold asks first, and a refusal opens nothing. Every entry
  /// point reaches the question through here, so none can skip it. An approval that already named
  /// the count says so in `options`, and the batch is not asked about twice.
  @discardableResult
  public func open(
    _ files: [URL], from anchor: RouteAnchor?, options: RoutedOpenOptions = RoutedOpenOptions()
  ) async -> RoutedOpenReport {
    if !options.countApproved {
      guard await approveBatch(of: files.count, over: Self.window(for: anchor)) else {
        return RoutedOpenReport()
      }
    }

    let router = FileRouter(
      declarations: declarations, types: types, savedChoices: store.choices(),
      pathKind: pathKind)
    let decisions = await router.decisions(for: files)

    var report = RoutedOpenReport()
    var ready: [Ready] = []

    for decision in decisions {
      switch decision {
      case .refused(let file, let refusal):
        report.failures.append(refusal.message(for: file))

      case .open(let file, let typeID, let startDirectory, _):
        make(file, typeID: typeID, startDirectory: startDirectory, into: &ready, report: &report)

      case .choose(let file, let candidates, let startDirectory, let type):
        guard let chooser else {
          let refusal = RouteRefusal.ambiguous(type: type, applets: candidates.map(\.displayName))
          report.failures.append(refusal.message(for: file))
          continue
        }

        if let picked = await chooser(RouteChoice(file: file, type: type, candidates: candidates)) {
          make(file, typeID: picked, startDirectory: startDirectory, into: &ready, report: &report)
        }
      }
    }

    let live = Self.live(anchor)
    place(ready, anchor: live, batch: files.count > 1, report: &report)
    summarize(report.failures, total: files.count, anchor: live)

    return report
  }

  /// Opens one file with the applet the user picks in the Open With chooser. The chooser lists
  /// every applet that declares the file's type, and it can save the pick or clear a saved one.
  /// Clearing routes the file again by rank. Cancelling opens nothing.
  ///
  /// The chooser hangs from the anchor's window and is gone before the pane is placed, so a sheet
  /// never makes the window look full.
  @discardableResult
  public func openWithChoice(
    _ file: URL, from anchor: RouteAnchor?, present: OpenWithPresenter
  ) async -> RoutedOpenReport {
    let router = FileRouter(
      declarations: declarations, types: types, savedChoices: store.choices(),
      pathKind: pathKind)

    var report = RoutedOpenReport()

    let inspection = await router.inspection(of: file)

    guard case .ready(_, let type, let startDirectory) = inspection else {
      if case .refused(let refusal) = inspection {
        report.failures.append(refusal.message(for: file))
      }

      summarize(report.failures, total: 1, anchor: Self.live(anchor))
      return report
    }

    guard
      let model = OpenWithModel(
        file: file, type: type, candidates: router.candidates(forType: type), store: store)
    else {
      report.failures.append(RouteRefusal.unsupported(type: type).message(for: file))
      summarize(report.failures, total: 1, anchor: Self.live(anchor))
      return report
    }

    switch await present(model, anchor?.controller.window) {
    case .open(let typeID):
      var ready: [Ready] = []
      make(file, typeID: typeID, startDirectory: startDirectory, into: &ready, report: &report)

      let live = Self.live(anchor)
      place(ready, anchor: live, batch: false, report: &report)
      summarize(report.failures, total: 1, anchor: live)
      return report

    case .clearedSavedChoice:
      return await open([file], from: anchor)

    case .cancelled:
      return report
    }
  }

  private func approveBatch(of count: Int, over window: NSWindow?) async -> Bool {
    guard count > Self.confirmationThreshold else { return true }

    let question = CloseConfirmation(
      title: "Open \(count) files?",
      detail: "uniterm opens one pane for each of the \(count) files.",
      confirmTitle: "Open", cancelTitle: "Cancel")

    return await confirmBatch(question, window)
  }

  private static func window(for anchor: RouteAnchor?) -> NSWindow? {
    anchor?.controller.window
  }

  private static func live(_ anchor: RouteAnchor?) -> RouteAnchor? {
    anchor.flatMap { $0.controller.window != nil ? $0 : nil }
  }

  private func make(
    _ file: URL, typeID: String, startDirectory: String, into ready: inout [Ready],
    report: inout RoutedOpenReport
  ) {
    guard let factory = factories[typeID] else {
      report.failures.append("\u{201C}\(file.lastPathComponent)\u{201D} has no applet to open it.")
      return
    }

    do {
      ready.append((file, try factory(file, startDirectory)))
    } catch {
      report.failures.append(
        "\u{201C}\(file.lastPathComponent)\u{201D} could not be opened: "
          + error.localizedDescription)
    }
  }

  private func place(
    _ ready: [Ready], anchor: RouteAnchor?, batch: Bool, report: inout RoutedOpenReport
  ) {
    var current: MainWindowController?

    for item in ready {
      let routed =
        batch
        ? current.flatMap { placeInLargest(item, in: $0) }
        : anchor.flatMap { placeBeside(item, anchor: $0) }

      if let routed {
        report.opened.append(routed)
        continue
      }

      do {
        let controller = try windows.open(routing: item.applet)
        current = controller

        if let pane = controller.paneIDs.first {
          report.opened.append(RoutedPane(file: item.file, controller: controller, pane: pane))
        }
      } catch {
        item.applet.close()
        report.failures.append(
          "\u{201C}\(item.file.lastPathComponent)\u{201D} could not be opened: "
            + error.localizedDescription)
      }
    }
  }

  private func placeBeside(_ item: Ready, anchor: RouteAnchor) -> RoutedPane? {
    guard let pane = anchor.controller.placeRouted(item.applet, beside: anchor.pane) else {
      return nil
    }

    return RoutedPane(file: item.file, controller: anchor.controller, pane: pane)
  }

  private func placeInLargest(_ item: Ready, in controller: MainWindowController) -> RoutedPane? {
    guard let pane = controller.placeRoutedInLargestPane(item.applet) else { return nil }

    return RoutedPane(file: item.file, controller: controller, pane: pane)
  }

  /// Posts one message for every file that failed, however many there were.
  private func summarize(_ failures: [String], total: Int, anchor: RouteAnchor?) {
    guard !failures.isEmpty else { return }

    let text: String

    if failures.count == 1 {
      text = failures[0]
    } else {
      let named = failures.prefix(Self.namedFailures).joined(separator: " ")
      let more = failures.count - Self.namedFailures
      let rest = more > 0 ? " And \(more) more." : ""
      text = "\(failures.count) of \(total) files were not opened. \(named)\(rest)"
    }

    if let anchor {
      anchor.controller.statusCenter.post(level: .warning, text: text)
    } else {
      windows.post(level: .warning, text: text)
    }
  }
}
