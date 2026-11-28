import AppKit
import AppletKit
import ImageViewerModel
import SourceAccess

/// The viewer's side of the applet command hook. Shared dispatch has already checked the
/// controller's authority, the schema version, and every argument by the time `perform` runs.
///
/// Show, step, and zoom change the pane, so each answers at once with a handle, and its result is
/// kept for `wait`. A remote caller receives no events, so `wait` is how it learns what is shown.
/// An attached exec driver receives the `shown` event instead.
///
/// Nothing from a file the caller may not read leaves the pane. A reply and an event carry the
/// image's path, its place in the listing, and the listing's size only when the caller's scope
/// holds both the source and the image's own real path. Otherwise they say only that the image is
/// outside the scope. An exec driver holds no path-reading power, so its events always say so.
extension ImageViewerApplet: AppletCommandHandling {
  public var commandSchema: AppletCommandSchema { Self.remoteSchema }

  public func perform(_ command: ValidatedAppletCommand) throws(AppletCommandError)
    -> AppletCommandReply
  {
    guard !closed else { throw AppletCommandError(.notFound, "the pane is closed") }

    switch command.name {
    case "show":
      guard let opened = command.opened["path"], let scope = command.access.scope,
        let realPath = DescriptorPath.read(opened.fileDescriptor)
      else { throw AppletCommandError(.failed, "the host opened nothing to show") }

      try requireRoom()

      let reply = try started(.show, wanted: nil)

      begin(opened: opened, scope: scope, realPath: realPath, keeping: remote.running.last?.id)

      return reply

    case "next":
      return try stepRemotely(.next, access: command.access)

    case "previous":
      return try stepRemotely(.previous, access: command.access)

    case "first":
      return try stepRemotely(.first, access: command.access)

    case "last":
      return try stepRemotely(.last, access: command.access)

    case "zoom":
      return try zoomRemotely(command.arguments, access: command.access)

    case "wait":
      guard case .number(let number)? = command.arguments["handle"] else {
        throw AppletCommandError(.badArgument, "the handle is missing")
      }

      var milliseconds = ImageViewerRemote.defaultWait

      if case .number(let given)? = command.arguments["timeout-ms"] { milliseconds = Int(given) }

      return try remote.wait(
        for: Int(number), milliseconds: milliseconds, access: command.access)

    default:
      throw AppletCommandError(.unknownCommand, "the viewer has no such command")
    }
  }

  // MARK: Handles

  /// A command with an effect refuses before it starts when the pane can keep no more results.
  private func requireRoom() throws(AppletCommandError) {
    guard remote.hasRoom else {
      throw AppletCommandError(
        .busy, "the pane keeps results for too many commands still running. Wait on one first")
    }
  }

  /// The effect has happened, so the reply cannot fail. `requireRoom` checked a moment ago on the
  /// same turn of the main actor, so a handle is always there.
  private func started(_ kind: ImageHandleTable.Kind, wanted: String?) throws(AppletCommandError)
    -> AppletCommandReply
  {
    guard let handle = remote.begin(kind, wanted: wanted) else {
      throw AppletCommandError(.failed, "the pane could not keep a result for the command")
    }

    return .immediate(.object(["handle": .number(Double(handle))]))
  }

  // MARK: Stepping

  /// Steps through the folder for a caller. A caller whose scope does not hold the pane's source
  /// is refused, since the step would tell it what the folder holds. At either end of the order
  /// the step answers with the image on screen.
  private func stepRemotely(_ step: ListingStep, access: ReadAccess) throws(AppletCommandError)
    -> AppletCommandReply
  {
    guard access.mayShow(source: record.path) else { throw ControlDispatcher.unreadable }

    guard hasSource else { throw AppletCommandError(.refused, "the pane shows no image") }

    guard listing.count > 0 else {
      if case .problem = phase {
        throw AppletCommandError(.refused, "the pane shows no image")
      }

      let wait =
        remote.running.last.map { ". Wait on handle \($0.id) first" } ?? ". Try again once it ends"

      throw AppletCommandError(.busy, "the pane is still opening its source" + wait)
    }

    try requireRoom()

    let wanted = listing.target(for: step).map { listing.images[$0].name } ?? listing.current?.name
    let reply = try started(.step, wanted: wanted)

    self.step(step)
    observeRemote()

    return reply
  }

  // MARK: Zoom

  /// What a zoom command asks for, before the pane's image is known.
  private enum ZoomRequest {
    case fit
    case actual
    case multiple(Double)

    init(_ arguments: [String: JSONValue]) throws(AppletCommandError) {
      switch (arguments["to"], arguments["scale"]) {
      case (.string("fit")?, nil):
        self = .fit

      case (.string("actual")?, nil):
        self = .actual

      case (nil, .number(let multiple)?):
        self = .multiple(multiple)

      default:
        throw AppletCommandError(
          .badArgument, "give either to, as fit or actual, or scale, as a multiple of actual size")
      }
    }
  }

  private func zoomRemotely(_ arguments: [String: JSONValue], access: ReadAccess)
    throws(AppletCommandError) -> AppletCommandReply
  {
    let request = try ZoomRequest(arguments)

    guard canZoom, let viewport = content.viewport else {
      guard !mayRefuseZoom(access) else {
        throw AppletCommandError(.refused, "the pane shows no image to zoom")
      }

      return try zoomNothing()
    }

    let target: ImageViewerView.ZoomTarget

    switch request {
    case .fit:
      target = .fit

    case .actual:
      target = .actual

    case .multiple(let multiple):
      let scale = multiple * viewport.actualScale
      let ceiling = viewport.maxScale(backing: Double(content.backingScale))

      // A caller that may not see the image is not refused, so the refusal cannot name the ceiling.
      guard scale <= ceiling * 1.0001 || !mayTell(access) else {
        let most = ceiling / viewport.actualScale

        throw AppletCommandError(
          .badArgument,
          "the most this image zooms is \(most.formatted(.number.precision(.significantDigits(1...4))))"
            + " times actual size")
      }

      target = .scale(scale)
    }

    try requireRoom()

    let reply = try started(.zoom, wanted: nil)

    if !mayTell(access) { endZoomAtOnce() }

    content.zoom(target)
    observeRemote()

    return reply
  }

  /// True when a zoom with no image on screen may be refused for `access`.
  ///
  /// The refusal says the pane holds no decodable image. That is only the caller's to know when its
  /// scope holds the pane's source and the real path of the image the source opened. A pane with no
  /// file of the user's has nothing to hide, so it is refused for every caller.
  private func mayRefuseZoom(_ access: ReadAccess) -> Bool {
    guard record.path != nil else { return true }

    return access.mayShow(source: record.path)
      && sourceRealPath.map { access.mayShow(source: $0) } ?? false
  }

  /// Ends the zoom just started with nothing to tell.
  ///
  /// This caller may not see the image. How long a zoom takes, and whether the helper refuses it,
  /// both say something about that image. So the handle reads `done` before the call returns,
  /// whatever the pane does next. The zoom itself still runs.
  private func endZoomAtOnce() {
    guard let entry = remote.running.last(where: { $0.kind == .zoom }) else { return }

    remote.settle(
      entry.id, .zoomed(ZoomReport(isFit: true, scale: 1, source: record.path, path: nil)))
  }

  /// Answers a zoom that has no image to act on, for a caller that may not be told so.
  ///
  /// The caller gets what it would get with an image on screen, a handle that is already `done`.
  /// Only the shape of its own arguments can refuse it, and that was checked already.
  private func zoomNothing() throws(AppletCommandError) -> AppletCommandReply {
    try requireRoom()

    let reply = try started(.zoom, wanted: nil)

    endZoomAtOnce()

    return reply
  }

  // MARK: Observing

  /// What the pane shows once its image has settled, or nil while it loads, steps, or shows none.
  /// A selection that moved ahead of the image on screen is a step still running.
  func currentReport() -> ShownReport? {
    guard phase == .showing, loadingName == nil, let held = shot, let path = held.realPath,
      let selected = listing.current, selected.name == held.name, let index = listing.index
    else { return nil }

    return ShownReport(
      name: held.name, path: path, source: record.path, index: index, count: listing.count,
      partial: !listing.isComplete)
  }

  /// True when `access` may be told about the pane's source and the image on screen.
  func mayTell(_ access: ReadAccess) -> Bool {
    access.mayShow(source: record.path)
      && shot?.realPath.map { access.mayShow(source: $0) } ?? false
  }

  /// Settles the commands waiting on what the pane shows now, and emits `shown` when the image
  /// changed, or when the payload a driver would get changed. It runs on every state change of the
  /// pane, so it does nothing while no command waits and no driver is attached.
  ///
  /// A driver holds no scope, so its payload says only that the image is outside it. A growing
  /// listing changes nothing in that payload, so it sends no event. A driver that attaches gets the
  /// current state once, through the outlet's attach hook.
  func observeRemote() {
    guard !closed, !remote.running.isEmpty || events.isConnected else { return }

    let report = currentReport()

    if let report {
      for entry in remote.running where entry.kind.isNavigation {
        if entry.wanted == nil || entry.wanted == report.name {
          remote.settle(entry.id, .shown(report))
        } else {
          remote.settle(entry.id, .superseded)
        }
      }
    }

    if let report, zoomIsSettled, let viewport = content.viewport {
      let done = ZoomReport(
        isFit: viewport.isFit, scale: viewport.scale / viewport.actualScale, source: report.source,
        path: report.path)
      let waiting = remote.running.filter { $0.kind == .zoom }

      for entry in waiting {
        remote.settle(entry.id, .zoomed(done))
      }

      // A pane off screen decoded that detail only to answer the zoom, so it goes back to the
      // backdrop.
      if isOffScreen, !waiting.isEmpty { releaseZoomOffScreen() }
    }

    guard events.isConnected else { return }

    guard let report else {
      return
    }

    let payload = JSONValue.object(
      report.fields(mayShow: { ReadAccess.none.mayShow(source: $0) }))
    let emission = ShownEmission(name: report.name, payload: payload)

    guard emission != lastEmitted else { return }

    lastEmitted = emission
    events.emit("shown", payload)
  }

  /// A zoom is done when the pane holds what it asked for: fit, or a zoomed image with at least
  /// one tile, or a zoomed animation holding its frames at the zoom's level.
  ///
  /// A pane off screen draws none of it. It still asks the helper for one tile, or one frame, so
  /// that a zoom the helper or a budget refuses fails with the zoom limit rather than reading done.
  private var zoomIsSettled: Bool {
    guard let viewport = content.viewport, !viewport.isFit else { return true }

    if plan.isAnimated { return zoomLevel == nil || zoomedFramesHeld }

    return !tiles.entries.isEmpty
  }

  /// True while a program waits on a zoom. Only then does a pane off screen ask for detail.
  var awaitsProgramZoom: Bool {
    remote.running.contains { $0.kind == .zoom }
  }

  /// The source or the image could not be shown. Every command waiting on it ends as failed.
  /// `path` is the real path of the image that failed. A caller whose scope does not hold it is
  /// told `unreadable`, and so is every caller when the path is not known.
  func failRemote(_ code: ImageRemoteFailure, path: String?) {
    for entry in remote.running where entry.kind.isNavigation {
      remote.settle(entry.id, .failed(code, source: record.path, path: path))
    }
  }

  /// A zoom the helper or a budget refused ends the zoom commands waiting for it.
  func failRemoteZoom() {
    for entry in remote.running where entry.kind == .zoom {
      remote.settle(entry.id, .failed(.zoomLimit, source: record.path, path: shot?.realPath))
    }
  }
}

/// What the last `shown` event delivered. An event goes out when the image or the payload changes.
struct ShownEmission: Equatable {
  var name: String
  var payload: JSONValue
}

extension ImageViewerApplet {
  /// The image viewer's remote commands and its one event, at schema 1.0.
  ///
  /// Show names a file or a folder, and the host opens it inside the caller's read scope before the
  /// pane sees the command. A step at either end answers with the image on screen. Zoom takes fit,
  /// actual size, or a multiple of actual size. Every command with an effect answers at once with
  /// a handle, and `wait` holds a pending reply until the handle ends.
  public nonisolated static let remoteSchema = AppletCommandSchema(
    appletType: ImageViewerDescription.typeID, version: AppletSchemaVersion(0, 0),
    commands: [
      AppletMessageSchema(
        name: "show",
        summary:
          "Shows an image, or the first image of a folder, in place of what the pane shows. The path must be absolute and inside the caller's read scope. Answers with a handle.",
        arguments: AppletObjectSchema(["path": .init(.path(maxBytes: ReadScope.maxPathBytes))]),
        example: .object(["path": .string("/Users/me/Pictures/trip")])),
      AppletMessageSchema(
        name: "next",
        summary:
          "Shows the next image of the folder. At the last image it answers with that image. Answers with a handle.",
        example: .object([:])),
      AppletMessageSchema(
        name: "previous",
        summary:
          "Shows the previous image of the folder. At the first image it answers with that image. Answers with a handle.",
        example: .object([:])),
      AppletMessageSchema(
        name: "first", summary: "Shows the first image of the folder. Answers with a handle.",
        example: .object([:])),
      AppletMessageSchema(
        name: "last",
        summary:
          "Shows the last image listed so far. While the folder lists, that may not be its last. Answers with a handle.",
        example: .object([:])),
      AppletMessageSchema(
        name: "zoom",
        summary:
          "Zooms the image on screen. Give to as fit or actual, or scale as a multiple of actual size, where 1 is actual size. A scale below fit shows fit. Answers with a handle.",
        arguments: AppletObjectSchema([
          "to": .init(.choice(["fit", "actual"]), required: false),
          "scale": .init(.number(minimum: 0.001, maximum: 1000), required: false),
        ]),
        example: .object(["scale": .number(2)])),
      AppletMessageSchema(
        name: "wait",
        summary:
          "Replies once a handle ends, or after timeout-ms. The state is shown, done, failed, superseded, or pending. A shown reply carries the image's path, index, and count, and whether the count is still partial, or only that the image is outside the caller's scope. It changes nothing, so it may wait.",
        arguments: AppletObjectSchema([
          "handle": .init(.integer(minimum: 1, maximum: Int(Int32.max))),
          "timeout-ms": .init(
            .integer(minimum: 0, maximum: ImageViewerRemote.maxWait), required: false),
        ]),
        example: .object(["handle": .number(1), "timeout-ms": .number(5000)]), mayWait: true),
    ],
    events: [
      AppletMessageSchema(
        name: "shown",
        summary:
          "An image settled on screen, or the folder listing's count or partial flag changed. A driver that holds no read scope receives only outside-scope as true, since the path, the index, and the count say what the folder holds.",
        arguments: AppletObjectSchema([
          "outside-scope": .init(.boolean),
          "path": .init(.string(maxBytes: 4096), required: false),
          "index": .init(.integer(minimum: 0, maximum: Int(Int32.max)), required: false),
          "count": .init(.integer(minimum: 0, maximum: Int(Int32.max)), required: false),
          "partial": .init(.boolean, required: false),
        ]),
        example: .object(["outside-scope": .bool(true)]))
    ])
}
