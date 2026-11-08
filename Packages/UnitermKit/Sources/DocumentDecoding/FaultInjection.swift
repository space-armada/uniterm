#if DEBUG
  import Darwin
  import Foundation

  /// Test-only faults, compiled into debug builds only. A file that starts with the marker asks the
  /// helper to misbehave on its next decode, so the supervisor's tests can crash, stop, spin, or
  /// bloat a real helper process on demand. A release build has none of this.
  enum FaultInjection {
    static let marker = Array("UNITERM-FAULT ".utf8)

    static func fault(in data: Data) -> String? {
      guard data.count > marker.count, Array(data.prefix(marker.count)) == marker else {
        return nil
      }

      let line = data.dropFirst(marker.count).prefix { $0 != 10 }

      return String(decoding: line, as: UTF8.self)
    }

    static func perform(_ fault: String) {
      let parts = fault.split(separator: ":")

      switch parts.first.map(String.init) {
      case "crash":
        abort()

      case "stop":
        raise(SIGSTOP)

      case "spin":
        while true { usleep(1000) }

      case "slow":
        let milliseconds = parts.dropFirst().first.flatMap { Int($0) } ?? 1000

        usleep(UInt32(milliseconds) * 1000)

      case "balloon":
        let megabytes = parts.dropFirst().first.flatMap { Int($0) } ?? 256
        let size = megabytes << 20

        if let memory = malloc(size) {
          memset(memory, 1, size)
        }

        while true { usleep(1000) }

      default:
        break
      }
    }
  }
#endif
