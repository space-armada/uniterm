import AppKit
import AppletKit
import AppletTestSupport
import StatusKit
import TableData
import XCTest

@testable import DataViewerApplet

/// How the data viewer's alerts reach the bar, and what a restore load says.
@MainActor
final class DataViewerAlertsTests: XCTestCase {
  private let amount = ColumnIdentity.named("amount")
  private let cut = "1 row had an oversized cell cut."

  private func oversized(_ scratch: Scratch, _ name: String = "big.csv") throws -> URL {
    let big = String(repeating: "x", count: (1 << 20) + 10)
    return try scratch.write(name, "note\n\(big)\nsmall\n")
  }

  private func restored(
    path: URL, host: RecordingHost, sort: SortSpec? = nil,
    budget: TableBudget = makeBudget()
  ) throws -> DataViewerApplet {
    let description = DataViewerDescription(
      startDirectory: path.deletingLastPathComponent().path, path: path.path, sort: sort)

    let applet = try DataViewerApplet(
      restoring: description.appletDescription(), budget: budget)

    applet.host = host

    return applet
  }

  private func loaded(_ applet: DataViewerApplet) async -> Bool {
    await eventually { applet.session.phase == .loaded }
  }

  // MARK: Restore

  /// Catches a restore load whose warning takes a turn on the bar. At launch, the warning raises
  /// attention without one. The origin must survive the asynchronous open and the streamed load.
  func testARestoreLoadWarnsWithoutATurn() async throws {
    let scratch = try Scratch(self)
    let host = RecordingHost()
    let applet = try restored(path: try oversized(scratch), host: host)

    applet.start(origin: .restore)
    let done = await loaded(applet)

    XCTAssertTrue(done)
    XCTAssertTrue(host.posts.isEmpty, "\(host.posts)")
    XCTAssertEqual(host.attentions.map(\.text), [cut])
    XCTAssertEqual(host.attentions.map(\.level), [.warning])
  }

  /// Catches a file found at a new path whose info takes a turn at launch.
  func testARestoreLoadOfAMovedFileRecordsItsInfoOnly() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("a.csv", "x\n1\n")

    let original = DataViewerApplet(startDirectory: nil, budget: makeBudget())
    try original.replaceSource(with: file, startDirectory: scratch.url.path)
    _ = await loaded(original)

    let description = original.describe()
    try FileManager.default.moveItem(
      at: file, to: scratch.url.appendingPathComponent("moved.csv"))

    let host = RecordingHost()
    let applet = try DataViewerApplet(restoring: description, budget: makeBudget())
    applet.host = host
    applet.start(origin: .restore)
    _ = await loaded(applet)

    XCTAssertTrue(host.posts.isEmpty)
    XCTAssertEqual(host.records.map(\.level), [.info])
    XCTAssertTrue(host.records.first?.text.hasPrefix("Moved. Found at") == true)
  }

  /// Catches a pane reopened by undo that goes quiet. Only the launch restore sets the origin.
  func testAReopenedPaneThatWasNotToldItIsAtLaunchPostsNormally() async throws {
    let scratch = try Scratch(self)
    let host = RecordingHost()
    let applet = try restored(path: try oversized(scratch), host: host)

    applet.start(origin: .user)
    _ = await loaded(applet)

    XCTAssertEqual(host.posts.map(\.text), [cut])
    XCTAssertTrue(host.attentions.isEmpty)
  }

  // MARK: Later loads

  /// Catches a user load that inherits the restore, and a sheet switch or a replacement that
  /// does. The restored pane loads quietly. Every load the user makes afterwards posts normally.
  func testAUserLoadAfterARestoreNeverInheritsIt() async throws {
    let scratch = try Scratch(self)
    let host = RecordingHost()
    let applet = try restored(path: try oversized(scratch), host: host)

    applet.start(origin: .restore)
    _ = await loaded(applet)

    XCTAssertTrue(host.posts.isEmpty)

    try applet.replaceSource(
      with: try oversized(scratch, "other.csv"), startDirectory: scratch.url.path)
    _ = await loaded(applet)

    XCTAssertEqual(host.posts.map(\.text), [cut], "the user's load was treated as a restore")
  }

  /// Catches a replacement that lands while the restore load is still in flight and then takes the
  /// restore's origin. The old load is cancelled and the new one posts normally.
  func testAReplacementWhileTheRestoreIsInFlightPostsNormally() async throws {
    let scratch = try Scratch(self)
    let host = RecordingHost()
    let applet = try restored(path: try oversized(scratch), host: host)

    applet.start(origin: .restore)
    try applet.replaceSource(
      with: try oversized(scratch, "other.csv"), startDirectory: scratch.url.path)
    _ = await loaded(applet)

    XCTAssertEqual(host.posts.map(\.text), [cut])
    XCTAssertTrue(host.attentions.isEmpty, "\(host.attentions)")
  }

  /// Catches a stored flag that taints a later user sort. A restored pane loads clean. A sort the
  /// user then makes cannot get its memory, and that notice posts normally. A restore-origin sort
  /// that cannot get its memory stays quiet, and the same sort made by the user is not taken for
  /// it.
  func testAUserSortOnARestoredPaneIsNotTaintedByTheRestore() async throws {
    let scratch = try Scratch(self)
    var text = "amount,other\n"

    for index in 0..<400 { text += "\(index % 7),row\(index)\n" }

    let file = try scratch.write("many.csv", text)

    let measuring = makeBudget()
    let first = DataViewerApplet(startDirectory: nil, budget: measuring)
    try first.replaceSource(with: file, startDirectory: scratch.url.path)
    _ = await loaded(first)

    let tight = TableBudget(limit: measuring.used + 1, floor: 0)
    first.close()

    let host = RecordingHost()
    let applet = try restored(path: file, host: host, budget: tight)

    applet.start(origin: .restore)
    _ = await loaded(applet)

    XCTAssertTrue(host.posts.isEmpty)
    XCTAssertTrue(host.attentions.isEmpty)

    applet.content.onSort?(amount)

    let skipped = await eventually { applet.session.sortSkipped }

    XCTAssertTrue(skipped, "the budget must refuse the sort for this test to mean anything")
    XCTAssertEqual(host.posts.count, 1, "\(host.posts) \(host.attentions)")
    XCTAssertTrue(host.attentions.isEmpty)
  }

  /// Catches a restored sort that cannot get its memory and takes a turn. It is part of the
  /// restore, so it raises attention only.
  func testARestoredSortThatCannotGetMemoryRaisesAttentionOnly() async throws {
    let scratch = try Scratch(self)
    var text = "amount,other\n"

    for index in 0..<400 { text += "\(index % 7),row\(index)\n" }

    let file = try scratch.write("many.csv", text)

    let measuring = makeBudget()
    let first = DataViewerApplet(startDirectory: nil, budget: measuring)
    try first.replaceSource(with: file, startDirectory: scratch.url.path)
    _ = await loaded(first)

    let tight = TableBudget(limit: measuring.used + 1, floor: 0)
    first.close()

    let host = RecordingHost()
    let applet = try restored(
      path: file, host: host,
      sort: SortSpec(column: amount, ascending: true), budget: tight)

    applet.start(origin: .restore)
    _ = await loaded(applet)

    let skipped = await eventually { applet.session.sortSkipped }

    XCTAssertTrue(skipped)
    XCTAssertTrue(host.posts.isEmpty, "\(host.posts)")
    XCTAssertEqual(host.attentions.count, 1)
  }

  /// Catches a user filter that relabels a restored sort's skipped notice as the user's own. The
  /// filter does not cause the skip, so the notice still belongs to the restore and takes no turn.
  func testAUserFilterDoesNotRelabelARestoredSortNotice() async throws {
    let scratch = try Scratch(self)
    var text = "amount,other\n"

    for index in 0..<400 { text += "\(index % 7),row\(index)\n" }

    let file = try scratch.write("many.csv", text)

    let measuring = makeBudget()
    let first = DataViewerApplet(startDirectory: nil, budget: measuring)
    try first.replaceSource(with: file, startDirectory: scratch.url.path)
    _ = await loaded(first)

    let tight = TableBudget(limit: measuring.used + 1, floor: 0)
    first.close()

    let host = RecordingHost()
    let applet = try restored(
      path: file, host: host, sort: SortSpec(column: amount, ascending: true), budget: tight)

    applet.start(origin: .restore)
    applet.content.onFilter?("row")

    let skipped = await eventually { applet.session.sortSkipped }

    XCTAssertTrue(skipped)
    XCTAssertTrue(host.posts.isEmpty, "\(host.posts)")
    XCTAssertEqual(host.attentions.count, 1)
  }
}
