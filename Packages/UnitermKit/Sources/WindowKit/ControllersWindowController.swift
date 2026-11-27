import AppKit
import ControllerPackage
import ControllerTrust
import ScriptHost
import SourceAccess

/// The Controllers & Permissions window. It lists the remembered approvals, each by its version or
/// key selector with the fingerprint and the approved scopes, and the controller runs that are
/// live now, each with how it was approved.
///
/// Revoke on a remembered approval removes it from the policy file, then ends the authority of
/// every live run it admitted, with their waiting work. Revoke on a run ends that run's authority
/// alone and keeps any remembered approval, as the pane badge's Revoke does. Neither undoes what
/// an approved program already did.
@MainActor
public final class ControllersWindowController: NSWindowController {
  enum Row: Equatable {
    case policy(ControllerPolicy)
    case run(ControllerRun)
  }

  private let scriptHost: ScriptHost
  private let tableView = NSTableView()
  private let detail = NSTextField(wrappingLabelWithString: "")
  private let notice = NSTextField(wrappingLabelWithString: "")
  private let unreadable = NSTextField(wrappingLabelWithString: "")
  private let revokeButton = NSButton(title: "Revoke", target: nil, action: nil)
  private var observer: ChangeObservers.Token?
  private var reading: Task<Void, Never>?

  private(set) var rows: [Row] = []

  /// The read-scope directories shown, with their links resolved. They are read off the main
  /// thread when a row first shows them, and the detail follows.
  private var resolvedReads: [String: String] = [:]
  private var askedReads: Set<String> = []

  public init(scriptHost: ScriptHost) {
    self.scriptHost = scriptHost

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)

    window.title = "Controllers & Permissions"
    window.identifier = NSUserInterfaceItemIdentifier("controllers-window")
    window.setAccessibilityIdentifier("controllers-window")
    window.isReleasedWhenClosed = false
    window.isRestorable = false

    super.init(window: window)

    buildContent()
    observer = scriptHost.changes.add { [weak self] in self?.refresh() }
    refresh()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  public func present() {
    NSApp.activate()
    refresh()
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
  }

  private func buildContent() {
    guard let contentView = window?.contentView else { return }

    let heading = NSTextField(
      labelWithString:
        "Remembered controller and script file approvals, and the runs live now:")

    heading.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)

    for (identifier, title, width) in [
      ("controller", "Controller", 260.0), ("selector", "Approved As", 200.0),
      ("scopes", "Powers", 220.0),
    ] {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))

      column.title = title
      column.width = width
      tableView.addTableColumn(column)
    }

    tableView.dataSource = self
    tableView.delegate = self
    tableView.usesAlternatingRowBackgroundColors = true
    tableView.setAccessibilityIdentifier("controllers-table")

    let scrollView = NSScrollView()

    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true

    detail.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    detail.isSelectable = true
    detail.setAccessibilityIdentifier("controllers-detail")
    notice.textColor = .secondaryLabelColor
    notice.setAccessibilityIdentifier("controllers-notice")
    unreadable.textColor = .secondaryLabelColor
    unreadable.isHidden = true
    unreadable.setAccessibilityIdentifier("controllers-unreadable")

    revokeButton.target = self
    revokeButton.action = #selector(revokePressed)
    revokeButton.setAccessibilityIdentifier("controllers-revoke")

    for view in [heading, scrollView, unreadable, detail, notice, revokeButton] {
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
      scrollView.bottomAnchor.constraint(equalTo: unreadable.topAnchor, constant: -8),

      unreadable.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
      unreadable.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
      unreadable.bottomAnchor.constraint(equalTo: detail.topAnchor, constant: -12),

      detail.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
      detail.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
      detail.bottomAnchor.constraint(equalTo: notice.topAnchor, constant: -8),
      detail.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),

      notice.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
      notice.trailingAnchor.constraint(equalTo: revokeButton.leadingAnchor, constant: -12),
      notice.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),

      revokeButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
      revokeButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
    ])
  }

  /// Reads the policy file off the main actor, then lists it with the live runs. A read that a
  /// later one overtakes is dropped.
  func refresh() {
    reading?.cancel()
    reading = Task { @MainActor [weak self] in
      guard let self else { return }

      let state = await scriptHost.rememberedTrust()

      guard !Task.isCancelled else { return }

      show(policies: state.policies, notice: state.notice, unreadable: state.unreadable)
    }
  }

  /// Waits for the read in progress, so a test sees what the window shows.
  func settle() async {
    await reading?.value
  }

  /// The selection follows the row the user chose, a policy by its selector and a run by its
  /// connection, since rows come and go and a run's row changes as its powers do. When that row
  /// is gone, nothing is selected, so Revoke never acts on a row the user did not choose.
  private func show(policies: [ControllerPolicy], notice text: String?, unreadable count: Int) {
    let selected =
      rows.indices.contains(tableView.selectedRow) ? identity(at: tableView.selectedRow) : nil

    rows =
      policies.sorted {
        Self.order($0).lexicographicallyPrecedes(Self.order($1))
      }
      .map(Row.policy) + scriptHost.allControllerRuns().map(Row.run)
    notice.stringValue = text ?? ""
    unreadable.stringValue = Self.unreadableText(count)
    unreadable.isHidden = count == 0
    tableView.reloadData()

    if let selected, let index = index(of: selected) {
      tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    } else {
      tableView.deselectAll(nil)
    }

    updateDetail()
    resolveReads()
  }

  /// Resolves the links of every read-scope directory a row shows that was not resolved yet. The
  /// disk is read off the main thread, and the detail is drawn again when the answer arrives.
  private func resolveReads() {
    var wanted: Set<String> = []

    for row in rows {
      let permissions: Set<ControllerPermission>

      switch row {
      case .policy(let policy): permissions = policy.scopes
      case .run(let run): permissions = run.scopes
      }

      for case .pathRead(let scope) in permissions.map(\.kind) {
        wanted.formUnion(scope.directories)
      }
    }

    let fresh = wanted.subtracting(askedReads)

    guard !fresh.isEmpty, let scope = try? ReadScope(directories: Array(fresh)) else { return }

    askedReads.formUnion(fresh)

    Task { @MainActor [weak self] in
      let resolved = await Task.detached { scope.resolvedDirectories() }.value

      guard let self else { return }

      resolvedReads.merge(resolved) { $1 }
      updateDetail()
    }
  }

  /// A policy is chosen by what it holds, with its place among identical ones, so two approvals
  /// for one selector are two rows and the selection never moves from one to the other.
  private enum RowIdentity: Equatable {
    case policy(ControllerPolicy, occurrence: Int)
    case run(UInt64)
  }

  private func identity(at index: Int) -> RowIdentity {
    switch rows[index] {
    case .policy(let policy):
      return .policy(policy, occurrence: rows[..<index].filter { $0 == rows[index] }.count)

    case .run(let run): return .run(run.connection)
    }
  }

  private func index(of identity: RowIdentity) -> Int? {
    switch identity {
    case .run(let connection):
      return rows.firstIndex {
        if case .run(let run) = $0 { return run.connection == connection }
        return false
      }

    case .policy(let policy, let occurrence):
      return rows.indices.filter { rows[$0] == .policy(policy) }.dropFirst(occurrence).first
    }
  }

  /// The order of the policy rows. Every field takes part, so two approvals for one selector keep
  /// their places from one refresh to the next.
  private static func order(_ policy: ControllerPolicy) -> [String] {
    [
      policy.selector.controllerID, policy.approved, policy.selector.kindName,
      policy.selector.value, policy.selector.artifact.rawValue, policy.name,
      policy.versionOf ?? "", policy.scopes.sorted().map(\.kindName).joined(separator: ","),
    ]
  }

  /// The line under the approvals when this build cannot read some. It says what the count means
  /// for this build and never says who wrote them, since a damaged entry reads the same.
  static func unreadableText(_ count: Int) -> String {
    guard count > 0 else { return "" }

    let subject = count == 1 ? "1 approval" : "\(count) approvals"
    let those = count == 1 ? "it does" : "they do"

    return "This uniterm cannot read \(subject) in its policy file, so \(those) not apply here. "
      + "A newer uniterm may read \(count == 1 ? "it" : "them"). The file keeps "
      + "\(count == 1 ? "it" : "them") as written."
  }

  private var selectedRow: Row? {
    let index = tableView.selectedRow

    return rows.indices.contains(index) ? rows[index] : nil
  }

  private func updateDetail() {
    revokeButton.isEnabled = selectedRow != nil
    detail.stringValue =
      selectedRow.map { row in
        var sharing = 1

        if case .policy(let policy) = row {
          sharing =
            rows.filter {
              if case .policy(let other) = $0 { return other.selector == policy.selector }

              return false
            }.count
        }

        return Self.describe(row, resolved: resolvedReads, sharing: sharing)
      } ?? ""
  }

  static func selectorText(_ selector: ControllerSelector) -> String {
    switch selector {
    case .version(_, let version): return "Version \(version.prefix(16))\u{2026}"
    case .identity(_, let fingerprint): return "Key \(fingerprint.prefix(16))\u{2026}"
    case .fileVersion(let version): return "File version \(version.prefix(16))\u{2026}"
    case .fileIdentity(_, let fingerprint): return "File key \(fingerprint.prefix(16))\u{2026}"
    }
  }

  /// A policy's name with what it names: a controller's ID, a signed file's ID, or "script file"
  /// for an unsigned file, which has no ID.
  static func subjectText(_ policy: ControllerPolicy) -> String {
    let id =
      policy.selector.controllerID.isEmpty ? "script file" : policy.selector.controllerID

    return "\(LaunchApprovalText.escaped(policy.name)) (\(id))"
  }

  /// `sharing` is how many approvals the window lists for the row's selector. Revoke removes them
  /// all, and the detail says so.
  static func describe(
    _ row: Row, resolved: [String: String] = [:], sharing: Int = 1
  ) -> String {
    switch row {
    case .policy(let policy):
      let selector: String

      switch policy.selector {
      case .version(let id, let version):
        selector = "Trusted version of \(id)\nVersion: \(version)"

      case .identity(let id, let fingerprint):
        selector =
          "Trusted identity: \(id), every version this key signs\nKey fingerprint: \(fingerprint)"

      case .fileVersion(let version):
        selector = "Trusted version of a script file\nVersion: \(version)"

      case .fileIdentity(let id, let fingerprint):
        selector =
          "Trusted identity of a script file: \(id), every version this key signs\n"
          + "Key fingerprint: \(fingerprint)"
      }

      var lines = [selector, "Approved: \(policy.approved)"]

      if let versionOf = policy.versionOf {
        lines.append("A version of: \(LaunchApprovalText.escaped(versionOf))")
      }

      if sharing > 1 {
        lines.append(
          "\(sharing) approvals in the list name this selector. Revoke removes all \(sharing).")
      }

      lines.append("Powers:")

      return
        (lines
        + policy.scopes.sorted().flatMap {
          ControllerReviewText.permissionLines(for: $0, prefix: "  ", resolved: resolved)
        })
        .joined(separator: "\n")

    case .run(let run):
      let key = run.identity.keyFingerprint.map { "Key fingerprint: \($0)" } ?? "Unsigned"

      return
        ([
          "Live run of \(LaunchApprovalText.escaped(run.name)) (\(run.identity.controllerID)), "
            + "process \(run.pid)",
          "Version: \(run.identity.version)", key, run.approval.displayText, "Powers it asked for:",
        ]
        + run.scopes.sorted().flatMap {
          ControllerReviewText.permissionLines(
            for: $0, prefix: "  ", suffix: run.standing.contains($0) ? "" : ", asks each time",
            resolved: resolved)
        }).joined(separator: "\n")
    }
  }

  @objc private func revokePressed() {
    guard let row = selectedRow else { return }

    Task { @MainActor [weak self] in
      guard let self else { return }

      await revoke(row)
    }
  }

  /// Revokes what a row shows. A remembered approval also ends the runs it admitted.
  func revoke(_ row: Row) async {
    switch row {
    case .policy(let policy):
      if let failure = await scriptHost.forgetPolicy(policy.selector), let window {
        let alert = NSAlert()

        alert.alertStyle = .warning
        alert.messageText = "The approval was not removed"
        alert.informativeText = failure
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { _ in }
      }

    case .run(let run):
      scriptHost.revokeControllers([run.connection])
    }

    refresh()
    await settle()
  }
}

extension ControllersWindowController: NSTableViewDataSource, NSTableViewDelegate {
  public func numberOfRows(in tableView: NSTableView) -> Int {
    rows.count
  }

  public func tableView(
    _ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int
  ) -> Any? {
    guard rows.indices.contains(row) else { return nil }

    switch (rows[row], tableColumn?.identifier.rawValue) {
    case (.policy(let policy), "controller"):
      return Self.subjectText(policy)
    case (.policy(let policy), "selector"): return Self.selectorText(policy.selector)
    case (.policy(let policy), "scopes"):
      return policy.scopes.sorted().map(\.kindName).joined(separator: ", ")
    case (.run(let run), "controller"):
      return "\(LaunchApprovalText.escaped(run.name)) (\(run.identity.controllerID))"
    case (.run(let run), "selector"): return "Live run, PID \(run.pid): \(run.approval.displayText)"
    case (.run(let run), "scopes"):
      return run.scopes.sorted().map(\.kindName).joined(separator: ", ")
    default: return nil
    }
  }

  public func tableViewSelectionDidChange(_ notification: Notification) {
    updateDetail()
  }
}
