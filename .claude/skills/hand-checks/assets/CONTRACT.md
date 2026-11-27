# Hand-check bundle contract

This is the working contract for whoever writes checks into this bundle. It is not shipped to testers.

## Layout

```
bundle/
  index.html            the offline runner (coordinator writes it)
  checks.js             generated from checks/*/check.json by tools/build.py
  stamp.js              appended by scripts/launch.sh on each launch
  README.md             tester instructions (coordinator writes it)
  checks/<id>/check.json   one check, the single source of truth
  checks/<id>/GUIDE.md     generated from check.json, never hand-edited
  fixtures/<area>/...      synthetic files the checks use
  scripts/launch.sh        builds and launches uniterm for a check (coordinator writes it)
  scripts/<area>/...       helper scripts a check runs (servers, drivers, crash senders)
  tools/build.py           generator (coordinator writes it)
```

`<area>` is the proposal id in lowercase, such as `uterm-005`.

## Check ids

`<proposal>-<milestone>-<slug>`, lowercase, such as `uterm-005-m2-mixed-content-warning`. The slug is 2 to 5 words.

## check.json

```json
{
  "id": "uterm-005-m2-mixed-content-warning",
  "proposal": "UTERM-005",
  "proposalTitle": "WebKit browser applet",
  "milestone": "M2",
  "milestoneTitle": "Security indicator",
  "title": "An HTTPS page that loads insecure content shows the warning",
  "source": "spec/proposals/UTERM-005-browser-applet.md, M2 As built",
  "status": "no-record",
  "goal": "One or two sentences: what this check proves and why no automated test proves it.",
  "needs": ["network"],
  "launch": "isolated",
  "setup": ["Run `scripts/launch.sh uterm-005-m2-mixed-content-warning` from the repo root."],
  "steps": ["Numbered steps, one action each."],
  "expected": ["Observable results the tester can tick yes or no."],
  "cleanup": ["Optional."],
  "notes": "Optional. Caveats, known limits, what a fail usually looks like.",
  "fixtures": ["fixtures/uterm-005/mixed.html"]
}
```

- `status` is `no-record` or `partial`. For `partial`, `notes` says what was already checked and when.
- `needs` uses this vocabulary only: `network`, `second-display`, `physical-mouse`, `trackpad`, `voiceover`,
  `ssh-host`, `docker`, `web-account`, `finder`, `keychain`, `xcode`, `pages`. An empty list means a plain Mac.
- `launch` is one of:
  - `isolated`: a throwaway state folder, wiped on each launch.
  - `isolated-persistent`: a state folder kept across launches of the same check, for relaunch and restore checks.
    `scripts/launch.sh <id> --fresh` wipes it.
  - `real`: the tester's real settings, layout, and browser store. Use only when the check cannot work isolated, such
    as Finder, the Dock, or Spotlight starting the app. `notes` must say why.
  - `none`: no app launch, such as the Xcode cold-checkout check.
- Text fields take a small markdown subset: `` `code` ``, `**bold**`, and `[text](url)`. Nothing else.
- Steps never say "verify it looks right". Each expected item is something a person can see or hear, stated
  plainly enough that two testers would agree.
- Name every menu item, command, shortcut, and setting exactly as the code spells it. Read the source to get it.

## scripts/launch.sh

Testers run it from the root of a uniterm checkout. It never assumes the bundle sits inside the repo.

```
<bundle>/scripts/launch.sh <check-id> [--fresh] [--no-build] [--env KEY=VALUE]... [-- <app args>]
```

- It runs `make build`, which is the Debug configuration. Debug builds honor the isolation variables.
- It stamps the build (commit, dirty flag, branch, macOS version) into `<bundle>/stamp.js`.
- For `isolated` and `isolated-persistent`, it sets, under `.build/hand-checks/<check-id>/`:
  `UNITERM_DEFAULTS_PATH`, `UNITERM_TERMINAL_DIR`, `UNITERM_LAYOUT_DIR`, `UNITERM_BROWSER_DIR`,
  `UNITERM_CONTROLLER_RUNS_DIR`, `UNITERM_CONTROLLER_POLICY_DIR`, and `UNITERM_SENT_DIR`. It sets `UNITERM_SCRIPT_DIR`
  to a short folder under `/tmp`. It does not set `UNITERM_BROWSER_STORE`, so the browser store is the real one
  unless a check passes `--env UNITERM_BROWSER_STORE=memory`.
- It exports `UHC_CHECK=<check-id>`, `UHC_BUNDLE=<bundle path>`, and `UHC_STATE=<state folder>`, and for isolated launches `UHC_SOCKET_DIR=<the /tmp/uhc-* script folder>`, so a shell inside
  uniterm can reach the fixtures as `$UHC_BUNDLE/fixtures/...`. The app scrubs `UNITERM_` variables from what its
  shells inherit, so helpers must use the `UHC_` names.
- It writes the app's pid to `<state folder>/app.pid` and to `<bundle>/.last-launch-pid`. A helper that signals the app
  reads one of these. It never matches processes by name.
- It runs the app binary in the foreground, so the terminal that launched it shows logs and any crash. Quitting the
  app ends the script.
- A seed of settings goes in with `--env UNITERM_DEFAULTS_SEED='{"key":"value"}'`.

A check that needs a second instance, a crash, or a relaunch says so in its steps. A second `launch.sh` with the same
id in another terminal tab shares the state folder.

## Fixtures

- Synthetic content only. No real names, hosts, paths, credentials, or photos of people.
- Ship generated files, and keep the generator beside them as `make-<name>.sh` or `.py`, runnable from any directory.
- Keep each file small. A fixture over 2 MB needs a reason in the check's `notes`.
- A helper script resolves its own folder with `"$(cd "$(dirname "$0")" && pwd)"`, never `pwd`.
