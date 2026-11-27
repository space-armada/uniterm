import AppKit
import AppletKit
import GeoData
import Theme

/// The map's side of the applet command hook. Shared dispatch has already checked the caller's
/// authority, the schema version, and the shape of every argument by the time `perform` runs.
///
/// Every command acts on the command layers or the camera and answers at once, so no reply
/// pends. A command that throws changes nothing. The file layer is outside the commands: a
/// command naming it as its source is refused, and no layer name reaches it.
///
/// Pins that programs place are program output, so they stay off the layout file. The description
/// holds one number about them, the count of layers that held pins in this launch. The layers
/// themselves ride in the description's undo-only part, so a reopen brings them back.
extension MapViewerApplet: AppletCommandHandling {
  public var commandSchema: AppletCommandSchema { Self.remoteSchema }

  public func perform(_ command: ValidatedAppletCommand) throws(AppletCommandError)
    -> AppletCommandReply
  {
    guard !closed else { throw AppletCommandError(.notFound, "the pane is closed") }

    let arguments = command.arguments

    switch command.name {
    case "add":
      try requireCommandSource(arguments)

      let layer = try Self.layerName(arguments)
      let pin = try Self.pin(from: arguments, at: "the pin")

      return .immediate(try add(pin, to: layer))

    case "remove":
      try requireCommandSource(arguments)

      let layer = try Self.layerName(arguments)
      let id = try Self.translated { () throws(CommandPinError) in
        try CommandPins.pinID(Self.text(arguments["id"]) ?? "")
      }

      return .immediate(remove(id: id, from: layer))

    case "clear":
      try requireCommandSource(arguments)

      return .immediate(clear(layer: try Self.layerName(arguments)))

    case "set-layer":
      try requireCommandSource(arguments)

      let layer = try Self.layerName(arguments)

      guard case .array(let values)? = arguments["pins"] else {
        throw AppletCommandError(.badArgument, "the pins are missing")
      }

      var pins: [GeoPin] = []

      for (index, value) in values.enumerated() {
        guard case .object(let fields) = value else {
          throw AppletCommandError(.badArgument, "pins[\(index)] must be an object")
        }

        pins.append(try Self.pin(from: fields, at: "pins[\(index)]"))
      }

      return .immediate(try replace(layer: layer, with: pins))

    case "set-region":
      return .immediate(try setRegion(arguments))

    default:
      throw AppletCommandError(.unknownCommand, "the map has no such command")
    }
  }

  // MARK: Commands

  private func requireCommandSource(_ arguments: [String: JSONValue]) throws(AppletCommandError) {
    guard case .string("file")? = arguments["source"] else { return }

    throw AppletCommandError(
      .refused, "commands cannot change the file layer. Name the command source, or none")
  }

  private func add(_ pin: GeoPin, to layer: String) throws(AppletCommandError) -> JSONValue {
    let change = try Self.translated { () throws(CommandPinError) in
      try commandLayers.add(pin, to: layer)
    }

    guard let shown = commandLayers.layer(named: layer) else {
      throw AppletCommandError(.failed, "the layer is missing after the pin was placed")
    }

    if change.clearedEarlierRun {
      showCommandLayer(shown)
    } else {
      content.upsert(pin: pin, layer: .command(layer), defaultAccent: shown.accent)
    }

    settled(change)

    return .object(["layer": .string(layer), "pins": .number(Double(shown.pins.count))])
  }

  private func remove(id: String, from layer: String) -> JSONValue {
    guard let change = commandLayers.remove(id: id, from: layer),
      let shown = commandLayers.layer(named: layer)
    else {
      let held = commandLayers.layer(named: layer)?.pins.count ?? 0

      return .object([
        "layer": .string(layer), "removed": .bool(false), "pins": .number(Double(held)),
      ])
    }

    if change.clearedEarlierRun {
      showCommandLayer(shown)
    } else {
      content.removePin(id: id, layer: .command(layer))
    }

    settled(change)

    return .object([
      "layer": .string(layer), "removed": .bool(true), "pins": .number(Double(shown.pins.count)),
    ])
  }

  private func clear(layer: String) -> JSONValue {
    let removed = commandLayers.layer(named: layer)?.pins.count ?? 0

    if let change = commandLayers.clear(layer: layer) {
      content.removePins(layer: .command(layer))
      settled(change)
    }

    return .object([
      "layer": .string(layer), "removed": .number(Double(removed)), "pins": .number(0),
    ])
  }

  /// Validates the whole layer, then swaps it in with one replacement, so a partial layer is never
  /// drawn.
  private func replace(layer: String, with pins: [GeoPin]) throws(AppletCommandError) -> JSONValue {
    let change = try Self.translated { () throws(CommandPinError) in
      try commandLayers.replace(layer: layer, with: pins)
    }

    if let shown = commandLayers.layer(named: layer) { showCommandLayer(shown) }

    settled(change)

    return .object(["layer": .string(layer), "pins": .number(Double(pins.count))])
  }

  private func setRegion(_ arguments: [String: JSONValue]) throws(AppletCommandError) -> JSONValue {
    guard case .object(let center)? = arguments["center"],
      case .object(let span)? = arguments["span"],
      let latitude = Self.number(center["latitude"]),
      let longitude = Self.number(center["longitude"]),
      let latitudeDelta = Self.number(span["latitude-delta"]),
      let longitudeDelta = Self.number(span["longitude-delta"])
    else { throw AppletCommandError(.badArgument, "the center and span are missing") }

    guard
      let region = GeoRegion(
        center: GeoCoordinate(latitude: latitude, longitude: longitude),
        span: GeoSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta))
    else {
      throw AppletCommandError(
        .badArgument, "the region is off the globe. Its edges must stay between the poles")
    }

    content.show(region: region)
    regionSettled(region)

    return .object([:])
  }

  // MARK: Display

  static let earlierRunNote = "From an earlier run"

  /// Draws every pin of `layer` in place of what the map shows for it.
  func showCommandLayer(_ layer: CommandLayer) {
    content.replacePins(
      layer: .command(layer.name), pins: layer.pins, defaultAccent: layer.accent,
      subtitle: layer.isFromEarlierRun ? Self.earlierRunNote : nil)
  }

  func showAllCommandLayers() {
    for layer in commandLayers.layers { showCommandLayer(layer) }
  }

  /// Takes in a change: counts a layer that held pins for the first time, and tells the host when
  /// the saved description or the status bar changed. Only those two tell the host, so a stream of
  /// pins does not.
  private func settled(_ change: CommandLayerChange) {
    refresh()

    guard change.becameCounted || change.clearedEarlierRun else { return }

    if change.becameCounted { record.commandLayerCount += 1 }

    host?.appletDidChange(self)
  }

  // MARK: The user's clear

  /// True when a command layer holds a pin for Clear Program Pins to remove.
  var canClearProgramPins: Bool { commandLayers.totalPins > 0 }

  /// Clears the pins of every command layer. The layers and their accents stay.
  func clearProgramPins() {
    for change in commandLayers.clearAll() {
      content.removePins(layer: .command(change.layer))
    }

    refresh()
    host?.appletDidChange(self)
  }

  // MARK: Restore

  /// Says once that the layers of the last session were not restored, when this pane was rebuilt
  /// from the saved layout and that layout counted some. A reopen carries the layers, so it says
  /// nothing. The count then starts again from zero.
  ///
  /// The notice enters the history without a turn on the bar. It never claims pins were lost from
  /// a layer the user cleared, since a counted layer held pins at some point and nothing more.
  func forgetEarlierRunLayersIfLost() {
    guard !restoredCommandLayers, commandLayers.isEmpty, record.commandLayerCount > 0
    else { return }

    let count = record.commandLayerCount

    record.commandLayerCount = 0

    let text =
      count == 1
      ? "1 program layer held pins last session. Restore does not run programs, so it is not shown."
      : "\(count.formatted()) program layers held pins last session. Restore does not run "
        + "programs, so they are not shown."

    alerts.deliver(
      AppletNotice(.info, text), origin: .restore, from: self, to: host)

    refresh()
    host?.appletDidChange(self)
  }

  // MARK: Events

  func mapClicked(at coordinate: GeoCoordinate) {
    guard events.isConnected, coordinate.latitude.isFinite, coordinate.longitude.isFinite else {
      return
    }

    events.emit(
      "map-clicked",
      .object([
        "latitude": .number(max(-90, min(90, coordinate.latitude))),
        "longitude": .number(Self.wrapped(longitude: coordinate.longitude)),
      ]))
  }

  /// Tells an attached driver which pin the user selected. A command pin names its layer and ID. A
  /// file pin names only its source, so nothing from the user's file reaches the driver.
  func pinSelected(_ annotation: MapPinAnnotation) {
    guard events.isConnected else { return }

    switch annotation.layer {
    case .file:
      events.emit("pin-selected", .object(["source": .string("file")]))

    case .command(let layer):
      events.emit(
        "pin-selected",
        .object([
          "source": .string("command"), "layer": .string(layer),
          "id": .string(annotation.pin.id),
        ]))
    }
  }

  private static func wrapped(longitude: Double) -> Double {
    guard longitude < -180 || longitude > 180 else { return longitude }

    let shifted = (longitude + 180).truncatingRemainder(dividingBy: 360)

    return (shifted < 0 ? shifted + 360 : shifted) - 180
  }

  // MARK: Reading arguments

  private static func text(_ value: JSONValue?) -> String? {
    if case .string(let text)? = value { return text }

    return nil
  }

  private static func number(_ value: JSONValue?) -> Double? {
    if case .number(let number)? = value { return number }

    return nil
  }

  private static func layerName(_ arguments: [String: JSONValue]) throws(AppletCommandError)
    -> String
  {
    try translated { () throws(CommandPinError) in
      try CommandPins.layerName(text(arguments["layer"]))
    }
  }

  private static func pin(from fields: [String: JSONValue], at place: String)
    throws(AppletCommandError) -> GeoPin
  {
    guard case .object(let coordinate)? = fields["coordinate"],
      let latitude = number(coordinate["latitude"]), let longitude = number(coordinate["longitude"])
    else { throw AppletCommandError(.badArgument, "\(place) needs a coordinate") }

    do {
      return try CommandPins.pin(
        id: text(fields["id"]) ?? "", latitude: latitude, longitude: longitude,
        label: text(fields["label"]), accent: text(fields["accent"]), glyph: text(fields["glyph"]))
    } catch {
      throw AppletCommandError(.badArgument, "\(place): \(error.message)")
    }
  }

  private static func translated<T>(_ body: () throws(CommandPinError) -> T)
    throws(AppletCommandError) -> T
  {
    do {
      return try body()
    } catch {
      throw AppletCommandError(
        error.kind == .capReached ? .refused : .badArgument, error.message)
    }
  }
}

// MARK: - The schema

extension MapViewerApplet {
  private nonisolated static var accentNames: [String] { ThemeToken.accents.map(\.rawValue) }

  private nonisolated static let layerFields: [String: AppletObjectSchema.Field] = [
    "layer": .init(.string(maxBytes: CommandPinLimits.maxLayerNameBytes), required: false),
    "source": .init(.choice(["command", "file"]), required: false),
  ]

  private nonisolated static let coordinate = AppletValueSchema.object(
    AppletObjectSchema([
      "latitude": .init(.number(minimum: -90, maximum: 90)),
      "longitude": .init(.number(minimum: -180, maximum: 180)),
    ]))

  private nonisolated static var pinFields: [String: AppletObjectSchema.Field] {
    [
      "id": .init(.string(maxBytes: CommandPinLimits.maxIDBytes)),
      "coordinate": .init(coordinate),
      "label": .init(.string(maxBytes: CommandPinLimits.maxLabelBytes), required: false),
      "accent": .init(.choice(accentNames), required: false),
      "glyph": .init(.string(maxBytes: CommandPinLimits.maxGlyphBytes), required: false),
    ]
  }

  private nonisolated static func example(
    id: String, latitude: Double, longitude: Double, label: String
  ) -> JSONValue {
    .object([
      "id": .string(id),
      "coordinate": .object(["latitude": .number(latitude), "longitude": .number(longitude)]),
      "label": .string(label), "accent": .string("peach"), "glyph": .string("\u{2605}"),
    ])
  }

  /// The map's remote commands and its two events, at schema 1.0.
  ///
  /// Every pin belongs to a named layer. A command that names none uses the layer `default`, for
  /// every caller. A pin's ID is unique within its layer. The file layer is not a layer a command
  /// can name: `source` takes `command`, and `file` is refused. Each pin command answers at once
  /// with the layer's pin count.
  ///
  /// A restarted driver finds the previous driver's pins in the default layer until it sends
  /// `set-layer`, which replaces the layer whole.
  public nonisolated static let remoteSchema = AppletCommandSchema(
    appletType: MapViewerDescription.typeID, version: AppletSchemaVersion(1, 0),
    commands: [
      AppletMessageSchema(
        name: "add",
        summary:
          "Places a pin in a layer. A pin with the same ID is replaced whole, so an omitted accent or glyph takes the default. The accent is a palette accent name, and the glyph is one or two characters or an SF Symbol name. Text is capped in UTF-8 bytes. Answers with the layer's pin count.",
        arguments: AppletObjectSchema(layerFields.merging(pinFields) { first, _ in first }),
        example: .object(
          [
            "layer": .string("trucks"),
            "id": .string("truck-7"),
            "coordinate": .object(["latitude": .number(37.7749), "longitude": .number(-122.4194)]),
            "label": .string("Truck 7"), "accent": .string("peach"),
          ])),
      AppletMessageSchema(
        name: "remove",
        summary:
          "Removes the pin with this ID from a layer. A layer with no such pin is left as it is, and the reply says removed is false.",
        arguments: AppletObjectSchema(
          layerFields.merging(["id": .init(.string(maxBytes: CommandPinLimits.maxIDBytes))]) {
            first, _ in first
          }),
        example: .object(["layer": .string("trucks"), "id": .string("truck-7")])),
      AppletMessageSchema(
        name: "clear",
        summary:
          "Removes every pin of a layer. The layer stays and keeps its color. Other layers are not touched.",
        arguments: AppletObjectSchema(layerFields),
        example: .object(["layer": .string("trucks")])),
      AppletMessageSchema(
        name: "set-layer",
        summary:
          "Replaces a layer's whole contents at once. A run again sends this to replace its own earlier pins, and no partial layer is ever drawn. A layer past the cap on pins per layer, pins per pane, or layers per pane is refused whole.",
        arguments: AppletObjectSchema(
          layerFields.merging([
            "pins": .init(
              .array(
                of: .object(AppletObjectSchema(pinFields)),
                maxCount: CommandPinLimits.maxPinsPerLayer))
          ]) { first, _ in first }),
        example: .object([
          "layer": .string("trucks"),
          "pins": .array([
            example(id: "truck-7", latitude: 37.7749, longitude: -122.4194, label: "Truck 7"),
            example(id: "truck-9", latitude: 37.8044, longitude: -122.2712, label: "Truck 9"),
          ]),
        ])),
      AppletMessageSchema(
        name: "set-region",
        summary:
          "Moves the map to show a region, given as a center and a span in degrees. The region's edges must stay between the poles. The region is saved with the pane, as Go to Place saves one.",
        arguments: AppletObjectSchema([
          "center": .init(coordinate),
          "span": .init(
            .object(
              AppletObjectSchema([
                "latitude-delta": .init(.number(minimum: 0.000001, maximum: 180)),
                "longitude-delta": .init(.number(minimum: 0.000001, maximum: 360)),
              ]))),
        ]),
        example: .object([
          "center": .object(["latitude": .number(37.77), "longitude": .number(-122.42)]),
          "span": .object(["latitude-delta": .number(0.5), "longitude-delta": .number(0.5)]),
        ])),
    ],
    events: [
      AppletMessageSchema(
        name: "map-clicked",
        summary:
          "The user pressed and released the primary button on the empty map, without dragging. A click on a pin, a cluster, or a file pin does not send this event.",
        arguments: AppletObjectSchema([
          "latitude": .init(.number(minimum: -90, maximum: 90)),
          "longitude": .init(.number(minimum: -180, maximum: 180)),
        ]),
        example: .object(["latitude": .number(37.77), "longitude": .number(-122.42)])),
      AppletMessageSchema(
        name: "pin-selected",
        summary:
          "The user selected one pin. A command pin carries its layer and ID. A pin from the user's file carries only source file, and no ID, coordinate, or other value from the file. Selecting a cluster sends no event.",
        arguments: AppletObjectSchema([
          "source": .init(.choice(["command", "file"])),
          "layer": .init(.string(maxBytes: CommandPinLimits.maxLayerNameBytes), required: false),
          "id": .init(.string(maxBytes: CommandPinLimits.maxIDBytes), required: false),
        ]),
        example: .object([
          "source": .string("command"), "layer": .string("trucks"), "id": .string("truck-7"),
        ])),
    ])
}
