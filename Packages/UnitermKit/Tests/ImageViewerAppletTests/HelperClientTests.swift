import Darwin
import HelperHost
import ImageTestSupport
import ImageViewerModel
import ImageWire
import XCTest

@testable import ImageViewerApplet

/// Drives the supervisor against real helper processes. Each test proves one way a helper ends or
/// misbehaves, and that only the pane that owns the helper feels it.
@MainActor
final class HelperClientTests: XCTestCase {
  private var folder: URL!
  private var clients: [ImageHelperClient] = []

  override func setUp() async throws {
    folder = try ImageFixtures.makeFolder()
  }

  override func tearDown() async throws {
    for client in clients { client.shutdown() }

    try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
  }

  private func makeClient(
    _ settings: HelperSettings? = nil,
    budget: ImageHelperBudget = ImageHelperBudget(limit: 8 << 30, floor: 1 << 30)
  ) -> (ImageHelperClient, EventLog) {
    let client = ImageHelperClient(settings: settings ?? Harness.settings(), budget: budget)
    clients.append(client)

    return (client, EventLog(client))
  }

  /// Catches a helper that does not hand back the image the app asked for. A PNG goes in by
  /// descriptor, the helper says which types it reads, and the pixels come back at the size asked.
  func testAClientOpensAndDecodesThroughARealHelper() async throws {
    let (client, log) = makeClient()
    client.open(try openedFile(ImageFixtures.png(width: 200, height: 100), in: folder))

    await expectEventually { log.opened != nil }
    XCTAssertTrue(client.types?.contains("public.png") ?? false)

    client.decode(maxPixel: 50, frame: 0, kind: .still)

    await expectEventually { !log.images.isEmpty }
    XCTAssertEqual(log.images.first.map { [$0.width, $0.height] }, [50, 25])
  }

  /// Catches a client that forgets which sources the helper still keeps. The helper drops the one
  /// decoded or opened longest ago, so selecting a source on the client side must not make it look
  /// newer. After four sources are open and the first is selected, a fifth drops the first on both
  /// sides.
  func testSelectingASourceDoesNotKeepItAliveOnlyOnTheClientSide() async throws {
    let (client, log) = makeClient()
    var ids: [UInt32] = []

    for index in 1...ImageProtocol.retainedSources {
      let file = try openedFile(ImageFixtures.png(), named: "f\(index).png", in: folder)

      ids.append(try XCTUnwrap(client.open(file, role: .prefetch)))
    }

    await expectEventually {
      log.events.filter { if case .prefetchOpened = $0 { return true } else { return false } }.count
        == ImageProtocol.retainedSources
    }

    XCTAssertTrue(client.select(source: ids[0]))

    let fifth = try openedFile(ImageFixtures.png(), named: "f5.png", in: folder)
    client.open(fifth, role: .prefetch)

    await expectEventually {
      log.events.filter { if case .prefetchOpened = $0 { return true } else { return false } }.count
        == ImageProtocol.retainedSources + 1
    }

    XCTAssertFalse(client.select(source: ids[0]), "the helper dropped it, so the client must too")
    XCTAssertTrue(client.select(source: ids[1]))
  }

  /// Catches a refused request moving a source up the client's recency list. The helper never hears
  /// of it, so the client would later forget a different source than the helper does. With four
  /// sources kept, a refused decode of the oldest must leave it the first one dropped by a fifth.
  func testARefusedRequestDoesNotKeepASourceAlive() async throws {
    let (client, log) = makeClient(Harness.settings(maxImageBytes: 8 << 20))
    let big = ImageFixtures.encode(
      ImageFixtures.solidQuadrants(width: 3000, height: 2000), as: .png)
    var ids: [UInt32] = []

    ids.append(
      try XCTUnwrap(client.open(try openedFile(big, named: "f1.png", in: folder), role: .prefetch)))

    for index in 2...ImageProtocol.retainedSources {
      let file = try openedFile(ImageFixtures.png(), named: "f\(index).png", in: folder)

      ids.append(try XCTUnwrap(client.open(file, role: .prefetch)))
    }

    func opened() -> Int {
      log.events.filter { if case .prefetchOpened = $0 { return true } else { return false } }.count
    }

    await expectEventually { opened() == ImageProtocol.retainedSources }

    XCTAssertTrue(client.select(source: ids[0]))

    let request = try XCTUnwrap(client.decode(maxPixel: 0, frame: 0, kind: .still))

    XCTAssertTrue(
      log.events.contains {
        if case .refused(let refused, _) = $0 {
          return refused.id == request.id
        } else {
          return false
        }
      },
      "the decode is past the size cap")

    client.open(try openedFile(ImageFixtures.png(), named: "f5.png", in: folder), role: .prefetch)
    await expectEventually { opened() == ImageProtocol.retainedSources + 1 }

    XCTAssertFalse(client.select(source: ids[0]), "the refusal did not touch it, so it went first")
    XCTAssertTrue(client.select(source: ids[1]))
  }

  /// Catches a zoom estimate that sizes an HDR level as eight-bit pixels. The helper keeps the
  /// level in sixteen-bit floats for an extended-linear source, which is twice the bytes. A zoom
  /// that fits the cap only as eight-bit pixels must be refused, and an unknown space counts as the
  /// larger size.
  func testAnHdrLevelIsSizedAsFloatsAndRefusedPastTheCap() async throws {
    let native = PixelSize(width: 6000, height: 4000)
    let pixels = 6000 * 4000
    let cap = 150 << 20

    XCTAssertEqual(
      ImageHelperClient.levelBytes(
        longerSide: 6000, native: native, space: .extendedLinearDisplayP3),
      pixels * 8)
    XCTAssertEqual(
      ImageHelperClient.levelBytes(longerSide: 6000, native: native, space: .sRGB), pixels * 4)
    XCTAssertEqual(
      ImageHelperClient.levelBytes(longerSide: 6000, native: native, space: nil), pixels * 8)
    XCTAssertLessThanOrEqual(pixels * 4, cap, "the eight-bit estimate would pass")
    XCTAssertGreaterThan(pixels * 8, cap)

    let (client, log) = makeClient(Harness.settings(maxImageBytes: cap))
    let big = ImageFixtures.encode(
      ImageFixtures.solidQuadrants(width: 6000, height: 4000), as: .png)

    client.open(try openedFile(big, in: folder))
    await expectEventually { log.opened != nil }

    let source = try XCTUnwrap(client.source?.source)

    client.decode(maxPixel: 64, frame: 0, kind: .still)
    await expectEventually { !log.images.isEmpty }
    XCTAssertEqual(client.outputSpaces[source], .sRGB, "the fit decode tells the client the space")

    client.outputSpaces[source] = .extendedLinearDisplayP3

    let region = TileRegion(level: 6000, x: 0, y: 0, width: 256, height: 256)
    let request = try XCTUnwrap(client.decodeRegion(region))

    XCTAssertTrue(
      log.events.contains {
        if case .refused(let refused, _) = $0 {
          return refused.id == request.id
        } else {
          return false
        }
      },
      "an HDR level of this size is past the cap")
  }

  /// Catches a prefetch the scheduler replaced going unreported. A frame request that replaces a
  /// waiting prefetch tells the pane, which would otherwise wait for a decode that never comes.
  func testAReplacedPrefetchIsReported() async throws {
    let (client, log) = makeClient()

    client.open(try openedFile(ImageFixtures.png(), named: "a.png", in: folder))
    await expectEventually { log.opened != nil }

    let spare = try XCTUnwrap(
      client.open(try openedFile(ImageFixtures.png(), named: "b.png", in: folder), role: .prefetch))
    await expectEventually {
      log.events.contains { if case .prefetchOpened = $0 { return true } else { return false } }
    }

    let held = try XCTUnwrap(
      log.events.compactMap { event -> SourceInfo? in
        if case .prefetchOpened(let info) = event { return info } else { return nil }
      }.first)
    XCTAssertEqual(held.source, spare)

    client.decode(maxPixel: 16, frame: 0, kind: .still)
    let waiting = try XCTUnwrap(client.prefetch(held, maxPixel: 16))

    client.decode(maxPixel: 16, frame: 0, kind: .frame)

    XCTAssertTrue(log.events.contains(.prefetchDropped(waiting)))
  }

  /// Catches a crashing file taking more than its own pane down. One helper aborts on a crafted
  /// file, the pane's client reports a crash that offers a retry, and a second client keeps
  /// decoding. The first client then starts a fresh helper.
  func testACrashEndsOnlyThatClientsHelperAndARetryStartsAFreshOne() async throws {
    let (bad, badLog) = makeClient()
    let (good, goodLog) = makeClient()

    good.open(try openedFile(ImageFixtures.png(), named: "good.png", in: folder))
    await expectEventually { goodLog.opened != nil }

    bad.open(try openedFile(ImageFixtures.fault("crash"), named: "crash.png", in: folder))
    await expectEventually { badLog.opened != nil }

    let crashedPID = bad.processID
    bad.decode(maxPixel: 0, frame: 0, kind: .still)

    await expectEventually { badLog.ended != nil }

    guard case .crashed(let text) = badLog.ended else {
      return XCTFail("\(String(describing: badLog.ended))")
    }

    XCTAssertTrue(text.contains("signal"), text)
    XCTAssertTrue(badLog.ended?.offersRetry ?? false)
    XCTAssertFalse(bad.isRunning)

    good.decode(maxPixel: 0, frame: 0, kind: .still)
    await expectEventually { !goodLog.images.isEmpty }
    XCTAssertNil(goodLog.ended)

    bad.open(try openedFile(ImageFixtures.png(), named: "ok.png", in: folder))
    await expectEventually { badLog.opened != nil && bad.isRunning }
    XCTAssertNotEqual(bad.processID, crashedPID)
  }

  /// Catches a task and its event stream outliving the helper. Each helper has one task that reads
  /// its events, and it must end when the helper does, after a crash and after a close, or every
  /// spawn would leak one.
  func testTheEventTaskEndsWithItsHelper() async throws {
    let (client, log) = makeClient()
    client.open(try openedFile(ImageFixtures.fault("crash"), named: "crash.png", in: folder))
    await expectEventually { log.opened != nil }

    client.decode(maxPixel: 0, frame: 0, kind: .still)
    await expectEventually { log.ended != nil }
    await expectEventually("the event task outlived a crashed helper") { client.activePumps == 0 }

    client.open(try openedFile(ImageFixtures.png(), named: "ok.png", in: folder))
    await expectEventually { log.opened != nil && client.isRunning }
    XCTAssertEqual(client.activePumps, 1)

    client.shutdown()
    await expectEventually("the event task outlived a closed pane") { client.activePumps == 0 }
  }

  /// Catches a stopped helper being waited on forever. A helper that stops answering pings is ended
  /// as unresponsive, which offers a retry.
  func testAHelperThatStopsAnsweringIsEndedAsUnresponsive() async throws {
    let (client, log) = makeClient()
    client.open(try openedFile(ImageFixtures.fault("stop"), named: "stop.png", in: folder))
    await expectEventually { log.opened != nil }

    client.decode(maxPixel: 0, frame: 0, kind: .still)

    await expectEventually { log.ended != nil }
    XCTAssertEqual(log.ended, .unresponsive)
    XCTAssertTrue(log.ended?.offersRetry ?? false)
  }

  /// Catches a legitimate slow decode being reported as a hang. The helper keeps answering pings
  /// while it spins, so overrunning the time bound reports a limit, and no retry is offered because
  /// a retry would repeat the overrun.
  func testADecodeThatOverrunsWhileAnsweringReportsALimitNotARetry() async throws {
    let (client, log) = makeClient(Harness.settings(timeBound: .milliseconds(400)))
    client.open(try openedFile(ImageFixtures.fault("spin"), named: "spin.png", in: folder))
    await expectEventually { log.opened != nil }

    client.decode(maxPixel: 0, frame: 0, kind: .still)

    await expectEventually { log.ended != nil }
    XCTAssertEqual(log.ended, .overranTimeBound)
    XCTAssertFalse(log.ended?.offersRetry ?? true)
  }

  /// Catches a memory blowup surviving the per-helper cap. A file makes the helper allocate far
  /// past a small cap, and the next footprint read ends it with a limit.
  func testAFootprintPastTheCapEndsTheHelperWithALimit() async throws {
    let (client, log) = makeClient(Harness.settings(footprintCap: 150 << 20))
    client.open(try openedFile(ImageFixtures.fault("balloon:400"), named: "big.png", in: folder))
    await expectEventually { log.opened != nil }

    client.decode(maxPixel: 0, frame: 0, kind: .still)

    await expectEventually { log.ended != nil }
    XCTAssertEqual(log.ended, .overFootprint)
    XCTAssertFalse(log.ended?.offersRetry ?? true)
  }

  /// Catches a helper that outlives its app. The app closes its end of the socket without reading,
  /// and the helper exits with status zero on its own.
  func testAHelperExitsWhenItsSocketCloses() async throws {
    let process = try HelperProcess.spawn(executable: ImageFixtures.packageHelper())
    defer { process.kill() }

    process.socket.shutdownAndClose()

    var status: Int32 = 0
    var reaped = false

    await expectEventually("the helper never exited") {
      reaped = waitpid(process.pid, &status, WNOHANG) == process.pid
      return reaped
    }

    XCTAssertTrue(reaped)
    XCTAssertEqual(status, 0, "a clean exit, not a signal")
  }

  /// Pins the fix for a signal reaching a reused pid. The reader waits without reaping, marks the
  /// process gone under the lock, and only then reaps, and a kill signals only under that lock. The
  /// race is a few instructions wide and cannot be reproduced on demand, so this test pins the
  /// fix, not the bug: once the exit is reported, a kill signals nothing.
  func testAKillAfterTheExitIsReportedSignalsNothing() async throws {
    let process = try HelperProcess.spawn(executable: ImageFixtures.packageHelper())
    let exited = ExitFlag()

    process.startReading(
      threadName: "test.reader", bodyLimit: { _ in 0 },
      decode: HelperMessage.decode(type:body:),
      deliver: { if case .exited = $0 { exited.set() } })
    process.socket.shutdownAndClose()

    await expectEventually("the helper never exited") { exited.isSet }

    XCTAssertFalse(process.kill())
  }

  final class ExitFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
      lock.lock()
      value = true
      lock.unlock()
    }

    var isSet: Bool {
      lock.lock()
      defer { lock.unlock() }

      return value
    }
  }

  /// Catches an app and a helper of different protocol versions agreeing to talk. A helper that
  /// says version 99 is ended before any image moves, with the reason the pane words as relaunch.
  func testAHelperOfAnotherVersionIsRefused() async throws {
    let location = try Harness.scriptHelper(
      writing: "\\001\\000\\000\\000\\004\\000\\143\\000\\000")
    let (client, log) = makeClient(Harness.settings(location: location))

    client.open(try openedFile(ImageFixtures.png(), in: folder))

    await expectEventually { log.ended != nil }
    XCTAssertEqual(log.ended, .versionMismatch)
    XCTAssertFalse(log.ended?.offersRetry ?? true)
  }

  /// Catches bytes that break the framing being tolerated. A helper that sends a message type the
  /// protocol lacks is ended as misbehaving, and its pane may retry.
  func testBytesThatBreakTheProtocolEndTheHelper() async throws {
    let location = try Harness.scriptHelper(
      writing: "\\001\\000\\000\\000\\004\\000\\002\\000\\000\\011\\000\\000\\000\\000")
    let (client, log) = makeClient(Harness.settings(location: location))

    client.open(try openedFile(ImageFixtures.png(), in: folder))

    await expectEventually { log.ended != nil }

    guard case .misbehaved = log.ended else { return XCTFail("\(String(describing: log.ended))") }
  }

  /// Catches the reader allocating for an image nobody asked for. A helper that declares a 256 MiB
  /// image body with no decode in flight is ended on the header, before any of the body is read.
  func testAnOversizeImageFrameIsRefusedOnItsHeader() async throws {
    let location = try Harness.scriptHelper(
      writing: "\\001\\000\\000\\000\\004\\000\\002\\000\\000\\003\\020\\000\\000\\000")
    let (client, log) = makeClient(Harness.settings(location: location))

    client.open(try openedFile(ImageFixtures.png(), in: folder))
    await expectEventually { log.ended != nil }

    guard case .misbehaved(let text) = log.ended else {
      return XCTFail("\(String(describing: log.ended))")
    }

    XCTAssertTrue(text.contains("tooLong"), text)
  }

  /// Catches a decode in flight raising the read limit past the image it asked for. With a 64 pixel
  /// request, the limit is the bytes of a 64 pixel image, and not the app's whole image cap.
  func testTheReadLimitFollowsTheRequestInFlight() async throws {
    let (client, log) = makeClient()
    client.open(try openedFile(ImageFixtures.png(width: 640, height: 320), in: folder))
    await expectEventually { log.opened != nil }

    XCTAssertEqual(client.imageReadLimit, 0)

    client.decode(maxPixel: 64, frame: 0, kind: .still)
    XCTAssertEqual(client.imageReadLimit, 64 * 32 * 8)

    await expectEventually { !log.images.isEmpty }
    XCTAssertEqual(client.imageReadLimit, 0)
  }

  /// Catches a missing helper executable leaving the pane waiting. The client reports it
  /// unavailable at once.
  func testAMissingHelperIsReportedUnavailable() throws {
    let (client, log) = makeClient(Harness.settings(location: HelperLocation(url: nil)))

    client.open(try openedFile(ImageFixtures.png(), in: folder))

    guard case .unavailable = log.ended else { return XCTFail("\(String(describing: log.ended))") }
  }

  /// Catches a decode that starts although the app-wide helper budget is spent. A budget with no
  /// room and no floor refuses the request, and the helper is not asked.
  func testADecodeIsRefusedWhenTheHelperBudgetIsSpent() async throws {
    let (client, log) = makeClient(budget: ImageHelperBudget(limit: 1, floor: 0))
    client.open(try openedFile(ImageFixtures.png(), in: folder))
    await expectEventually { log.opened != nil }

    client.decode(maxPixel: 0, frame: 0, kind: .still)

    XCTAssertTrue(
      log.events.contains {
        if case .refused = $0 { return true } else { return false }
      })
    XCTAssertTrue(log.images.isEmpty)
    XCTAssertTrue(client.isRunning, "a refusal does not end the helper")
  }

  /// Records the helper's peak footprint for a large native-size decode, and keeps it under four
  /// times the image. The decode itself sets the peak, so this does not pin the framing. The wire
  /// tests pin that. The unsandboxed debug build's number is printed for the notes.
  func testThePeakFootprintOfALargeDecodeStaysNearTheImage() async throws {
    let (client, log) = makeClient()
    let image = ImageFixtures.png(width: 3000, height: 2000)

    client.open(try openedFile(image, named: "large.png", in: folder))
    await expectEventually { log.opened != nil }

    client.decode(maxPixel: 0, frame: 0, kind: .still)
    await expectEventually { !log.images.isEmpty }

    let pixels = 3000 * 2000 * 4
    let peak = client.peakFootprint ?? 0

    print("large decode: image \(pixels >> 20) MiB, helper peak \(peak >> 20) MiB")

    XCTAssertLessThan(peak, pixels * 4)
  }

  /// Records the helper's spawn time and resting footprint for the milestone's notes. The numbers
  /// are for the unsandboxed SwiftPM build in a debug configuration, so they bound the shipped
  /// helper only roughly. The assertions are loose sanity checks.
  func testSpawnTimeAndRestingFootprintAreWithinSaneBounds() async throws {
    let start = ContinuousClock.now
    let (client, log) = makeClient()

    client.open(try openedFile(ImageFixtures.png(), in: folder))
    await expectEventually { log.opened != nil }

    let spawn = ContinuousClock.now - start

    client.decode(maxPixel: 0, frame: 0, kind: .still)
    await expectEventually { !log.images.isEmpty }
    await expectEventually { client.lastFootprint != nil }

    let footprint = client.lastFootprint ?? 0

    print(
      "image helper (SwiftPM debug, unsandboxed): spawn to opened \(spawn), resting footprint \(footprint >> 20) MiB"
    )

    XCTAssertLessThan(footprint, 256 << 20)
    XCTAssertLessThan(spawn, .seconds(10))
  }
}
