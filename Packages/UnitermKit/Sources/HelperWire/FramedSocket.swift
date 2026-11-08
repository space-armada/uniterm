import Darwin
import Foundation

/// One end of the private socketpair between the app and a helper.
///
/// It sends and reads whole frames, and it carries file descriptors beside a frame with
/// `SCM_RIGHTS`. One thread reads. Any thread may send, and sends take a lock so frames never
/// interleave. The socket closes with the object.
public final class FramedSocket: @unchecked Sendable {
  private let descriptor: Int32
  private let writeLock = NSLock()
  private var received: [Int32] = []
  private var closed = false
  private let closeLock = NSLock()

  /// The most descriptors that may wait unclaimed before the extras are closed.
  private static let maxWaiting = 4

  public init(descriptor: Int32) {
    self.descriptor = descriptor

    var on: Int32 = 1
    _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
  }

  /// Closing the descriptor does not shut the connection down. A child process may hold a copy of
  /// this end, and only an explicit `shutdownAndClose` ends the connection for both.
  deinit {
    for fd in received {
      Darwin.close(fd)
    }

    Darwin.close(descriptor)
  }

  /// A connected pair of sockets, both close-on-exec.
  public static func pair() throws -> (FramedSocket, FramedSocket) {
    var fds: [Int32] = [0, 0]

    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw WireError.io(errno) }

    for fd in fds {
      _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    return (FramedSocket(descriptor: fds[0]), FramedSocket(descriptor: fds[1]))
  }

  /// The raw descriptor, for a caller that hands the end to a child process.
  public var rawDescriptor: Int32 { descriptor }

  /// Ends both directions, so a blocked reader wakes with end of file. Safe to call twice. The
  /// descriptor itself closes with the object, so a reader still unwinding never reads a reused
  /// descriptor number.
  public func shutdownAndClose() {
    closeLock.lock()
    defer { closeLock.unlock() }

    guard !closed else { return }

    closed = true
    _ = shutdown(descriptor, SHUT_RDWR)

    for fd in received {
      Darwin.close(fd)
    }

    received = []
  }

  /// Sends `prefix` and `trailer` as one frame, without joining them in memory. The helper uses it
  /// for an image or a bitmap, so the pixels are written from the buffer they were drawn into.
  public func send(prefix: Data, trailer: Data) throws {
    writeLock.lock()
    defer { writeLock.unlock() }

    try sendLocked(prefix, descriptor: nil)
    try sendLocked(trailer, descriptor: nil)
  }

  /// Sends `frame` whole, with `descriptor` beside it when given.
  public func send(_ frame: Data, descriptor attached: Int32? = nil) throws {
    writeLock.lock()
    defer { writeLock.unlock() }

    try sendLocked(frame, descriptor: attached)
  }

  private func sendLocked(_ frame: Data, descriptor attached: Int32?) throws {
    var offset = 0
    var pendingDescriptor = attached

    while offset < frame.count {
      let sent = try frame.withUnsafeBytes { raw -> Int in
        var iov = iovec(
          iov_base: UnsafeMutableRawPointer(mutating: raw.baseAddress! + offset),
          iov_len: frame.count - offset)

        return try withUnsafeMutablePointer(to: &iov) { iovPointer -> Int in
          var message = msghdr()
          message.msg_iov = iovPointer
          message.msg_iovlen = 1

          if let fd = pendingDescriptor {
            let space = Int(controlMessageSpace(MemoryLayout<Int32>.size))
            var control = [UInt8](repeating: 0, count: space)

            return try control.withUnsafeMutableBytes { buffer -> Int in
              message.msg_control = buffer.baseAddress
              message.msg_controllen = socklen_t(space)

              let header = buffer.baseAddress!.assumingMemoryBound(to: cmsghdr.self)
              header.pointee.cmsg_len = socklen_t(controlMessageLength(MemoryLayout<Int32>.size))
              header.pointee.cmsg_level = SOL_SOCKET
              header.pointee.cmsg_type = SCM_RIGHTS

              (buffer.baseAddress! + controlMessageLength(0)).storeBytes(of: fd, as: Int32.self)

              return try Self.sendOnce(descriptor: self.descriptor, message: &message)
            }
          }

          return try Self.sendOnce(descriptor: self.descriptor, message: &message)
        }
      }

      pendingDescriptor = nil
      offset += sent
    }
  }

  private static func sendOnce(descriptor: Int32, message: inout msghdr) throws -> Int {
    while true {
      let count = sendmsg(descriptor, &message, 0)

      if count >= 0 { return count }

      if errno == EINTR { continue }

      throw errno == EPIPE ? WireError.closed : WireError.io(errno)
    }
  }

  /// Reads one frame. `limit` maps a frame type to the most body bytes it may declare, and is
  /// checked before the body is allocated.
  public func readFrame(limit: (UInt8) -> Int) throws -> (type: UInt8, body: Data) {
    let head = try readExactly(FrameHeader.size)
    let (type, length) = try FrameHeader.parse(head)
    let bound = limit(type)

    guard length <= bound else { throw WireError.tooLong(declared: length, limit: bound) }

    return (type, try readExactly(length))
  }

  /// The oldest descriptor that arrived beside a frame, or nil.
  public func takeDescriptor() -> Int32? {
    closeLock.lock()
    defer { closeLock.unlock() }

    return received.isEmpty ? nil : received.removeFirst()
  }

  private func readExactly(_ count: Int) throws -> Data {
    var data = PageBuffer.data(count: count)
    var offset = 0

    while offset < count {
      let got = try data.withUnsafeMutableBytes { raw -> Int in
        try readOnce(into: raw.baseAddress! + offset, count: count - offset)
      }

      if got == 0 { throw WireError.closed }

      offset += got
    }

    return data
  }

  private func readOnce(into pointer: UnsafeMutableRawPointer, count: Int) throws -> Int {
    let space = Int(controlMessageSpace(MemoryLayout<Int32>.size * Self.maxWaiting))
    var control = [UInt8](repeating: 0, count: space)

    while true {
      var iov = iovec(iov_base: pointer, iov_len: count)

      let result: (count: Int, controlLength: Int) = withUnsafeMutablePointer(to: &iov) {
        iovPointer in
        control.withUnsafeMutableBytes { buffer in
          var message = msghdr()
          message.msg_iov = iovPointer
          message.msg_iovlen = 1
          message.msg_control = buffer.baseAddress
          message.msg_controllen = socklen_t(space)

          let got = recvmsg(descriptor, &message, 0)

          return (got, Int(message.msg_controllen))
        }
      }

      if result.count < 0 {
        if errno == EINTR { continue }

        throw errno == ECONNRESET ? WireError.closed : WireError.io(errno)
      }

      collectDescriptors(from: control, length: result.controlLength)

      return result.count
    }
  }

  private func collectDescriptors(from control: [UInt8], length: Int) {
    guard length >= controlMessageLength(0) else { return }

    control.withUnsafeBytes { buffer in
      var offset = 0

      while offset + controlMessageLength(0) <= min(length, buffer.count) {
        let header = (buffer.baseAddress! + offset).loadUnaligned(as: cmsghdr.self)
        let total = Int(header.cmsg_len)

        guard total >= controlMessageLength(0), offset + total <= buffer.count else { return }

        if header.cmsg_level == SOL_SOCKET, header.cmsg_type == SCM_RIGHTS {
          let payload = total - controlMessageLength(0)

          for index in 0..<(payload / MemoryLayout<Int32>.size) {
            let fd =
              (buffer.baseAddress! + offset + controlMessageLength(0)
              + index * MemoryLayout<Int32>.size).loadUnaligned(as: Int32.self)

            closeLock.lock()

            if received.count < Self.maxWaiting && !closed {
              _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
              received.append(fd)
            } else {
              Darwin.close(fd)
            }

            closeLock.unlock()
          }
        }

        offset += (total + 3) & ~3
      }
    }
  }
}

// Darwin aligns control messages to four bytes. The CMSG macros are not imported into Swift.
private func controlMessageLength(_ length: Int) -> Int {
  ((MemoryLayout<cmsghdr>.size + 3) & ~3) + length
}

private func controlMessageSpace(_ length: Int) -> Int {
  ((MemoryLayout<cmsghdr>.size + 3) & ~3) + ((length + 3) & ~3)
}
