import AppKit
import AppletKit
import Theme

#if DEBUG
  /// What every hosted fixture shares: a plain view of labels and one button, a single tab, an event
  /// outlet, and an inert description. Each fixture adds its own schema, state, and commands.
  ///
  /// The fixtures stand in for the presentation applets that later proposals design. Their schemas
  /// are real, so the exec wire, shared dispatch, and the command hook are proven against applets
  /// that take commands and emit events, not against mocks of them.
  @MainActor
  public class FixtureApplet: Applet {
    public let typeID: String
    public let view: NSView
    public let segments: [AppletSegment] = []
    public let isRunningSomething = false
    public weak var host: (any AppletHost)?
    public let publishedTabs: AppletTabList
    public let events = AppletEventOutlet()

    let stack = NSStackView()
    public let button: NSButton
    private let heading: NSTextField

    init(typeID: String, title: String, buttonTitle: String) {
      self.typeID = typeID
      heading = NSTextField(labelWithString: title)
      button = NSButton(title: buttonTitle, target: nil, action: nil)
      publishedTabs = AppletTabList(first: AppletTab(id: .make(), title: title))

      let view = NSView()
      self.view = view

      heading.font = .systemFont(ofSize: 13, weight: .semibold)
      button.setAccessibilityIdentifier("\(typeID)-button")

      stack.orientation = .vertical
      stack.alignment = .leading
      stack.spacing = 8
      stack.translatesAutoresizingMaskIntoConstraints = false
      stack.addArrangedSubview(heading)

      view.addSubview(stack)

      NSLayoutConstraint.activate([
        stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
        stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
        stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
      ])

      button.target = self
      button.action = #selector(buttonPressed)
    }

    public var title: String { heading.stringValue }

    /// A label the UI tests read by its identifier.
    func label(_ name: String) -> NSTextField {
      let label = NSTextField(labelWithString: "")
      label.setAccessibilityIdentifier("\(typeID)-\(name)")
      stack.addArrangedSubview(label)
      return label
    }

    func addButton() {
      stack.addArrangedSubview(button)
    }

    @objc private func buttonPressed() {
      userPressedButton()
    }

    /// What the fixture's one button does. It emits the fixture's user event.
    func userPressedButton() {}

    public func start(origin: StartOrigin) {}

    /// Closing the outlet ends an attached driver, as part of the applet's own cleanup.
    public func close() {
      events.close()
    }

    public func focus() {
      view.window?.makeFirstResponder(button)
    }

    public func describe() -> AppletDescription {
      AppletDescription(type: typeID, version: 1, payload: payload)
    }

    /// The fixture's saved state. It is inert, as every description is.
    var payload: JSONValue { .object([:]) }

    public func apply(_ palette: ThemePalette) {
      view.wantsLayer = true
      view.layer?.backgroundColor = palette[.base].cgColor
    }

    static func object(of description: AppletDescription, type: String) throws -> [String:
      JSONValue]
    {
      guard description.type == type else {
        throw AppletRestoreError.wrongType(expected: type, found: description.type)
      }

      guard description.version <= 1 else {
        throw AppletRestoreError.newerVersion(found: description.version, supported: 1)
      }

      guard case .object(let fields) = description.payload else {
        throw AppletRestoreError.corrupt("the payload is not an object")
      }

      return fields
    }
  }

  extension JSONValue {
    var integerValue: Int? {
      guard case .number(let number) = self, number == number.rounded(), abs(number) < 1e15 else {
        return nil
      }

      return Int(number)
    }
  }
#endif
