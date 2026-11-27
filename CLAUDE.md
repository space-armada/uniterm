# uniterm

uniterm is a unified terminal emulator for macOS. See [README.md](README.md) for the overview.

## Coding Standards

@~/.claude/coding-standards-current/profiles/swift-macos-app.md
@~/.claude/coding-standards-current/languages/lisp.md
@~/.claude/coding-standards-current/languages/janet.md
@~/.claude/coding-standards-current/languages/lisp-embedding.md

These imports stand in for a future `swift-macos-janet-host` profile. Promote them to a real profile once the
combination is proven here.

## Stack Decisions

- Swift is the host language.
- AppKit owns the window, the pane tree, and applet hosting. The `swift-macos-app` profile assumes SwiftUI. Here, its
  SwiftUI rules apply only to SwiftUI code.
- SwiftUI is allowed for small leaf views, such as status bar segments and widgets.
- libghostty provides terminal emulation. Its API is unstable. Pin it to an exact version.
- Janet is the embedded scripting language. It backs the REPL applet and the scripting API.

## Applet Attributes

- When an applet has a concept such as a current directory, that value flows explicitly through the applet contract.
  It never rides on hidden behavior in a library, such as libghostty passing state from one terminal to the next.
- uniterm need not sit in the middle of everything. Not every attribute needs plumbing, and not every behavior needs
  a setting.
- Whenever implicit inheritance or hidden state flow turns up, raise it with the user as an explicit decision, either
  way. Do not silently keep it or silently replace it.

## UI Feedback

uniterm is UI-heavy, so the user's hands-on reviews produce a steady stream of tweaks.

- A UI change from a review does not need a proposal. Building it now is always one of the options offered.
- Default to building visual and interaction polish directly. Review, test, and commit it like any other change.
- A mockup first helps when the change is a new interaction. A Design canvas artifact works for this.
- Keep proposals for changes to contracts, ADRs, or rules that cut across applets, such as shortcut ownership.

## External Versions

- Every external version stays at 0 until uniterm's maintainers declare it version 1. An external version is one that a
  program or file uniterm does not build names or checks. See UTERM-063 and "Wires and versions" in `docs/glossary.md`.
- The declared-stable list is `spec/declared-stable-versions.md`. Only uniterm's maintainers add to it, and an addition
  is the declaration. A session never adds to it to make `scripts/check-external-versions.sh` pass.
- A breaking change to an external interface at 0 lands in place, without a new version. An older program's message is
  read with its old meaning or refused, never reinterpreted.

## Queue Rows That Wait on CI

- Some queue rows wait on something only CI can produce, such as a failed job or a count of clean runs. Their note
  names `make ci-waiting-evidence`.
- A `/work-queue` run runs `make ci-waiting-evidence` once, while it plans. The command reads GitHub, so it needs the
  sandbox off.
- A row whose line says WAITING is held for that run, the way a run note holds a proposal. Pass `--hold` for its
  proposal to `proposals.py next`. The row takes no `next N` slot, runs no milestone, and gets no report. The plan
  names it as held in one line.
- A row whose line says FIRED runs as usual. So does a waiting row the user names by its ID.
- No run repeats a test or reruns a CI job to make a row's trigger fire.
- The clean count the command prints is a floor. The closing rule in `spec/flaky-tests.md` decides the real count.
- When a waiting row finishes, remove its check from `scripts/ci-waiting-evidence.sh`.

## Git

- You may commit without asking first.
- Keep each commit to one logical change.
- Pushing still needs approval.
