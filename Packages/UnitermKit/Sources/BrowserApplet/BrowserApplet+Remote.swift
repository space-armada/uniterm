import AppKit
import AppletKit
import BrowserModel

/// The browser's side of the applet command hook. Shared dispatch has already checked the
/// caller's authority and its browser permission, the schema version, and every argument by the
/// time `perform` runs.
///
/// A controller acts only on tabs it opened. `open` records the caller against the new tab. Every
/// other command names its tab through the command's target, and the tab must belong to the same
/// grant.
///
/// Each command runs the code of the user's matching action. Only the authority checks, the tab
/// cap, and the schemes that no source may load come before it.
extension BrowserApplet: AppletCommandHandling {
  public var commandSchema: AppletCommandSchema { Self.remoteSchema }

  public func perform(_ command: ValidatedAppletCommand) throws(AppletCommandError)
    -> AppletCommandReply
  {
    guard !closed else { throw AppletCommandError(.notFound, "the pane is closed") }

    switch command.name {
    case "open":
      return .immediate(try open(command))

    case "navigate":
      let owned = try ownedTab(of: command)
      let text = try typedText(command.arguments["url"])

      guard commit(address: text, in: owned) else {
        throw AppletCommandError(.failed, "the address loaded nothing")
      }

      return .immediate(.object([:]))

    case "reload":
      let owned = try ownedTab(of: command)

      return .immediate(try moved(reload(in: owned), unavailable: "nothing to reload"))

    case "back":
      let owned = try ownedTab(of: command)

      return .immediate(try moved(goBack(in: owned), unavailable: "there is no earlier page"))

    case "forward":
      let owned = try ownedTab(of: command)

      return .immediate(try moved(goForward(in: owned), unavailable: "there is no later page"))

    case "select":
      let owned = try ownedTab(of: command)

      if let index = tabs.firstIndex(where: { $0 === owned }) { selectTab(at: index) }

      return .immediate(.object([:]))

    case "read":
      let owned = try ownedTab(of: command)

      return .immediate(
        .object([
          "url": .string(Self.readAddress(of: owned)),
          "title": .string(String(Self.title(of: owned).prefix(Self.replyTitleLimit))),
        ]))

    default:
      throw AppletCommandError(.unknownCommand, "the browser has no such command")
    }
  }

  /// The address a read answers with: the page on screen, or the last committed address while a
  /// first load has not committed. A blank page reads as an empty address.
  private static func readAddress(of tab: BrowserTab) -> String {
    guard let url = tab.currentURL ?? storedURL(of: tab), !SecurityIndicator.isBlank(url) else {
      return ""
    }

    return url.absoluteString
  }

  /// The most tabs one grant may hold open in a pane. Each is a web view and a content process.
  /// A policy value with no setting, equal to the bound on held downloads and waiting dialogs.
  static let controllerTabLimit = 16

  /// The longest title a reply carries, in characters. A page chose the title.
  private static let replyTitleLimit = 512

  // MARK: Opening

  private func open(_ command: ValidatedAppletCommand) throws(AppletCommandError) -> JSONValue {
    guard let caller = command.caller else {
      throw AppletCommandError(.permissionMissing, "the open command needs a grant to act under")
    }

    let text = try typedText(command.arguments["url"])

    guard tabOwners.values.filter({ $0 == caller }).count < Self.controllerTabLimit else {
      throw AppletCommandError(
        .busy,
        "this controller already holds \(Self.controllerTabLimit) open tabs in the pane. Retry "
          + "after one closes")
    }

    guard let id = openTab(startingIn: nil), let opened = tabs.first(where: { $0.id == id }) else {
      throw AppletCommandError(.notFound, "the pane is closed")
    }

    tabOwners[id] = caller
    refresh()

    // The text passed every check in `typedText`, so a false answer is not expected. The caller
    // still gets the reference, since it owns the tab that now exists.
    commit(address: text, in: opened)

    return .object(["tab": .string(id.replyText)])
  }

  // MARK: Checks

  /// The tab the command names, when this grant opened it.
  private func ownedTab(of command: ValidatedAppletCommand) throws(AppletCommandError)
    -> BrowserTab
  {
    let id = try namedTab(of: command)

    guard let tab = tabs.first(where: { $0.id == id }) else {
      throw AppletCommandError(.notFound, "the tab is not open in that pane")
    }

    guard let caller = command.caller, tabOwners[id] == caller else {
      throw AppletCommandError(
        .notOwned, "this controller did not open that tab, so it cannot act on it")
    }

    return tab
  }

  /// The tab a command names, through its target or its `tab` argument. A script names it in the
  /// target. An exec driver has no target for a tab, so it passes the reference `open` answered.
  private func namedTab(of command: ValidatedAppletCommand) throws(AppletCommandError)
    -> AppletTabID
  {
    var argument: AppletTabID?

    if case .string(let text)? = command.arguments["tab"] {
      guard let parsed = AppletTabID(reply: text) else {
        throw AppletCommandError(.badArgument, "the tab is not a tab reference")
      }

      argument = parsed
    }

    switch (command.tab, argument) {
    case (let target?, let named?):
      guard target == named else {
        throw AppletCommandError(
          .badArgument, "the target and the tab argument name different tabs")
      }

      return target

    case (let target?, nil):
      return target

    case (nil, let named?):
      return named

    case (nil, nil):
      throw AppletCommandError(
        .badArgument, "the \(command.name) command acts on one tab, so it must name one")
    }
  }

  /// The text of an address argument. Whatever the typed-address path would refuse is refused
  /// here, before any tab opens or loads, as the address bar marks an invalid address.
  private func typedText(_ value: JSONValue?) throws(AppletCommandError) -> String {
    guard case .string(let text)? = value else {
      throw AppletCommandError(.badArgument, "the url is missing")
    }

    switch AddressPolicy.resolve(text) {
    case .refused(let refusal):
      throw AppletCommandError(.badArgument, refusal.message(for: text))

    case .empty:
      throw AppletCommandError(.badArgument, "the url is empty")

    case .search(let query):
      guard services.searchEngine().searchURL(for: query) != nil else {
        throw AppletCommandError(.badArgument, SchemeRefusal.notAnAddress.message(for: text))
      }

      return text

    case .load, .handoff:
      return text
    }
  }

  private func moved(_ move: HistoryMove, unavailable: String) throws(AppletCommandError)
    -> JSONValue
  {
    switch move {
    case .moved:
      return .object([:])

    case .unavailable:
      throw AppletCommandError(.failed, unavailable)

    case .refused(let refusal, let address):
      throw AppletCommandError(.failed, refusal.message(for: address))
    }
  }

  // MARK: Owners

  /// A new generation of control ends every grant, so no tab stays owned across it.
  public func controlDidChange(_ control: PaneControl) {
    guard control.generation != controlGeneration else { return }

    controlGeneration = control.generation

    releaseOwnedTabs()
  }

  public func adoptFirstTab(for caller: AppletCaller) {
    guard !closed else { return }

    tabOwners[tab.id] = caller
    refresh()
  }

  public func grantDidEnd(_ caller: AppletCaller) {
    for (id, owner) in tabOwners where owner == caller { tabOwners[id] = nil }

    refresh()
  }

  private func releaseOwnedTabs() {
    tabOwners.removeAll()
    refresh()
  }

  public func authorityDidChange(_ authority: PaneAuthority) {
    guard authority != self.authority else { return }

    self.authority = authority
    refresh()
  }

  public func hostBadgeReachDidChange(_ width: CGFloat) {
    content.badgeReach = width
  }

  public var programOpenRefusal: String? {
    "a browser pane opens tabs with its open command, which needs the browser-navigation permission"
  }

  // MARK: Schema

  /// The browser's remote commands, at schema 1.0.
  ///
  /// Open and the tab commands need browser navigation, and read needs browser read. Every
  /// command answers at once. The commands after open act on the tab the command's target names.
  public nonisolated static let remoteSchema = AppletCommandSchema(
    appletType: BrowserDescription.typeID, version: AppletSchemaVersion(0, 0),
    commands: [
      AppletMessageSchema(
        name: "open",
        summary:
          "Opens a tab as the New Tab command does, selects it, and loads the address as if it were typed into the address bar. Answers with the tab's reference.",
        arguments: urlArguments,
        example: .object(["url": .string("https://example.com/")]),
        requires: .browserNavigation),
      AppletMessageSchema(
        name: "navigate",
        summary:
          "Loads an address in a tab this controller opened, as if it were typed into the address bar. Text that is not an address searches, and an address for another app asks first.",
        arguments: navigateArguments,
        example: .object(["url": .string("https://example.com/next")]),
        requires: .browserNavigation),
      AppletMessageSchema(
        name: "reload",
        summary:
          "Reloads a tab this controller opened, as the Reload button does. A page that came from a form asks the user first.",
        arguments: tabArguments, requires: .browserNavigation),
      AppletMessageSchema(
        name: "back",
        summary:
          "Goes back one page in a tab this controller opened, as the Back button does. A page that came from a form asks the user first.",
        arguments: tabArguments, requires: .browserNavigation),
      AppletMessageSchema(
        name: "forward",
        summary:
          "Goes forward one page in a tab this controller opened, as the Forward button does. A page that came from a form asks the user first.",
        arguments: tabArguments, requires: .browserNavigation),
      AppletMessageSchema(
        name: "select",
        summary:
          "Shows a tab this controller opened, as a click on its tab does.",
        arguments: tabArguments, requires: .browserNavigation),
      AppletMessageSchema(
        name: "read",
        summary:
          "Answers with the address and title of a tab this controller opened. An address may carry a token.",
        arguments: tabArguments, example: .object([:]), requires: .browserRead),
    ],
    events: [])

  private nonisolated static let urlArguments = AppletObjectSchema([
    "url": .init(.string(maxBytes: 8192))
  ])

  private nonisolated static let tabArgument = AppletValueSchema.string(maxBytes: 64)

  private nonisolated static let tabArguments = AppletObjectSchema([
    "tab": .init(tabArgument, required: false)
  ])

  private nonisolated static let navigateArguments = AppletObjectSchema([
    "url": .init(.string(maxBytes: 8192)), "tab": .init(tabArgument, required: false),
  ])
}
