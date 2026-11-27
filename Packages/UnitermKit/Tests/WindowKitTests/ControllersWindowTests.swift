import AppKit
import ControllerPackage
import ControllerTrust
import ScriptTestSupport
import SourceAccess
import XCTest

@testable import ScriptHost
@testable import WindowKit

/// The startup review's text and choices, and the Controllers & Permissions window, against a real
/// script host and a real policy file. The UI tests show both on screen.
@MainActor
final class ControllersWindowTests: XCTestCase {
  private var folder: URL!
  private var host: ScriptHost!

  override func setUp() async throws {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "controllers-\(UUID().uuidString.prefix(8))", isDirectory: true)

    let sockets = folder.appendingPathComponent("s", isDirectory: true)

    try FileManager.default.createDirectory(at: sockets, withIntermediateDirectories: true)

    host = ScriptHost(
      listener: try ScriptListener.startWithoutCommandIdentityForTests(directory: sockets),
      issueProducer: { _ in nil },
      controllers: ControllerSettings(
        runsRoot: folder.appendingPathComponent("runs"),
        helper: BundleHelperIdentity(helperURL: folder.appendingPathComponent("none")),
        trustDirectory: folder.appendingPathComponent("trust")))
  }

  override func tearDown() async throws {
    host.stop()
    try? FileManager.default.removeItem(at: folder)
  }

  private static let identity = ControllerIdentity(
    controllerID: "dev.uniterm.fixture.window", version: String(repeating: "1", count: 64),
    keyFingerprint: String(repeating: "2", count: 64))

  private func review(signed: Bool, canRemember: Bool) throws -> ControllerReview {
    ControllerReview(
      id: 1, name: "Synthetic\u{202E}Name",
      identity: ControllerIdentity(
        controllerID: Self.identity.controllerID, version: Self.identity.version,
        keyFingerprint: signed ? Self.identity.keyFingerprint : nil),
      requested: [
        .paneControl, .clipboardRead,
        .hostLaunch(
          try HostLaunchScope(
            executable: "/usr/bin/true", directory: "/tmp", environmentKeys: ["TOKEN"])),
      ],
      added: [.clipboardRead],
      revises: .version(
        controllerID: "dev.uniterm.fixture.window", version: String(repeating: "0", count: 64)),
      canRemember: canRemember, notice: nil, waiting: [(1, 100), (2, 101)])
  }

  /// Catches Trust This Identity offered for an unsigned controller, or either trust choice
  /// offered when the policy file cannot take one, and help text that describes a button the
  /// panel does not show.
  func testTheReviewOffersTrustOnlyWhereItCanHold() throws {
    let choices = { (review: ControllerReview) in ControllerReviewText.offered(for: review) }

    XCTAssertEqual(
      choices(try review(signed: true, canRemember: true)),
      [.allowOnce, .allowForSession, .trustVersion, .trustIdentity, .deny])
    XCTAssertEqual(
      choices(try review(signed: false, canRemember: true)),
      [.allowOnce, .allowForSession, .trustVersion, .deny])
    XCTAssertEqual(
      choices(try review(signed: true, canRemember: false)), [.allowOnce, .allowForSession, .deny])

    let help = { (review: ControllerReview) in ControllerReviewText.choices(for: review) }
    let signed = help(try review(signed: true, canRemember: true))
    let unsigned = help(try review(signed: false, canRemember: true))
    let unwritable = help(try review(signed: true, canRemember: false))

    XCTAssertTrue(signed.contains("Trust This Identity"), signed)
    XCTAssertTrue(unsigned.contains("Trust This Version"), unsigned)
    XCTAssertFalse(unsigned.contains("Trust This Identity"), unsigned)
    XCTAssertFalse(unwritable.contains("Trust This"), unwritable)
    XCTAssertTrue(unwritable.contains("Allow for This Run"), unwritable)
  }

  /// Catches a review that asks to read paths without saying what Allow Once does for it, and one
  /// that leaves out a protected place a scope lies in, names, or leaves out. A link into a
  /// protected place is named through the resolved directories.
  func testAPathReadingReviewSaysAllowOnceReadsNothingAndNamesProtectedPlaces() throws {
    let home = NSHomeDirectory()
    let scope = try ReadScope(directories: [home, home + "/notes"])
    var reading = ControllerReview(
      id: 3, name: "Reader",
      identity: ControllerIdentity(
        controllerID: "dev.uniterm.fixture.reader", version: String(repeating: "2", count: 64),
        keyFingerprint: nil),
      requested: [.pathRead(scope)], added: [.pathRead(scope)], revises: nil, canRemember: true,
      notice: nil, waiting: [(1, 100)])

    var text = ControllerReviewText.summary(reading)

    XCTAssertTrue(text.contains(ControllerReviewText.readsNeedStanding), text)
    XCTAssertTrue(text.contains("Allow for This Run"), text)
    XCTAssertTrue(text.contains("Leaves out: "), text)
    XCTAssertTrue(text.contains("Documents"), text)
    XCTAssertTrue(text.contains("Downloads"), text)
    XCTAssertFalse(text.contains("Lies in or names: Documents"), text)

    reading.resolvedReadDirectories = [home + "/notes": home + "/Documents/notes"]
    text = ControllerReviewText.summary(reading)

    XCTAssertTrue(text.contains("Lies in or names: Documents"), text)

    let plain = ControllerReviewText.summary(try review(signed: true, canRemember: true))

    XCTAssertFalse(plain.contains(ControllerReviewText.readsNeedStanding), plain)
  }

  /// Catches a review that asks for browser navigation without saying it is network access signed in
  /// as the user, one that asks for browser read without saying addresses may carry tokens, and a
  /// review that says either when the controller did not ask for that power.
  func testABrowserReviewSaysNavigationIsNetworkAccessAndReadReturnsAddresses() throws {
    func summary(_ requested: Set<ControllerPermission>) -> String {
      ControllerReviewText.summary(
        ControllerReview(
          id: 4, name: "Reviewed",
          identity: ControllerIdentity(
            controllerID: "dev.uniterm.fixture.reviewed",
            version: String(repeating: "3", count: 64), keyFingerprint: nil),
          requested: requested.sorted(), added: [], revises: nil, canRemember: true, notice: nil,
          waiting: [(1, 100)]))
    }

    let navigation = summary([.paneControl, .browserNavigation])
    let reading = summary([.paneControl, .browserRead])
    let neither = summary([.paneControl])

    XCTAssertTrue(navigation.contains(ControllerReviewText.navigationIsNetworkAccess), navigation)
    XCTAssertTrue(navigation.contains("network access signed in as you"), navigation)
    XCTAssertFalse(navigation.contains(ControllerReviewText.browserReadShowsAddresses), navigation)
    XCTAssertTrue(reading.contains(ControllerReviewText.browserReadShowsAddresses), reading)
    XCTAssertTrue(reading.contains("may carry a token"), reading)
    XCTAssertFalse(reading.contains(ControllerReviewText.navigationIsNetworkAccess), reading)
    XCTAssertFalse(neither.contains("browser"), neither)
    XCTAssertFalse(neither.contains("Browser"), neither)
  }

  /// Catches a window row that leaves out a remembered browser power, or names it as another.
  func testTheWindowNamesEachBrowserPower() {
    XCTAssertTrue(
      ControllerPermission.browserNavigation.displayText.contains("network access signed in"))
    XCTAssertTrue(ControllerPermission.browserRead.displayText.contains("addresses and titles"))

    let lines = ControllerReviewText.permissionLines(
      for: .browserNavigation, prefix: "  ", suffix: ", asks each time")

    XCTAssertEqual(lines.count, 1)
    XCTAssertTrue(lines[0].hasSuffix(", asks each time"), lines[0])
  }

  /// Catches a review that hides what is new, leaves out a power, or lets a name reorder the text
  /// the user reads.
  func testTheReviewShowsWhatIsNewAndEveryPowerEscaped() throws {
    let text = ControllerReviewText.summary(try review(signed: true, canRemember: true))

    XCTAssertTrue(text.contains("New since you trusted it:\n  + Read the clipboard"), text)
    XCTAssertTrue(text.contains("Control panes it may address"), text)
    XCTAssertTrue(text.contains("Start /usr/bin/true as a driver, with any arguments"), text)
    XCTAssertTrue(
      text.contains("2 runs wait. Allow Once and Allow for This Run start the oldest alone."),
      text)
    XCTAssertTrue(text.contains("Synthetic\\u{202E}Name"), text)
    XCTAssertFalse(text.contains("\u{202E}"), text)
  }

  /// Catches a window that hides a remembered approval's selector, fingerprint, or scopes, or a
  /// Revoke that leaves the approval in the file.
  func testTheWindowListsApprovalsAndRevokeRemovesThem() async throws {
    let store = ControllerTrustStore(directory: folder.appendingPathComponent("trust"))
    let policy = ControllerPolicy(
      selector: .identity(
        controllerID: Self.identity.controllerID,
        keyFingerprint: try XCTUnwrap(Self.identity.keyFingerprint)),
      name: "Synthetic", scopes: [.paneControl, .clipboardWrite],
      approved: "2026-11-11T10:00:00Z")

    try store.update { _ in [policy] }

    let window = ControllersWindowController(scriptHost: host)

    try await bounded("the window reads the policies") { await window.settle() }

    XCTAssertEqual(window.rows, [.policy(policy)])

    let detail = ControllersWindowController.describe(.policy(policy))

    XCTAssertTrue(detail.contains("Key fingerprint: \(Self.identity.keyFingerprint!)"), detail)
    XCTAssertTrue(detail.contains("Replace the clipboard"), detail)

    try await bounded("the revoke is done") { await window.revoke(.policy(policy)) }

    XCTAssertEqual(window.rows, [])
    XCTAssertEqual(store.read().policies, [])
  }

  /// Catches a window that hides a live run or how it was approved, or a run's Revoke that
  /// forgets a remembered approval. Revoke on a run ends that run alone.
  func testTheWindowListsLiveRunsAndRevokeEndsTheRunAlone() async throws {
    let store = ControllerTrustStore(directory: folder.appendingPathComponent("trust"))
    let selector = ControllerSelector.version(
      controllerID: Self.identity.controllerID, version: Self.identity.version)
    let policy = ControllerPolicy(
      selector: selector, name: "Synthetic", scopes: [.paneControl],
      approved: "2026-11-11T10:00:00Z")

    try store.update { _ in [policy] }

    let run = ControllerRun(
      identity: Self.identity, name: "Synthetic", entryKind: .janet, entryPath: "main.janet",
      scopes: [.paneControl, .clipboardRead], approval: .remembered(selector),
      standing: [.paneControl], pid: 4242, generation: 1, connection: 9, sourceRoot: nil,
      window: nil, pane: nil, snapshot: folder.appendingPathComponent("snapshot"))

    host.controllerRuns[9] = run

    let window = ControllersWindowController(scriptHost: host)

    try await bounded("the window reads the policies") { await window.settle() }

    XCTAssertEqual(window.rows, [.policy(policy), .run(run)])

    let detail = ControllersWindowController.describe(.run(run))

    XCTAssertTrue(detail.contains("process 4242"), detail)
    XCTAssertTrue(detail.contains("Trusted version"), detail)
    XCTAssertTrue(detail.contains("Read the clipboard, asks each time"), detail)

    try await bounded("the revoke is done") { await window.revoke(.run(run)) }

    XCTAssertTrue(host.isRevoked(9))
    XCTAssertEqual(window.rows, [.policy(policy)])
    XCTAssertEqual(store.read().policies, [policy])
  }

  /// Catches a script file's approval that is missing from the window, listed as a controller's, or
  /// left in its file by Revoke. Revoke also ends the live run that approval admitted, and leaves
  /// the controller approvals as they were.
  func testTheWindowListsFileApprovalsAsTheirOwnRowsAndRevokeRemovesThem() async throws {
    let trust = folder.appendingPathComponent("trust")
    let packages = ControllerTrustStore(directory: trust)
    let files = packages
    let packagePolicy = ControllerPolicy(
      selector: .version(
        controllerID: Self.identity.controllerID, version: Self.identity.version),
      name: "Package", scopes: [.paneControl], approved: "2026-11-11T10:00:00Z")
    let selector = ControllerSelector.fileVersion(version: String(repeating: "7", count: 64))
    let filePolicy = ControllerPolicy(
      selector: selector, name: "Tidy", scopes: [.paneControl, .clipboardRead],
      approved: "2026-11-11T10:00:00Z")

    try packages.update { _ in [packagePolicy, filePolicy] }

    host.controllerRuns[9] = ControllerRun(
      identity: ControllerIdentity(
        controllerID: "tidy.janet", version: String(repeating: "7", count: 64),
        keyFingerprint: nil, artifact: .file),
      name: "Tidy", entryKind: .janet, entryPath: "tidy.janet",
      scopes: [.paneControl, .clipboardRead], approval: .remembered(selector),
      standing: [.paneControl, .clipboardRead], pid: 4242, generation: 1, connection: 9,
      sourceRoot: nil, window: nil, pane: nil, snapshot: folder.appendingPathComponent("snap"))

    let window = ControllersWindowController(scriptHost: host)

    try await bounded("the window reads the policies") { await window.settle() }

    XCTAssertEqual(window.rows.count, 3)
    XCTAssertTrue(window.rows.contains(.policy(packagePolicy)))
    XCTAssertTrue(window.rows.contains(.policy(filePolicy)))

    let detail = ControllersWindowController.describe(.policy(filePolicy))

    XCTAssertTrue(detail.contains("Trusted version of a script file"), detail)
    XCTAssertTrue(detail.contains("Version: \(String(repeating: "7", count: 64))"), detail)
    XCTAssertEqual(ControllersWindowController.subjectText(filePolicy), "Tidy (script file)")
    XCTAssertEqual(
      ControllersWindowController.selectorText(selector), "File version 7777777777777777\u{2026}")

    try await bounded("the revoke is done") { await window.revoke(.policy(filePolicy)) }

    XCTAssertEqual(files.read().policies, [packagePolicy])
    XCTAssertTrue(host.isRevoked(9), "Revoke left the run the approval admitted")
    XCTAssertEqual(window.rows.filter { if case .policy = $0 { true } else { false } }.count, 1)
  }

  /// Catches a file's review that is titled as a controller's.
  func testAFilesReviewIsTitledAsAScriptFile() {
    let review = ControllerReview(
      id: 2, name: "Tidy",
      identity: ControllerIdentity(
        controllerID: "tidy.janet", version: String(repeating: "1", count: 64), keyFingerprint: nil,
        artifact: .file),
      requested: [.paneControl], added: [.paneControl], revises: nil, canRemember: true,
      notice: nil, waiting: [(1, 100)])
    let text = ControllerReviewText.summary(review)

    XCTAssertTrue(text.hasPrefix("Script file: Tidy (tidy.janet)"), text)
    XCTAssertTrue(text.contains("Unsigned: only this exact version can be trusted."), text)
    XCTAssertEqual(
      ControllerReviewText.offered(for: review),
      [.allowOnce, .allowForSession, .trustVersion, .deny])
  }

  /// Catches an undeclared file's review that leaves out an `--allow` capability or the way to make
  /// the script trustable, lets a name reorder the text the user reads, or describes a run as
  /// broader than its choice.
  func testTheUndeclaredReviewListsTheAllowedCapabilitiesAndTheWayToTrust() {
    let review = UndeclaredReview(
      id: 1, name: "tidy\u{202E}.janet", capabilities: ["fs-read", "net-connect"], connection: 4,
      pid: 100)
    let text = ControllerReviewText.summary(review)

    XCTAssertTrue(text.hasPrefix("Undeclared script file: tidy\\u{202E}.janet"), text)
    XCTAssertFalse(text.contains("\u{202E}"), text)
    XCTAssertTrue(text.contains("--allow fs-read\n  --allow net-connect"), text)
    XCTAssertTrue(text.contains("(declare-permissions ...)"), text)
    XCTAssertTrue(text.contains("this run only"), text)

    let bare = ControllerReviewText.summary(
      UndeclaredReview(id: 2, name: "a.janet", capabilities: [], connection: 5, pid: 101))

    XCTAssertTrue(bare.contains("no --allow capabilities"), bare)
    XCTAssertFalse(ControllerReviewText.undeclaredChoices.contains("Trust"))

    let everything = ControllerReviewText.summary(
      UndeclaredRun(
        connection: 4, name: "tidy.janet", pid: 100, capabilities: [], choice: .allowEverything))
    let asking = ControllerReviewText.summary(
      UndeclaredRun(
        connection: 4, name: "tidy.janet", pid: 100, capabilities: [], choice: .askEachUse))

    XCTAssertTrue(everything.contains("without asking"), everything)
    XCTAssertTrue(everything.contains("host launch"), everything)
    XCTAssertTrue(asking.contains("clipboard calls ask"), asking)
    XCTAssertFalse(asking.contains("without asking"), asking)
  }

  /// Catches a window that keeps its selection by index when the chosen row goes. The next row
  /// then takes its place, and Revoke ends a run the user did not choose. The selection goes
  /// with its row.
  func testRevokeNeverActsOnARowTheUserDidNotChoose() async throws {
    for connection in [9, 10] as [UInt64] {
      host.controllerRuns[connection] = ControllerRun(
        identity: Self.identity, name: "Synthetic \(connection)", entryKind: .janet,
        entryPath: "main.janet", scopes: [.paneControl], approval: .session,
        standing: [.paneControl], pid: pid_t(4200 + connection), generation: 1,
        connection: connection, sourceRoot: nil, window: nil, pane: nil,
        snapshot: folder.appendingPathComponent("snapshot-\(connection)"))
    }

    let window = ControllersWindowController(scriptHost: host)

    addTeardownBlock { @MainActor in window.close() }

    try await bounded("the window reads the policies") { await window.settle() }

    let content = try XCTUnwrap(window.window?.contentView)

    guard let table = content.firstDescendant(identifier: "controllers-table") as? NSTableView,
      let revoke = content.firstDescendant(identifier: "controllers-revoke") as? NSButton
    else { return XCTFail("the window has no table or no Revoke button") }

    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    host.controllerRuns[9] = nil
    window.refresh()
    try await bounded("the window reads the policies") { await window.settle() }

    XCTAssertEqual(table.selectedRow, -1, "the selection moved to a row the user did not choose")

    revoke.performClick(nil)

    // Revoke starts a task on the main actor, which runs at the next turn.
    for _ in 0..<5 { await Task.yield() }

    try await bounded("the window settles") { await window.settle() }

    XCTAssertFalse(host.isRevoked(10), "Revoke ended a run the user did not choose")
  }

  /// Catches a window that hides entries this build cannot read, or says who wrote them. A line
  /// under the list gives the count, says this build cannot read them and they do not apply, and
  /// says a newer uniterm may read them. A damaged entry reads the same as a newer one, so the line
  /// never claims a newer version wrote them.
  func testTheWindowCountsKeptEntriesWithoutSayingWhoWroteThem() async throws {
    let store = ControllerTrustStore(directory: folder.appendingPathComponent("trust"))
    let kept = ControllerKeptEntry(
      bytes: Array(
        #"{"approved": "2026-11-11T10:00:00Z", "artifact": "driver", "name": "Later", "scopes": [], "selector": {"kind": "version", "version": "x"}}"#
          .utf8))
    let readable = ControllerPolicy(
      selector: .version(controllerID: Self.identity.controllerID, version: Self.identity.version),
      name: "Synthetic", scopes: [.paneControl], approved: "2026-11-11T10:00:00Z")

    try FileManager.default.createDirectory(
      at: store.directory, withIntermediateDirectories: true)
    try ControllerPolicyFile.encode([readable], kept: [kept, kept]).write(to: store.fileURL)

    let window = ControllersWindowController(scriptHost: host)

    addTeardownBlock { @MainActor in window.close() }

    try await bounded("the window reads the policies") { await window.settle() }

    let content = try XCTUnwrap(window.window?.contentView)
    let line = try XCTUnwrap(
      content.firstDescendant(identifier: "controllers-unreadable") as? NSTextField)

    XCTAssertFalse(line.isHidden)
    XCTAssertTrue(line.stringValue.contains("2 approvals"), line.stringValue)
    XCTAssertTrue(line.stringValue.contains("cannot read"), line.stringValue)
    XCTAssertTrue(line.stringValue.contains("do not apply here"), line.stringValue)
    XCTAssertTrue(line.stringValue.contains("A newer uniterm may read them"), line.stringValue)
    XCTAssertFalse(line.stringValue.lowercased().contains("wrote"), line.stringValue)
    XCTAssertEqual(window.rows, [.policy(readable)], "a kept entry got a row")
    XCTAssertEqual(ControllersWindowController.unreadableText(0), "")
    XCTAssertTrue(ControllersWindowController.unreadableText(1).contains("1 approval"))
    XCTAssertTrue(ControllersWindowController.unreadableText(1).contains("may read it"))
  }

  /// Catches two entries for one selector that fold into one row, or a selection that jumps from
  /// one to the other. Both show, each keeps the selection when the list refreshes, the detail says
  /// Revoke removes both, and Revoke does.
  func testTwoEntriesForOneSelectorBothShowAndSelectionKeepsItsRow() async throws {
    let store = ControllerTrustStore(directory: folder.appendingPathComponent("trust"))
    let selector = ControllerSelector.version(
      controllerID: Self.identity.controllerID, version: Self.identity.version)
    let first = ControllerPolicy(
      selector: selector, name: "Synthetic", scopes: [.paneControl],
      approved: "2026-11-11T10:00:00Z")
    let second = ControllerPolicy(
      selector: selector, name: "Synthetic", scopes: [.clipboardRead],
      approved: "2026-11-12T10:00:00Z")

    try store.update { _ in [first, second] }

    let window = ControllersWindowController(scriptHost: host)

    addTeardownBlock { @MainActor in window.close() }

    try await bounded("the window reads the policies") { await window.settle() }

    XCTAssertEqual(window.rows, [.policy(first), .policy(second)])

    let content = try XCTUnwrap(window.window?.contentView)
    let table = try XCTUnwrap(
      content.firstDescendant(identifier: "controllers-table") as? NSTableView)

    table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
    window.refresh()
    try await bounded("the window reads the policies") { await window.settle() }

    XCTAssertEqual(table.selectedRow, 1, "the selection moved off the row the user chose")

    let detail = ControllersWindowController.describe(.policy(second), sharing: 2)

    XCTAssertTrue(detail.contains("2 approvals in the list name this selector"), detail)
    XCTAssertTrue(detail.contains("Revoke removes all 2"), detail)

    try await bounded("the revoke is done") { await window.revoke(.policy(second)) }

    XCTAssertEqual(window.rows, [])
    XCTAssertEqual(store.read().policies, [])
  }

  /// Catches a prompt that offers no replacement, or one that hides what it replaces. It names each
  /// older approval, says a live run of a replaced version ends, and offers to keep both.
  func testTheReviewNamesWhatTrustingAVersionReplaces() throws {
    let older = (1...2).map { index in
      ControllerPolicy(
        selector: .version(
          controllerID: Self.identity.controllerID,
          version: String(repeating: String(index), count: 64)),
        name: "Older\(index)", scopes: [.paneControl], approved: "2026-11-0\(index)T10:00:00Z",
        versionOf: Self.identity.controllerID)
    }
    let review = ControllerReview(
      id: 5, name: "Synthetic", identity: Self.identity, requested: [.paneControl],
      added: [.paneControl], revises: nil, canRemember: true, notice: nil, waiting: [(1, 100)],
      versionOf: Self.identity.controllerID, older: older)
    let text = ControllerReviewText.summary(review)

    XCTAssertTrue(text.contains("replaces 2 older approvals of dev.uniterm.fixture.window"), text)
    XCTAssertTrue(text.contains("Older1, version 111111111111, approved 2026-11-01"), text)
    XCTAssertTrue(text.contains("Older2, version 222222222222, approved 2026-11-02"), text)
    XCTAssertTrue(text.contains("A live run of a replaced version ends"), text)
    XCTAssertTrue(text.contains("keep them"), text)
    XCTAssertEqual(
      ControllerReviewText.offered(for: review),
      [
        .allowOnce, .allowForSession, .trustVersion, .trustVersionKeepingOlder, .trustIdentity,
        .deny,
      ])
    XCTAssertTrue(ControllerReviewText.choices(for: review).contains("a live run of one ends"))

    let alone = ControllerReview(
      id: 6, name: "Synthetic", identity: Self.identity, requested: [.paneControl],
      added: [.paneControl], revises: nil, canRemember: true, notice: nil, waiting: [(1, 100)])

    XCTAssertFalse(ControllerReviewText.summary(alone).contains("replaces"))
    XCTAssertFalse(ControllerReviewText.offered(for: alone).contains(.trustVersionKeepingOlder))

    let locked = ControllerReview(
      id: 7, name: "Synthetic", identity: Self.identity, requested: [.paneControl],
      added: [.paneControl], revises: nil, canRemember: false, notice: nil, waiting: [(1, 100)],
      versionOf: Self.identity.controllerID, older: older)

    XCTAssertFalse(ControllerReviewText.summary(locked).contains("replaces"))
  }
}
