import Darwin
import DocumentWire
import Foundation
import HelperHost
import SourceAccess
import TextViewerModel

/// A regular file opened read-only for the helper. It owns the descriptor, which the helper
/// receives.
final class OpenedDocumentFile: @unchecked Sendable {
  let descriptor: Int32
  let path: String
  let size: Int

  private init(descriptor: Int32, path: String, size: Int) {
    self.descriptor = descriptor
    self.path = path
    self.size = size
  }

  deinit {
    Darwin.close(descriptor)
  }

  /// Opens `path`, accepting only a regular file after symlinks are followed. The app never reads
  /// the bytes. The helper does, from this descriptor.
  static func open(path: String) -> Result<OpenedDocumentFile, SourceAccessError> {
    RegularFile.open(path: path).map {
      OpenedDocumentFile(descriptor: $0.descriptor, path: path, size: $0.info.size)
    }
  }
}

extension HelperLocation {
  /// The document decoder in the app bundle. A debug build honors `UNITERM_DOCUMENT_HELPER`.
  static var bundledDocumentDecoder: HelperLocation {
    bundled(named: "DocumentDecoder", debugOverride: "UNITERM_DOCUMENT_HELPER")
  }
}

/// Tuning for one decode. Tests shorten the times and the cap to reach each limit.
struct DocumentHelperSettings: Sendable {
  var location: HelperLocation
  var limits = TextViewerLimits.standard
  var probeInterval: Duration = .milliseconds(250)
  var pongGrace: Duration = .seconds(3)

  static var bundled: DocumentHelperSettings {
    DocumentHelperSettings(location: .bundledDocumentDecoder)
  }
}

/// How one decode ended, short of a reply.
enum DocumentDecodeEnd: Error, Equatable, Sendable {
  /// The helper declined and kept running. The text is the helper's.
  case declined(DocumentFailureKind, String)

  /// The helper stopped, was stopped, or sent bytes the app refused.
  case helper(HelperEnd)

  /// The decode was cancelled by a newer open, a reload, or a close.
  case cancelled
}

/// One decode in one helper process.
///
/// The helper starts when `run` is called and is gone when it returns. Nothing keeps a helper
/// between documents, so none outlives its pane, and a reopened pane starts a fresh one. Cancelling
/// kills the process. The app ends the helper when its footprint passes the cap or the decode runs
/// past the time bound.
@MainActor
final class DocumentHelperJob {
  private let settings: DocumentHelperSettings
  private var process: HelperProcess?
  private var cancelled = false
  private var ended: HelperEnd?
  private var liveness: HelperLiveness
  private var watchdog: Task<Void, Never>?

  /// The footprint last read, which tests report.
  private(set) var lastFootprint: Int?

  init(settings: DocumentHelperSettings) {
    self.settings = settings
    liveness = HelperLiveness(
      timeBound: settings.limits.decodeTimeBound, pongGrace: settings.pongGrace,
      footprintCap: settings.limits.footprintCap)
  }

  var processID: pid_t? { process?.pid }

  /// Ends the helper at once. A `run` in progress returns `cancelled`.
  func cancel() {
    cancelled = true
    watchdog?.cancel()
    process?.kill()
  }

  func run(kind: DocumentKind, file: OpenedDocumentFile) async -> Result<
    DocumentReply, DocumentDecodeEnd
  > {
    guard !cancelled else { return .failure(.cancelled) }

    guard let url = settings.location.url else {
      return .failure(
        .helper(.unavailable("The document reader is missing from this copy of uniterm.")))
    }

    let spawned: HelperProcess

    do {
      spawned = try HelperProcess.spawn(executable: url)
    } catch {
      return .failure(.helper(.unavailable("The document reader could not start (\(error)).")))
    }

    process = spawned
    defer { finish() }

    let stream = AsyncStream<HelperRead<DocumentHelperMessage>>.makeStream()

    spawned.startReading(
      threadName: "uniterm.document-helper.reader",
      bodyLimit: { DocumentHelperMessage.bodyLimit(type: $0) },
      decode: DocumentHelperMessage.decode(type:body:),
      deliver: { event in
        stream.continuation.yield(event)

        if case .exited = event { stream.continuation.finish() }
      })

    let request: UInt32 = 1
    var assembler = DocumentReplyAssembler(request: request, limits: settings.limits.replyLimits)
    var sawHello = false

    do {
      try spawned.socket.send(DocumentAppMessage.hello(version: DocumentProtocol.version).frame())
      try spawned.socket.send(
        DocumentAppMessage.decode(request: request, kind: kind).frame(),
        descriptor: file.descriptor)
    } catch {
      return .failure(.helper(.crashed("The document reader stopped answering.")))
    }

    liveness.markBusy()
    startWatchdog()

    for await event in stream.stream {
      if cancelled { return .failure(.cancelled) }

      if let ended { return .failure(.helper(ended)) }

      switch event {
      case .violation(let text):
        return .failure(.helper(.misbehaved(text)))

      case .exited(let status):
        let text = "The document reader \(HelperProcess.describe(status: status))."

        return .failure(.helper(.crashed(text)))

      case .message(let message):
        if !sawHello {
          do {
            try DocumentHelperMessage.validateHello(message)
          } catch {
            return .failure(.helper(.versionMismatch))
          }

          sawHello = true
          continue
        }

        if case .pong(let value) = message {
          liveness.pong(value)
          continue
        }

        do {
          switch try assembler.accept(message) {
          case .pending: continue
          case .complete(let reply): return .success(reply)
          case .failed(let kind, let text): return .failure(.declined(kind, text))
          }
        } catch {
          return .failure(.helper(.misbehaved("\(error)")))
        }
      }
    }

    if cancelled { return .failure(.cancelled) }

    return .failure(.helper(ended ?? .crashed("The document reader stopped.")))
  }

  private func startWatchdog() {
    let interval = settings.probeInterval

    watchdog = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: interval)

        guard let self, !Task.isCancelled else { return }

        self.probe()
      }
    }
  }

  private func probe() {
    guard let process, liveness.isBusy else { return }

    let footprint = process.footprint()

    if let footprint { lastFootprint = footprint }

    switch liveness.probe(footprint: footprint) {
    case .healthy:
      break

    case .end(let reason):
      ended = reason
      process.kill()

    case .sendPing(let value):
      try? process.socket.send(DocumentAppMessage.ping(nonce: value).frame())
    }
  }

  private func finish() {
    watchdog?.cancel()
    watchdog = nil
    liveness.markIdle()
    process?.kill()
    process = nil
  }
}
