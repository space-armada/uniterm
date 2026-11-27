import AppletKit
import Foundation
import StatusKit

/// Stands in for the pane's host in applet tests. It collects what an applet tells its pane, and it
/// numbers each history record it admits.
@MainActor
public final class RecordingHost: AppletHost {
  /// One delivery, in the order the applet sent it.
  public struct Sent: Equatable {
    public var delivery: StatusDelivery
    public var level: StatusLevel
    public var text: String
  }

  public private(set) var sent: [Sent] = []

  public var changes = 0
  public var tabChanges = 0
  public var exited = false

  /// The answer to a question, unless `holdsQuestions` is set.
  public var answer = false
  public var confirmations: [AppletConfirmation] = []

  /// When set, a question waits here until a test answers it.
  public var holdsQuestions = false
  public var pendingAnswer: CheckedContinuation<Bool, Never>?

  /// Signals each question as it is asked, so a test awaits it and never polls.
  public let questions = AsyncStream.makeStream(of: Void.self)

  public var lastStamp: UInt64 = 0

  /// The files the applet asked the pane to open, in order.
  public private(set) var openedFiles: [URL] = []

  private var lastRecord: StatusRecordID = 0

  public init() {}

  /// Forgets what the applet sent so far, so a test reads only what comes after.
  public func forgetSent() {
    sent = []
  }

  /// What the applet delivered with a turn on the bar.
  public var posts: [(level: StatusLevel, text: String)] { texts(of: .message) }

  /// What the applet recorded in the history without a turn on the bar.
  public var records: [(level: StatusLevel, text: String)] { texts(of: .historyOnly) }

  /// What the applet delivered with the unseen signal and no turn on the bar.
  public var attentions: [(level: StatusLevel, text: String)] { texts(of: .attention) }

  private func texts(of delivery: StatusDelivery) -> [(level: StatusLevel, text: String)] {
    sent.filter { $0.delivery == delivery }.map { ($0.level, $0.text) }
  }

  public func applet(
    _ applet: any Applet, send delivery: StatusDelivery, level: StatusLevel, text: String
  ) -> StatusRecordID? {
    sent.append(Sent(delivery: delivery, level: level, text: text))

    lastRecord += 1
    return lastRecord
  }

  public func appletDidExit(_ applet: any Applet) { exited = true }

  public func appletDidChange(_ applet: any Applet) { changes += 1 }

  public func appletTabsDidChange(_ applet: any Applet) { tabChanges += 1 }

  /// The permissions asked for, and the answer each gets.
  public var permissions: [AppletPermissionRequest] = []
  public var permissionAnswer = AppletPermissionAnswer.deny

  public func applet(_ applet: any Applet, askPermission request: AppletPermissionRequest) async
    -> AppletPermissionAnswer
  {
    permissions.append(request)

    return permissionAnswer
  }

  public func applet(_ applet: any Applet, confirm request: AppletConfirmation) async -> Bool {
    confirmations.append(request)
    questions.continuation.yield()

    if holdsQuestions {
      return await withCheckedContinuation { pendingAnswer = $0 }
    }

    return answer
  }

  public func applet(_ applet: any Applet, open file: URL) {
    openedFiles.append(file)
  }

  public func issueCloseStamp() -> UInt64 {
    lastStamp += 1
    return lastStamp
  }

  /// A terminal session an applet reported, by its spawned process.
  public struct Session: Equatable {
    public let tab: AppletTabID
    public let pid: pid_t
    public let started: Int
  }

  /// The sessions applets reported starting, and those they reported ending, oldest first.
  public private(set) var startedSessions: [Session] = []
  public private(set) var endedSessions: [Session] = []

  public func applet(
    _ applet: any Applet, sessionStarted tab: AppletTabID, pid: pid_t, started: Int,
    generation: UInt64
  ) {
    startedSessions.append(Session(tab: tab, pid: pid, started: started))
  }

  public func applet(_ applet: any Applet, sessionEnded tab: AppletTabID, pid: pid_t, started: Int)
  {
    endedSessions.append(Session(tab: tab, pid: pid, started: started))
  }
}
