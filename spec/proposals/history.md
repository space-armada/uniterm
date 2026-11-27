# History

| Milestones | Depends on | Note |
|------------|------------|------|
| UTERM-001 M1-M10 | None | M9 is the user's visual check |
| UTERM-002 M1-M3 | None | |
| UTERM-013 M1-M2 | UTERM-002 M1 | Needs the command registry UTERM-002 M1 builds |
| UTERM-014 M1 | None | Review fixes from the user's hands-on check |
| UTERM-015 M1-M3 | None | Split at M3: M4-M7 wait on UTERM-004 M6's approval flow and permission set, and M8, a hand check with no dependency, is also left |
| UTERM-015 M8 | None | The user records the sender each Finder and Dock path reports, and checks a Finder drag onto the app icon and a Dock drop by hand. Its result can reopen "Opens that arrive through Launch Services" before M7 builds on it |
| UTERM-009 M1-M4 | None | |
| UTERM-008 M1-M2 | None | Split at M2: M3 needs the exec driver and applet command hook from UTERM-004 M3 |
| UTERM-016 M1-M3 | None | Built from the map review outside the queue. M4 waits on UTERM-008 M3 |
| UTERM-017 M1-M3 | None | Sets the notice contract the queued viewers and UTERM-004 build on. M2 lands before UTERM-004 adds driver stderr |
| UTERM-005 M1-M7 | None | Split at M7: M8 needs the control permissions from UTERM-004 M6 |
| UTERM-006 M1-M3 | None | Split at M3: M4's control and exec support need UTERM-015 M4's read power |
| UTERM-007 M1-M4 | None | Split at M4: M5's remote commands need UTERM-004 M3 |
| UTERM-003 M1-M5 | None | |
| UTERM-004 M1-M6 | UTERM-003 | Needs the host API and listener UTERM-003 builds. Placed right after it to close the same-user control window UTERM-003 M3 opens |
| UTERM-021 M1-M5 | None | |
| UTERM-007 M5 | UTERM-004 M3 | Split from M1-M4: waits on remote-controlled panes and the applet command hook from UTERM-004 M3 |
| UTERM-015 M4-M7 | UTERM-004 M6 | Split from M1-M3: M4's read power, M5's approvals, and M7's Launch Services approvals need UTERM-004 M6, and M5 needs UTERM-003 M3, which that row follows |
| UTERM-006 M4 | UTERM-015 M4 | Split from M1-M3: waits on UTERM-015 M4's read power, after UTERM-003 M2 and UTERM-004 M3 |
| UTERM-036 M1 | None | Landed with the ADR-12 retraction, before the proposal was filed |
| UTERM-008 M3 | UTERM-004 M3 | Split from M1-M2: waits on the exec driver and applet command hook from UTERM-004 M3 |
| UTERM-005 M8 | UTERM-004 M6 | Split from M1-M7: waits on UTERM-004 M6, which builds descriptor format 2 for M8's browser permissions |
| UTERM-037 M1 | None | Follows ADR-12's retraction through the browser's remote commands, which UTERM-005 M8 just built |
| UTERM-038 M1 | None | Follows ADR-12's retraction into the map's set-region and the browser's layout seed |
| UTERM-022 M1-M4 | UTERM-021 M4 | M3's question-only session builds on UTERM-021 M4's strict mode, begins, and command authentication |
| UTERM-022 M5 | UTERM-022 M4 | The user's own checks in the running app, split from M2 and M4 |
| UTERM-045 M1 | None | Split from M2: M1 writes the closing rule and recounts the launcher test's clean CI runs. M3 carries the count |
| UTERM-044 M1 | None | Shards CI's UI tests first, so every later row gets a shorter run and a shorter flake rerun |
| UTERM-060 M1-M3 | UTERM-044 M1 | M1's kept-log upload builds on UTERM-044 M1's per-shard jobs, so it is built once |
| UTERM-046 M1-M2 | UTERM-045 M1 | Its flaky-entry checks close by the rule UTERM-045 M1 writes into `spec/flaky-tests.md` |
| UTERM-046 M4 | None | Split from M3: the product's kills move to the guarded signal call, and M3's sender wraps that call |
| UTERM-044 M2 | UTERM-044 M1 | Needs a pushed CI run of M1's shards |
| UTERM-060 M4 | UTERM-060 M3 | Needs a pushed CI run of M1's kept-log upload |
| UTERM-046 M3 | UTERM-046 M2, UTERM-046 M4 | Split from M1-M2 and M4: moves test sites onto M2's fixture handle and M4's guarded call |
