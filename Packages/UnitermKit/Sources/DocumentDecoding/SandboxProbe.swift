#if DEBUG
  import Darwin
  import Foundation

  /// Reports whether this process can open a file by path and reach the network, as lines on
  /// standard output. It exists so the build's real signed helper can prove its sandbox: the
  /// shipped profile grants neither, so both lines must say denied. Release builds leave it out.
  ///
  /// Usage: `--probe-sandbox <path>`. The exit status is 0 when both are denied.
  enum SandboxProbe {
    static func run(arguments: [String]) -> Int32 {
      var allDenied = true

      let path = arguments.first ?? "/etc/hosts"
      let file = open(path, O_RDONLY)

      if file >= 0 {
        close(file)
        print("file: opened")
        allDenied = false
      } else {
        print("file: denied")
      }

      let sock = socket(AF_INET, SOCK_STREAM, 0)

      if sock < 0 {
        print("network: denied")
      } else {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(9).bigEndian
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian

        let result = withUnsafePointer(to: &address) {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
          }
        }

        let code = errno
        close(sock)

        if result != 0, code == EPERM || code == EACCES {
          print("network: denied")
        } else {
          print("network: allowed (errno \(code))")
          allDenied = false
        }
      }

      fflush(stdout)

      return allDenied ? 0 : 1
    }
  }
#endif
