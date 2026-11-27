# Writer brief

Fill in the bracketed parts and send it to one `general-purpose` agent per group.

---

You are writing step-by-step manual test guides ("hand checks") for uniterm, a macOS terminal app at
`/Users/ripta/projects/uniterm`. Human testers will follow them in the running app and record a verdict in an
offline HTML runner. Testers build with `make build` from their own clone.

Read the contract first: `[bundle]/CONTRACT.md`. Write every file under `[bundle]`, following it exactly:

- one `checks/<id>/check.json` per check
- fixtures under `fixtures/<area>/`
- helper scripts under `scripts/<area>/`

Do not write GUIDE.md; `tools/build.py` generates it. You may call `build.py`'s `validate()` on your own checks, but
do not run the full build. Do not edit anything in the repo, and do not commit. Do not launch the app. Take every menu
title, command name, shortcut, setting label, and message text from the source code (`App/`,
`Packages/UnitermKit/Sources/`) and the proposals.

Your scope: [proposal ids and titles]. These are the candidates and where they come from:

[For each candidate: the milestone, the item as written, its source by file and line, and its bucket: no-record or
partial. For partial, the evidence of what was already covered.]

[For a check carried over from an earlier bundle: "Re-verify `<path>/check.json` against current code and keep what
still holds."]

Rules:

- Read the Decision Log and any later proposal that superseded part of this one. Expected results describe current
  intended behavior, not superseded text.
- When code and proposal disagree, do not pick one silently. Report it as a candidate bug.
- If an item is obsolete or provably done, write no check for it, and report it with file and line evidence.
- Split items into separate checks when they could pass or fail independently.
- Expected results are things a person can see or hear, stated so that two testers would agree.
- Fixtures are synthetic. Ship the generated file and its generator. Keep each under 2 MB.
- A helper that talks to the app uses `UHC_SOCKET_DIR` and `$UHC_STATE/app.pid`. The socket is `<pid>.sock`. A
  helper that signals the app reads `app.pid`, and never matches processes by name.

When done, reply with:

- the check ids you wrote, with each one's bucket
- the fixtures and scripts, with sizes
- any item you judged obsolete or already done, with evidence
- every candidate bug, with file and line
- every UI name or behavior you could not confirm in code
