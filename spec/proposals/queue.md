# Queue

| Milestones | Depends on | Note |
|------------|------------|------|
| UTERM-044 M3 | UTERM-044 M2 | Needs a shard to fail on CI. It advances only when one does |
| UTERM-060 M5 | UTERM-060 M2 | Needs a Cmd-T stall with recording on. It advances only when the shortcut test stalls |
| UTERM-060 M6 | UTERM-060 M4 | Needs a shard to fail on CI. It advances only when one does |
| UTERM-046 M3 | UTERM-046 M2, UTERM-046 M4 | Split from M1-M2 and M4: moves test sites onto M2's fixture handle and M4's guarded call |
| UTERM-045 M3 | UTERM-045 M1 | Split from M1: the count gates M2. It advances only as pushed CI runs accumulate. A later run recounts |
| UTERM-045 M2 | UTERM-045 M3, UTERM-044 M1 | Split from M1: starts once M3's clean count is met. After UTERM-044 M1, so its own count runs on shards and never spans that landing |
| UTERM-063 M1-M2 | None | Placed before UTERM-043 M1, the first row that changes an external wire. In-place wire changes below it land after M2 |
| UTERM-067 M1-M2 | None | Before UTERM-032 M2, which stores folder approvals in the one store M2 builds. Beside UTERM-063 M1-M2, so the two store breaks can ship together |
| UTERM-043 M1 | None | Split from M2: M1 builds only on today's control code. M2 checks it against newer features |
| UTERM-041 M1-M2 | None | |
| UTERM-042 M1-M3 | UTERM-041 M2 | M2 builds on UTERM-041 M1's tab bar and markers. M3 builds on its chip. M1 needs neither |
| UTERM-054 M6 | None | Split from M1-M5: M6 amends UTERM-019 and must land before UTERM-019 M1 ships |
| UTERM-054 M1-M4 | None | Split from M5 and M6: M1-M4 need nothing from UTERM-019. M2 builds the full-page route if UTERM-019 M4 has not |
| UTERM-018 M1-M2 | None | Split from M3-M5: M1 builds the walk and the shared metric that UTERM-061 and UTERM-064 reuse. M2's links open browser tabs, which need no viewer tabs |
| UTERM-069 M1-M2 | UTERM-063 M2, UTERM-067 M2, UTERM-054 M4 | Placed before UTERM-019 so every program-facing row builds on the three source kinds and without Grant Access. Needs UTERM-054 M4's terminal tab owners for a tab source's scope |
| UTERM-064 M1 | UTERM-069, UTERM-018 M1, UTERM-054 M4, UTERM-063 M2 | Placed before UTERM-019 and every program-facing row, so they build on named targets and opaque identities once. Uses UTERM-018 M1's nearest-pane metric, moved up for it. UTERM-062 waits on it |
| UTERM-019 M1-M2 | None | Split from M3: M1-M2 need nothing from UTERM-041 or UTERM-042 |
| UTERM-019 M3 | UTERM-041 M1, UTERM-042 M2 | Split from M1-M2: M3 publishes the run-end marker. It needs UTERM-041 M1's slot and UTERM-042 M2's "Rebuild Tab" menu, so the marker never ships without a way to rebuild the tab |
| UTERM-054 M5 | UTERM-019 M3 | Split from M1-M4: M5 needs UTERM-019 M3's handles, read-result, and byte type |
| UTERM-019 M4-M6 | None | Split after M3: these follow M3 in order and need nothing more from these proposals |
| UTERM-020 M1-M9 | UTERM-019 M6 | Its Dependencies name UTERM-019 whole, including trusted input. M1 starts after UTERM-019 M1 |
| UTERM-032 M1-M2 | None | |
| UTERM-034 M1 | UTERM-032 | M1 amends UTERM-032's input-file sections and moves its input-file mark onto the bytes the command reads |
| UTERM-057 M1 | UTERM-034 M1 | Reuses the chunk messages UTERM-034 M1 builds. Its ScriptWire change lands in place at version 0, after UTERM-063 M2 |
| UTERM-024 M1-M2 | UTERM-032 | New permission kinds follow UTERM-032's rule on where a kind may appear |
| UTERM-030 M1-M2 | UTERM-032, UTERM-024 | Slide images load from UTERM-032's granted folder. The Markdown page opts in to UTERM-024's controller keys |
| UTERM-025 M1 | UTERM-024, UTERM-030, UTERM-032 | The presenter needs UTERM-024's commands and keys, UTERM-030's slides, and UTERM-032's deck argument |
| UTERM-026 M1-M4 | UTERM-024, UTERM-025, UTERM-032 | The presenter view extends UTERM-025's controller across two windows |
| UTERM-028 M1 | UTERM-024, UTERM-063 M2 | Exec drivers gain UTERM-024's commands, keys, and events. Its frames land in place at version 0, after UTERM-063 M2's strict decoders |
| UTERM-065 M1-M2 | UTERM-063 M2 | Its read frames land in place at version 0, after UTERM-063 M2's strict decoders. Placed beside UTERM-028 M1, the other driver frame work |
| UTERM-066 M1 | UTERM-063 | Split from M2-M3: the package declaration lands in place at version 0, after UTERM-063's reset. Placed beside UTERM-065, the other driver work |
| UTERM-055 M1 | UTERM-028 M1, UTERM-054 M5, UTERM-019 M3 | Needs UTERM-028 M1's driver grant and queued-frame drop, and UTERM-054's capture. Its frames land in place at version 0, after UTERM-063 M2, which UTERM-028 M1 already waits for. UTERM-019 M3 gains the check for the `data` and `offset` keys, and builds the read hold M1 reuses. UTERM-054 M5 builds the read-scope rule for `20261122-capture-bypasses-image-viewer-read-scope` |
| UTERM-066 M2-M3 | UTERM-066 M1, UTERM-067 M2, UTERM-028 M1, UTERM-055 M1, UTERM-065 M2 | Split from M1: M2 remembers the command, capture, and read-scope powers those rows build, and stores driver approvals in UTERM-067 M2's one store. M3's verified scripts keep remembered approvals, so M3 follows M2 |
| UTERM-029 M1-M3 | UTERM-024 M2, UTERM-025, UTERM-026, UTERM-030 M2, UTERM-032 M1 | Extends the presenter with UTERM-026's notes window, UTERM-030 M2's slide images, and UTERM-032 M1's input file |
| UTERM-043 M2 | UTERM-019 M6, UTERM-024, UTERM-028, UTERM-041, UTERM-042 | Split from M1: each check runs when the feature it names has landed. UTERM-019 M3 precedes M6 in its rows |
| UTERM-061 M1-M2 | None | Reuses the shared nearest-pane metric and tie rule that UTERM-018 M1 builds |
| UTERM-040 M1-M3 | None | |
| UTERM-039 M1 | None | |
| UTERM-033 M1 | None | |
| UTERM-048 M1 | None | Split from M2-M5: the shared snapshot needs nothing from UTERM-041 or the open bugs |
| UTERM-050 M1-M3 | None | Fixes `20261122-terminal-directory-check-blocks-main-thread.md`, which holds UTERM-048 M2 |
| UTERM-048 M2-M5 | UTERM-041 M1 | Split from M1: M3's tab IDs and M5's markers need UTERM-041 M1. M2 is also blocked until `bugs/20261122-terminal-directory-check-blocks-main-thread.md` and `bugs/20261122-approval-text-leaves-zero-width-scalars-raw.md` are fixed. The directory-check fix still needs a design call |
| UTERM-051 M1-M3 | None | |
| UTERM-052 M1-M2 | None | |
| UTERM-053 M1 | UTERM-041 M1, UTERM-052 M2 | Needs UTERM-041 M1's scrolling tab bar and UTERM-052 M2's record choke point |
| UTERM-068 M1-M4 | UTERM-053 M1 | Per-tab rule installation builds on UTERM-053 M1's tab work, so it never grows with the tab count |
| UTERM-059 M1 | UTERM-052 M2 | Needs UTERM-052 M2's saved-state revision. Placed after UTERM-053 M1, so every write to the terminal's tabs reaches the one place the revision observers watch |
| UTERM-058 M1-M3 | UTERM-053 M1 | M1 measures after UTERM-053 M1's read-through view. Placed after UTERM-059 M1, so M2's terminal ID map joins a terminal whose writes already move the revision |
| UTERM-062 M1-M6 | UTERM-063, UTERM-064 | UTERM-006 M5 must name a tab before it is built, which UTERM-065 carries |
| UTERM-006 M5 | UTERM-065 M2, UTERM-062 M4 | Split from M1-M4: a driver's `show` and stepping need UTERM-065's read grant, and name a tab, so M5 follows UTERM-062 M4's image viewer tabs |
| UTERM-018 M3-M5 | UTERM-062 M5 | Split from M1-M2: a routed open adds a tab under UTERM-062, so these start once every viewer takes an open as a tab |
| UTERM-049 M1-M3 | UTERM-018 M5 | M2 routes through UTERM-018's walk when no pane takes a tab file in place. M3's program open uses UTERM-018 M5's script file open |
