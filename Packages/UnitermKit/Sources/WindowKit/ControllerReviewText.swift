import ControllerPackage
import ControllerTrust
import ScriptHost
import SourceAccess

/// The text of a controller's startup review. The descriptor's name and paths come from the
/// package, so each is escaped as a launch's inputs are, and no name can fake a line.
enum ControllerReviewText {
  /// Everything the review shows: who asks, what is new, and every requested power.
  static func summary(_ review: ControllerReview) -> String {
    let subject = review.identity.artifact == .file ? "Script file" : "Controller"
    var lines = [
      "\(subject): \(LaunchApprovalText.escaped(review.name)) (\(review.identity.controllerID))",
      "Version: \(review.identity.version)",
      review.identity.keyFingerprint.map { "Signed by key: \($0)" }
        ?? "Unsigned: only this exact version can be trusted.",
    ]

    if review.revises != nil, !review.added.isEmpty {
      lines.append("New since you trusted it:")
      lines += review.added.flatMap { permissionLines(for: $0, prefix: "  + ") }
    }

    lines.append("Asks for:")
    lines += review.requested.flatMap {
      permissionLines(for: $0, prefix: "  ", resolved: review.resolvedReadDirectories)
    }

    if review.requested.contains(where: { $0.kindName == "path-read" }) {
      lines.append(readsNeedStanding)
    }

    if review.requested.contains(where: { $0.kindName == "browser-navigation" }) {
      lines.append(navigationIsNetworkAccess)
    }

    if review.requested.contains(where: { $0.kindName == "browser-read" }) {
      lines.append(browserReadShowsAddresses)
    }

    if offered(for: review).contains(.trustVersionKeepingOlder) {
      lines += replacementLines(for: review)
    }

    if review.waiting.count > 1 {
      lines.append(
        "\(review.waiting.count) runs wait. Allow Once and Allow for This Run start the "
          + "oldest alone.")
    }

    if let notice = review.notice { lines.append(notice) }

    return lines.joined(separator: "\n")
  }

  /// What Trust This Version replaces. It names every older approval it removes, and says that a
  /// run a replaced approval admitted ends, as Revoke ends it. The user may keep both instead.
  static func replacementLines(for review: ControllerReview) -> [String] {
    let count = review.older.count
    var lines = [
      "Trust This Version replaces \(count == 1 ? "1 older approval" : "\(count) older approvals") "
        + "of \(LaunchApprovalText.escaped(review.versionOf)):"
    ]

    for policy in review.older.sorted(by: { $0.approved < $1.approved }).prefix(5) {
      lines.append(
        "  \(LaunchApprovalText.escaped(policy.name)), version "
          + "\(policy.selector.value.prefix(12)), approved \(policy.approved)")
    }

    if count > 5 { lines.append("  and \(count - 5) more") }

    lines.append(
      "A live run of a replaced version ends, as Revoke ends it. Clear the box below to keep "
        + "them and add this version beside them.")

    return lines
  }

  /// The lines that show one permission. A path-reading power adds a line for every protected
  /// location its scope lies in or names, and one for each it leaves out, so the user sees what
  /// the plain directories do not say. `resolved` holds the directories with their links resolved,
  /// read off the main thread, so a link into a protected place is named too.
  static func permissionLines(
    for permission: ControllerPermission, prefix: String, suffix: String = "",
    resolved: [String: String] = [:]
  ) -> [String] {
    var lines = [prefix + LaunchApprovalText.escaped(permission.displayText) + suffix]

    guard case .pathRead(let scope) = permission.kind else { return lines }

    let labels = scope.protectedLabels(resolved: resolved)
    let indent = String(repeating: " ", count: prefix.count + 2)

    if !labels.lyingIn.isEmpty {
      lines.append(indent + "Lies in or names: " + labels.lyingIn.joined(separator: ", "))
    }

    if !labels.leftOut.isEmpty {
      lines.append(indent + "Leaves out: " + labels.leftOut.joined(separator: ", "))
    }

    return lines
  }

  /// What a review that asks for browser navigation says. The browser signs in as the user, and
  /// the controller's own sandbox does not limit what a page it opens can reach.
  static let navigationIsNetworkAccess =
    "Browser navigation is network access signed in as you. It reaches whatever the browser can, "
    + "whatever this controller's own sandbox allows."

  /// What a review that asks for browser read says. An address can carry a token.
  static let browserReadShowsAddresses =
    "Browser read returns the addresses of tabs it opened. An address may carry a token."

  /// What a review that asks to read paths says about the choices. A run allowed once reads
  /// nothing, since each read would need its own question.
  static let readsNeedStanding =
    "Reading paths needs Allow for This Run or a trust choice. A run allowed once is refused "
    + "when it reads."

  /// The choices a review offers, in the order the panel shows them. Trust This Identity is
  /// offered only for a signed controller. Neither trust choice is offered when the policy file
  /// cannot take one.
  static func offered(for review: ControllerReview) -> [ControllerReviewChoice] {
    var offered: [ControllerReviewChoice] = [.allowOnce, .allowForSession]

    if review.canRemember {
      offered.append(.trustVersion)

      if !review.older.isEmpty { offered.append(.trustVersionKeepingOlder) }

      if review.isSigned { offered.append(.trustIdentity) }
    }

    return offered + [.deny]
  }

  /// What each offered choice covers, so the user can tell them apart before choosing. The panel's
  /// help button shows it. A choice the review does not offer is not described.
  static func choices(for review: ControllerReview) -> String {
    var sentences = [
      "Allow Once starts this run, and each later use of a power asks again.",
      "Allow for This Run gives this run these powers until it ends.",
    ]
    let shown = offered(for: review)

    if shown.contains(.trustVersion) {
      sentences.append("Trust This Version remembers them for this exact verified version.")
    }

    if shown.contains(.trustVersionKeepingOlder) {
      sentences.append(
        "Trust This Version also replaces the older versions listed, and a live run of one ends. "
          + "Clear the box to keep them.")
    }

    if shown.contains(.trustIdentity) {
      let subject = review.identity.artifact == .file ? "file" : "controller"

      sentences.append(
        "Trust This Identity remembers them for every version this key signs under this "
          + "\(subject) ID.")
    }

    if shown.contains(.trustVersion) || shown.contains(.trustIdentity) {
      sentences.append(
        "Nothing remembered overrides a disconnected pane, adopts restored panes, or chooses Run.")
    }

    return sentences.joined(separator: " ")
  }

  /// Everything the review of an undeclared file shows. The name comes from the command, so it is
  /// escaped as a descriptor's is.
  static func summary(_ review: UndeclaredReview) -> String {
    let allowed =
      review.capabilities.isEmpty
      ? "  no --allow capabilities"
      : review.capabilities.map { "  --allow \(LaunchApprovalText.escaped($0))" }
        .joined(separator: "\n")

    return [
      "Undeclared script file: \(LaunchApprovalText.escaped(review.name))",
      "It declares nothing, so uniterm cannot tell what it will do. Adding a "
        + "(declare-permissions ...) form makes it reviewable and trustable.",
      "Asks for:",
      allowed,
      "Each choice lasts this run only.",
    ].joined(separator: "\n")
  }

  /// What an undeclared run that the user admitted can do now.
  static func summary(_ run: UndeclaredRun) -> String {
    let power =
      run.choice == .allowEverything
      ? "Allow Everything: it reads and replaces the clipboard without asking. A host launch "
        + "still asks each time."
      : "Allow and Ask Each Use: its clipboard calls ask, and its pane calls follow the pane rules."

    return [
      "Undeclared script file: \(LaunchApprovalText.escaped(run.name)), process \(run.pid)",
      power,
      "Revoke ends its authority. Its next call is refused.",
    ].joined(separator: "\n")
  }

  /// What each choice of an undeclared file's review covers.
  static let undeclaredChoices =
    "Reject does not start the script. Allow and Ask Each Use starts it, and each clipboard call "
    + "asks again. Allow Everything starts it and lets it read and replace the clipboard until it "
    + "ends. A host launch always asks. None of the choices is remembered."
}
