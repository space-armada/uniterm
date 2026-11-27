import Foundation

/// Why a list of directories is not a read scope.
public struct ReadScopeError: Error, Equatable, CustomStringConvertible, Sendable {
  public let description: String
}

/// The directories a controller may make an applet read from.
///
/// A scope is its own type. It is never a host launch's directory: a launched process holds its
/// macOS grants directly and needs no exclusion, and a read scope leaves out every protected
/// location it contains but does not name. See `ProtectedLocations`.
///
/// Containment and coverage compare as APFS does, through `PathComparison`, with the places in
/// `ProtectedLocations` removed. The check here is lexical. It touches no file. `ScopedOpen` does
/// the check again on what it opens.
public struct ReadScope: Hashable, Sendable {
  public static let maxDirectories = 32
  public static let maxPathBytes = 1024

  /// Sorted, with no directory twice.
  public let directories: [String]

  /// Checks every directory. Each must be a plain absolute path, so one folder has one spelling
  /// and no path climbs out of another.
  public init(directories: [String]) throws(ReadScopeError) {
    guard !directories.isEmpty, directories.count <= Self.maxDirectories else {
      throw ReadScopeError(
        description:
          "a read scope must list 1 to \(Self.maxDirectories) directories")
    }

    try self.init(approved: directories)
  }

  /// A scope an approval holds, with the same checks except the count. Approvals add up through
  /// `union`, so a stored one may list more directories than one descriptor may declare.
  public init(approved directories: [String]) throws(ReadScopeError) {
    guard !directories.isEmpty else {
      throw ReadScopeError(description: "a read scope must list at least one directory")
    }

    for directory in directories where PathComparison.plainComponents(of: directory) == nil {
      throw ReadScopeError(
        description:
          "a read scope's directories must be absolute paths with no '.', '..', or empty "
          + "component")
    }

    guard Set(directories).count == directories.count else {
      throw ReadScopeError(description: "a read scope lists a directory twice")
    }

    self.directories = directories.sorted()
  }

  private init(unchecked directories: [String]) {
    self.directories = directories.sorted()
  }

  /// The directories of both scopes, with no limit on their number. Approvals add up, and the
  /// count limit is for what one descriptor declares.
  public func union(_ other: ReadScope) -> ReadScope {
    ReadScope(unchecked: Array(Set(directories).union(other.directories)))
  }

  private var names: [[String]] {
    directories.compactMap(PathComparison.plainComponents(of:))
  }

  /// True when the plain absolute `path` lies in the scope and in none of the protected places the
  /// scope leaves out. Nothing is read, so a link in the path is not followed.
  public func contains(
    path: String, using comparison: PathComparison = .exact,
    protected: ProtectedLocations = .current
  ) -> Bool {
    guard let target = PathComparison.plainComponents(of: path) else { return false }

    return contains(names: target, using: comparison, protected: protected)
  }

  func contains(
    names target: [String], using comparison: PathComparison, protected: ProtectedLocations,
    resolved: [String: String] = [:]
  )
    -> Bool
  {
    let real = directories.compactMap { resolved[$0] }.compactMap(
      PathComparison.plainComponents(of:))

    return (names + real).contains { directory in
      comparison.isInside(target, directory)
        && protected.place(holding: target, strictlyInside: directory) == nil
    }
  }

  /// True when everything this scope reaches, the effective scope, is also reached by `approved`.
  ///
  /// A directory is covered by an approved directory that holds it, unless that approved directory
  /// leaves out a protected place that the directory lies in or names. A request for
  /// `~/Documents/x` is therefore broader than an approved `~`. Names compare exactly after
  /// normalization, so a different spelling can only make a scope ask again.
  public func isCovered(by approved: ReadScope, protected: ProtectedLocations = .current) -> Bool {
    let comparison = PathComparison.exact
    let wanted = names
    let allowed = approved.names

    return wanted.allSatisfy { directory in
      allowed.contains { holder in
        comparison.isInside(directory, holder)
          && protected.place(holding: directory, strictlyInside: holder) == nil
      }
    }
  }

  /// Each directory with every link in it resolved, by the directory as written. A directory that
  /// is not there is left out. This reads the disk, so it is not for the main thread.
  public func resolvedDirectories() -> [String: String] {
    Self.resolve(directories)
  }

  /// Each of `directories` with every link in it resolved, by the directory as written. A
  /// directory that is not there is left out. This reads the disk, so it is not for the main
  /// thread.
  public static func resolve(_ directories: some Sequence<String>) -> [String: String] {
    var resolved: [String: String] = [:]

    for directory in directories {
      guard let pointer = realpath(directory, nil) else { continue }

      defer { free(pointer) }

      resolved[directory] = String(cString: pointer)
    }

    return resolved
  }

  /// Every protected place any directory lies in or names, then every one it leaves out, each
  /// label once and in the order of the list. An approval names them to the user.
  ///
  /// `resolved` is the result of `resolvedDirectories`. A directory that is a link into a protected
  /// place lies in it as the open sees it, so the resolved directories are named too.
  public func protectedLabels(
    resolved: [String: String] = [:], protected: ProtectedLocations = .current
  ) -> (lyingIn: [String], leftOut: [String]) {
    let comparison = PathComparison.exact
    var inside: [String] = []
    var outside: [String] = []

    let resolvedNames = resolved.values.compactMap(PathComparison.plainComponents(of:))

    for directory in names + resolvedNames {
      for label in protected.labels(lyingIn: directory, using: comparison)
      where !inside.contains(label) {
        inside.append(label)
      }

      for label in protected.labels(leftOutOf: directory, using: comparison)
      where !outside.contains(label) {
        outside.append(label)
      }
    }

    return (inside, outside.filter { !inside.contains($0) })
  }
}

/// What a command's caller may see, and what an applet must check before it shows a user's file to
/// that caller.
///
/// A pane whose source is a user's file that lies outside the caller's scope sends the caller no
/// path or content detail from it. Content the caller sent itself is not a user's file, so it is
/// the caller's to see. `controllerSentRoot` is where such content waits.
public struct ReadAccess: Equatable, Sendable {
  /// The directories the caller may read, or nil when it holds no path-reading power.
  public let scope: ReadScope?

  /// The folder that holds the content programs sent, or nil when there is none.
  public let controllerSentRoot: String?

  /// True when the caller declared the power and it does not stand, as when the user allowed the
  /// run once. The caller knows its own grant, so telling it so reveals nothing about any path.
  public let isDeclaredButNotGranted: Bool

  /// The scope's directories with their links resolved, by the directory as written. The
  /// comparison here reads no disk, and the panes hand it real paths. A scope written through a
  /// link holds none of them unless the resolved spelling is checked too. The owner resolves off
  /// the main thread and passes the result in. A directory missing from it has no other spelling
  /// yet, which hides paths and never shows extra ones.
  public let resolvedDirectories: [String: String]

  public init(
    scope: ReadScope?, controllerSentRoot: String? = nil, isDeclaredButNotGranted: Bool = false,
    resolvedDirectories: [String: String] = [:]
  ) {
    self.resolvedDirectories = resolvedDirectories
    self.scope = scope
    self.controllerSentRoot = controllerSentRoot
    self.isDeclaredButNotGranted = isDeclaredButNotGranted
  }

  /// No power and no sent folder.
  public static let none = ReadAccess(scope: nil)

  /// True when the caller may be told about a pane whose user's file is at `path`. A pane with no
  /// user's file is always shown.
  public func mayShow(source path: String?, protected: ProtectedLocations = .current) -> Bool {
    guard let path else { return true }

    guard let target = PathComparison.plainComponents(of: path) else { return false }

    if let root = controllerSentRoot, let names = PathComparison.plainComponents(of: root),
      PathComparison.exact.isInside(target, names)
    {
      return true
    }

    return scope?.contains(
      names: target, using: .exact, protected: protected, resolved: resolvedDirectories) ?? false
  }
}
