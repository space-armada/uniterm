# Queue

| Milestones | Depends on | Note |
|------------|------------|------|
| UTERM-003 M1-M5 | None | |
| UTERM-004 M1-M6 | UTERM-003 | Needs the host API and listener UTERM-003 builds. Placed right after it to close the same-user control window UTERM-003 M3 opens |
| UTERM-007 M5 | UTERM-004 M3 | Split from M1-M4: waits on remote-controlled panes and the applet command hook from UTERM-004 M3 |
| UTERM-015 M4-M7 | UTERM-004 M6 | Split from M1-M3: M4's read power, M5's approvals, and M7's Launch Services approvals need UTERM-004 M6, and M5 needs UTERM-003 M3, which that row follows |
| UTERM-006 M4 | UTERM-015 M4 | Split from M1-M3: waits on UTERM-015 M4's read power, after UTERM-003 M2 and UTERM-004 M3 |
| UTERM-008 M3 | UTERM-004 M3 | Split from M1-M2: waits on the exec driver and applet command hook from UTERM-004 M3 |
| UTERM-005 M8 | UTERM-004 M6 | Split from M1-M7: waits on UTERM-004 M6 and its browser-permission amendment |
