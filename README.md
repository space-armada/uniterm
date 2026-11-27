# uniterm

uniterm is a unified terminal emulator for macOS. It goes beyond a plain terminal.

A window holds a tree of resizable split panes. Each pane runs one applet. Planned applets include a terminal, a
browser, a data viewer, an image viewer, a text viewer, a map viewer, and a REPL. The REPL scripts uniterm itself in
Janet, a Lisp. See [docs/repl.md](docs/repl.md) for using it. [docs/glossary.md](docs/glossary.md) defines the terms
the docs and specs use.

Each window also has a status bar and a command palette. Both can be docked in different places.

## Status

Early development. The terminal applet runs through libghostty, with tabs and a program mode. A window holds splits that
can be resized, and the app opens several windows. It has a status bar with message history, undo for a closed pane, and
close guards for running programs. Every window's layout is saved and restored across launches. A data viewer opens
CSV, JSON, and `.xlsx` files as tables that sort, filter, and search. The other applets and the command palette are not
built yet.

## Stack

- Swift, with AppKit for windows, panes, and applet hosting.
- SwiftUI for small views, such as status bar segments.
- [libghostty](https://ghostty.org) for terminal emulation.
- [Janet](https://janet-lang.org) for scripting.
- [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) for the ZIP container of `.xlsx` files. It is the only
  third-party Swift package. It is pinned to an exact version, and its notice ships in `Licenses/`.

## Building

Prerequisites:

- macOS 26 and Xcode 26.6 (build 17F113). Select it with `xcode-select`.
- The Metal toolchain: `xcodebuild -downloadComponent MetalToolchain`.
- Network access on a cold cache, so the build can download the Zig that `ghostty.pin` names. The first build and
  every Ghostty upgrade need it. That Zig lives in the build's own cache, and the build never uses or changes a Zig
  installed on the machine.

Commands:

- `make build` builds the pinned libghostty, then `uniterm.app`, into `.build/DerivedData`.
- `make run` builds, then runs the app in the foreground, so its logs and any crash show in the terminal.
- `make test` runs the CI gating checks, package tests, and app UI tests. UI tests need a logged-in desktop session
  and Accessibility permission for the terminal. The UI tests build into `.build/DerivedData-test`, so their test
  signing never reaches the app that `make build` leaves. `make test-ci` runs just the CI gating checks, without Xcode or Zig.
- `make test-app-select UI_TESTS='...'` and `make test-package-select PACKAGE_TESTS='...'` run only the named tests.
  See "Testing while iterating" below.
- `make fuzz` runs the table readers' fuzzer under the address sanitizer, in its own build folder. It tries
  `FUZZ_ITERATIONS` mutated inputs, 5000 by default. `make test-package` runs the same fuzzer at a small count. `make ci`
  does not run `make fuzz`.
- `make fmt`, `make fmt-check`, `make lint`, and `make check` format and check the sources.
- `make ghostty-offline-check` proves that the pinned libghostty rebuilds with the network off. It takes about four
  minutes, and `make ci` runs it.
- `make ci` runs every CI job. `make ci-package` runs the package job, and `make ci-app` runs every UI test. CI splits the
  UI tests into three shards that run in parallel. A failed shard reruns with `make test-app-shard SHARD=n SHARDS=3`.
- `make swiftpm-offline-check` proves that the Swift packages resolve and build with the network off. The versions come
  from the committed `Package.resolved` files and the sources from `.cache/swiftpm`. It takes under a minute, and
  `make ci` runs it. CI does not keep `.cache/swiftpm`, so a CI run fetches the packages once before the offline step.
- `make help` lists every target.

GitHub CI runs three macOS jobs side by side: `package` for the checks, package tests, and helper sandbox tests; `app`
for the UI tests in three shards; and `ghostty-offline` for the offline Ghostty rebuild. The rebuild runs only when no
earlier run proved the same Ghostty inputs on the same runner image. Otherwise the job ends in seconds. The required
`ci` check passes only when all shards pass.

CI skips the macOS jobs when all changed files are root-level Markdown or Markdown under `spec/`. The lightweight
`ci` check still reports a result. Markdown shipped in the app, such as files under `Licenses/`, still triggers the
full build. Manual workflow runs always build fully. Missing comparison history also falls back to the full build.

`ghostty.pin` records the Ghostty commit and the toolchain that built it. The build fails when the downloaded Zig does
not match `ZIG_SHA256`, or when Xcode or the SDK differ from the pin. It also fails when the extracted Ghostty source does not
match `GHOSTTY_TREE_SHA256`, a hash over every file in the source tree. To bump the pin, set `GHOSTTY_TAG` and
`GHOSTTY_COMMIT`, run `scripts/build-ghostty.sh tree-hash`, record its output as `GHOSTTY_TREE_SHA256`, then update the
toolchain fields.

The libghostty build, the pinned Zig, its package cache, and the artifacts live under `.cache/ghostty`. A rebuild of the pinned
commit needs no network once that cache exists.

### Testing while iterating

The full UI suite takes about 27 minutes, and the package tests about 2. While iterating on a feature or a fix, run
only the tests the change touches:

```sh
make test-app-select UI_TESTS='TabsUITests PaneTreeUITests/testCommandZLeavesAClosedPaneClosed'
make test-package-select PACKAGE_TESTS='LayoutStoreTests'
```

`UI_TESTS` takes UI test class names, or `Class/testMethod` for a single test. `PACKAGE_TESTS` takes `swift test`
filters. Each name becomes its own `--filter`. Both targets fail when their list is empty, so a partial run never
stands in for a full one.

Pick the classes from what the diff touches, plus any new test. Run the full `make test-app` and `make test-package`
before calling the work done. Run them earlier when a change touches shared UI test helpers or app-wide code.

### Hand checks

Some checks need a person at the Mac. Examples are how a view looks, a trackpad or mouse gesture, a real sign-in, or
VoiceOver. Reports and proposals leave these to the user. The `hand-checks` Claude Code skill in
`.claude/skills/hand-checks/` finds the ones with no record of being done. It writes a guide for each, and builds a
bundle outside the repo that testers can zip and share. The bundle holds an offline page for recording verdicts, and a
`launch.sh` that builds the app and starts it with throwaway state. Testers need only a clone that `make build` works
in. The generated checks are never committed. Each round regenerates them from the current proposals and reports.

## License

MIT. See [LICENSE](LICENSE).
