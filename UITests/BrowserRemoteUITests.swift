import XCTest

/// A Janet controller drives a browser pane in the real app: a layout seeds the pane with a
/// loopback page, the controller opens a second tab, which is selected as the user's New Tab
/// would be, and reads it back. Both pages come from a small server on the loopback interface, so
/// nothing leaves the machine.
///
/// The server runs from the terminal's shell, not from the test. The UI test runner is sandboxed
/// with the network client entitlement alone, so a listener in the runner accepts no connection
/// from the app.
///
/// What only the real app shows is the pane's control badge standing clear of the browser's
/// profile button, and the opened tab loading in the pane. The package tests prove the permission
/// rules, ownership, and the refusals one by one. The capture holds synthetic pages only.
@MainActor
final class BrowserRemoteUITests: UnitermUITestCase {
  /// Answers every request with a page titled by its path, and appends each path to a log. It
  /// writes its port to a file once it listens.
  private static let server = #"""
    use strict;
    use warnings;
    use IO::Socket::INET;

    $SIG{PIPE} = 'IGNORE';

    my ($portfile, $log) = @ARGV;
    my $listener = IO::Socket::INET->new(
      Listen => 16, LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp', ReuseAddr => 1
    ) or die "no listener: $!";

    open my $out, '>', "$portfile.tmp" or die;
    print $out $listener->sockport;
    close $out;
    rename "$portfile.tmp", $portfile;

    while (my $client = $listener->accept) {
      my $line = <$client>;
      while (my $header = <$client>) { last if $header =~ /^\r?\n$/; }
      if (defined $line && $line =~ m{^\S+\s+(\S+)}) {
        my $path = $1;
        open my $fh, '>>', $log or die;
        print $fh "$path\n";
        close $fh;
        my $title = ucfirst(substr($path, 1));
        my $body = "<title>$title</title><body>$title</body>";
        print $client "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nCache-Control: no-store\r\n"
          . "Content-Length: " . length($body) . "\r\nConnection: close\r\n\r\n$body";
      }
      close $client;
    }
    """#

  /// Catches a seed that loads nothing, an opened tab that never loads, a read that does not
  /// answer with the tab's address, and a control badge that covers the profile button or the
  /// tab bar.
  func testAControllerSeedsABrowserPaneOpensATabAndReadsItAndTheBadgeStaysClear() throws {
    let command = try bundledCommand()

    try write("PROMPT='%% '\nRPROMPT=''\n", to: scratch + "-shell/.zshrc")

    let app = launchApp()
    let window = mainWindow(in: app)

    _ = waitForTerminal(in: app)
    enableRemoteControl(pane: 1, in: app)

    let template = scratch + "-browser.template"
    let script = scratch + "-browser.janet"
    let shell = scratch + "-browser.sh"
    let errors = scratch + "-browser.err"
    let status = scratch + "-browser.status"
    let server = scratch + "-browser.server.pl"
    let portFile = scratch + "-browser.port"
    let requests = scratch + "-browser.requests"

    try write(Self.server, to: server)
    try write(
      """
      (declare-permissions {:name "Synthetic Browser Controller"}
        {:kind :pane-control}
        {:kind :browser-navigation}
        {:kind :browser-read})

      (import uniterm)

      (def me (get (uniterm/list-windows) 0))
      (def source {:window (me :window) :pane (me :pane)})

      (def layout
        (uniterm/request-layout
          source
          {:split :row
           :children [{:pane (me :pane)}
                      {:open :browser :control :remote-controlled
                       :url "http://127.0.0.1:__PORT__/seeded"}]}))

      (def [_ browser] (layout :panes))
      (def opened
        (uniterm/send-command browser :browser 0 :open {:url "http://127.0.0.1:__PORT__/second"}))
      (def page (uniterm/send-command opened :browser 0 :read {}))

      (print (browser :pane) " " (page :url))
      """, to: template)

    try write(
      """
      /usr/bin/perl "\(server)" "\(portFile)" "\(requests)" &
      serving=$!
      waited=0
      while [ ! -s "\(portFile)" ] && [ $waited -lt 100 ]; do
        waited=$((waited + 1))
        sleep 0.1
      done
      sed "s/__PORT__/$(cat "\(portFile)")/g" "\(template)" > "\(script)"
      attempts=0
      while [ $attempts -lt 100 ]; do
        "\(command)" run --socket "\(testSocket)" "\(script)" > "\(status).out" 2> "\(errors)"
        code=$?
        [ $code -ne 69 ] && break
        attempts=$((attempts + 1))
        sleep 0.1
      done
      waited=0
      while [ $waited -lt 300 ]; do
        grep -q '^/seeded$' "\(requests)" 2>/dev/null && grep -q '^/second$' "\(requests)" \
          2>/dev/null && break
        waited=$((waited + 1))
        sleep 0.1
      done
      kill $serving
      printf '\\033[H\\033[2J\\033[3J'
      echo "exit=$code" > "\(status)"
      """, to: shell)

    defer {
      for path in [
        template, script, shell, errors, status, status + ".out", server, portFile, requests,
      ] {
        try? FileManager.default.removeItem(atPath: path)
      }
    }

    runInTerminal(shell, in: app)
    answerFirstReview(in: app, pressing: "pending-requests-allow-session")

    let result = try XCTUnwrap(waitForFile(status), "the shell never finished the script")
    let errorText = (try? String(contentsOfFile: errors, encoding: .utf8)) ?? ""

    XCTAssertEqual(result, "exit=0\n", errorText)

    let port = try String(contentsOfFile: portFile, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let printed = try String(contentsOfFile: status + ".out", encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .split(separator: " ").map(String.init)

    XCTAssertEqual(printed.count, 2, "the script printed \(printed)")

    let pane = printed[0]

    XCTAssertEqual(
      printed[1], "http://127.0.0.1:\(port)/second", "read did not answer with the tab")

    let seen = (try? String(contentsOfFile: requests, encoding: .utf8)) ?? ""
    let paths = seen.split(separator: "\n").map(String.init)

    XCTAssertTrue(
      paths.contains("/seeded") && paths.contains("/second"),
      "the pages were not both requested. The server saw \(paths)")

    let badge = window.buttons["pane-control-\(pane)"]
    let browser = window.groups["pane-\(pane)"].descendants(matching: .any)["browser"]
    let profile = browser.buttons["browser-profile"]

    XCTAssertTrue(badge.appears(timeout: 10), "the browser pane has no control badge")
    XCTAssertTrue(profile.appears(timeout: 10), "the browser pane has no profile button")
    XCTAssertTrue(
      badge.frame.intersection(profile.frame).isNull,
      "the badge \(badge.frame) covers the profile button \(profile.frame)")

    let attachment = XCTAttachment(screenshot: window.screenshot())

    attachment.name = "Browser pane with its control badge beside the profile button"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
