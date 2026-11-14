import AppletKit
import Foundation

/// What the router decided for one file.
public enum RouteDecision: Sendable, Equatable {
  /// Open the file in this applet type, in a pane that starts in `startDirectory`.
  case open(file: URL, appletTypeID: String, startDirectory: String, type: String)

  /// Several applets claim the type equally. The user picks, and nothing picks for them.
  case choose(file: URL, candidates: [AppletTypeDeclaration], startDirectory: String, type: String)

  case refused(file: URL, RouteRefusal)
}

/// Picks one applet type for each file by the file's content type.
///
/// When the file's own type matches no applet, the types the system registers for its extension
/// are tried instead, by the same rules. The file's own type always wins when it matches.
///
/// A more specific match wins, meaning one whose declared type conforms to the other's. Rank decides
/// only between matches that are equally specific or unrelated. A saved choice for the file's exact
/// type overrides both. Two applets claiming a type at the same rank is a catalog error that a test
/// catches, so a tie at run time asks the user and never picks a default.
///
/// The router is plain data. Its file-system and type work blocks, so callers run it off the main
/// thread. The async entry points do that.
public struct FileRouter: Sendable {
  private let declarations: [AppletTypeDeclaration]
  private let types: any ContentTypeSystem
  private let savedChoices: [String: String]

  /// The saved choices are a snapshot. They map an exact type identifier to an applet type ID.
  public init(
    declarations: [AppletTypeDeclaration], types: any ContentTypeSystem = SystemContentTypes(),
    savedChoices: [String: String] = [:]
  ) {
    self.declarations = declarations
    self.types = types
    self.savedChoices = savedChoices
  }

  // MARK: Entry points

  /// Decides each file, in order, off the main thread.
  @concurrent
  public func decisions(for files: [URL]) async -> [RouteDecision] {
    files.map { decide($0) }
  }

  /// Looks at a path and finds its type, off the main thread.
  @concurrent
  public func inspection(of file: URL) async -> FileInspection {
    inspect(file)
  }

  // MARK: Blocking

  /// Looks at a path without opening it. A FIFO, a device, or a socket is refused before the type
  /// system sees it.
  public func inspect(_ file: URL) -> FileInspection {
    switch PathInspector.kind(of: file) {
    case .failure(let refusal):
      return .refused(refusal)

    case .success(let kind):
      // The system types a symlink as `public.symlink`, so the type comes from the target. The
      // start directory below keeps the path as the request named it.
      guard let type = types.identifier(of: file.resolvingSymlinksInPath()) else {
        return .refused(.unsupported(type: nil))
      }

      return .ready(
        kind: kind, type: type, startDirectory: PathInspector.startDirectory(of: file, kind: kind))
    }
  }

  public func decide(_ file: URL) -> RouteDecision {
    switch inspect(file) {
    case .refused(let refusal):
      return .refused(file: file, refusal)

    case .ready(_, let type, let startDirectory):
      return decision(file: file, type: type, startDirectory: startDirectory)
    }
  }

  // MARK: Matching

  /// The decision for a file of a known type.
  public func decision(file: URL, type: String, startDirectory: String) -> RouteDecision {
    var claims = self.claims(forType: type)
    let preferredMatches = !claims.isEmpty

    if !preferredMatches {
      claims = extensionClaims(for: file)
    }

    guard !claims.isEmpty else {
      return .refused(file: file, .unsupported(type: type))
    }

    let claimants = Self.applets(of: claims, in: declarations)

    if preferredMatches, let saved = savedChoices[type],
      claimants.contains(where: { $0.typeID == saved })
    {
      return .open(file: file, appletTypeID: saved, startDirectory: startDirectory, type: type)
    }

    let best = Self.best(of: claims, types: types)
    let winners = Self.applets(of: best, in: declarations)

    guard winners.count == 1, let winner = winners.first else {
      return .choose(file: file, candidates: winners, startDirectory: startDirectory, type: type)
    }

    return .open(
      file: file, appletTypeID: winner.typeID, startDirectory: startDirectory, type: type)
  }

  /// The claims of every type the system registers for the file's extension. The router falls back
  /// to these only when the file's preferred type matches no claim. Another app can own the
  /// extension with a type that conforms to nothing uniterm declares, while the system also
  /// registers a type that does. A symlink takes its target's extension, as its type does.
  func extensionClaims(for file: URL) -> [Claim] {
    let ext = file.resolvingSymlinksInPath().pathExtension

    guard !ext.isEmpty else { return [] }

    var seen = Set<String>()
    var claims: [Claim] = []

    for identifier in types.identifiers(forExtension: ext) {
      for claim in self.claims(forType: identifier) {
        let key = "\(claim.appletTypeID)\n\(claim.declared)"

        if seen.insert(key).inserted {
          claims.append(claim)
        }
      }
    }

    return claims
  }

  /// Every applet that declares a type the file's type conforms to, the likeliest first. An "Open
  /// With" chooser lists these. The order is the winners, then the rest by specificity and rank.
  public func candidates(forType type: String) -> [AppletTypeDeclaration] {
    let claims = self.claims(forType: type)
    let best = Self.best(of: claims, types: types)
    let winners = Self.applets(of: best, in: declarations)

    let others = Self.applets(of: claims, in: declarations).filter { applet in
      !winners.contains { $0.typeID == applet.typeID }
    }

    return winners + others
  }

  /// The applet type a saved choice for this exact type names, when it still declares the type.
  /// A choice for a missing applet, or one that stopped declaring the type, is kept on disk and
  /// ignored here.
  public func savedAppletTypeID(forType type: String) -> String? {
    guard let saved = savedChoices[type] else { return nil }

    let declares = candidates(forType: type).contains { $0.typeID == saved }
    return declares ? saved : nil
  }

  struct Claim: Equatable {
    let appletTypeID: String
    let declared: String
    let rank: OpenRank
  }

  func claims(forType type: String) -> [Claim] {
    declarations.flatMap { declaration in
      declaration.opens.compactMap { opened in
        types.conforms(type, to: opened.identifier)
          ? Claim(
            appletTypeID: declaration.typeID, declared: opened.identifier, rank: opened.rank)
          : nil
      }
    }
  }

  /// The claims left after specificity and rank. A claim is dropped when another claim's declared
  /// type is a strict subtype of its own. Among the rest, owners beat alternates.
  static func best(of claims: [Claim], types: any ContentTypeSystem) -> [Claim] {
    let specific = claims.filter { claim in
      !claims.contains { other in
        other.declared != claim.declared && types.conforms(other.declared, to: claim.declared)
      }
    }

    let owners = specific.filter { $0.rank == .owner }
    return owners.isEmpty ? specific : owners
  }

  /// The declarations behind some claims, once each, in declaration order.
  static func applets(of claims: [Claim], in declarations: [AppletTypeDeclaration])
    -> [AppletTypeDeclaration]
  {
    declarations.filter { declaration in
      claims.contains { $0.appletTypeID == declaration.typeID }
    }
  }
}
