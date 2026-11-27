# uniterm hand checks

These are checks that no automated test can make. Each one needs a person at a Mac, looking at the real app or
using real hardware. Each check has a guide with numbered steps and the results to look for. You record a verdict for
each check in a page that runs offline in your browser.

## Before you start

1. Clone uniterm and make sure `make run` builds and starts it. Every check builds the same way.
2. Unzip this bundle anywhere. It does not need to sit inside the checkout.
3. Open `index.html` in Safari or Chrome. Enter your name, then pick the proposal you were assigned.

You can also read the guides without the page. `CHECKS.md` lists them, and each one is `checks/<id>/GUIDE.md`. In a
guide, `<bundle>` stands for the folder this README is in. The page fills in the real path for you.

## Running a check

1. Read the check's goal, notes, and needs. If you lack something it needs, such as a second display, record
   **Couldn't run** and say what was missing.
2. Launch the app with the command the page shows. Run it from the root of your uniterm checkout:

   ```
   /path/to/bundle/scripts/launch.sh <check-id>
   ```

   It builds with `make build`, records which commit you built, and starts uniterm in the foreground. The terminal
   you ran it from shows the app's log, and quitting uniterm ends the script.
3. Press **Reload stamp** in the page. The toolbar then shows the commit you built. Each verdict records it.
4. Follow the steps. Tick each expected result you saw.
5. Pick a verdict and write a note.

### What the launch does to your data

Most checks run with a throwaway state folder under `.build/hand-checks/<check-id>/` in your checkout. They do not
touch your own uniterm settings, saved layout, or remembered approvals. Checks that test a relaunch keep that
folder between launches until you pass `--fresh`.

A few checks must use your real settings, because Finder, the Dock, or Spotlight starts the app. The page marks
these "your real settings and data". The browser checks use your real browser store, so a site you sign in to stays
signed in until you remove its data.

Options:

- `--fresh` wipes the check's state folder first.
- `--no-build` skips the build, for a quick relaunch.
- `--env KEY=VALUE` passes a setting through to the app. A guide says when you need it.

## Verdicts

- **Pass**: it works as the expected results say.
- **Pass with changes**: it works, but you would like something different. Say what, and why.
- **Fail**: it is broken. Pick the step where it went wrong, and say what happened and what you expected.
- **Couldn't run**: you could not do the check, such as missing hardware or a setup step that failed. Say what
  stopped you.

A milestone takes the worst verdict among its checks. Fail is worst, then Pass with changes, then Couldn't run, then
Pass.

## Screenshots

Paste or drop screenshots into a check's verdict box. Capture only uniterm's window, never your whole screen: press
Cmd-Shift-4, then Space, then click the window. The page scales them down and keeps them with your results.

## Sending results back

Press **Export results**. The page saves a file named `results-<name>-<proposal>-<date>.json`, with your
screenshots inside it. Send that file back. **Summary** gives a short text version for a chat message.

Your results stay in this browser until you clear its site data, so you can stop and pick up later. To move to
another browser or Mac, export, then use **Import results** there. An import keeps whichever copy of each result is
newer.

## If something goes wrong

- If the app crashes, `launch.sh` prints the signal. Crash reports are in `~/Library/Logs/DiagnosticReports`,
  named `uniterm-*.ips`. Attach the newest one's name and the crashed thread to your note.
- If a guide's step does not match what you see, such as a menu item with another name, that is worth a Fail or a
  Pass with changes. Say what you saw instead.
