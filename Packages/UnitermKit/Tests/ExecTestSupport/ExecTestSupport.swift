import Foundation

/// The synthetic driver the exec tests run. Each mode is one behavior a driver can have, good or
/// bad, so a test names the one it proves.
public enum ExecTestDriver {
  public static let perl = "/usr/bin/perl"

  /// The driver script. Perl runs it with the arguments a test gives, and no shell reads them.
  public static var script: String {
    guard let url = Bundle.module.url(forResource: "Fixtures/driver", withExtension: "pl") else {
      preconditionFailure("the driver fixture is missing from the test bundle")
    }

    return url.path
  }

  /// The argv for one mode, for the applet type and schema version the driver says hello with. The
  /// version is "major.minor". The default is the schema of the fixture applets and of every registered
  /// viewer. A test whose subject is the 1.0 major and minor rule names its own version.
  public static func arguments(
    _ mode: String, type: String, schema: String = "0.0", _ rest: [String] = []
  ) -> [String] {
    [perl, script, mode, type, schema] + rest
  }
}
