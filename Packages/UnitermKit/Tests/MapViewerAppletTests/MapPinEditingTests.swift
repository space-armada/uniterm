import AppKit
import AppletKit
import AppletTestSupport
import FileWatching
import Foundation
import GeoData
import MapKit
import XCTest

@testable import MapViewerApplet

/// Editing a file's pins through the applet: what the map shows, what Save writes, undo, the
/// unsaved state the close dialog reads, and changes on disk.
@MainActor
final class MapPinEditingTests: XCTestCase {
  private func load(_ applet: MapViewerApplet, _ file: URL) async {
    applet.replaceSource(with: file, startDirectory: file.deletingLastPathComponent().path)
    await applet.opening?.value
  }

  private func settle(_ applet: MapViewerApplet) async {
    await applet.editing?.value
  }

  private func mixedFile(_ scratch: GeoScratch) throws -> URL {
    try scratch.write(
      "places.geojson",
      GeoFixtures.collection([
        GeoFixtures.point("A", 1, 1), GeoFixtures.line, GeoFixtures.point("B", 2, 2),
      ]))
  }

  /// Catches an edit the map shows but Save loses, a save that drops what the map cannot show,
  /// and a pane that still says it is edited after saving. An added pin shows at once, the pane
  /// is edited until Save, and the file on disk then holds the pin beside the original line.
  func testAnAddedPinShowsAndSaveWritesItBesideWhatTheMapCannotShow() async throws {
    let scratch = try GeoScratch(self)
    let file = try mixedFile(scratch)
    let applet = MapViewerApplet(startDirectory: nil)
    let host = RecordingHost()
    applet.host = host
    await load(applet, file)

    applet.addPin(at: GeoCoordinate(latitude: 5, longitude: 6))
    await settle(applet)

    XCTAssertEqual(applet.filePinsShown.count, 3)
    XCTAssertTrue(applet.isDirty)
    XCTAssertEqual(applet.unsavedWork, AppletUnsavedWork(label: "places.geojson"))
    XCTAssertEqual(applet.title, "places.geojson \u{2014} Edited")

    let saved = await applet.save()

    XCTAssertTrue(saved)
    XCTAssertFalse(applet.isDirty)
    XCTAssertNil(applet.unsavedWork)

    let onDisk = try String(contentsOf: file, encoding: .utf8)
    XCTAssertTrue(onDisk.contains(GeoFixtures.line), onDisk)
    XCTAssertTrue(onDisk.contains("[6.0, 5.0]"), onDisk)
  }

  /// Catches an undo that does not put the file's bytes back, and a redo that is lost because the
  /// undo registered a new action instead. Undo of a removal brings the pin and the clean state
  /// back. Redo removes it again.
  func testUndoAndRedoPutBackTheExactBytes() async throws {
    let scratch = try GeoScratch(self)
    let file = try mixedFile(scratch)
    let original = try Data(contentsOf: file)
    let applet = MapViewerApplet(startDirectory: nil)
    await load(applet, file)

    let pin = try XCTUnwrap(applet.filePinsShown.first { $0.label == "B" })
    applet.remove(pin)
    await settle(applet)

    XCTAssertEqual(applet.filePinsShown.map(\.label), ["A"])
    XCTAssertEqual(applet.undoManager.undoActionName, "Remove Pin")

    applet.undoManager.undo()
    await settle(applet)

    XCTAssertEqual(applet.document, original)
    XCTAssertFalse(applet.isDirty)
    XCTAssertEqual(applet.filePinsShown.map(\.label), ["A", "B"])
    XCTAssertTrue(applet.undoManager.canRedo)

    applet.undoManager.redo()
    await settle(applet)

    XCTAssertEqual(applet.filePinsShown.map(\.label), ["A"])
  }

  /// Catches a second edit that lands on stale pin IDs. While the first edit's pins are being
  /// read, a second edit is refused, so a removal that renumbers pins cannot misdirect it.
  func testAnEditWaitsForTheLastOneToLand() async throws {
    let scratch = try GeoScratch(self)
    let applet = MapViewerApplet(startDirectory: nil)
    await load(applet, try mixedFile(scratch))

    applet.addPin(at: GeoCoordinate(latitude: 1, longitude: 2))
    XCTAssertFalse(applet.canEdit)

    let before = applet.document
    applet.addPin(at: GeoCoordinate(latitude: 3, longitude: 4))
    XCTAssertEqual(applet.document, before)

    await settle(applet)
    XCTAssertTrue(applet.canEdit)
  }

  /// Catches a map with no file that cannot keep its pins. Its pins are unsaved, Save asks where,
  /// and the chosen file becomes the pane's file and is restored with it.
  func testPinsOnAMapWithNoFileSaveToANewFile() async throws {
    let scratch = try GeoScratch(self)
    let target = scratch.url.appendingPathComponent("new.geojson")
    let applet = MapViewerApplet(startDirectory: scratch.url.path)
    var asked: [(String, String?)] = []
    applet.chooseSaveLocation = { name, folder, _ in
      asked.append((name, folder))
      return target
    }

    applet.addPin(at: GeoCoordinate(latitude: 48.85, longitude: 2.35))
    await settle(applet)

    XCTAssertEqual(applet.unsavedWork?.label, "Untitled")

    let saved = await applet.saveUnsavedWork()

    XCTAssertTrue(saved)
    XCTAssertEqual(asked.first?.0, "Pins.geojson")
    XCTAssertEqual(asked.first?.1, scratch.url.path)
    XCTAssertFalse(applet.isDirty)
    XCTAssertEqual(try MapViewerDescription.decode(applet.describe()).path, target.path)

    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: target)) as? [String: Any]
    XCTAssertEqual((object?["features"] as? [Any])?.count, 1)
  }

  /// Catches a cancelled Save As that counts as saved, which would let a close drop the pins.
  func testACancelledSaveAsIsNotASave() async {
    let applet = MapViewerApplet(startDirectory: nil)
    applet.chooseSaveLocation = { _, _, _ in nil }

    applet.addPin(at: GeoCoordinate(latitude: 1, longitude: 1))
    await settle(applet)

    let saved = await applet.saveUnsavedWork()

    XCTAssertFalse(saved)
    XCTAssertTrue(applet.isDirty)
  }

  /// Catches a save that silently overwrites another program's change. Save asks first. Cancel
  /// writes nothing, and Overwrite writes the edits.
  func testSaveAsksBeforeOverwritingAChangeOnDisk() async throws {
    let scratch = try GeoScratch(self)
    let file = try mixedFile(scratch)
    let applet = MapViewerApplet(startDirectory: nil)
    var choices: [SaveConflictChoice] = [.cancel, .overwrite]
    var asked = 0
    applet.resolveConflict = { _, _ in
      asked += 1
      return choices.removeFirst()
    }
    await load(applet, file)

    applet.addPin(at: GeoCoordinate(latitude: 9, longitude: 9))
    await settle(applet)

    let theirs = GeoFixtures.collection([GeoFixtures.point("Theirs", 0, 0)])
    try Data(theirs.utf8).write(to: file)

    let cancelled = await applet.save()
    XCTAssertFalse(cancelled)
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), theirs)

    let overwritten = await applet.save()
    XCTAssertTrue(overwritten)
    XCTAssertEqual(try Data(contentsOf: file), applet.document)
    XCTAssertEqual(asked, 2)
  }

  /// Catches a save that resets the file's permissions, as a plain atomic write does.
  func testSaveKeepsTheFilesPermissions() async throws {
    let scratch = try GeoScratch(self)
    let file = try mixedFile(scratch)
    chmod(file.path, 0o600)
    let applet = MapViewerApplet(startDirectory: nil)
    await load(applet, file)

    applet.addPin(at: GeoCoordinate(latitude: 1, longitude: 2))
    await settle(applet)
    _ = await applet.save()

    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }

  /// Catches a pane that goes stale when another program changes its file, and one that drops
  /// the user's edits to follow the change. A clean pane reads the file again. An edited pane
  /// keeps its edits and says the file changed.
  func testAChangeOnDiskReloadsACleanPaneAndWarnsAnEditedOne() async throws {
    let scratch = try GeoScratch(self)
    let file = try mixedFile(scratch)
    let applet = MapViewerApplet(startDirectory: nil)
    await load(applet, file)

    try Data(GeoFixtures.collection([GeoFixtures.point("C", 3, 3)]).utf8).write(to: file)
    applet.fileChangedOnDisk()
    await applet.opening?.value

    XCTAssertEqual(applet.filePinsShown.map(\.label), ["C"])

    applet.addPin(at: GeoCoordinate(latitude: 4, longitude: 4))
    await settle(applet)
    try Data(GeoFixtures.collection([GeoFixtures.point("D", 5, 5)]).utf8).write(to: file)
    applet.fileChangedOnDisk()

    XCTAssertEqual(applet.filePinsShown.count, 2)
    XCTAssertTrue(applet.isDirty)
    XCTAssertTrue(
      applet.statusNotices.contains {
        $0.level == .warning && $0.text.hasPrefix("The file changed on disk")
      })
  }

  /// Catches a watcher that never fires, or one that stops after an editor replaces the file by
  /// renaming a new one over it.
  func testTheWatcherSeesWritesAndReplacements() async throws {
    let scratch = try GeoScratch(self)
    let file = try mixedFile(scratch)
    var changes = 0
    let replaced = expectation(description: "replaced")
    let written = expectation(description: "written")
    let watcher = FileWatcher(url: file) { _ in
      changes += 1
      if changes == 1 { replaced.fulfill() }
      if changes == 2 { written.fulfill() }
    }
    defer { watcher.stop() }
    await watcher.whenArmed()

    let replacement = scratch.url.appendingPathComponent("replacement.geojson")
    try Data("{}".utf8).write(to: replacement)
    _ = try FileManager.default.replaceItemAt(file, withItemAt: replacement)
    await fulfillment(of: [replaced], timeout: 5)

    try Data("{} ".utf8).write(to: file)
    await fulfillment(of: [written], timeout: 5)
  }

  /// Catches a closed pane whose unsaved pins are gone on reopen. The undo-only part of its
  /// description carries them, and a reopen shows them as still unsaved. The layout file never
  /// holds them.
  func testReopenBringsBackUnsavedPins() async throws {
    let scratch = try GeoScratch(self)
    let file = try mixedFile(scratch)
    let applet = MapViewerApplet(startDirectory: nil)
    await load(applet, file)

    applet.addPin(at: GeoCoordinate(latitude: 7, longitude: 7))
    await settle(applet)

    let description = applet.describe()
    XCTAssertNotNil(description.undoState)
    XCTAssertNil(description.withoutUndoState.undoState)

    let reopened = try MapViewerApplet(restoring: description)
    reopened.start(origin: .user)
    await reopened.opening?.value
    await settle(reopened)

    XCTAssertEqual(reopened.filePinsShown.count, 3)
    XCTAssertTrue(reopened.isDirty)
  }

  /// Catches lost pins reported as a warning, which clears in seconds. Pins left unsaved at close
  /// that cannot come back are lost work, so the status bar keeps them as an error.
  func testUnsavedPinsThatCannotComeBackPostAnError() async throws {
    let scratch = try GeoScratch(self)
    let file = try mixedFile(scratch)
    let applet = MapViewerApplet(startDirectory: nil)
    await load(applet, file)

    applet.addPin(at: GeoCoordinate(latitude: 7, longitude: 7))
    await settle(applet)

    let description = applet.describe()
    try FileManager.default.removeItem(at: file)

    let reopened = try MapViewerApplet(restoring: description)
    let host = RecordingHost()
    reopened.host = host
    reopened.start(origin: .user)
    await reopened.opening?.value

    let lost = host.posts.filter { $0.text.hasPrefix("The pins left unsaved") }
    XCTAssertEqual(lost.map(\.level), [.error], "\(host.posts)")
  }

  /// Catches a context menu that adds nothing, or adds the pin somewhere other than where the
  /// user clicked.
  func testAddPinHereAddsAPinAtTheClick() async throws {
    let applet = MapViewerApplet(startDirectory: nil)
    applet.content.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    applet.content.layoutSubtreeIfNeeded()

    let items = applet.content.contextItems(atWindowPoint: NSPoint(x: 300, y: 200))
    XCTAssertEqual(items.map(\.title), ["Add Pin Here"])

    (items.first as? ClosureMenuItem)?.perform()
    await settle(applet)

    let center = applet.content.mapView.convert(
      NSPoint(x: 300, y: 200), toCoordinateFrom: applet.content.mapView)
    let pin = try XCTUnwrap(applet.filePinsShown.first)
    XCTAssertEqual(pin.coordinate.latitude, center.latitude, accuracy: 0.0001)
    XCTAssertEqual(pin.coordinate.longitude, center.longitude, accuracy: 0.0001)
  }

  /// Catches an editor whose Done writes nothing, or a picked glyph that never reaches the file.
  /// A symbol picked from the grid, then characters typed past two, land as the last pick.
  func testTheEditorWritesWhatThePickerPicks() async throws {
    let scratch = try GeoScratch(self)
    let applet = MapViewerApplet(startDirectory: nil)
    await load(applet, try mixedFile(scratch))

    let pin = try XCTUnwrap(applet.filePinsShown.first { $0.label == "A" })
    let editor = PinEditorController(pin: pin, layerAccent: .blue, palette: .latte)
    _ = editor.view
    editor.onDone = { applet.update(pin, to: $0) }

    editor.labelField.stringValue = "Alpha"
    editor.accentMenu.selectItem(withTitle: "Peach")

    editor.showPicker()
    var picker = try XCTUnwrap(editor.picker?.controller)
    _ = picker.view
    try XCTUnwrap(picker.tiles["cup.and.saucer.fill"]).performClick(nil)

    XCTAssertEqual(editor.glyph, .symbol("cup.and.saucer.fill"))
    XCTAssertNil(editor.picker, "a pick left the picker open")
    XCTAssertEqual(editor.glyphButton.title, "cup.and.saucer.fill")

    editor.showPicker()
    picker = try XCTUnwrap(editor.picker?.controller)
    _ = picker.view
    picker.showCharacters()
    picker.characterField.stringValue = "ABC"
    picker.controlTextDidChange(
      Notification(name: NSControl.textDidChangeNotification, object: picker.characterField))
    XCTAssertEqual(picker.characterField.stringValue, "C", "a third character did not replace")

    picker.characterField.stringValue = "\u{2605}"
    picker.useCharacters()
    editor.done()
    await settle(applet)

    let edited = try XCTUnwrap(applet.filePinsShown.first { $0.label == "Alpha" })
    XCTAssertEqual(edited.accent, .peach)
    XCTAssertEqual(edited.glyph, PinGlyph("\u{2605}"))
  }

  /// Catches No Glyph that leaves the old glyph, and a filter that hides the symbol it names.
  func testNoGlyphClearsAndTheFilterNarrowsTheGrid() throws {
    let pin = GeoPin(
      id: "0:0", coordinate: GeoCoordinate(latitude: 1, longitude: 1), label: "A",
      glyph: .symbol("star.fill"))
    let editor = PinEditorController(pin: pin, layerAccent: .blue, palette: .latte)
    _ = editor.view

    editor.showPicker()
    let picker = try XCTUnwrap(editor.picker?.controller)
    _ = picker.view
    XCTAssertEqual(picker.tiles["star.fill"]?.state, .on)

    picker.filterField.stringValue = "cup"
    picker.controlTextDidChange(
      Notification(name: NSControl.textDidChangeNotification, object: picker.filterField))
    XCTAssertEqual(
      Set(picker.tiles.keys), ["cup.and.saucer.fill", "takeoutbag.and.cup.and.straw.fill"])

    picker.pickNone()
    XCTAssertNil(editor.glyph)
    XCTAssertEqual(editor.editedPin.glyph, nil)
  }

  /// Catches a filter that spreads the remaining groups out or resizes the picker. The groups
  /// stay packed from the top, one spacing apart, and the grid's area keeps its height.
  func testFilteringKeepsTheGroupsPackedAndThePickerStill() throws {
    let picker = GlyphPickerController(current: nil, used: [])
    picker.view.layoutSubtreeIfNeeded()
    let height = picker.symbolArea.frame.height

    picker.filterField.stringValue = "h"
    picker.controlTextDidChange(
      Notification(name: NSControl.textDidChangeNotification, object: picker.filterField))
    picker.view.layoutSubtreeIfNeeded()

    XCTAssertEqual(picker.symbolArea.frame.height, height, accuracy: 0.5)

    let sections = picker.groupsStack.arrangedSubviews.map {
      $0.convert($0.bounds, to: picker.symbolArea.documentView)
    }

    XCTAssertGreaterThan(sections.count, 1)
    XCTAssertEqual(sections[0].minY, 0, accuracy: 0.5, "the first group is not at the top")

    for (above, below) in zip(sections, sections.dropFirst()) {
      XCTAssertEqual(below.minY - above.maxY, picker.groupsStack.spacing, accuracy: 0.5)
    }
  }

  /// Catches a symbol in the picker that this Mac cannot draw, which would show as a blank tile and
  /// save a glyph that draws as the default dot.
  func testEverySymbolThePickerOffersExists() {
    for group in GlyphCatalog.groups {
      for name in group.names {
        XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), name)
        XCTAssertEqual(PinGlyph(name), .symbol(name), name)
      }
    }
  }

  /// Catches a pin list that disagrees with the map, or a filter that misses.
  func testThePinListFollowsThePinsAndFilters() async throws {
    let scratch = try GeoScratch(self)
    let applet = MapViewerApplet(startDirectory: nil)
    await load(applet, try mixedFile(scratch))

    applet.content.setPinList(visible: true)
    let list = try XCTUnwrap(applet.content.pinList)
    XCTAssertEqual(list.shown.map(\.label), ["A", "B"])

    list.filter("b")
    XCTAssertEqual(list.shown.map(\.label), ["B"])

    list.filter("")
    applet.addPin(at: GeoCoordinate(latitude: 8, longitude: 8))
    await settle(applet)
    XCTAssertEqual(list.shown.count, 3)

    applet.content.setPinList(visible: false)
    XCTAssertNil(applet.content.pinList)
  }
}

/// Remove Pin's Cmd-Delete belongs to the map, never to a text field over it.
@MainActor
final class RemovePinKeyTests: XCTestCase {
  /// Catches Cmd-Delete in the place search removing the selected pin. The command is on only
  /// while the map has the keyboard.
  func testRemovePinIsOffWhileATextFieldHasTheKeyboard() async throws {
    let applet = MapViewerApplet(startDirectory: nil)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = applet.content
    defer { window.close() }

    applet.addPin(at: GeoCoordinate(latitude: 1, longitude: 1))
    await applet.editing?.value

    let annotation = try XCTUnwrap(
      applet.content.mapView.annotations.compactMap { $0 as? MapPinAnnotation }.first)
    applet.content.mapView.selectAnnotation(annotation, animated: false)

    let remove = try XCTUnwrap(
      MapViewerApplet.commandSet.commands.first { $0.name == "remove-pin" })

    window.makeFirstResponder(applet.content.mapView)
    XCTAssertTrue(remove.isAvailable(applet))

    let field = NSTextField()
    applet.content.addSubview(field)
    window.makeFirstResponder(field)
    XCTAssertFalse(remove.isAvailable(applet))
  }
}

/// Edits that must never leave the user's file at risk.
@MainActor
final class PinEditSafetyTests: XCTestCase {
  private func loaded(_ scratch: GeoScratch) async throws -> (MapViewerApplet, RecordingHost, Data)
  {
    let file = try scratch.write(
      "places.geojson", GeoFixtures.collection([GeoFixtures.point("A", 1, 1)]))
    let applet = MapViewerApplet(startDirectory: nil)
    let host = RecordingHost()
    applet.host = host
    applet.replaceSource(with: file, startDirectory: scratch.url.path)
    await applet.opening?.value

    return (applet, host, try Data(contentsOf: file))
  }

  /// Catches an edit whose bytes the reader refuses, which would leave unreadable bytes for Save
  /// to write. The document goes back, the pane stays clean, and the user is told.
  func testAnEditTheReaderRefusesIsTakenBack() async throws {
    let (applet, host, original) = try await loaded(try GeoScratch(self))

    applet.replaceDocument(with: Data("not geojson".utf8), registeringUndo: true)
    await applet.editing?.value

    XCTAssertEqual(applet.document, original)
    XCTAssertFalse(applet.isDirty)
    XCTAssertFalse(applet.undoManager.canUndo)
    XCTAssertEqual(applet.filePinsShown.map(\.label), ["A"])
    XCTAssertTrue(host.posts.contains { $0.text.hasPrefix("The edit was not applied") })
  }

  /// Catches an edit refusal rated as lost work. A refused edit leaves the earlier unsaved pins
  /// and the file untouched. Only the undo stack goes, which is history and not work. The notice is
  /// a warning, because the requested change is what was not applied.
  func testARefusedEditKeepsEarlierUnsavedPinsAndIsOnlyAWarning() async throws {
    let (applet, host, _) = try await loaded(try GeoScratch(self))
    applet.addPin(at: GeoCoordinate(latitude: 2, longitude: 2))
    await applet.editing?.value

    let edited = applet.document

    applet.replaceDocument(with: Data("not geojson".utf8), registeringUndo: true)
    await applet.editing?.value

    XCTAssertEqual(applet.document, edited)
    XCTAssertEqual(applet.filePinsShown.count, 2)
    XCTAssertTrue(applet.isDirty)
    XCTAssertFalse(applet.undoManager.canUndo)

    let refused = host.posts.filter { $0.text.hasPrefix("The edit was not applied") }
    XCTAssertEqual(refused.map(\.level), [.warning])
  }

  /// Catches a failed save rated below the work it puts at risk. A save that cannot write leaves
  /// the edits unpersisted, and the user must act or lose them, so it stays an error.
  func testASaveThatCannotWriteIsAnError() async throws {
    let scratch = try GeoScratch(self)
    let (applet, host, _) = try await loaded(scratch)
    applet.addPin(at: GeoCoordinate(latitude: 2, longitude: 2))
    await applet.editing?.value

    XCTAssertEqual(chmod(scratch.url.path, 0o500), 0)

    let saved = await applet.save()

    XCTAssertFalse(saved)
    XCTAssertTrue(applet.isDirty, "the edits are still held")
    XCTAssertEqual(
      host.posts.filter { $0.text.contains("could not be saved") }.map(\.level), [.error])
  }

  /// Catches Clear File Pins dropping unsaved pins without asking. Cancel keeps them, and
  /// confirming clears.
  func testClearingWithUnsavedPinsAsksFirst() async throws {
    let (applet, host, _) = try await loaded(try GeoScratch(self))
    applet.addPin(at: GeoCoordinate(latitude: 2, longitude: 2))
    await applet.editing?.value

    host.answer = false
    applet.clearFile()
    await applet.asking?.value

    XCTAssertEqual(host.confirmations.count, 1)
    XCTAssertEqual(applet.filePinsShown.count, 2)
    XCTAssertTrue(applet.isDirty)

    host.answer = true
    applet.clearFile()
    await applet.asking?.value

    XCTAssertTrue(applet.filePinsShown.isEmpty)
    XCTAssertFalse(applet.isDirty)
  }

  /// Catches opening another file over unsaved pins without asking.
  func testOpeningAnotherFileOverUnsavedPinsAsksFirst() async throws {
    let scratch = try GeoScratch(self)
    let (applet, host, _) = try await loaded(scratch)
    applet.addPin(at: GeoCoordinate(latitude: 2, longitude: 2))
    await applet.editing?.value

    let other = try scratch.write("other.geojson", GeoFixtures.collection([]))
    host.answer = false
    applet.replaceSource(with: other, startDirectory: scratch.url.path)
    await applet.asking?.value

    XCTAssertEqual(applet.displayName, "places.geojson")
    XCTAssertTrue(applet.isDirty)
  }
}

/// Review findings in the applet: restored unsaved bytes, refused drags, and symlinked files.
@MainActor
final class PinEditReviewTests: XCTestCase {
  /// Catches unsaved pins from a closed pane being laid over a different file. The pane's own file
  /// is gone on reopen, so its unsaved pins cannot apply, and a file opened later in the pane must
  /// show as it is on disk.
  func testRestoredUnsavedPinsNeverLandOnAnotherFile() async throws {
    let scratch = try GeoScratch(self)
    let first = try scratch.write(
      "first.geojson", GeoFixtures.collection([GeoFixtures.point("A", 1, 1)]))
    let applet = MapViewerApplet(startDirectory: nil)
    applet.replaceSource(with: first, startDirectory: scratch.url.path)
    await applet.opening?.value
    applet.addPin(at: GeoCoordinate(latitude: 2, longitude: 2))
    await applet.editing?.value

    let description = applet.describe()
    try FileManager.default.removeItem(at: first)

    let reopened = try MapViewerApplet(restoring: description)
    reopened.start(origin: .user)
    await reopened.opening?.value

    let second = try scratch.write(
      "second.geojson", GeoFixtures.collection([GeoFixtures.point("Z", 5, 5)]))
    reopened.replaceSource(with: second, startDirectory: scratch.url.path)
    await reopened.asking?.value
    await reopened.opening?.value
    await reopened.editing?.value

    XCTAssertEqual(reopened.document, try Data(contentsOf: second))
    XCTAssertFalse(reopened.isDirty)
    XCTAssertEqual(reopened.filePinsShown.map(\.label), ["Z"])
  }

  /// Catches a refused drag that leaves the pin where it was dropped while the file keeps it
  /// where it was. The pin goes back to the file's coordinate.
  func testARefusedDragPutsThePinBack() async throws {
    let applet = MapViewerApplet(startDirectory: nil)
    applet.addPin(at: GeoCoordinate(latitude: 1, longitude: 1))
    await applet.editing?.value

    let annotation = try XCTUnwrap(
      applet.content.mapView.annotations.compactMap { $0 as? MapPinAnnotation }.first)
    let old = annotation.pin
    annotation.coordinate = CLLocationCoordinate2D(latitude: 30, longitude: 30)

    let gone = GeoPin(id: "9:0", coordinate: old.coordinate, label: old.label)
    applet.update(
      gone,
      to: GeoPin(
        id: "9:0", coordinate: GeoCoordinate(latitude: 30, longitude: 30), label: old.label))
    await applet.editing?.value

    let shown = try XCTUnwrap(
      applet.content.mapView.annotations.compactMap { $0 as? MapPinAnnotation }.first)
    XCTAssertEqual(shown.coordinate.latitude, 1, accuracy: 0.0001)
  }

  /// Catches a pin in a geometry collection offered for dragging and editing, which the patcher
  /// refuses.
  func testAPinInAGeometryCollectionIsNotEditable() async throws {
    let scratch = try GeoScratch(self)
    let file = try scratch.write(
      "gc.geojson",
      #"{"type":"FeatureCollection","features":[{"type":"Feature","properties":{"name":"G"},"geometry":{"type":"GeometryCollection","geometries":[{"type":"Point","coordinates":[1,2]}]}},{"type":"Feature","properties":{"name":"P"},"geometry":{"type":"Point","coordinates":[3,4]}}]}"#
    )
    let applet = MapViewerApplet(startDirectory: nil)
    applet.replaceSource(with: file, startDirectory: scratch.url.path)
    await applet.opening?.value

    let editable = applet.content.mapView.annotations.compactMap { $0 as? MapPinAnnotation }
      .filter(\.isEditable).map(\.pin.label)
    XCTAssertEqual(editable, ["P"])
  }

  /// Catches a save that replaces a symlinked file with a plain one, which breaks the link.
  func testSaveThroughASymlinkKeepsTheLink() async throws {
    let scratch = try GeoScratch(self)
    let target = try scratch.write(
      "real.geojson", GeoFixtures.collection([GeoFixtures.point("A", 1, 1)]))
    let link = scratch.url.appendingPathComponent("link.geojson")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let applet = MapViewerApplet(startDirectory: nil)
    applet.replaceSource(with: link, startDirectory: scratch.url.path)
    await applet.opening?.value

    applet.addPin(at: GeoCoordinate(latitude: 2, longitude: 2))
    await applet.editing?.value
    _ = await applet.save()

    XCTAssertEqual(
      try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType,
      .typeSymbolicLink)
    XCTAssertEqual(try Data(contentsOf: target), applet.document)
  }
}
