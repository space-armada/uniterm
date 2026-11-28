import XCTest

/// The tab marker slot in the launched app: the authority marker on a tab a controller can act on,
/// the pane-level marker beside the control badge, and the tab bar that scrolls when its tabs do
/// not fit. Package tests prove which tabs are marked and where each view lies. These prove what
/// only the real window server shows: the elements a user and VoiceOver reach, the click and wheel
/// paths, and a capture of each look.
///
/// A controller must stay connected for its marker to show, so each script holds its connection
/// open after it has printed. The app's end ends it. Nothing publishes the run-end marker yet, so
/// its captures use the marked fixture, which only a debug build with `UNITERM_TEST_APPLETS` knows.
@MainActor
final class MarkerUITests: UnitermUITestCase {
  private func element(_ identifier: String, in container: XCUIElement) -> XCUIElement {
    container.descendants(matching: .any)[identifier]
  }

  /// Answers every request with a page titled by its path, and appends each path to a log.
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

  /// Starts a controller script from the terminal and leaves it connected. The script prints the
  /// pane it made, and the test reads that from `output`. `before` runs in the shell first, and may
  /// write the script.
  private func startController(
    janet: String, named name: String, before: String = "", in app: XCUIApplication
  ) throws -> (output: String, requests: String) {
    let command = try bundledCommand()
    let script = scratch + "-\(name).janet"
    let shell = scratch + "-\(name).sh"
    let output = scratch + "-\(name).out"
    let status = scratch + "-\(name).status"
    let requests = scratch + "-\(name).requests"

    try write(janet, to: script)
    try write(
      """
      \(before.replacingOccurrences(of: "__REQUESTS__", with: requests))
      (
        attempts=0
        while [ $attempts -lt 100 ]; do
          "\(command)" run --socket "\(testSocket)" "\(script)" > "\(output)" 2> "\(output).err"
          code=$?
          [ $code -ne 69 ] && break
          attempts=$((attempts + 1))
          sleep 0.1
        done
        echo "exit=$code" > "\(status)"
      ) < /dev/null > /dev/null 2>&1 &
      printf '\\033[H\\033[2J\\033[3J'
      """, to: shell)

    addTeardownBlock {
      for path in [script, shell, output, output + ".err", status, requests] {
        try? FileManager.default.removeItem(atPath: path)
      }
    }

    runInTerminal(shell, in: app)
    answerFirstReview(in: app, pressing: "pending-requests-allow-session")

    return (output, requests)
  }

  private func printedPane(_ program: (output: String, requests: String)) throws -> String {
    let text = try XCTUnwrap(waitForFile(program.output), "the controller printed nothing")

    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Catches a marker on the wrong tab, a marker the user cannot reach, and a user tab that picks
  /// one up. A controller seeds a browser pane and opens a second tab, so both tabs carry the
  /// authority marker as an image with its meaning as the label. The user then opens a third tab
  /// with the new-tab button. That one has no marker. The capture shows the marked and unmarked
  /// tabs side by side.
  func testABrowserTabTheControllerOpenedIsMarkedAndTheUsersTabIsNot() throws {
    try write("PROMPT='%% '\nRPROMPT=''\n", to: scratch + "-shell/.zshrc")

    let app = launchApp()
    let window = mainWindow(in: app)

    _ = waitForTerminal(in: app)
    enableRemoteControl(pane: 1, in: app)

    let server = scratch + "-markers.server.pl"
    let portFile = scratch + "-markers.port"
    let template = scratch + "-markers.template"

    try write(Self.server, to: server)
    try write(
      """
      (declare-permissions {:name "Synthetic Marker Controller"}
        {:kind :pane-control}
        {:kind :browser-navigation}
        {:kind :browser-read})

      (import uniterm)

      (def me (get (uniterm/list-windows) 0))
      (def layout
        (uniterm/request-layout
          {:window (me :window) :pane (me :pane)}
          {:split :row
           :children [{:pane (me :pane)}
                      {:open :browser :control :remote-controlled
                       :url "http://127.0.0.1:__PORT__/seeded"}]}))

      (def [_ browser] (layout :panes))
      (uniterm/send-command browser :browser 0 :open {:url "http://127.0.0.1:__PORT__/second"})

      (print (browser :pane))
      (flush)
      (os/sleep 180)
      """, to: template)

    addTeardownBlock {
      for path in [server, portFile, template] {
        try? FileManager.default.removeItem(atPath: path)
      }
    }

    let program = try startController(
      janet: "",
      named: "markers",
      before: """
        /usr/bin/perl "\(server)" "\(portFile)" "__REQUESTS__" &
        waited=0
        while [ ! -s "\(portFile)" ] && [ $waited -lt 100 ]; do
          waited=$((waited + 1))
          sleep 0.1
        done
        sed "s/__PORT__/$(cat "\(portFile)")/g" "\(template)" > "\(scratch)-markers.janet"
        """, in: app)

    let pane = try printedPane(program)
    let group = window.groups["pane-\(pane)"]

    XCTAssertTrue(group.waitForExistence(timeout: 15), "the browser pane never opened")

    let first = element("tab-0-marker-authority", in: group)
    let second = element("tab-1-marker-authority", in: group)

    XCTAssertTrue(first.appears(timeout: 20), "the seeded tab shows no authority marker")
    XCTAssertTrue(second.appears(timeout: 20), "the tab the controller opened shows no marker")
    XCTAssertEqual(first.label, "Controller can act on this tab")
    XCTAssertEqual(element("tab-1", in: group).value as? String, "selected")

    element("new-tab", in: group).click()

    XCTAssertTrue(element("tab-2", in: group).appears(timeout: 10), "the user's tab never opened")
    XCTAssertFalse(
      element("tab-2-marker-authority", in: group).exists, "a tab the user opened was marked")
    XCTAssertTrue(first.exists, "opening a tab cleared the controller's marker")

    keepElementScreenshot(group, named: "Browser pane with two marked tabs and one unmarked tab")
  }

  /// Catches a one-tab pane that shows its marker nowhere, or one that covers the badge. A
  /// controller opens a text viewer. The viewer has no tab bar, so its marker sits just leading of
  /// the pane's control badge, at the same height, and the capture shows the two together.
  func testASingleTabViewerShowsItsMarkerBesideTheBadge() throws {
    try write("PROMPT='%% '\nRPROMPT=''\n", to: scratch + "-shell/.zshrc")

    let app = launchApp()
    let window = mainWindow(in: app)

    _ = waitForTerminal(in: app)
    enableRemoteControl(pane: 1, in: app)

    let program = try startController(
      janet: """
        (declare-permissions {:name "Synthetic Marker Controller"}
          {:kind :pane-control})

        (import uniterm)

        (def me (get (uniterm/list-windows) 0))
        (def layout
          (uniterm/request-layout
            {:window (me :window) :pane (me :pane)}
            {:split :row
             :children [{:pane (me :pane)}
                        {:open :text-viewer :control :remote-controlled :weight 2}]}))

        (def [_ viewer] (layout :panes))

        (print (viewer :pane))
        (flush)
        (os/sleep 180)
        """, named: "viewer-marker", in: app)

    let pane = try printedPane(program)
    let group = window.groups["pane-\(pane)"]

    XCTAssertTrue(group.waitForExistence(timeout: 15), "the viewer pane never opened")
    XCTAssertFalse(element("tab-0", in: group).exists, "a single tab showed a tab bar")

    let marker = element("pane-marker-authority-\(pane)", in: group)
    let badge = window.buttons["pane-control-\(pane)"]

    XCTAssertTrue(marker.appears(timeout: 20), "the viewer's one tab shows no marker")
    XCTAssertTrue(badge.appears(timeout: 10), "the viewer has no control badge")
    XCTAssertEqual(marker.label, "Controller can act on this tab")
    XCTAssertLessThanOrEqual(marker.frame.maxX, badge.frame.minX)
    XCTAssertEqual(marker.frame.midY, badge.frame.midY, accuracy: 2)

    keepElementScreenshot(group, named: "Text viewer with its marker beside the control badge")
  }

  /// Catches tabs that lie out of reach, a wheel or a key that leaves the selected tab hidden, and
  /// a bar that gives no sign of more tabs. A browser pane restored with 14 tabs cannot show them
  /// all. The last tab is out of reach at first. A sideways swipe and a wheel with Shift each move
  /// the tabs, and selecting the last tab by key brings it fully into view, clear of the new-tab
  /// button. The captures show the edge cue at each end.
  func testAnOverflowedTabBarScrollsByTrackpadAndShiftAndKeepsTheSelectedTabInView() throws {
    let titles = (0..<14).map { #"{"url":"about:blank","title":"Tab \#($0)"}"# }
      .joined(separator: ",")

    try plantLayout(
      """
      {"version":1,"windows":[{"frame":{"x":100,"y":100,"width":900,"height":600},"highWaterMark":1,
      "tree":{"kind":"pane","id":1,"applet":{"type":"browser","version":1,
      "payload":{"tabs":[\(titles)],"selected":0}}}}]}
      """)

    let app = launchApp()
    let window = mainWindow(in: app)

    func tab(_ index: Int) -> XCUIElement { element("tab-\(index)", in: window) }

    let newTab = element("new-tab", in: window)

    XCTAssertTrue(tab(0).appears(timeout: 15), "the first tab never showed")
    XCTAssertFalse(
      tab(13).exists && tab(13).isHittable, "the last tab was within reach with no scrolling")

    keepElementScreenshot(
      window, named: "Overflowed tab bar at its start, with the fade on the right")

    let start = tab(0).frame.minX

    func moved(by deltaX: CGFloat) -> Bool {
      sendWheel(deltaX: deltaX, deltaY: 0, at: tab(0), in: window)

      return pollUntil(timeout: 3) { abs(tab(0).frame.minX - start) > 40 }
    }

    XCTAssertTrue(
      moved(by: -400) || moved(by: 400), "a sideways swipe over the tabs moved nothing")

    keepElementScreenshot(window, named: "Overflowed tab bar scrolled by a sideways swipe")

    app.typeKey("1", modifierFlags: .command)

    XCTAssertTrue(
      pollUntil(timeout: 5) { abs(tab(0).frame.minX - start) < 2 },
      "selecting the first tab did not bring it back into view")

    let before = tab(0).frame.minX

    XCUIElement.perform(withKeyModifiers: .shift) {
      sendWheel(deltaY: -300, at: tab(0), in: window)
    }

    XCTAssertTrue(
      pollUntil(timeout: 3) { abs(tab(0).frame.minX - before) > 40 },
      "a wheel with Shift held moved nothing")

    app.typeKey("9", modifierFlags: .command)

    XCTAssertTrue(waitFor(tab(13), timeout: 10) { $0 == "selected" })
    XCTAssertTrue(waitUntilHittable(tab(13)), "the selected last tab stayed out of view")
    XCTAssertLessThanOrEqual(
      tab(13).frame.maxX, newTab.frame.minX + 1, "the selected tab runs under the new-tab button")
    XCTAssertGreaterThanOrEqual(tab(13).frame.minX, window.frame.minX)

    keepElementScreenshot(
      window, named: "Overflowed tab bar with the last tab selected, fade on the left")
  }

  /// Plants a window whose one pane is the marked fixture, with `tabs` tabs, and opens it.
  private func openMarkedFixture(tabs: Int) throws -> (app: XCUIApplication, pane: XCUIElement) {
    try plantLayout(
      """
      {"version":1,"windows":[{"frame":{"x":100,"y":100,"width":900,"height":600},"highWaterMark":1,
      "tree":{"kind":"pane","id":1,"applet":{"type":"fixture-marked","version":1,
      "payload":{"tabs":\(tabs)}}}}]}
      """)

    let app = launchApp(environment: ["UNITERM_TEST_APPLETS": "1"])
    let pane = mainWindow(in: app).groups["pane-1"]

    XCTAssertTrue(pane.waitForExistence(timeout: 15), "the marked fixture never opened")

    return (app, pane)
  }

  /// Catches a run-end marker that shows nowhere, or one that draws without its slash. The marked
  /// fixture publishes one tab that carries the kind, so with no control badge showing the marker
  /// takes the badge's corner. The capture shows the slashed gears there.
  func testARunEndMarkerTakesTheBadgesCornerWhenNoBadgeShows() throws {
    let (app, pane) = try openMarkedFixture(tabs: 1)
    let marker = element("pane-marker-runEnded-1", in: pane)

    XCTAssertTrue(marker.appears(timeout: 10), "the run-end marker never showed")
    XCTAssertEqual(marker.label, "Finished run may still run in this tab")
    XCTAssertFalse(
      mainWindow(in: app).buttons["pane-control-1"].exists, "a badge showed beside the marker")
    XCTAssertGreaterThan(marker.frame.midX, pane.frame.midX, "the marker is not in the corner")
    XCTAssertLessThan(marker.frame.midY, pane.frame.minY + 40)

    keepElementScreenshot(pane, named: "Run-end marker in the badge's corner, slashed gears")
  }

  /// Catches a run-end marker that a tab bar does not draw. The marked fixture holds two tabs, and
  /// the second carries the kind. Its marker is an image beside the title, and the tab stays
  /// unselected. The capture shows the slashed gears in the bar.
  func testARunEndMarkerShowsInATabBar() throws {
    let (_, pane) = try openMarkedFixture(tabs: 2)
    let marker = element("tab-1-marker-runEnded", in: pane)

    XCTAssertTrue(marker.appears(timeout: 10), "the run-end marker never showed in the bar")
    XCTAssertEqual(marker.label, "Finished run may still run in this tab")
    XCTAssertFalse(element("tab-0-marker-runEnded", in: pane).exists)
    XCTAssertEqual(element("tab-1", in: pane).value as? String, "unselected")

    keepElementScreenshot(pane, named: "Run-end marker in a tab bar, slashed gears")
  }
}
