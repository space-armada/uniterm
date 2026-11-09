import Darwin
import Foundation

/// How a watcher treats events and a path that is gone.
public struct WatchPolicy: Sendable, Equatable {
  /// Seconds of quiet before a change is delivered. Zero delivers every event at once.
  public var settle: Double

  /// The longest a continuous burst delays a delivery.
  public var ceiling: Double

  /// Watches the file's folder too. An editor's write-new-then-rename save, and a file or folder
  /// that is deleted and made again, show up there.
  public var watchesFolder: Bool

  /// How many times a path that cannot be watched is looked at again, or nil to look until the
  /// watcher stops.
  public var retryLimit: Int?

  /// Seconds between the first looks at a path that cannot be watched.
  public var retryInterval: Double

  /// The map viewer's watch: the file alone, every event at once, and ten looks for a file that is
  /// gone, half a second apart. An editor that deletes the file before writing the new one puts it
  /// back within that time.
  public static let fileOnly = WatchPolicy(
    settle: 0, ceiling: 0, watchesFolder: false, retryLimit: 10, retryInterval: 0.5)

  /// The document viewer's watch: the file and its folder, bursts merged, and a look at a missing
  /// path for as long as the pane lives.
  public static let document = WatchPolicy(
    settle: 0.15, ceiling: 1, watchesFolder: true, retryLimit: nil, retryInterval: 0.5)

  public init(
    settle: Double, ceiling: Double, watchesFolder: Bool, retryLimit: Int?, retryInterval: Double
  ) {
    self.settle = settle
    self.ceiling = ceiling
    self.watchesFolder = watchesFolder
    self.retryLimit = retryLimit
    self.retryInterval = retryInterval
  }
}

/// Calls back when a file is written, renamed, deleted, or put back.
///
/// An editor that saves by writing a new file and renaming it over the old one replaces the
/// watched file, so the watch moves to whatever file is at the path after each change. With
/// `watchesFolder`, the folder is watched too. A change in the folder counts only when it changes
/// what the path holds, so a neighbor's change delivers nothing. When the path or its folder is
/// gone, the watcher looks again on a timer and delivers when the path is back.
///
/// The callback gets the path's signature at delivery, which says whether a file is there.
///
/// Every call that touches the path runs on a queue of the watcher's own, never on the main
/// thread. A path on a stalled network mount or an automount can block a `stat` or an `open`
/// indefinitely, and only that queue waits. Results come back to the main actor.
///
/// A watcher does not see a rename of a folder above the watched folder. The folder's descriptor
/// follows the moved folder, so the watch quietly watches the file at its new location. A manual
/// reload covers that case.
@MainActor
public final class FileWatcher {
  public let url: URL

  private let worker: WatchWorker
  private let onChange: @MainActor (FileSignature) -> Void
  private var coalescer: ChangeCoalescer?
  private var stopped = false

  public init(
    url: URL, policy: WatchPolicy = .fileOnly, scheduler: (any WatchScheduler)? = nil,
    onChange: @escaping @MainActor (FileSignature) -> Void
  ) {
    self.url = url
    self.onChange = onChange

    let worker = WatchWorker(url: url, policy: policy)
    self.worker = worker

    coalescer = ChangeCoalescer(
      settle: policy.settle, ceiling: policy.ceiling,
      scheduler: scheduler ?? DispatchWatchScheduler()
    ) { [weak self] in self?.deliver() }

    worker.signal = { [weak self] in
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.noted() }
      }
    }

    worker.start()
  }

  deinit {
    worker.stop()
  }

  /// Returns once the watch is in place, so a caller that reads the file next sees every change
  /// after that read.
  public func whenArmed() async {
    await worker.whenArmed()
  }

  public func stop() {
    stopped = true
    coalescer?.cancel()
    worker.stop()
  }

  private func noted() {
    guard !stopped else { return }

    coalescer?.note()
  }

  private func deliver() {
    guard !stopped else { return }

    worker.sample { [weak self] signature in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self, !self.stopped else { return }

          self.onChange(signature)
        }
      }
    }
  }
}

/// The watcher's file-system side. All of its state belongs to `queue`.
private final class WatchWorker: @unchecked Sendable {
  /// How many looks at a missing path come at `retryInterval` before the slower rate.
  private static let quickLooks = 10

  /// Seconds between looks after the quick ones, for a watcher that looks without a limit.
  private static let slowInterval = 5.0

  /// Called on `queue` when an event is worth noting. Set before `start`.
  var signal: @Sendable () -> Void = {}

  private let queue = DispatchQueue(label: "uniterm.file-watcher", qos: .utility)
  private let path: String
  private let folder: String
  private let policy: WatchPolicy
  private var fileSource: (any DispatchSourceFileSystemObject)?
  private var folderSource: (any DispatchSourceFileSystemObject)?
  private var observed = FileSignature.missing
  private var retries = 0
  private var retryItem: DispatchWorkItem?
  private var stopped = false

  init(url: URL, policy: WatchPolicy) {
    path = url.path
    folder = url.deletingLastPathComponent().path
    self.policy = policy
  }

  func start() {
    queue.async {
      self.observed = FileSignature.of(path: self.path)
      self.arm()
    }
  }

  func stop() {
    queue.async {
      self.stopped = true
      self.retryItem?.cancel()
      self.retryItem = nil
      self.fileSource?.cancel()
      self.fileSource = nil
      self.folderSource?.cancel()
      self.folderSource = nil
    }
  }

  func sample(_ done: @escaping @Sendable (FileSignature) -> Void) {
    queue.async {
      guard !self.stopped else { return }

      done(FileSignature.of(path: self.path))
    }
  }

  func whenArmed() async {
    await withCheckedContinuation { continuation in
      queue.async { continuation.resume() }
    }
  }

  // MARK: Arming

  /// Whether the watch has what it needs. The folder is the anchor when it is watched, since it
  /// sees the file come back. Otherwise the file is.
  private var isArmed: Bool {
    policy.watchesFolder ? folderSource != nil : fileSource != nil
  }

  private func arm() {
    guard !stopped else { return }

    armFile()

    if policy.watchesFolder { armFolder() }

    if !isArmed { scheduleLook() }
  }

  private func armFile() {
    fileSource?.cancel()
    fileSource = makeSource(path: path) { [weak self] flags in self?.fileEvent(flags) }
  }

  private func armFolder() {
    folderSource?.cancel()
    folderSource = makeSource(path: folder) { [weak self] flags in self?.folderEvent(flags) }
  }

  private func makeSource(
    path: String, handler: @escaping @Sendable (DispatchSource.FileSystemEvent) -> Void
  ) -> (any DispatchSourceFileSystemObject)? {
    // O_NONBLOCK keeps the open from waiting on a named pipe that has no writer. A path can name a
    // pipe, since a viewer watches whatever the user opened.
    let descriptor = open(path, O_EVTONLY | O_NONBLOCK)

    guard descriptor >= 0 else { return nil }

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename], queue: queue)

    source.setEventHandler { [weak source] in
      guard let source else { return }

      handler(source.data)
    }

    source.setCancelHandler { close(descriptor) }
    source.resume()

    return source
  }

  // MARK: Events

  private func fileEvent(_ flags: DispatchSource.FileSystemEvent) {
    guard !stopped else { return }

    if !flags.isDisjoint(with: [.delete, .rename]) { rearmFile() }

    observed = FileSignature.of(path: path)
    signal()
  }

  private func folderEvent(_ flags: DispatchSource.FileSystemEvent) {
    guard !stopped else { return }

    if !flags.isDisjoint(with: [.delete, .rename]) {
      arm()
      observed = FileSignature.of(path: path)
      signal()
      return
    }

    let current = FileSignature.of(path: path)

    guard current != observed else { return }

    if !current.isSameFile(as: observed) { rearmFile() }

    observed = current
    signal()
  }

  private func rearmFile() {
    armFile()

    if !isArmed { scheduleLook() }
  }

  // MARK: Looking for a path that is gone

  private func scheduleLook() {
    guard !stopped, retryItem == nil else { return }

    if let limit = policy.retryLimit, retries >= limit { return }

    let interval =
      retries < Self.quickLooks
      ? policy.retryInterval : max(policy.retryInterval, Self.slowInterval)

    retries += 1

    let item = DispatchWorkItem { [weak self] in self?.look() }

    retryItem = item
    queue.asyncAfter(deadline: .now() + interval, execute: item)
  }

  private func look() {
    retryItem = nil

    guard !stopped else { return }

    arm()

    guard isArmed else { return }

    retries = 0
    observed = FileSignature.of(path: path)
    signal()
  }
}
