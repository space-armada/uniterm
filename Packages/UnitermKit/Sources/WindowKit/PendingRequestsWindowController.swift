import AppKit
import ControllerPackage
import ControllerTrust
import PaneModel
import ScriptHost

/// The panel that lists programs asking for a pane, exec drivers asking to run, and the grants
/// the user has made for either.
///
/// A program outside every uniterm pane has no pane access. The user grants one connection one
/// pane here, denies it, or revokes a grant. Nothing here lasts past the connection.
///
/// A driver launch shows every input it binds: its argv, its directory, its environment values,
/// and its pane. Allow Once runs exactly those inputs once. Allow in This Pane also lets later
/// runs of the same program, in the same directory and pane, with no environment key beyond
/// these, start without asking, whatever their arguments and values. These buttons are the only
/// way a launch is approved.
///
/// A controller's startup review lists the powers it asks for once, and is answered here. The
/// trust choices show only where the review offers them, and the help button says what each
/// choice covers. A permission question from a script, a driver, or a terminal waits here as one
/// row however many times it is asked. A denial stays listed, and Ask Again is the only way to be
/// asked again.
@MainActor
public final class PendingRequestsWindowController: NSWindowController {
  private enum Row {
    case request(ScriptHost.PendingRequest)
    case grant(ScriptHost.ExplicitGrant)
    case launch(ExecLaunchAuthority.Request)
    case launchGrant(ExecLaunchAuthority.Grant)
    case review(ControllerReview)
    case undeclaredReview(UndeclaredReview)
    case undeclaredRun(UndeclaredRun)
    case question(PermissionRequests.Row)
    case denial(PermissionRequests.Denial)

    /// What the row is about, which stays the same while its contents change.
    var identity: RowIdentity {
      switch self {
      case .request(let request): return .request(request.id)
      case .grant(let grant): return .grant(grant.connection)
      case .launch(let request): return .launch(request.id)
      case .launchGrant(let grant): return .launchGrant(grant.id)
      case .review(let review): return .review(review.id)
      case .undeclaredReview(let review): return .undeclaredReview(review.id)
      case .undeclaredRun(let run): return .undeclaredRun(run.connection)
      case .question(let question): return .question(question.id)
      case .denial(let denial): return .denial(denial.id)
      }
    }
  }

  private enum RowIdentity: Equatable {
    case request(UInt64)
    case grant(UInt64)
    case launch(UInt64)
    case launchGrant(UInt64)
    case review(UInt64)
    case undeclaredReview(UInt64)
    case undeclaredRun(UInt64)
    case question(UInt64)
    case denial(UInt64)
  }

  private let scriptHost: ScriptHost?
  private let windows: WindowSet
  private let tableView = NSTableView()
  private let detail = NSTextField(wrappingLabelWithString: "")
  private let grantButton = NSButton(title: "Grant Access\u{2026}", target: nil, action: nil)
  private let allowOnceButton = NSButton(title: "Allow Once", target: nil, action: nil)
  private let allowInPaneButton = NSButton(title: "Allow in This Pane", target: nil, action: nil)
  private let denyButton = NSButton(title: "Deny", target: nil, action: nil)
  private let revokeButton = NSButton(title: "Revoke", target: nil, action: nil)
  private let trustVersionButton = NSButton(title: "Trust This Version", target: nil, action: nil)
  private let trustIdentityButton = NSButton(
    title: "Trust This Identity", target: nil, action: nil)
  private let helpButton = NSButton(title: "", target: nil, action: nil)

  /// Whether Trust This Version replaces the older version approvals the review names. It is on
  /// for each review the user selects.
  private let replaceOlderCheckbox = NSButton(
    checkboxWithTitle: "Replace the older versions listed above", target: nil, action: nil)
  private var replaceOlderReview: UInt64?
  private let sessionButton = NSButton(title: "Allow for This Run", target: nil, action: nil)
  private let askAgainButton = NSButton(title: "Ask Again", target: nil, action: nil)
  private var rows: [Row] = []

  /// The popover the help button opens, with the review it describes.
  private var help: (popover: NSPopover, row: RowIdentity)?
  private var observers: [ChangeObservers.Token] = []

  private var permissions: PermissionRequests { windows.permissionRequests }

  private var launches: ExecLaunchAuthority { windows.launchAuthority }

  public init(scriptHost: ScriptHost?, windows: WindowSet) {
    self.scriptHost = scriptHost
    self.windows = windows

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 360),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)

    window.title = "Pending Requests"
    window.identifier = NSUserInterfaceItemIdentifier("pending-requests-window")
    window.setAccessibilityIdentifier("pending-requests-window")
    window.isReleasedWhenClosed = false

    super.init(window: window)

    buildContent()
    refresh()

    if let scriptHost {
      observers.append(scriptHost.changes.add { [weak self] in self?.refresh() })
    }

    observers.append(windows.permissionRequests.changes.add { [weak self] in self?.refresh() })
    windows.launchAuthority.onChange = { [weak self] in self?.refresh() }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func buildContent() {
    guard let contentView = window?.contentView else { return }

    let heading = NSTextField(
      labelWithString:
        "Programs that asked to act for a pane, controllers and drivers that asked to run, and "
        + "permissions programs asked for:")

    heading.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)

    for (identifier, title, width) in [
      ("program", "Program", 300.0), ("pid", "PID", 70.0), ("status", "Status", 200.0),
    ] {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))

      column.title = title
      column.width = width
      tableView.addTableColumn(column)
    }

    tableView.dataSource = self
    tableView.delegate = self
    tableView.usesAlternatingRowBackgroundColors = true
    tableView.setAccessibilityIdentifier("pending-requests-table")

    let scrollView = NSScrollView()

    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true

    detail.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    detail.isSelectable = true
    detail.setAccessibilityIdentifier("pending-requests-detail")

    grantButton.target = self
    grantButton.action = #selector(grantPressed)
    allowOnceButton.target = self
    allowOnceButton.action = #selector(allowOncePressed)
    allowOnceButton.setAccessibilityIdentifier("pending-requests-allow-once")
    allowInPaneButton.target = self
    allowInPaneButton.action = #selector(allowInPanePressed)
    allowInPaneButton.setAccessibilityIdentifier("pending-requests-allow-in-pane")
    denyButton.target = self
    denyButton.action = #selector(denyPressed)
    revokeButton.target = self
    revokeButton.action = #selector(revokePressed)
    trustVersionButton.target = self
    trustVersionButton.action = #selector(trustVersionPressed)
    trustVersionButton.setAccessibilityIdentifier("pending-requests-trust-version")
    trustIdentityButton.target = self
    trustIdentityButton.action = #selector(trustIdentityPressed)
    trustIdentityButton.setAccessibilityIdentifier("pending-requests-trust-identity")
    helpButton.bezelStyle = .helpButton
    helpButton.target = self
    helpButton.action = #selector(helpPressed)
    helpButton.setAccessibilityIdentifier("pending-requests-help")
    helpButton.setAccessibilityLabel("Help")
    sessionButton.target = self
    sessionButton.action = #selector(sessionPressed)
    sessionButton.setAccessibilityIdentifier("pending-requests-allow-session")
    askAgainButton.target = self
    askAgainButton.action = #selector(askAgainPressed)
    askAgainButton.setAccessibilityIdentifier("pending-requests-ask-again")
    replaceOlderCheckbox.setAccessibilityIdentifier("pending-requests-replace-older")
    replaceOlderCheckbox.isHidden = true

    let buttons = NSStackView(views: [
      helpButton, grantButton, allowOnceButton, allowInPaneButton, sessionButton,
      trustVersionButton, trustIdentityButton, denyButton, NSView(), askAgainButton, revokeButton,
    ])

    // The row holds more buttons than fit at once. A hidden button must take no room. The row
    // keeps a button's height while it shows none, so the list does not jump on selection.
    buttons.detachesHiddenViews = true
    buttons.orientation = .horizontal
    buttons.heightAnchor.constraint(greaterThanOrEqualToConstant: denyButton.fittingSize.height)
      .isActive = true

    let footer = NSStackView(views: [replaceOlderCheckbox, buttons])

    footer.orientation = .vertical
    footer.alignment = .leading
    footer.detachesHiddenViews = true
    buttons.trailingAnchor.constraint(equalTo: footer.trailingAnchor).isActive = true

    for view in [heading, scrollView, detail, footer] {
      view.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(view)
    }

    NSLayoutConstraint.activate([
      heading.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
      heading.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
      heading.trailingAnchor.constraint(
        lessThanOrEqualTo: contentView.trailingAnchor, constant: -20),

      scrollView.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
      scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
      scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
      scrollView.bottomAnchor.constraint(equalTo: detail.topAnchor, constant: -12),

      detail.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
      detail.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
      detail.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
      detail.heightAnchor.constraint(greaterThanOrEqualToConstant: 64),

      footer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
      footer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
      footer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
    ])
  }

  /// Reads the requests and grants again. The script host and the launch authority call it
  /// whenever either changes.
  ///
  /// The selection follows the row the user chose, not its position, since rows above it come
  /// and go. When that row is gone, nothing is selected, so no button acts on a row the user did
  /// not choose.
  private func refresh() {
    let chosen = selectedRow?.identity

    rows =
      (scriptHost?.controllerReviews.map(Row.review) ?? [])
      + (scriptHost?.undeclaredReviews.map(Row.undeclaredReview) ?? [])
      + (scriptHost?.allPendingRequests().map(Row.request) ?? [])
      + launches.requests.map(Row.launch) + permissions.rows.map(Row.question)
      + (scriptHost?.allGrants().map(Row.grant) ?? [])
      + (scriptHost?.allUndeclaredRuns().map(Row.undeclaredRun) ?? [])
      + launches.grants.map(Row.launchGrant)
      + permissions.denials.map(Row.denial)

    tableView.reloadData()

    if let chosen, let index = rows.firstIndex(where: { $0.identity == chosen }) {
      tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    } else {
      tableView.deselectAll(nil)
    }

    updateButtons()
  }

  private var selectedRow: Row? {
    let index = tableView.selectedRow

    return rows.indices.contains(index) ? rows[index] : nil
  }

  /// Shows only the buttons that answer the selected row. Every button it shows is live. With
  /// nothing selected, no button shows, and the detail says what to do.
  private func updateButtons() {
    let row = selectedRow

    for button in allButtons {
      button.isHidden = true
      button.isEnabled = true
    }

    replaceOlderCheckbox.isHidden = true

    allowOnceButton.title = "Allow Once"
    sessionButton.title = "Allow for This Run"
    denyButton.title = "Deny"

    if let help, row?.identity != help.row {
      help.popover.close()
      self.help = nil
    }

    let shown: [NSButton]

    switch row {
    case .request:
      shown = [grantButton, denyButton]

    case .launch:
      shown = [allowOnceButton, allowInPaneButton, denyButton]

    case .grant, .launchGrant:
      shown = [revokeButton]

    case .review(let review):
      let offered = ControllerReviewText.offered(for: review)

      shown =
        [helpButton, allowOnceButton, sessionButton]
        + (offered.contains(.trustVersion) ? [trustVersionButton] : [])
        + (offered.contains(.trustIdentity) ? [trustIdentityButton] : []) + [denyButton]

      if offered.contains(.trustVersionKeepingOlder) {
        if replaceOlderReview != review.id {
          replaceOlderReview = review.id
          replaceOlderCheckbox.state = .on
        }

        replaceOlderCheckbox.isHidden = false
      }

    case .undeclaredReview:
      allowOnceButton.title = "Allow and Ask Each Use"
      sessionButton.title = "Allow Everything"
      denyButton.title = "Reject"
      shown = [helpButton, allowOnceButton, sessionButton, denyButton]

    case .undeclaredRun:
      shown = [revokeButton]

    case .question(let question):
      sessionButton.title = question.sessionTitle
      shown =
        question.onceOnly
        ? [allowOnceButton, denyButton] : [allowOnceButton, sessionButton, denyButton]

    case .denial:
      shown = [askAgainButton]

    case nil:
      shown = []
    }

    for button in shown {
      button.isHidden = false
    }

    if let row {
      detail.stringValue = describe(row)
    } else {
      detail.stringValue =
        rows.isEmpty ? "Nothing waits for your answer." : "Select a request to answer it."
    }
  }

  private var allButtons: [NSButton] {
    [
      helpButton, grantButton, allowOnceButton, allowInPaneButton, sessionButton,
      trustVersionButton, trustIdentityButton, denyButton, askAgainButton, revokeButton,
    ]
  }

  /// Every input a launch binds, or the scope a grant covers, in full.
  private func describe(_ row: Row) -> String {
    switch row {
    case .launch(let request):
      return LaunchApprovalText.request(
        request.launch, pane: paneTitle(request.target, fallback: request.paneTitle))

    case .launchGrant(let grant):
      return LaunchApprovalText.grant(
        grant, pane: paneTitle(grant.target, fallback: grant.paneTitle))

    case .review(let review):
      return ControllerReviewText.summary(review)

    case .undeclaredReview(let review):
      return ControllerReviewText.summary(review)

    case .undeclaredRun(let run):
      return ControllerReviewText.summary(run)

    case .question(let question):
      return question.waiting > 1
        ? "\(question.detail)\n\(question.waiting) requests wait. Allow Once allows the oldest alone."
        : question.detail

    case .denial(let denial):
      return
        "You denied \(denial.subject): \(denial.title). Later requests are refused without "
        + "asking until you choose Ask Again."

    case .request, .grant:
      return ""
    }
  }

  private func paneTitle(_ target: ExecLaunchAuthority.Target, fallback: String) -> String {
    guard let controller = windows.controller(forScriptWindow: target.window),
      let applet = controller.paneArea.applet(for: target.pane)
    else { return fallback }

    return "\(controller.window?.title ?? "Window"): \(applet.title)"
  }

  @objc private func allowOncePressed() {
    switch selectedRow {
    case .launch(let request): launches.decide(request.id, .allowOnce)
    case .question(let question): permissions.decide(question.id, .allowOnce)
    case .review(let review): answer(review, .allowOnce)
    case .undeclaredReview(let review): answer(review, .askEachUse)
    default: break
    }
  }

  @objc private func sessionPressed() {
    switch selectedRow {
    case .question(let question): permissions.decide(question.id, .allowForSession)
    case .review(let review): answer(review, .allowForSession)
    case .undeclaredReview(let review): answer(review, .allowEverything)
    default: break
    }
  }

  @objc private func askAgainPressed() {
    guard case .denial(let denial) = selectedRow else { return }

    permissions.askAgain(denial.id)
  }

  @objc private func trustVersionPressed() {
    guard case .review(let review) = selectedRow,
      ControllerReviewText.offered(for: review).contains(.trustVersion)
    else { return }

    let replacing =
      replaceOlderCheckbox.isHidden || replaceOlderCheckbox.state == .on
    answer(review, replacing ? .trustVersion : .trustVersionKeepingOlder)
  }

  @objc private func trustIdentityPressed() {
    guard case .review(let review) = selectedRow,
      ControllerReviewText.offered(for: review).contains(.trustIdentity)
    else { return }

    answer(review, .trustIdentity)
  }

  /// How wide the help text wraps, about the width of a standard alert's text.
  private static let helpWidth: CGFloat = 320

  /// Shows what each offered choice covers, or closes the help when it already shows. The text
  /// is read when the help opens, and the help closes once its review is no longer selected.
  @objc private func helpPressed() {
    if let help {
      help.popover.close()
      self.help = nil

      return
    }

    let words: String

    switch selectedRow {
    case .review(let review): words = ControllerReviewText.choices(for: review)
    case .undeclaredReview: words = ControllerReviewText.undeclaredChoices
    default: return
    }

    let text = NSTextField(wrappingLabelWithString: words)

    text.isSelectable = true
    text.preferredMaxLayoutWidth = Self.helpWidth
    text.setAccessibilityIdentifier("pending-requests-help-text")
    text.translatesAutoresizingMaskIntoConstraints = false

    let content = NSView()

    content.addSubview(text)

    NSLayoutConstraint.activate([
      text.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
      text.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
      text.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
      text.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
      text.widthAnchor.constraint(equalToConstant: Self.helpWidth),
    ])

    let controller = NSViewController()
    let popover = NSPopover()

    controller.view = content
    popover.contentViewController = controller
    // A click elsewhere in the panel leaves the help up, so the help button can close it rather
    // than a transient close followed by the same click opening it again.
    popover.behavior = .semitransient
    popover.delegate = self
    help = (popover, selectedRow?.identity ?? .review(0))

    // Above the button, so the help covers the panel and not whatever lies below it.
    popover.show(
      relativeTo: helpButton.bounds, of: helpButton,
      preferredEdge: helpButton.isFlipped ? .minY : .maxY)
  }

  private func answer(_ review: ControllerReview, _ choice: ControllerReviewChoice) {
    Task { @MainActor [weak self] in
      guard let self, let scriptHost,
        let failure = await scriptHost.decideReview(review.id, choice), let window
      else { return }

      let alert = NSAlert()

      alert.alertStyle = .warning
      alert.messageText = "The review was not answered"
      alert.informativeText = failure
      alert.addButton(withTitle: "OK")
      alert.beginSheetModal(for: window) { _ in }
    }
  }

  private func answer(_ review: UndeclaredReview, _ choice: UndeclaredReviewChoice) {
    guard let failure = scriptHost?.decideUndeclaredReview(review.id, choice), let window
    else { return }

    let alert = NSAlert()

    alert.alertStyle = .warning
    alert.messageText = "The review was not answered"
    alert.informativeText = failure
    alert.addButton(withTitle: "OK")
    alert.beginSheetModal(for: window) { _ in }
  }

  @objc private func allowInPanePressed() {
    guard case .launch(let request) = selectedRow else { return }

    launches.decide(request.id, .allowInPane)
  }

  @objc private func grantPressed() {
    guard case .request(let request) = selectedRow else { return }

    askForPane(for: request)
  }

  @objc private func denyPressed() {
    switch selectedRow {
    case .request(let request): scriptHost?.denyRequest(connection: request.id)
    case .launch(let request): launches.decide(request.id, .deny)
    case .question(let question): permissions.decide(question.id, .deny)
    case .review(let review): answer(review, .deny)
    case .undeclaredReview(let review): answer(review, .reject)
    default: break
    }
  }

  @objc private func revokePressed() {
    switch selectedRow {
    case .grant(let grant): scriptHost?.revokeGrant(connection: grant.connection)
    case .undeclaredRun(let run): scriptHost?.revokeUndeclaredRun(connection: run.connection)
    case .launchGrant(let grant): launches.revokeGrant(grant.id)
    default: break
    }
  }

  /// The panes a grant can name: those that run a recorded session, in window order.
  private func grantablePanes() -> [(title: String, window: UInt64, pane: NodeID)] {
    guard let scriptHost else { return [] }

    return windows.controllers.flatMap { controller in
      controller.paneIDs.compactMap { pane in
        guard let applet = controller.paneArea.applet(for: pane),
          scriptHost.sessionRoot(window: controller.scriptWindowID, pane: pane) != nil
        else { return nil }

        let windowTitle = controller.window?.title ?? "Window"

        return ("\(windowTitle): \(applet.title)", controller.scriptWindowID, pane)
      }
    }
  }

  private func askForPane(for request: ScriptHost.PendingRequest) {
    guard let window else { return }

    let program = request.executablePath ?? request.name
    let panes = grantablePanes()
    let alert = NSAlert()

    guard !panes.isEmpty else {
      alert.messageText = "No pane can be granted"
      alert.informativeText = "Only a terminal or REPL pane with a running session can be granted."
      alert.addButton(withTitle: "OK")
      alert.beginSheetModal(for: window)

      return
    }

    let popup = NSPopUpButton()

    popup.setAccessibilityIdentifier("pending-requests-pane")

    for (index, pane) in panes.enumerated() {
      popup.addItem(withTitle: pane.title)
      popup.lastItem?.tag = index
    }

    popup.sizeToFit()

    alert.messageText = "Let this program act for a pane?"
    alert.informativeText =
      "\(program), process \(request.pid), may then act for the pane you choose, in that pane's "
      + "window only. The grant ends when the program disconnects or exits, when the pane's "
      + "session ends, when the window closes, or when you revoke it."
    alert.accessoryView = popup
    alert.addButton(withTitle: "Grant")
    alert.addButton(withTitle: "Cancel")

    alert.beginSheetModal(for: window) { [weak self] response in
      guard response == .alertFirstButtonReturn, let self,
        panes.indices.contains(popup.selectedTag())
      else { return }

      let pane = panes[popup.selectedTag()]

      guard let scriptHost = self.scriptHost else { return }

      self.report(
        scriptHost.grantAccess(connection: request.id, window: pane.window, pane: pane.pane))
    }
  }

  private func report(_ result: ScriptHost.GrantResult) {
    guard let window else { return }

    let alert = NSAlert()

    switch result {
    case .granted:
      return

    case .connectionClosed:
      alert.messageText = "The program has gone"
      alert.informativeText = "It disconnected or exited before the grant, so nothing was granted."

    case .failed(let reason):
      alert.messageText = "Nothing was granted"
      alert.informativeText = reason
    }

    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    alert.beginSheetModal(for: window)
  }
}

extension PendingRequestsWindowController: NSPopoverDelegate {
  /// The popover also closes itself, on Escape or a click in another window, so the help forgets
  /// it here.
  public func popoverDidClose(_ notification: Notification) {
    if (notification.object as? NSPopover) === help?.popover { help = nil }
  }
}

extension PendingRequestsWindowController: NSTableViewDataSource, NSTableViewDelegate {
  public func numberOfRows(in tableView: NSTableView) -> Int {
    rows.count
  }

  public func tableView(
    _ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int
  ) -> Any? {
    guard rows.indices.contains(row) else { return nil }

    switch (rows[row], tableColumn?.identifier.rawValue) {
    case (.request(let request), "program"): return request.executablePath ?? request.name
    case (.request(let request), "pid"): return String(request.pid)
    case (.request, "status"): return "Waiting"
    case (.grant(let grant), "program"): return grant.executablePath ?? "unknown"
    case (.grant(let grant), "pid"): return String(grant.pid)
    case (.grant(let grant), "status"): return "Granted \(paneTitle(grant))"
    case (.launch(let request), "program"): return request.launch.declaration.executable
    case (.launch, "pid"): return "\u{2014}"
    case (.launch(let request), "status"):
      return "Wants to run in \(paneTitle(request.target, fallback: request.paneTitle))"
    case (.launchGrant(let grant), "program"): return grant.executable
    case (.launchGrant, "pid"): return "\u{2014}"
    case (.launchGrant(let grant), "status"):
      return "Allowed in \(paneTitle(grant.target, fallback: grant.paneTitle))"
    case (.review(let review), "program"): return "\(review.name) (\(review.identity.controllerID))"
    case (.review(let review), "pid"):
      return review.waiting.map { String($0.pid) }.joined(separator: ", ")
    case (.review(let review), "status"):
      return review.waiting.count > 1
        ? "Waits for review, \(review.waiting.count) runs" : "Waits for review"
    case (.undeclaredReview(let review), "program"): return "\(review.name) (undeclared)"
    case (.undeclaredReview(let review), "pid"): return String(review.pid)
    case (.undeclaredReview, "status"): return "Waits for review"
    case (.undeclaredRun(let run), "program"): return "\(run.name) (undeclared)"
    case (.undeclaredRun(let run), "pid"): return String(run.pid)
    case (.undeclaredRun(let run), "status"):
      return run.choice == .allowEverything ? "Running, Allow Everything" : "Running, Ask Each Use"
    case (.question(let question), "program"): return question.subject
    case (.question(let question), "pid"): return question.pid.map(String.init) ?? "\u{2014}"
    case (.question(let question), "status"):
      return question.waiting > 1
        ? "\(question.title), \(question.waiting) waiting" : question.title
    case (.denial(let denial), "program"): return denial.subject
    case (.denial, "pid"): return "\u{2014}"
    case (.denial(let denial), "status"): return "Denied: \(denial.title)"
    default: return nil
    }
  }

  public func tableViewSelectionDidChange(_ notification: Notification) {
    updateButtons()
  }

  private func paneTitle(_ grant: ScriptHost.ExplicitGrant) -> String {
    guard let controller = windows.controller(forScriptWindow: grant.window),
      let applet = controller.paneArea.applet(for: grant.pane)
    else { return "a closed pane" }

    return "\(controller.window?.title ?? "Window"): \(applet.title)"
  }
}
