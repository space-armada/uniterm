import AppKit
import FileRouting
import Foundation
import OSLog
import ScriptHost
import StatusKit

/// Calls `onEnd` when the process `pid` exits or starts another executable, and returns a call that
/// stops watching. Both end what a session grant bound, since the kernel gives the process another
/// version when it starts another executable.
public typealias SenderWatcher =
  @MainActor (_ pid: Int32, _ onEnd: @escaping @MainActor () -> Void) -> () -> Void

/// The system's watcher. A process that already exited ends at once.
@MainActor
public func watchProcessEnd(
  pid: Int32, onEnd: @escaping @MainActor () -> Void
) -> () -> Void {
  let source = DispatchSource.makeProcessSource(
    identifier: pid, eventMask: [.exit, .exec], queue: .main)

  source.setEventHandler {
    MainActor.assumeIsolated { onEnd() }
  }

  source.activate()

  return { source.cancel() }
}

/// Takes the files that Launch Services hands the app, decides whether the sender may open them,
/// and routes them to panes.
///
/// Apple's openers are the user's act. Every other sender's event is one operation in the pending
/// indicator, and the question lists every path. Nothing touches a path before the user allows it,
/// so a pending, denied, withdrawn, or exited open learns nothing about the files it names and
/// cannot raise a privacy prompt under uniterm's name.
///
/// An app uniterm could name may be allowed for its run. The grant binds to the sender's process ID
/// and its version, lives in memory, and goes when the process exits or starts another executable.
/// A sender that cannot be identified, and an Apple-signed program that is not an opener, are
/// allowed once only.
///
/// An open that arrives before layout restore finishes waits. `launchFinished` replays it after
/// every launch outcome. The layout's default window decision asks `hasPending` first, so a
/// cold-launch open does not start a shell beside the routed pane. An open that still waits for
/// the user's answer does not count, so the default window opens and the question has a window.
@MainActor
public final class LaunchOpenCoordinator {
  private static let logger = Logger(subsystem: "dev.uniterm.app", category: "open")

  private struct Request {
    let files: [URL]

    /// Where a program's open anchors, read when the request runs. Nil for a Launch Services open,
    /// which anchors to the most recently key window. Either way the anchor's window comes forward.
    let programAnchor: (@MainActor () -> RouteAnchor?)?
  }

  private let windows: WindowSet
  private let opener: RoutedOpener
  private let now: @MainActor () -> TimeInterval
  private let openFallbackWindow: @MainActor () -> Void
  private let watchSender: SenderWatcher

  private struct SenderKey: Hashable {
    let pid: Int32
    let pidVersion: Int32
  }

  private var grants: Set<SenderKey> = []
  private var watches: [SenderKey: () -> Void] = [:]
  private var lastEvent: UInt64 = 0

  private var coalescer: RefusalCoalescer
  private var queue: [Request] = []
  private var ready = false

  /// The task that runs the queue, while one does. Its end means every open that could run has run.
  private var drain: Task<Void, Never>?
  private var windowCheckDue = false

  /// `openFallbackWindow` runs after the replay when no window is open, so a launch whose only
  /// opens were refused or failed still shows a window.
  public init(
    windows: WindowSet, opener: RoutedOpener,
    coalescer: RefusalCoalescer = RefusalCoalescer(),
    now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    watchSender: @escaping SenderWatcher = { watchProcessEnd(pid: $0, onEnd: $1) },
    openFallbackWindow: @escaping @MainActor () -> Void
  ) {
    self.watchSender = watchSender
    self.windows = windows
    self.opener = opener
    self.coalescer = coalescer
    self.now = now
    self.openFallbackWindow = openFallbackWindow
  }

  /// True while an allowed open waits for layout restore. An open that waits for the user's answer
  /// is not counted, and neither is a refused one.
  public var hasPending: Bool { !queue.isEmpty }

  /// Handles one open-documents event. The reply to the sender never depends on the outcome, so
  /// this returns nothing.
  public func receive(_ urls: [URL], from sender: SenderIdentity?) {
    switch OpenAuthority.decide(for: sender) {
    case .needsApproval(let sender, let onceOnly):
      ask(urls, from: sender, onceOnly: onceOnly)

    case .userAct:
      queue.append(Request(files: urls, programAnchor: nil))
      drainIfReady()
    }
  }

  /// Takes the files of a program's open that the user already approved. It waits for layout
  /// restore as a Launch Services open does. The anchor is asked when the open runs, so a pane
  /// that closed while it waited falls back to the most recently key window. It lands as the
  /// user's own open does: the anchor's window comes forward, and the new pane takes focus.
  ///
  /// The approval named every path and the count. Nothing here has looked at a path.
  public func receiveProgramOpen(_ urls: [URL], anchor: @escaping @MainActor () -> RouteAnchor?) {
    queue.append(Request(files: urls, programAnchor: anchor))
    drainIfReady()
  }

  /// Layout restore is over. Replays every open that waited, then opens a window if there is none.
  public func launchFinished() {
    ready = true
    windowCheckDue = true
    drainIfReady()

    if drain == nil {
      ensureWindow()
    }
  }

  private func refuse(sender: String, reason: OpenAuthority.Refusal) {
    Self.logger.info(
      "did not open files from \(sender, privacy: .public): \(String(describing: reason))")

    guard let text = coalescer.note(sender: sender, reason: reason, at: now()) else { return }

    windows.post(level: .warning, text: text)
  }

  /// Puts one event before the user as one operation. Nothing here reads a path. The text of the
  /// question comes from each URL's own string.
  private func ask(_ urls: [URL], from sender: SenderIdentity?, onceOnly: Bool) {
    let name = sender?.name ?? "an unidentified program"
    let paths = urls.filter(\.isFileURL).map(\.path)

    guard !paths.isEmpty else {
      return refuse(sender: name, reason: .noLocalFiles)
    }

    let key = sender.map { SenderKey(pid: $0.pid, pidVersion: $0.pidVersion) }

    if !onceOnly, let key, grants.contains(key) {
      return receiveProgramOpen(urls) { nil }
    }

    let requester: PermissionRequests.Requester

    if !onceOnly, let key {
      requester = .launchSender(pid: key.pid, pidVersion: key.pidVersion)
      watch(key)
    } else {
      lastEvent += 1
      requester = .launchEvent(lastEvent)
    }

    let outcome = windows.permissionRequests.ask(
      PermissionRequests.Key(requester: requester, power: "open files"),
      subject: LaunchOpenApprovalText.subject(sender: sender), pid: sender?.pid,
      title: OpenApprovalText.title(count: paths.count),
      detail: LaunchOpenApprovalText.detail(
        paths: paths, skipped: urls.count - paths.count, sender: sender, onceOnly: onceOnly),
      sessionTitle: LaunchOpenApprovalText.sessionTitle, onceOnly: onceOnly
    ) { [weak self] answer in
      self?.answered(answer, urls, sender: name, key: onceOnly ? nil : key, requester: requester)
    }

    switch outcome {
    case .waiting:
      break

    case .denied:
      refuse(sender: name, reason: .denied)

    case .busy:
      refuse(sender: name, reason: .busy)
    }
  }

  private func answered(
    _ answer: PermissionRequests.Answer, _ urls: [URL], sender: String, key: SenderKey?,
    requester: PermissionRequests.Requester
  ) {
    switch answer {
    case .allowOnce:
      receiveProgramOpen(urls) { nil }

    case .allowForSession:
      if let key { grants.insert(key) }

      receiveProgramOpen(urls) { nil }

    case .deny:
      refuse(sender: sender, reason: .denied)

      if key == nil { windows.permissionRequests.end(requester) }

    case .withdrawn:
      refuse(sender: sender, reason: .withdrawn)
    }
  }

  /// Starts watching a sender that may hold a session grant. Its end clears the grant and
  /// withdraws what still waits for it, and its denial goes too.
  private func watch(_ key: SenderKey) {
    guard watches[key] == nil else { return }

    watches[key] = watchSender(key.pid) { [weak self] in
      self?.senderEnded(key)
    }
  }

  private func senderEnded(_ key: SenderKey) {
    grants.remove(key)
    watches.removeValue(forKey: key)?()

    windows.permissionRequests.end(.launchSender(pid: key.pid, pidVersion: key.pidVersion))
  }

  private func drainIfReady() {
    guard ready, drain == nil, !queue.isEmpty else { return }

    drain = Task { @MainActor [weak self] in
      guard let self else { return }

      while !self.queue.isEmpty {
        await self.run(self.queue.removeFirst())
      }

      self.drain = nil
      self.ensureWindow()
    }
  }

  /// Returns once no drain is running. Routing runs off the main thread, so yielding the main actor
  /// does not wait for it, and this does. An open that waits for layout restore or for the user's
  /// answer to a sender's question has not started a drain, so it does not hold this. A drain that
  /// waits on a question the router asks does.
  func idle() async {
    while let drain {
      await drain.value
    }
  }

  private func ensureWindow() {
    guard windowCheckDue else { return }

    windowCheckDue = false

    guard windows.controllers.isEmpty else { return }

    openFallbackWindow()
  }

  private func run(_ request: Request) async {
    let files = request.files.filter(\.isFileURL)

    if files.count < request.files.count {
      windows.post(
        level: .warning,
        text:
          "\(request.files.count - files.count) item(s) were not local files, "
          + "so they were not opened."
      )
    }

    guard !files.isEmpty else { return }

    let anchor = request.programAnchor?() ?? windows.launchAnchor()

    if let anchor {
      windows.bringForward(anchor.controller)
    } else {
      NSApp.activate()
    }

    let options: RoutedOpenOptions = request.programAnchor == nil ? .init() : .approvedProgram
    await opener.open(files, from: anchor, options: options)
  }
}
