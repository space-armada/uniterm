import AppletKit
import Foundation
import TextViewerModel

/// Runs `action` after `seconds` and returns a closure that cancels it. A test hands the pane a
/// scheduler it fires by hand, so no test sleeps for a timeout.
public typealias WaitScheduler =
  @MainActor (
    _ seconds: Double, _ action: @escaping @MainActor () -> Void
  ) -> @MainActor () -> Void

/// The pane's remote results and the waits on them.
///
/// A command with an effect answers at once with a handle, and its result is kept under that
/// handle. The `wait` command has no effect, so it holds a pending reply until the handle ends or
/// the wait times out. Closing the pane fails every wait and frees every handle.
@MainActor
final class TextViewerRemote {
  /// The longest a wait may hold, however long the caller asks.
  nonisolated static let maxWait = 30_000

  /// How long a wait holds when the caller names no time.
  nonisolated static let defaultWait = 10_000

  static let realScheduler: WaitScheduler = { seconds, action in
    let task = Task { @MainActor in
      try? await Task.sleep(for: .seconds(seconds))

      guard !Task.isCancelled else { return }

      action()
    }

    return { task.cancel() }
  }

  private struct Waiter {
    let serial: Int
    let reply: PendingReply
    let cancelTimer: @MainActor () -> Void

    /// Asked when the reply is built. False hides what came from the pane's file. It holds the
    /// access the caller had when it began to wait, and asks the pane for its source again. A
    /// run's power can grow while it waits and can never shrink short of ending the run, which
    /// fails the wait, so the held access is never wider than the caller's own.
    let mayShow: @MainActor () -> Bool
  }

  private(set) var table = RemoteHandleTable()
  var scheduler: WaitScheduler = TextViewerRemote.realScheduler

  private var waiters: [Int: [Waiter]] = [:]
  private var nextSerial = 0

  var hasRoom: Bool { table.hasRoom }

  var waitCount: Int { waiters.values.reduce(0) { $0 + $1.count } }

  /// The handle of the load a command started, while that load runs.
  var activeLoad: Int? { table.activeLoad }

  /// Makes a handle. The caller checked `hasRoom` before it changed anything.
  func begin(_ kind: RemoteHandleTable.Kind) -> Int? {
    table.open(kind)
  }

  /// Ends a handle and answers every wait on it.
  func settle(_ id: Int, _ outcome: RemoteOutcome) {
    guard table.settle(id, outcome), let entry = table.entry(id) else { return }

    for waiter in waiters.removeValue(forKey: id) ?? [] {
      waiter.cancelTimer()
      waiter.reply.complete(RemoteHandleTable.reply(for: entry, redacted: !waiter.mayShow()))
    }
  }

  /// Ends the load a command started, if one is running. A load nobody asked for by command has no
  /// handle.
  func settleLoad(_ outcome: RemoteOutcome) {
    guard let id = table.activeLoad else { return }

    settle(id, outcome)
  }

  func supersedeLoad() {
    settleLoad(.superseded)
  }

  /// Answers a wait. The reply is ready now when the handle ended, and pends when it did not.
  ///
  /// `mayShow` says whether the waiting caller may see what came from the pane's file. It is asked
  /// when the reply is built, so a pane whose source changed while the caller waited is judged by
  /// the source it shows then.
  func wait(
    for id: Int, milliseconds: Int, mayShow: @escaping @MainActor () -> Bool
  ) throws(AppletCommandError) -> AppletCommandReply {
    guard let entry = table.entry(id) else {
      throw AppletCommandError(.notFound, "there is no result under that handle")
    }

    guard !entry.isSettled else {
      return .immediate(RemoteHandleTable.reply(for: entry, redacted: !mayShow()))
    }

    guard milliseconds > 0 else { return .immediate(RemoteHandleTable.pendingReply) }

    let reply = PendingReply()

    nextSerial += 1

    let serial = nextSerial

    let cancelTimer = scheduler(Double(milliseconds) / 1000) { [weak self, weak reply] in
      guard let self, let reply else { return }

      waiters[id]?.removeAll { $0.serial == serial }

      reply.complete(RemoteHandleTable.pendingReply)
    }

    waiters[id, default: []].append(
      Waiter(serial: serial, reply: reply, cancelTimer: cancelTimer, mayShow: mayShow))

    reply.onCancel = { [weak self] in
      guard let self else { return }

      let mine = waiters[id]?.first { $0.serial == serial }

      mine?.cancelTimer()
      waiters[id]?.removeAll { $0.serial == serial }
    }

    return .pending(reply)
  }

  /// The pane closed. Waits fail, since nothing ran for them, and the handles go.
  func close() {
    let all = waiters.values.flatMap { $0 }

    waiters = [:]
    table = RemoteHandleTable()

    for waiter in all {
      waiter.cancelTimer()
      waiter.reply.fail(AppletCommandError(.notFound, "the pane closed"))
    }
  }
}

extension TextViewerApplet {
  /// The text viewer's remote commands, at schema 1.0.
  ///
  /// Show, reload, scroll, and find change the pane, so each answers at once with a handle. A
  /// separate wait command holds a pending reply until a handle ends. No command opens a file by
  /// path. Nothing here answers with document text, heading text, the query, or a path.
  public nonisolated static let remoteSchema = AppletCommandSchema(
    appletType: TextViewerDescription.typeID, version: AppletSchemaVersion(0, 0),
    commands: [
      AppletMessageSchema(
        name: "show-markdown",
        summary:
          "Shows Markdown text in place of what the pane shows. Answers with a handle for the load.",
        arguments: AppletObjectSchema([
          "text": .init(.string(maxBytes: TextViewerLimits.maxInlineMarkdownBytes))
        ]),
        example: .object(["text": .string("# Notes\n\nMention the deadline.")])),
      AppletMessageSchema(
        name: "reload",
        summary:
          "Reads the pane's file again. Answers with a handle for the load, and is refused when the pane has no file.",
        example: .object([:])),
      AppletMessageSchema(
        name: "scroll",
        summary:
          "Scrolls to a PDF page, a contents entry, a Markdown source line, or an RTF or Word character. Answers with a handle, and is refused while a load runs.",
        arguments: AppletObjectSchema(["anchor": .init(RemoteAnchor.schema)]),
        example: .object([
          "anchor": .object(["kind": .string("line"), "line": .number(40)])
        ])),
      AppletMessageSchema(
        name: "find",
        summary:
          "Searches the document with the pane's own query and shows the first match, or the last when backward. Answers with a handle, and is refused while a load runs.",
        arguments: AppletObjectSchema([
          "query": .init(.string(maxBytes: FindMatching.maxQueryLength * 4)),
          "backward": .init(.boolean, required: false),
        ]),
        example: .object(["query": .string("deadline")])),
      AppletMessageSchema(
        name: "wait",
        summary:
          "Replies once a handle ends, or after timeout-ms. The state is loaded, done, failed, superseded, or pending. It changes nothing, so it may wait.",
        arguments: AppletObjectSchema([
          "handle": .init(.integer(minimum: 1, maximum: Int(Int32.max))),
          "timeout-ms": .init(
            .integer(minimum: 0, maximum: TextViewerRemote.maxWait), required: false),
        ]),
        example: .object(["handle": .number(1), "timeout-ms": .number(5000)]), mayWait: true),
    ],
    events: [])
}
