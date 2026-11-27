import Foundation

/// A viewer's swap to a file the user picked or dropped, waiting for the file's start directory.
///
/// The start directory needs a `stat`, which can wait as long as the file's mount takes to answer.
/// So it runs off the main thread, and the swap lands when it answers. The swap may wait again for
/// the pane to check the file, and `isCurrent` tells it whether a later swap or a cancel came in
/// the meantime. A later swap supersedes one still waiting, so the last file the user chose is the
/// one the pane shows. `cancel()` drops a swap still waiting, as a closing pane does.
@MainActor
public final class SourceSwap {
  /// The swap in flight, until it lands or is superseded.
  public private(set) var pending: Task<Void, Never>?

  private var generation = 0

  /// Learns a file's start directory. Tests replace it to hold the answer.
  var startDirectory: @Sendable (URL) async -> String = SourceStartDirectory.resolving

  public init() {}

  /// Learns `file`'s start directory, then calls `replace` with both, unless a later swap or a
  /// cancel came first. `replace` may suspend. It asks `isCurrent` before it changes the pane.
  @discardableResult
  public func start(
    _ file: URL,
    then replace:
      @escaping @MainActor (URL, String, _ isCurrent: @MainActor () -> Bool) async -> Void
  ) -> Task<Void, Never> {
    pending?.cancel()
    generation += 1

    let current = generation
    let resolve = startDirectory

    let task = Task { @MainActor [weak self] in
      let directory = await resolve(file)

      guard let self, current == self.generation else { return }

      await replace(file, directory) { [weak self] in self?.generation == current }

      if self.generation == current { self.pending = nil }
    }

    pending = task

    return task
  }

  /// Drops any swap still waiting.
  public func cancel() {
    pending?.cancel()
    generation += 1
    pending = nil
  }
}

extension SourceStartDirectory {
  /// `of(_:)`, off the main thread.
  @concurrent
  public static func resolving(_ url: URL) async -> String {
    of(url)
  }
}
