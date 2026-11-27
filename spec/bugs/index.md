# Bugs

| Bug | Description | Status |
|-----|-------------|--------|
| [20261101-status-bar-segment-leading-after-dark](20261101-status-bar-segment-leading-after-dark.md) | Status bar directory segment jumps to the leading edge after switching to Dark | open |
| [20261114-policy-file-newer-format-read-as-broken](20261114-policy-file-newer-format-read-as-broken.md) | A newer policy file that holds a boolean, null, or fraction is moved aside as broken | fixed |
| [20261114-second-ctrl-c-test-flaky-under-full-suite](20261114-second-ctrl-c-test-flaky-under-full-suite.md) | The second-Ctrl-C test sometimes sees the first Ctrl-C end the script | open |
| [20261114-launcher-rows-short-of-filter-box-with-legacy-scroller](20261114-launcher-rows-short-of-filter-box-with-legacy-scroller.md) | The launcher's rows end 17 points short of the filter box while a legacy scroller shows | fixed |
| [20261115-loader-variables-reach-hardened-command-with-sip-off](20261115-loader-variables-reach-hardened-command-with-sip-off.md) | A loader variable reaches the hardened `uniterm` command on a Mac with SIP off | proposed |
| [20261115-sent-markdown-images-escape-sent-folder](20261115-sent-markdown-images-escape-sent-folder.md) | Images in Markdown a script sends resolve anywhere on the volume | fixed |
| [20261116-script-snapshot-reads-program-chosen-path](20261116-script-snapshot-reads-program-chosen-path.md) | The app copies any path a command names into a script snapshot, with uniterm's privacy grants | proposed |
| [20261116-pdf-form-fields-take-typed-text](20261116-pdf-form-fields-take-typed-text.md) | The text viewer's PDF body lets the user type into form fields | fixed |
| [20261116-unclaimed-command-key-reaches-terminal-program](20261116-unclaimed-command-key-reaches-terminal-program.md) | A Command key that no menu item takes reaches the terminal program, against the surface's own comment | fixed |
| [20261116-disconnected-source-badge-hides-live-controller](20261116-disconnected-source-badge-hides-live-controller.md) | A disconnected pane that a live controller acts from shows no control badge | fixed |
| [20261116-disconnected-driver-cannot-command-owned-members](20261116-disconnected-driver-cannot-command-owned-members.md) | A driver whose pane is disconnected cannot command the members it owns | fixed |
| [20261116-groupless-driver-clipboard-grant-has-no-revoke](20261116-groupless-driver-clipboard-grant-has-no-revoke.md) | A driver that owns no group keeps its clipboard grant until its run ends | fixed |
| [20261115-helper-sandbox-tests-fail-after-ui-test-build](20261115-helper-sandbox-tests-fail-after-ui-test-build.md) | The helper sandbox tests fail after a UI test build leaves test entitlements on the helpers | fixed |
| [20261117-stderr-line-split-across-reads-shows-as-two-lines](20261117-stderr-line-split-across-reads-shows-as-two-lines.md) | A driver's stderr line split across two reads shows as two status lines | fixed |
| [20261117-read-scope-compared-as-written-hides-real-paths](20261117-read-scope-compared-as-written-hides-real-paths.md) | A read scope written through a link hides every path from its own controller | fixed |
| [20261121-edited-map-past-size-bound-saves-but-cannot-reopen](20261121-edited-map-past-size-bound-saves-but-cannot-reopen.md) | An edited map past 32 MiB saves, but cannot be reopened | open |
| [20261121-terminal-tab-bar-ignores-control-badge](20261121-terminal-tab-bar-ignores-control-badge.md) | The terminal's tab bar ignores the control badge | fixed |
| [20261121-tab-bar-overflow-hides-tabs](20261121-tab-bar-overflow-hides-tabs.md) | Tabs past the tab bar's trailing edge cannot be seen or clicked | open |
| [20261121-revoked-controller-stays-on-badge](20261121-revoked-controller-stays-on-badge.md) | A revoked controller that keeps its connection open stays listed on the badge | fixed |
| [20261121-owner-end-withdraws-other-owners-launches](20261121-owner-end-withdraws-other-owners-launches.md) | An owner's end withdraws every launch waiting in its panes, whoever staged it | open |
| [20261121-held-requests-grow-without-bound](20261121-held-requests-grow-without-bound.md) | Calls held during a peer's full check grow without bound | not-reproducible |
| [20261121-ui-test-paste-replaces-the-real-clipboard](20261121-ui-test-paste-replaces-the-real-clipboard.md) | The UI tests' open-panel paste replaces the real clipboard and restores only its text | fixed |
| [20261122-approval-text-leaves-zero-width-scalars-raw](20261122-approval-text-leaves-zero-width-scalars-raw.md) | Launch approvals and controller names draw zero-width scalars raw | fixed |
| [20261122-bounded-status-text-keeps-line-separators](20261122-bounded-status-text-keeps-line-separators.md) | Bounded status text keeps U+2028 and U+2029 line breaks | fixed |
| [20261122-terminal-directory-check-blocks-main-thread](20261122-terminal-directory-check-blocks-main-thread.md) | An applet's current directory checks the file system on the main thread | proposed |
| [20261122-layout-save-runs-on-main-thread](20261122-layout-save-runs-on-main-thread.md) | The layout save encodes and writes every tab on the main thread | fixed |
| [20261122-layout-launch-read-runs-on-main-thread](20261122-layout-launch-read-runs-on-main-thread.md) | The launch reads and decodes the whole layout file on the main thread | proposed |
| [20261122-browser-describe-reencodes-tabs-on-main-thread](20261122-browser-describe-reencodes-tabs-on-main-thread.md) | The browser re-encodes every tab record on the main thread at each change | proposed |
| [20261122-browser-tab-bar-builds-a-view-per-tab-on-main-thread](20261122-browser-tab-bar-builds-a-view-per-tab-on-main-thread.md) | The browser's tab bar builds and updates one view per tab on the main thread | proposed |
| [20261122-optimized-build-crashes-compiler-in-status-queue](20261122-optimized-build-crashes-compiler-in-status-queue.md) | An optimized build of the package crashes the Swift compiler in StatusKit | fixed |
| [20261122-undo-reopen-decodes-pane-on-main-thread](20261122-undo-reopen-decodes-pane-on-main-thread.md) | Undo reopen of a closed pane decodes its description on the main thread | proposed |
| [20261122-save-tabs-defers-reply-after-write](20261122-save-tabs-defers-reply-after-write.md) | UTERM-049's `save-tabs` reply waits for a file write, against ADR-11 | fixed |
| [20261122-native-controller-refused-after-scriptwire-change](20261122-native-controller-refused-after-scriptwire-change.md) | A native controller is refused at hello after any ScriptWire change | proposed |
| [20261122-script-open-pane-leaves-first-tab-unowned](20261122-script-open-pane-leaves-first-tab-unowned.md) | A pane a script opens with open-pane leaves its first tab unowned | fixed |
| [20261122-uterm-028-says-no-exec-capable-applet-ships](20261122-uterm-028-says-no-exec-capable-applet-ships.md) | UTERM-028 says no exec-capable applet ships, but two do | fixed |
| [20261122-capture-bypasses-image-viewer-read-scope](20261122-capture-bypasses-image-viewer-read-scope.md) | A program's pane capture can show an image the program may not read | proposed |
| [20261122-tests-leak-preference-files](20261122-tests-leak-preference-files.md) | Tests leave tens of thousands of preference files in ~/Library/Preferences | fixed |
| [20261122-package-snapshot-opens-program-chosen-folder](20261122-package-snapshot-opens-program-chosen-folder.md) | The app opens a package folder the command names, with uniterm's privacy grants | proposed |
| [20261122-rusage-units-comment-claims-safe-failure](20261122-rusage-units-comment-claims-safe-failure.md) | The usage reader claims a units change fails safe, but it would signal idle unused processes | fixed |
| [20261122-declared-file-watchdog-may-signal-reused-pid](20261122-declared-file-watchdog-may-signal-reused-pid.md) | The declared-file test watchdog may signal a process id that was already reused | proposed |
| [20261122-picked-file-start-directory-stat-on-main-thread](20261122-picked-file-start-directory-stat-on-main-thread.md) | A viewer stats a picked or dropped file on the main thread | fixed |
| [20261122-quit-skips-unsaved-work-when-nothing-runs](20261122-quit-skips-unsaved-work-when-nothing-runs.md) | Quitting loses unsaved work when nothing is running | fixed |
| [20261122-map-save-reads-file-on-main-thread](20261122-map-save-reads-file-on-main-thread.md) | Saving a map reads its file on the main thread | fixed |
| [20261122-closing-pane-on-dead-mount-may-join-io-thread](20261122-closing-pane-on-dead-mount-may-join-io-thread.md) | Closing a pane whose shell is stuck on a dead mount may freeze the app | not-reproducible |
| [20261122-terminal-tab-changes-walk-every-tab](20261122-terminal-tab-changes-walk-every-tab.md) | A terminal pane walks every tab at each title change and tab switch | fixed |
| [20261122-palette-rebuild-walks-every-tab](20261122-palette-rebuild-walks-every-tab.md) | The palette rebuilds and filters every tab of every pane while it shows | proposed |
| [20261122-tab-close-button-may-close-a-shifted-tab](20261122-tab-close-button-may-close-a-shifted-tab.md) | A tab's close button may close a neighboring tab after the tabs shift | fixed |
| [20261122-browser-close-encodes-every-tab-history-on-main-thread](20261122-browser-close-encodes-every-tab-history-on-main-thread.md) | Closing a browser pane encodes every tab's history on the main thread | fixed |
| [20261122-map-describe-encodes-document-at-every-save](20261122-map-describe-encodes-document-at-every-save.md) | A map pane encodes its undo part at every save and change check | proposed |
| [20261122-terminal-describe-encodes-every-tab-at-each-change](20261122-terminal-describe-encodes-every-tab-at-each-change.md) | The terminal encodes every tab and closed tab on the main thread at each change | proposed |
| [20261122-questions-bar-disagrees-with-the-shared-hide-rule](20261122-questions-bar-disagrees-with-the-shared-hide-rule.md) | The questions applet's tab bar disagrees with UTERM-041's shared hide rule | proposed |
| [20261122-exec-browser-read-result-burst-ends-driver](20261122-exec-browser-read-result-burst-ends-driver.md) | A driver that sends its browser reads in a burst is ended | fixed |
| [20261123-map-saved-through-a-symlink-stays-dirty](20261123-map-saved-through-a-symlink-stays-dirty.md) | A map saved through a symlink stays unsaved | fixed |
| [20261123-map-file-change-reads-file-on-main-thread](20261123-map-file-change-reads-file-on-main-thread.md) | A map's file-change check reads the whole file on the main thread | fixed |
| [20261123-package-admission-read-has-no-bound](20261123-package-admission-read-has-no-bound.md) | A controller package read that never returns leaves its admission pending forever | proposed |
| [20261123-script-tab-numbers-keep-closed-tabs](20261123-script-tab-numbers-keep-closed-tabs.md) | A window's script tab numbers keep an entry for every tab ever seen | proposed |
| [20261126-detached-image-zoom-wait-never-settles](20261126-detached-image-zoom-wait-never-settles.md) | A program's zoom wait on a detached image pane never settles until the pane comes back | fixed |
| [20261126-memory-warning-stops-sorting-in-open-data-panes](20261126-memory-warning-stops-sorting-in-open-data-panes.md) | A memory-pressure warning stops sorting in every data pane already open | fixed |
| [20261126-file-menu-shows-two-open-items-for-viewers](20261126-file-menu-shows-two-open-items-for-viewers.md) | The File menu shows two items titled "Open…" while a viewer is focused | fixed |
| [20261126-palette-filter-rows-read-empty-kind](20261126-palette-filter-rows-read-empty-kind.md) | VoiceOver reads a palette filter row's kind as empty | fixed |
| [20261126-palette-command-refused-after-refresh-is-silent](20261126-palette-command-refused-after-refresh-is-silent.md) | A palette command that becomes unavailable after the list was built does nothing, silently | fixed |
| [20261126-image-zoom-wait-hangs-when-every-tile-is-refused](20261126-image-zoom-wait-hangs-when-every-tile-is-refused.md) | A program's zoom wait hangs when the budget refuses every tile it needs | fixed |
| [20261126-host-never-sends-detach-or-reattach](20261126-host-never-sends-detach-or-reattach.md) | The host never sends an applet detach or reattach, so audio and alerts never pause off screen | fixed |
| [20261126-failed-pane-open-drops-the-old-source](20261126-failed-pane-open-drops-the-old-source.md) | A failed Open in This Pane drops the pane's old file instead of keeping it | fixed |
| [20261126-iso-gain-map-images-show-as-sdr](20261126-iso-gain-map-images-show-as-sdr.md) | An image with an ISO 21496-1 gain map shows as SDR in the image viewer | fixed |
| [20261126-unanswered-reviews-fill-connection-slots](20261126-unanswered-reviews-fill-connection-slots.md) | Unanswered reviews hold connection slots until every script is refused | rejected |
| [20261127-exec-driver-cannot-name-its-pane-for-a-first-layout](20261127-exec-driver-cannot-name-its-pane-for-a-first-layout.md) | An exec driver cannot make its first layout, since nothing tells it its pane's number | proposed |
