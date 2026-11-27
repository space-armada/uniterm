---
name: hand-checks
description: Regenerate the hand-check bundle. Find every check that only a person can make (visual looks, real hardware, real accounts, VoiceOver) that the reports and proposals left to the user and that has no record of being done, then write step-by-step guides, fixtures, and helper scripts for each, and build an offline HTML runner that testers use to record verdicts. Also ingests results files that testers send back. Triggers: "regenerate the hand checks", "build the hand-check bundle", "what hand checks are outstanding", "ingest these hand-check results".
---

# Hand checks

A hand check is a check no automated test can make. A person looks at the real app, or uses real hardware, a real
account, or VoiceOver. Runs and reports leave these "to the user", and nothing else tracks them. This skill finds the
open ones, writes a guide for each, and builds a bundle that testers unzip and run.

The bundle is generated output. It is never committed. This skill and its `assets/` are the only committed parts.

## Output

Write the bundle to `~/tmp_work/uniterm-hand-checks-<YYYYMMDD>/` unless the user names another place. That folder is
outside the sandbox's write list, so build in the scratchpad and copy it there with one unsandboxed `cp -R` at the
end. If a bundle from an earlier run exists, ask whether to reuse its checks before starting (see step 3).

The bundle layout, the `check.json` format, the launch modes, and the fixture rules are in `assets/CONTRACT.md`. Read
it first. Every writer follows it.

## 1. Harvest candidates

Read the sources. Do not rely on a fixed list from an earlier run.

- `spec/reports/*.md`: sections and lines saying "left to the user", "left for the user", "checks left to the user",
  "for the user", "left open", "visual check", "hand check", "hands-on", "by hand", "untested", "unverified", "real
  hardware".
- `spec/proposals/*.md` As built blocks: "Left to the user", "the user checks", "the user's eyes", and milestones
  titled "The user's check". A report and its proposal often disagree in detail. The proposal's As built is usually
  more complete.
- Extract whole sections, not grep lines. A grep cut at 200 characters hides the sentence that says a check was done.
  An awk pass that prints each matching heading through the next heading of the same level works well.

Leave out "left for the user" items that are decisions, such as ADR candidates, freeze hunks, or wording choices.
They are not hand checks.

## 2. Sort each candidate

Look for evidence before calling anything outstanding:

- The proposal's Decision Log: entries such as "the user ran the visual check", "the user's choice in a hands-on
  review", "the user confirmed".
- A report's "The user's hand check", "Hands-on review", or "the user's checks" section.
- `spec/proposals/history.md`.
- `git log -i --format='%ad %s' --date=short -E --grep='visual check|hand check|hands-on|user.s check'`.
- A later proposal that superseded the behavior, from "Superseded in part" markers and the index.

Each candidate lands in one bucket:

- **no-record**: nothing says it was done. Say "no record", never "not done".
- **partial**: a review covered part of it. The check's notes say what was covered and when.
- **done**: cite the evidence, and drop it.
- **obsolete**: the behavior is gone. Cite the change, and drop it.
- **scheduled**: its milestone is NOT STARTED. Leave it to that milestone.

Show the user the buckets in chat before writing guides, then go on without waiting unless something needs a
decision.

## 3. Reuse an earlier bundle

When an earlier bundle exists, its `checks/*/check.json` files are a head start. For each still-outstanding candidate
with a matching check, give the writer that file to re-verify against current code instead of writing from scratch.
Drop checks whose candidate is now done or obsolete. A results file the testers sent back is evidence too. Ingest it
first, per "Ingesting results".

## 4. Write the checks

Split the candidates into at most 6 groups along proposal lines, and start one `general-purpose` agent per group in
parallel. Give each the brief in `assets/BRIEF.md`, filled in with its candidates and their sources by file and line.

While they run, copy `assets/index.html`, `assets/launch.sh` (to `scripts/launch.sh`), `assets/build.py` (to
`tools/build.py`), `assets/README.md`, and `assets/CONTRACT.md` into the bundle. Make the two scripts executable.

## 5. Verify the writers' work

Writers read code but never run the app, so their reports carry claims to check:

- Every bug a writer reports: check it against the code before filing. File confirmed ones in `spec/bugs/` per the
  project's bug format, add an index row, and commit each in its own commit. A claimed bug can be intended behavior,
  so read the code's own docs first.
- Helper scripts that reach the app's socket: the listener is `<script folder>/<pid>.sock`. `launch.sh` exports
  `UHC_SOCKET_DIR` and writes the pid to `$UHC_STATE/app.pid`.
- Anything a writer could not confirm in code stays hedged in the check's notes, so testers record what they see.
- Grep the bundle for personal paths and names before copying it out.

## 6. Build and test

1. `python3 tools/build.py` in the bundle. It validates every check and writes `checks.js`, each `GUIDE.md`, and
   `CHECKS.md`. Fix every problem it lists.
2. Test the runner in headless Chrome with `assets/harness.js`. Copy `index.html` to `_test.html` with
   `<script src="../harness.js"></script>` before `</body>`, put `harness.js` beside the bundle, and run Chrome with
   `--headless=new --user-data-dir=<temp> --allow-file-access-from-files --virtual-time-budget=4000 --dump-dom`. The
   harness prints its results into `#harness-out`. Chrome needs the sandbox off. Take `--screenshot` captures in
   light and with `--force-dark-mode`, and look at them. Delete `_test.html` and any test `stamp.js` afterwards.
3. Copy the bundle out with one unsandboxed `cp -R`.

## 7. Report

Tell the user:
- the bundle path and check count by proposal
- what changed from the harvest: new, carried over, done, obsolete
- bugs filed, by file name, and claimed bugs that proved to be intended
- what no one has run yet, such as helper scripts never run against the real app

## Ingesting results

Testers send `results-<name>-<scope>-<date>.json` files, in the format `uniterm-hand-check-results`. For each result:

- **Pass**: add an As built line to the proposal's milestone, such as "On <date> <tester> ran the hand check <id> on
  <commit>, and it passed." Use the stamp's commit and the result's date.
- **Pass with changes**: the note is UI feedback. Build it as polish under the project's UI Feedback rule.
- **Fail**: reproduce it, then fix it or file it in `spec/bugs/`.
- **Couldn't run**: the check stays outstanding. Note what blocked it.

Commit the proposal edits by path. Never commit the results file or the bundle.

## Pitfalls seen before

- Only a Debug build honors the `UNITERM_` isolation variables. `launch.sh` always builds Debug.
- uniterm scrubs `UNITERM_` and `GHOSTTY_` variables from what its shells inherit. Helpers use the `UHC_` names.
- Never start the app with `&` from a script. A background job starts with SIGINT ignored, and the app's terminals
  inherit it, so Ctrl-C stops working.
- The browser's website data store is the real one unless a check passes `--env UNITERM_BROWSER_STORE=memory`.
- `launch: real` checks are for Finder, Dock, and Spotlight launches. Launch Services picks whichever uniterm.app it
  registered, so other copies must be quit.
- Writers sometimes tune a check to current code where the proposal says otherwise. When code and proposal disagree,
  that is a candidate bug, not a guide detail.
