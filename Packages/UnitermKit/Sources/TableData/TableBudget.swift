import Dispatch
import Foundation
import os

/// One memory budget for every row the data viewer panes hold, together.
///
/// A pane takes a lease and reserves bytes through it as its pages seal. A lease that is over the
/// budget still gets its floor, so a pane that opens last still loads a minimum of rows. The
/// budget therefore bounds the app at its limit plus one floor for each pane beyond it.
///
/// A memory-pressure warning ends every load running at that moment. A pane opened afterward
/// loads normally, and a pane already open can still sort.
public final class TableBudget: Sendable {
  public enum Reservation: Sendable, Equatable {
    case granted
    case overBudget
    case memoryPressure

    /// The lease was released. A load that was slow to notice its cancellation gets this.
    case released
  }

  private struct State {
    var used = 0
    var epoch = 0
    var nextLease = 0
    var leases: [Int: Int] = [:]
  }

  public let limit: Int
  public let floor: Int
  private let state = OSAllocatedUnfairLock(initialState: State())

  public init(limit: Int, floor: Int) {
    self.limit = limit
    self.floor = floor
  }

  /// The budget the app uses: a quarter of physical memory, at most 1 GiB, with a 32 MiB floor for
  /// each pane. A memory-pressure warning from the system ends the loads running at that moment.
  public static let shared: TableBudget = {
    let physical = Int(clamping: ProcessInfo.processInfo.physicalMemory)
    let budget = TableBudget(limit: min(1 << 30, physical / 4), floor: 32 << 20)
    MemoryPressureWatch.start(budget)
    return budget
  }()

  /// Bytes reserved by every lease together.
  public var used: Int { state.withLock { $0.used } }

  public func makeLease() -> Lease {
    let (id, epoch) = state.withLock { state -> (Int, Int) in
      state.nextLease += 1
      state.leases[state.nextLease] = 0
      return (state.nextLease, state.epoch)
    }

    return Lease(budget: self, id: id, epoch: epoch)
  }

  /// Ends every load running now. The system sends this on a memory-pressure warning.
  public func memoryPressureWarning() {
    state.withLock { $0.epoch += 1 }
  }

  fileprivate func reserve(_ bytes: Int, lease: Int, epoch: Int) -> Reservation {
    state.withLock { state in
      guard state.epoch == epoch else { return .memoryPressure }

      guard let held = state.leases[lease] else { return .released }

      guard state.used + bytes <= limit || held + bytes <= floor else { return .overBudget }

      state.leases[lease] = held + bytes
      state.used += bytes
      return .granted
    }
  }

  fileprivate func reserveForWork(_ bytes: Int, lease: Int) -> Reservation {
    state.withLock { state in
      guard let held = state.leases[lease] else { return .released }

      guard state.used + bytes <= limit || held + bytes <= floor else { return .overBudget }

      state.leases[lease] = held + bytes
      state.used += bytes
      return .granted
    }
  }

  fileprivate func release(lease: Int) {
    state.withLock { state in
      state.used -= state.leases.removeValue(forKey: lease) ?? 0
    }
  }

  fileprivate func giveBack(_ bytes: Int, lease: Int) {
    state.withLock { state in
      guard let held = state.leases[lease] else { return }

      let given = min(bytes, held)
      state.leases[lease] = held - given
      state.used -= given
    }
  }

  /// One pane's claim on the budget. Dropping the lease gives its bytes back.
  public final class Lease: Sendable {
    private let budget: TableBudget
    private let id: Int
    private let epoch: Int

    fileprivate init(budget: TableBudget, id: Int, epoch: Int) {
      self.budget = budget
      self.id = id
      self.epoch = epoch
    }

    deinit {
      budget.release(lease: id)
    }

    public func reserve(_ bytes: Int) -> Reservation {
      budget.reserve(bytes, lease: id, epoch: epoch)
    }

    /// Reserves bytes for work on rows already loaded, such as a sort's keys. A memory-pressure
    /// warning ends loads and nothing else, so this ignores it. The limit and floor still apply, and
    /// a released lease is still refused.
    public func reserveForWork(_ bytes: Int) -> Reservation {
      budget.reserveForWork(bytes, lease: id)
    }

    /// Gives bytes back that were reserved for work that is done, such as a sort's keys.
    public func giveBack(_ bytes: Int) {
      budget.giveBack(bytes, lease: id)
    }

    /// Gives every reserved byte back at once and ends the lease. A later `reserve` is refused, so a
    /// loader that has not yet noticed its cancellation cannot take bytes back.
    public func release() {
      budget.release(lease: id)
    }
  }
}

private enum MemoryPressureWatch {
  /// The source lives as long as the process. The shared budget is never torn down.
  nonisolated(unsafe) private static var source: (any DispatchSourceMemoryPressure)?

  static func start(_ budget: TableBudget) {
    let source = DispatchSource.makeMemoryPressureSource(
      eventMask: [.warning, .critical], queue: .global(qos: .utility))
    source.setEventHandler { budget.memoryPressureWarning() }
    source.resume()

    Self.source = source
  }
}
