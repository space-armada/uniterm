import AppKit
import AppletCatalog
import AppletKit
import BrowserApplet
import DataViewerApplet
import FileRouting
import ImageViewerApplet
import MapViewerApplet
import OSLog
import PlaceSearch
import Preferences
import QuestionsApplet
import ReplApplet
import ScriptHost
import SettingsKit
import StatusKit
import TerminalApplet
import TerminalSurface
import TextViewerApplet
import WindowKit

#if DEBUG
  import AppletFixtures
#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let logger = Logger(subsystem: "dev.uniterm.app", category: "app")
  private let settings: SettingsStore
  private let defaults: UserDefaults
  private var appearance: AppearanceController?
  private var appearanceToken: UUID?
  private var paletteSync: TerminalPaletteSync?
  private var terminalEngine: GhosttyTerminalEngine?
  private var windowSet: WindowSet?
  private var routedOpener: RoutedOpener?
  private var launchOpens: LaunchOpenCoordinator?
  private var fileOpens: FileOpenCommands?

  #if DEBUG
    private var questionsTestHook: QuestionsTestHook?
  #endif

  /// Opens that arrived before the coordinator existed. Launch Services can deliver the event of a
  /// cold launch ahead of the end of launching. The sender is identified when the event arrives,
  /// since a sender that exits afterward cannot be identified.
  private var earlyOpens: [(urls: [URL], sender: SenderIdentity?)] = []
  private var commands: CommandRegistry?
  private var commandMenu: CommandMenu?
  private var layoutPersistence: LayoutPersistence?
  private var settingsWindowController: SettingsWindowController?
  private var pendingRequestsWindowController: PendingRequestsWindowController?
  private var controllersWindowController: ControllersWindowController?
  private let clipboard = PasteboardClipboard()
  private var pendingObserver: ChangeObservers.Token?
  private var pendingIndicator: PendingRequestsIndicator?
  private var browserWebsiteData: BrowserWebsiteData?
  private var scriptHost: ScriptHost?
  private var askingToQuit = false

  /// The `UNITERM_` variables the process started with. The scrub of the inherited environment
  /// removes them from the process, so they are read from here. Only debug builds honor them.
  private let debugEnvironment: [String: String]

  init(debugEnvironment: [String: String]) {
    self.debugEnvironment = debugEnvironment
    let defaults = Self.makeDefaults(debugEnvironment)
    self.defaults = defaults
    self.settings = SettingsStore(defaults: defaults)
    super.init()

    #if DEBUG
      ImageViewerScrollLog.enabled = debugEnvironment["UNITERM_DEBUG_SCROLL"] == "1"
    #endif
  }

  /// UI tests set `UNITERM_DEFAULTS_PATH` to a plist path inside the test runner's container, so
  /// they never touch the developer's real preferences. Only debug builds honor it.
  ///
  /// `UNITERM_DEFAULTS_SEED` holds the settings a test starts with, as a JSON object of strings.
  /// They are stored as given, even when invalid, the way `defaults write` would store them. The
  /// app writes them itself, so it is the suite's only writer. On macOS 26.7, a suite opened by
  /// path keeps answering with a value another process wrote, even after this process overwrites
  /// it, so a seed written by the runner would hide every later change.
  private static func makeDefaults(_ environment: [String: String]) -> UserDefaults {
    #if DEBUG
      if let path = environment["UNITERM_DEFAULTS_PATH"],
        let defaults = UserDefaults(suiteName: path)
      {
        if let seed = environment["UNITERM_DEFAULTS_SEED"] {
          for (key, value) in decodeSeed(seed) {
            defaults.set(value, forKey: key)
          }
        }

        return defaults
      }
    #endif

    return .standard
  }

  #if DEBUG
    /// A seed that does not decode stops the launch. Ignoring it would start the test from the
    /// wrong settings, and the test would then fail far from the cause.
    private static func decodeSeed(_ json: String) -> [String: String] {
      guard let seed = try? JSONDecoder().decode([String: String].self, from: Data(json.utf8))
      else {
        fatalError("UNITERM_DEFAULTS_SEED is not a JSON object of strings: \(json)")
      }

      return seed
    }
  #endif

  /// UI tests set `UNITERM_TERMINAL_DIR` so the generated terminal config stays out of the
  /// developer's Application Support folder. Only debug builds honor it, since a release build has
  /// no test to serve.
  private func terminalConfigDirectory() throws -> URL {
    #if DEBUG
      if let path = debugEnvironment["UNITERM_TERMINAL_DIR"] {
        return URL(fileURLWithPath: path, isDirectory: true)
      }
    #endif

    return try TerminalConfigStore.defaultDirectory()
  }

  /// The open panel that viewers and File > Open ask through.
  ///
  /// UI tests set `UNITERM_OPEN_PANEL_ANSWER` to a file that holds the answer, so a test that is
  /// about what uniterm does with a chosen file never drives the system's panel. That panel runs in
  /// another process, and each accessibility query of it takes seconds. Only debug builds honor it.
  private func openPicker() -> OpenPicker {
    #if DEBUG
      if let path = debugEnvironment["UNITERM_OPEN_PANEL_ANSWER"] {
        return OpenPanelTestHook(answerFile: URL(fileURLWithPath: path)).pick
      }
    #endif

    return SystemOpenPanel.pick
  }

  /// UI tests set `UNITERM_LAYOUT_DIR` so the saved layout stays out of the developer's Application
  /// Support folder. Only debug builds honor it, for the same reason as the terminal folder.
  private func layoutDirectory() throws -> URL {
    #if DEBUG
      if let path = debugEnvironment["UNITERM_LAYOUT_DIR"] {
        return URL(fileURLWithPath: path, isDirectory: true)
      }
    #endif

    return try LayoutPersistence.defaultDirectory()
  }

  /// UI tests set `UNITERM_SCRIPT_DIR` so the script socket stays out of the developer's Application
  /// Support folder. The folder must be short, since a socket path holds 104 bytes. Only debug
  /// builds honor it, for the same reason as the layout folder.
  private func scriptDirectory() throws -> URL {
    #if DEBUG
      if let path = debugEnvironment["UNITERM_SCRIPT_DIR"] {
        return URL(fileURLWithPath: path, isDirectory: true)
      }
    #endif

    return try ScriptSocketDirectory.defaultDirectory()
  }

  /// UI tests set `UNITERM_SENT_DIR` so content that scripts send stays out of the developer's
  /// Application Support folder. Only debug builds honor it, for the same reason as the layout
  /// folder.
  private func sentContentDirectory() throws -> URL {
    #if DEBUG
      if let path = debugEnvironment["UNITERM_SENT_DIR"] {
        return URL(fileURLWithPath: path, isDirectory: true)
      }
    #endif

    return try ScriptSentContent.defaultRoot()
  }

  /// The folder for content scripts send. A failure leaves scripting running without sends, and
  /// says so in the log.
  private func makeSentContent() -> ScriptSentContent? {
    do {
      return try ScriptSentContent(root: try sentContentDirectory())
    } catch {
      logger.error("sent content is off: \(String(describing: error), privacy: .public)")
      return nil
    }
  }

  /// UI tests set `UNITERM_CONTROLLER_RUNS_DIR` so the snapshots of controller runs stay out of the
  /// developer's caches folder. Only debug builds honor it, for the same reason as the layout
  /// folder.
  private func controllerRunsDirectory() throws -> URL {
    #if DEBUG
      if let path = debugEnvironment["UNITERM_CONTROLLER_RUNS_DIR"] {
        return URL(fileURLWithPath: path, isDirectory: true)
      }
    #endif

    return try ControllerSettings.defaultRunsRoot()
  }

  /// Where remembered controller approvals live.
  ///
  /// UI tests set `UNITERM_CONTROLLER_POLICY_DIR` so remembered controller approvals stay out of
  /// the developer's own policy file. Only debug builds honor it, for the same reason as the
  /// layout folder.
  private func controllerPolicyDirectory() -> URL? {
    #if DEBUG
      if let path = debugEnvironment["UNITERM_CONTROLLER_POLICY_DIR"] {
        return URL(fileURLWithPath: path, isDirectory: true)
      }
    #endif

    do {
      return try ControllerSettings.defaultTrustDirectory()
    } catch {
      logger.error("controller trust is off: \(String(describing: error), privacy: .public)")
      return nil
    }
  }

  /// Where controller runs keep their snapshots, and the bundle command that may ask for one. The
  /// snapshots that ended instances left are removed first. A failure leaves scripting running
  /// without controller packages, and says so in the log.
  private func makeControllerSettings(helper: BundleHelperIdentity) -> ControllerSettings? {
    do {
      return try ControllerSettings.atLaunch(
        root: try controllerRunsDirectory(), trustDirectory: controllerPolicyDirectory(),
        helper: helper)
    } catch {
      logger.error("controller runs are off: \(String(describing: error), privacy: .public)")
      return nil
    }
  }

  /// Starts the listener that script helpers connect to. A failure leaves the app running without
  /// scripting, and says so.
  private func startScripting(windows: WindowSet) {
    do {
      // The command's identity is read at once, and the listener checks the command against it
      // before it admits a call. The same value serves the controller settings, so one read of the
      // command's file is what both keep.
      let command = BundleHelperIdentity.current()
      let listener = try ScriptListener.start(
        directory: try scriptDirectory(), commandIdentity: command)

      let host = ScriptHost(
        listener: listener,
        issueProducer: { [weak windows] name in
          windows?.requestProducer(kind: .script, name: name) ?? .noWindow
        },
        windows: WindowScripting(windows: windows),
        sentContent: makeSentContent(),
        onRefusal: { [weak self] refusal in
          self?.logger.error("a script connection was refused: \(refusal.text, privacy: .public)")
          self?.windowSet?.post(level: .warning, text: refusal.text)
        },
        controllers: makeControllerSettings(helper: command), clipboard: clipboard,
        permissionRequests: windows.permissionRequests, settings: settings)

      host.start()
      scriptHost = host

      windows.wireControllers(to: host)

      host.onPendingRequestsActiveChanged = { [weak self] _ in self?.refreshPendingSlot() }
      pendingObserver = windows.permissionRequests.changes.add { [weak self] in
        self?.refreshPendingSlot()
      }

      windows.wireSessionReporting(
        onStarted: { [weak host] windowID, pane, _, pid, started, generation in
          host?.recordSessionRoot(
            ProcessIdentity(pid: pid, started: started), sessionGeneration: generation,
            window: windowID, pane: pane)
        },
        onEnded: { [weak host] windowID, pane, _, pid, started in
          host?.removeSessionRoot(
            ProcessIdentity(pid: pid, started: started), window: windowID, pane: pane)
        },
        onWindowClosed: { [weak host] windowID in host?.windowClosed(windowID) }
      )
    } catch {
      logger.error("scripting did not start: \(String(describing: error), privacy: .public)")
      windows.post(level: .warning, text: "Scripts cannot connect to uniterm: \(error)")
    }
  }

  /// UI tests set `UNITERM_TEST_APPLETS` to 1 to register the hosted slide, notes, and chart
  /// fixtures, so an exec pane can be driven in the real app. Only debug builds compile the
  /// registration in, so no release applet gains exec support through it.
  private var testAppletsEnabled: Bool {
    #if DEBUG
      return debugEnvironment["UNITERM_TEST_APPLETS"] == "1"
    #else
      return false
    #endif
  }

  /// The applet types this build's windows know: the built-in ones, and the fixtures when a debug
  /// build is asked for them.
  private var appletDeclarations: [AppletTypeDeclaration] {
    #if DEBUG
      if testAppletsEnabled { return BuiltInApplets.declarations + AppletFixtures.declarations }
    #endif

    return BuiltInApplets.declarations
  }

  /// UI tests set `UNITERM_BROWSER_DIR` so the browser's own files stay out of the developer's
  /// Application Support folder. Only debug builds honor it, for the same reason as the layout
  /// folder. Nil means the default folder.
  private func browserDirectory() -> URL? {
    #if DEBUG
      if let path = debugEnvironment["UNITERM_BROWSER_DIR"] {
        return URL(fileURLWithPath: path, isDirectory: true)
      }
    #endif

    return nil
  }

  /// UI tests set `UNITERM_BROWSER_STORE` to `memory`, so the browser keeps its cookies and site data
  /// in memory and never reaches the developer's real store. The app's bundle identifier scopes the
  /// real store, and a UI test runs under the same one. Only debug builds honor it, for the same
  /// reason as the other folders.
  private func browserStoreIsInMemory() -> Bool {
    #if DEBUG
      return debugEnvironment["UNITERM_BROWSER_STORE"] == "memory"
    #else
      return false
    #endif
  }

  /// UI tests set `UNITERM_LAYOUT_DEBOUNCE` to a long delay in seconds, so only the save on quit can
  /// write the layout. Only debug builds honor it.
  private func layoutDebounce() -> TimeInterval {
    #if DEBUG
      if let text = debugEnvironment["UNITERM_LAYOUT_DEBOUNCE"],
        let seconds = TimeInterval(text), seconds > 0
      {
        return seconds
      }
    #endif

    return 1
  }

  /// The `ghostty` folder that the build copies into the bundle's resources. It holds the
  /// shell-integration scripts. The `terminfo` folder sits next to it.
  private static func ghosttyResourcesDirectory() -> URL {
    let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
    return resources.appending(path: "ghostty", directoryHint: .isDirectory)
  }

  private static func ghosttyHelperDirectory() -> URL {
    let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
    return resources.appending(path: "ghostty-bin", directoryHint: .isDirectory)
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    logger.info("libghostty \(TerminalSurfaceInfo.libraryVersion, privacy: .public)")

    let appearance = AppearanceController(store: settings)
    self.appearance = appearance

    let engine: GhosttyTerminalEngine
    do {
      engine = try GhosttyTerminalEngine(
        configStore: TerminalConfigStore(directory: try terminalConfigDirectory()),
        resourcesDirectory: Self.ghosttyResourcesDirectory(),
        helperDirectory: Self.ghosttyHelperDirectory(), palette: appearance.palette)
    } catch {
      logger.error("the terminal engine did not start: \(String(describing: error))")

      failLaunch("uniterm could not start its terminal engine", detail: error)
      return
    }

    terminalEngine = engine

    let commands = CommandRegistry(
      app: AppCommandHooks(
        newWindow: { [weak self] in self?.openWindow() },
        showSettings: { [weak self] in self?.presentSettings() },
        showPendingRequests: { [weak self] in self?.presentPendingRequests() },
        showControllers: { [weak self] in self?.presentControllers() },
        suspendAllControllers: { [weak self] in self?.windowSet?.suspendAllControllers() },
        resumeAllControllers: { [weak self] in self?.windowSet?.resumeAllControllers() },
        showSuspendedControllers: { [weak self] in
          self?.windowSet?.presentSuspendedControllersMenu()
        },
        installCommandLineTool: { [weak self] in self?.installCommandLineTool() },
        openFile: { [weak self] anchor in
          Task { await self?.fileOpens?.open(from: anchor) }
        },
        openFileWith: { [weak self] anchor in
          Task { await self?.fileOpens?.openWith(from: anchor) }
        },
        canQuit: { [weak self] in self?.askingToQuit == false },
        warn: { [weak self] text in
          self?.windowSet?.post(level: .warning, text: text)
        }))
    for set in BuiltInApplets.commandSets {
      commands.register(set)
    }

    self.commands = commands

    let settings = settings

    // The UI tests turn off the place names, so a test's map never sends its center to Apple. The
    // search stays, since it sends nothing until someone types.
    let places =
      ProcessInfo.processInfo.environment["UNITERM_PLACE_NAMES"] == "off"
      ? PlaceServices(search: PlaceServices.apple.search) : PlaceServices.apple

    // Every viewer pane and File > Open ask through this panel. A debug build lets a UI test answer
    // it without showing the system's panel.
    let picker = openPicker()

    // Every browser pane, new or restored, gets these. The engine is read at each search, so a
    // change in Settings applies to the next search in every open pane.
    let browserServices = BrowserServices.live(
      searchEngine: { settings.value(of: .searchEngine) }, directory: browserDirectory())

    // Every browser pane shares this store. It is never WebKit's default store.
    let websiteData = BrowserWebsiteData.live(
      services: browserServices, inMemory: browserStoreIsInMemory())
    browserWebsiteData = websiteData

    // The closures read the script host when they run. A REPL restored at launch asks for its
    // channel after the listener has started, and a REPL opened later finds it the same way.
    let replServices = ReplServices(
      helper: { ScriptCommandInstaller.command(in: Bundle.main.bundleURL) },
      openChannel: { [weak self] history in
        self?.scriptHost?.admitRepl(history: history) ?? .refused(.scriptingOff)
      },
      traceSigint: debugEnvironment["UNITERM_REPL_TRACE_SIGINT"] == "1")

    #if DEBUG
      let testApplets = testAppletsEnabled
    #endif

    let declarations = appletDeclarations

    let scrollbackStore = (try? terminalConfigDirectory()).map {
      ScrollbackStore(directory: $0.appending(path: "scrollback", directoryHint: .isDirectory))
    }

    let restoreApplet: AppletRestorer = { description in
      switch description.type {
      case TerminalDescription.typeID:
        return try TerminalApplet(
          engine: engine, restoring: description, scrollbackStore: scrollbackStore)

      case DataViewerDescription.typeID:
        return try DataViewerApplet(restoring: description, picker: picker)

      case MapViewerDescription.typeID:
        return try MapViewerApplet(
          restoring: description, places: places, picker: picker)

      case ImageViewerDescription.typeID:
        return try ImageViewerApplet(restoring: description, picker: picker)

      case TextViewerDescription.typeID:
        return try TextViewerApplet(restoring: description, picker: picker)

      case BrowserApplet.descriptionTypeID:
        return try BrowserApplet(
          restoring: description, dataStore: websiteData.store, services: browserServices)

      case ReplDescription.typeID:
        return try ReplApplet(engine: engine, services: replServices, restoring: description)

      case QuestionsApplet.descriptionTypeID:
        return try QuestionsApplet(restoring: description)

      default:
        #if DEBUG
          if testApplets, AppletFixtures.typeIDs.contains(description.type) {
            return try AppletFixtures.restore(description)
          }
        #endif

        throw AppletRestoreError.unsupported("the applet type \"\(description.type)\" is unknown")
      }
    }

    let makeApplet: AppletFactory = { choice, directory in
      switch choice {
      case .terminalShell:
        return TerminalApplet(
          engine: engine, workingDirectory: directory, scrollbackStore: scrollbackStore)

      case .terminalProgram(let command):
        return try TerminalApplet(engine: engine, program: command, workingDirectory: directory)

      case .dataViewer:
        return DataViewerApplet(startDirectory: directory, picker: picker)

      case .mapViewer(let region):
        return MapViewerApplet(
          startDirectory: directory, region: region, places: places, picker: picker)

      case .browser:
        return BrowserApplet(dataStore: websiteData.store, services: browserServices)

      case .browserPage(let text):
        return BrowserApplet(
          dataStore: websiteData.store, services: browserServices, seed: text)

      case .imageViewer:
        return ImageViewerApplet(startDirectory: directory, picker: picker)

      case .textViewer:
        return TextViewerApplet(startDirectory: directory, picker: picker)

      case .repl:
        return ReplApplet(engine: engine, services: replServices)

      case .hosted(let typeID):
        #if DEBUG
          if testApplets, let applet = AppletFixtures.make(typeID: typeID) { return applet }
        #endif

        throw AppletRestoreError.unsupported("uniterm cannot open a \(typeID) pane here")
      }
    }

    let windows = WindowSet(
      makeRestoredController: { identifier, restored in
        try MainWindowController(
          appearance: appearance, settings: settings, identifier: identifier,
          commands: commands, appletTypes: declarations, restoring: restored,
          restoreApplet: restoreApplet,
          places: places, makeApplet: makeApplet)
      },
      makeRoutedController: { identifier, applet in
        try MainWindowController(
          appearance: appearance, settings: settings, identifier: identifier,
          commands: commands, appletTypes: declarations, startingWith: applet,
          restoreApplet: restoreApplet,
          places: places, makeApplet: makeApplet)
      },
      makeController: { identifier, directory in
        try MainWindowController(
          appearance: appearance, settings: settings, identifier: identifier,
          startingIn: directory, commands: commands, appletTypes: declarations,
          restoreApplet: restoreApplet,
          places: places, makeApplet: makeApplet)
      })
    windowSet = windows
    windows.clipboard = clipboard
    pendingIndicator = PendingRequestsIndicator(
      windows: windows, scriptHost: { [weak self] in self?.scriptHost })
    windows.launchAuthority.onActiveChanged = { [weak self] _ in self?.refreshPendingSlot() }

    // Scripting starts before any window, so a REPL that a window restores finds the listener.
    startScripting(windows: windows)

    let sourceFactories: [String: AppletSourceFactory] = [
      TerminalDescription.typeID: { _, startDirectory in
        try makeApplet(.terminalShell, startDirectory)
      },
      DataViewerDescription.typeID: { file, startDirectory in
        try DataViewerApplet.opening(file, startDirectory: startDirectory, picker: picker)
      },
      MapViewerDescription.typeID: { file, startDirectory in
        MapViewerApplet.opening(
          file, startDirectory: startDirectory, places: places, picker: picker)
      },
      ImageViewerDescription.typeID: { file, startDirectory in
        try ImageViewerApplet.opening(file, startDirectory: startDirectory, picker: picker)
      },
      TextViewerDescription.typeID: { file, startDirectory in
        try TextViewerApplet.opening(file, startDirectory: startDirectory, picker: picker)
      },
    ]

    routedOpener = RoutedOpener(
      windows: windows, declarations: BuiltInApplets.declarations, factories: sourceFactories,
      store: SavedChoiceStore(defaults: defaults))

    if let routedOpener {
      windows.routedOpener = routedOpener
      fileOpens = FileOpenCommands(opener: routedOpener, picker: picker)

      let coordinator = LaunchOpenCoordinator(
        windows: windows, opener: routedOpener,
        openFallbackWindow: { [weak self] in self?.openWindow() })
      launchOpens = coordinator
      scriptHost?.fileOpener = ScriptFileOpener(windows: windows, coordinator: coordinator)

      for early in earlyOpens {
        coordinator.receive(early.urls, from: early.sender)
      }

      earlyOpens = []
    }

    let menu = CommandMenu(
      registry: commands, activeController: { [weak self] in self?.windowSet?.activeController })
    commandMenu = menu
    menu.install()

    let persistence: LayoutPersistence?
    do {
      persistence = LayoutPersistence(
        directory: try layoutDirectory(), windows: windows, debounce: layoutDebounce())
    } catch {
      logger.error("the layout folder is not available: \(String(describing: error))")
      persistence = nil

      do {
        if launchOpens?.hasPending != true {
          try windows.open()
        }

        windows.post(
          level: .error,
          text: "The layout folder is not available, so this window's layout is not saved: \(error)"
        )
      } catch {
        failLaunch("uniterm could not open its first window", detail: error)
        return
      }
    }

    layoutPersistence = persistence

    do {
      try persistence?.launch(hasPendingOpen: { [weak self] in self?.launchOpens?.hasPending == true
      })
    } catch {
      logger.error("the first window did not open: \(String(describing: error))")
      failLaunch("uniterm could not open its first window", detail: error)
      return
    }

    launchOpens?.launchFinished()

    let sync = TerminalPaletteSync(engine: engine) { [weak self] error in
      self?.paletteDidNotApply(error)
    }
    paletteSync = sync
    appearanceToken = appearance.addObserver { palette in
      sync.apply(palette)
    }

    NSApp.activate()

    if let controller = windows.activeController {
      postDebugError(to: controller)
    }

    startQuestionsTestHook(windows: windows)
  }

  /// UI tests set `UNITERM_TEST_QUESTIONS_DIR` to open forms in the Questions pane from files, so a
  /// test opens a form without running a script. Only debug builds honor it.
  private func startQuestionsTestHook(windows: WindowSet) {
    #if DEBUG
      guard let path = debugEnvironment["UNITERM_TEST_QUESTIONS_DIR"] else { return }

      let hook = QuestionsTestHook(directory: URL(fileURLWithPath: path), windows: windows)

      questionsTestHook = hook
      hook.start()
    #endif
  }

  /// Tells the user what failed at launch, then quits. Without a window there is nowhere else to
  /// say it.
  private func failLaunch(_ message: String, detail: any Error) {
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = message
    alert.informativeText =
      "\(detail)\n\nQuit uniterm and open it again. If this keeps happening, check the log."
    alert.runModal()
    NSApp.terminate(nil)
  }

  /// UI tests set `UNITERM_DEBUG_POST_ERROR` to get an error on the status bar without relying on
  /// a feature that may change. Only debug builds honor it.
  private func postDebugError(to controller: MainWindowController) {
    #if DEBUG
      if let text = debugEnvironment["UNITERM_DEBUG_POST_ERROR"] {
        controller.statusCenter.post(level: .error, text: text)
      }
    #endif
  }

  /// `WindowSet.shouldQuit` decides whether to ask, and what about. It answers at once when
  /// nothing is unsaved and nothing runs. The answer may come later, so AppKit waits for it. A
  /// second Cmd-Q while the question is open does not stack another one.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let windowSet else { return .terminateNow }

    guard !askingToQuit else { return .terminateCancel }

    askingToQuit = true

    Task { @MainActor [weak self] in
      let confirmed = await windowSet.shouldQuit()
      self?.askingToQuit = false
      sender.reply(toApplicationShouldTerminate: confirmed)
    }

    return .terminateLater
  }

  func applicationWillTerminate(_ notification: Notification) {
    windowSet?.endDriversForQuit()
    scriptHost?.stop()
    layoutPersistence?.saveForQuit()
    terminalEngine?.removeConfigFile()
  }

  /// uniterm restores its own layout on every launch, from its own file. AppKit's window
  /// restoration is off, so it never opens a second copy of a restored window, and it never follows
  /// the system setting that closes windows when quitting.
  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    true
  }

  func application(_ app: NSApplication, shouldRestoreSecureApplicationState coder: NSCoder) -> Bool
  {
    false
  }

  /// Closing the last window leaves the app running, as on macOS generally. Cmd-N or a click on
  /// the Dock icon opens a new window, and Cmd-Q quits.
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  /// A click on the Dock icon opens a window when none is open. The Settings window does not
  /// count. With a window open, minimized or not, AppKit's own handling brings it back.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    !openWindow(onlyIfNone: true)
  }

  /// Files from Finder, the Dock, or another program.
  ///
  /// The sender is read from the event being handled.
  ///
  /// The reply to the sender is the same whatever happens to its files, so a refused sender learns
  /// nothing about them. AppKit sends that reply, since this method returns nothing.
  func application(_ application: NSApplication, open urls: [URL]) {
    let event = NSAppleEventManager.shared().currentAppleEvent
    let tokens = OpenEventSender.tokens(of: event)
    let resolver = SystemSenderResolver()

    // The code-signing lookups run on the main thread. Each is a local check of a signed binary
    // on disk and of a live process's signing state, with no network and no wait on the user, so
    // the wait is short. They must run here. The event is current only inside this callback, and
    // the sender exits quickly, so a later lookup would find it gone.

    let sender = tokens.sender.flatMap { resolver.identity(of: $0) }
    let actual = tokens.actual.flatMap { resolver.identity(of: $0) }

    debugLog(
      "open-event files=\(urls.count) event=\(event != nil) "
        + "sender-token=\(tokens.sender.map { "pid=\($0.pid)" } ?? "none") "
        + "sender={\(sender?.logDescription ?? "unidentified")} "
        + "actual-token=\(tokens.actual.map { "pid=\($0.pid)" } ?? "none") "
        + "actual={\(actual?.logDescription ?? "unidentified")}")

    guard let launchOpens else {
      earlyOpens.append((urls, sender))
      return
    }

    launchOpens.receive(urls, from: sender)
  }

  /// Writes a line to standard error in debug builds, so a run started from a shell can record
  /// who sent an open. The unified log drops debug lines by default.
  private func debugLog(_ line: String) {
    logger.debug("\(line, privacy: .public)")

    #if DEBUG
      FileHandle.standardError.write(Data("uniterm: \(line)\n".utf8))
    #endif
  }

  private func paletteDidNotApply(_ error: any Error) {
    logger.error("the terminal palette did not update: \(String(describing: error))")
    windowSet?.post(
      level: .error, text: "The terminal colors did not update: \(error)")
  }

  /// Says whether a window opened. With `onlyIfNone`, an open window means nothing opens.
  @discardableResult
  private func openWindow(onlyIfNone: Bool = false) -> Bool {
    guard let windowSet else { return false }

    do {
      if onlyIfNone { return try windowSet.openIfNone() }

      try windowSet.open()
      return true
    } catch {
      logger.error("the window did not open: \(String(describing: error))")

      if let active = windowSet.activeController {
        active.statusCenter.post(
          level: .error, text: "The window did not open: \(error)")
        return false
      }

      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = "uniterm could not open a window"
      alert.informativeText = "\(error)"
      alert.runModal()
      return false
    }
  }

  /// Asks where to put the `uniterm` command, then links it into this bundle. The panel opens in
  /// `~/.local/bin`, which is made first so the panel has somewhere to start.
  private func installCommandLineTool() {
    let installer = ScriptCommandInstaller(
      command: ScriptCommandInstaller.command(in: Bundle.main.bundleURL))

    installer.prepareDefaultDirectory()

    let panel = NSSavePanel()
    panel.title = "Install Command Line Tool"
    panel.message = "uniterm links its command here, so a shell can run uniterm by name."
    panel.prompt = "Install"
    panel.directoryURL = installer.defaultDirectory
    panel.nameFieldStringValue = "uniterm"
    panel.canCreateDirectories = true

    guard panel.runModal() == .OK, let url = panel.url else { return }

    let alert = NSAlert()

    do {
      let installed = try installer.install(at: url)

      alert.messageText = "The uniterm command is installed"
      alert.informativeText = installed.message
    } catch {
      alert.alertStyle = .warning
      alert.messageText = "The uniterm command was not installed"
      alert.informativeText = "\(error)"
    }

    alert.runModal()
  }

  private func presentSettings() {
    let controller =
      settingsWindowController
      ?? SettingsWindowController(
        store: settings,
        clearWebsiteData: { [weak self] in
          guard let data = self?.browserWebsiteData else {
            throw BrowserWebsiteData.ClearError.unavailable
          }

          try await data.clear()
        })
    settingsWindowController = controller
    controller.present()
  }

  /// The pending-permissions slot shows while a program waits for a pane, a controller waits for
  /// its review, a driver waits to run, or any program waits for a permission.
  private func refreshPendingSlot() {
    pendingIndicator?.refresh()
  }

  /// Opens Controllers & Permissions. Without scripting there is nothing to list, so it says so.
  private func presentControllers() {
    guard let scriptHost else {
      let alert = NSAlert()

      alert.messageText = "No controllers can run"
      alert.informativeText = "Scripting did not start, so no controller runs or approvals exist."
      alert.addButton(withTitle: "OK")
      alert.runModal()

      return
    }

    let controller =
      controllersWindowController ?? ControllersWindowController(scriptHost: scriptHost)
    controllersWindowController = controller
    controller.present()
  }

  private func presentPendingRequests() {
    guard let windows = windowSet else { return }

    let controller =
      pendingRequestsWindowController
      ?? PendingRequestsWindowController(scriptHost: scriptHost, windows: windows)
    pendingRequestsWindowController = controller
    controller.showWindow(nil)
  }
}
