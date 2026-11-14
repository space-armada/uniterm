import AppletKit
import FileRouting
import Foundation

/// A type system backed by a table. The system's own database cannot be given made-up types, so a
/// test describes the conformance it needs. A file's type comes from its extension.
final class FixtureTypes: ContentTypeSystem, @unchecked Sendable {
  private let parents: [String: [String]]
  private let byExtension: [String: String]
  private let registered: [String: [String]]
  private let lock = NSLock()
  private var seen: [Bool] = []

  /// Called with each URL the type lookup is asked about.
  private(set) var asked: [URL] = []

  /// `registered` lists every type the system would register for an extension, apart from the
  /// one a file of that extension is given.
  init(
    parents: [String: [String]], byExtension: [String: String],
    registered: [String: [String]] = [:]
  ) {
    self.parents = parents
    self.byExtension = byExtension
    self.registered = registered
  }

  /// A small graph: geojson conforms to json, which conforms to text. Folder and package kinds
  /// stand beside them.
  static func standard() -> FixtureTypes {
    FixtureTypes(
      parents: [
        "com.example.geojson": ["com.example.json"],
        "com.example.json": ["public.text"],
        "com.example.notes": ["public.text"],
        "public.text": ["public.data"],
        "public.folder": ["public.directory"],
        "public.directory": ["public.item"],
        "public.data": ["public.item"],
      ],
      byExtension: [
        "geojson": "com.example.geojson", "json": "com.example.json",
        "notes": "com.example.notes", "txt": "public.text", "bin": "public.data",
      ])
  }

  var lookups: Int {
    lock.lock()
    defer { lock.unlock() }
    return asked.count
  }

  func identifier(of url: URL) -> String? {
    lock.lock()
    asked.append(url)
    seen.append(Thread.isMainThread)
    lock.unlock()

    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    {
      return "public.folder"
    }

    return byExtension[url.pathExtension]
  }

  func identifiers(forExtension ext: String) -> [String] {
    lock.lock()
    seen.append(Thread.isMainThread)
    lock.unlock()

    return registered[ext] ?? []
  }

  /// True when any lookup ran on the main thread.
  var lookedUpOnMainThread: Bool {
    lock.lock()
    defer { lock.unlock() }
    return seen.contains(true)
  }

  func conforms(_ identifier: String, to other: String) -> Bool {
    if identifier == other { return true }

    return (parents[identifier] ?? []).contains { conforms($0, to: other) }
  }

  func isKnown(_ identifier: String) -> Bool {
    identifier == "public.folder" || parents[identifier] != nil || identifier == "public.item"
  }
}

func applet(_ id: String, _ opens: [(String, OpenRank)]) -> AppletTypeDeclaration {
  AppletTypeDeclaration(
    typeID: id, displayName: id.capitalized, symbolName: "app",
    opens: opens.map { OpenedType($0.0, rank: $0.1) })
}

/// A temporary directory that goes away with the test.
func makeTemporaryDirectory(_ name: String = "routing") throws -> URL {
  let url = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("uniterm-\(name)-\(UUID().uuidString)", isDirectory: true)
    .resolvingSymlinksInPath()

  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
