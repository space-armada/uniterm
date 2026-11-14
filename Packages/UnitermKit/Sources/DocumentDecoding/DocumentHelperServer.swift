import Darwin
import Dispatch
import DocumentWire
import Foundation

/// Serves the decode-only protocol on a socket until the app closes it.
///
/// The thread that calls `run` reads messages and answers pings at once. Decodes go to one serial
/// queue, so a decode that spins never stops the pong the app uses to tell a slow decode from a
/// stopped helper.
public final class DocumentHelperServer: @unchecked Sendable {
  private let socket: FramedSocket
  private let queue = DispatchQueue(label: "uniterm.document-decoder.work")

  public init(socket: FramedSocket) {
    self.socket = socket
  }

  /// Reads until the socket closes. Returns the process exit status.
  public func run() -> Int32 {
    guard
      (try? socket.send(DocumentHelperMessage.hello(version: DocumentProtocol.version).frame()))
        != nil
    else { return 1 }

    while true {
      let frame: (type: UInt8, body: Data)

      do {
        frame = try socket.readFrame { _ in DocumentProtocol.maxControlBody }
      } catch WireError.closed {
        return 0
      } catch {
        return 2
      }

      guard let message = try? DocumentAppMessage.decode(type: frame.type, body: frame.body) else {
        return 3
      }

      switch message {
      case .hello(let version):
        guard version == DocumentProtocol.version else { return 4 }

      case .ping(let nonce):
        _ = try? socket.send(DocumentHelperMessage.pong(nonce: nonce).frame())

      case .decode(let request, let kind):
        let descriptor = socket.takeDescriptor()

        queue.async { [self] in decode(request: request, kind: kind, descriptor: descriptor) }
      }
    }
  }

  private func decode(request: UInt32, kind: DocumentKind, descriptor: Int32?) {
    guard let descriptor else {
      reply(.failure(request: request, kind: .noSource, text: "No file came with the request."))
      return
    }

    do {
      let file = try MappedDocument(descriptor: descriptor)

      #if DEBUG
        if let fault = FaultInjection.fault(in: file.data) {
          FaultInjection.perform(fault)
        }
      #endif

      let result = try DocumentReader.read(file, kind: kind)

      send(
        .archive(request: request, imageCount: UInt16(result.images.count), bytes: result.archive))

      for (index, image) in result.images.enumerated() {
        send(
          .image(
            request: request, index: UInt16(index), width: UInt32(image.width),
            height: UInt32(image.height), pixels: image.pixels))
      }

      reply(.done(request: request))
    } catch let error as DocumentFailure {
      reply(.failure(request: request, kind: error.kind, text: error.text))
    } catch {
      reply(.failure(request: request, kind: .unreadable, text: "The document could not be read."))
    }
  }

  private func send(_ message: DocumentHelperMessage) {
    if let parts = message.parts() {
      _ = try? socket.send(prefix: parts.prefix, trailer: parts.trailer)
    } else {
      reply(message)
    }
  }

  private func reply(_ message: DocumentHelperMessage) {
    _ = try? socket.send(message.frame())
  }
}
