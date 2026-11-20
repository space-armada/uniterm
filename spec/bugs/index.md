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
| [20261118-script-opened-tab-takes-keyboard](20261118-script-opened-tab-takes-keyboard.md) | A tab a script opens with `uniterm/open-tab` takes the keyboard, against ADR-12 | open |
| [20261118-program-changes-never-announced-to-assistive-technology](20261118-program-changes-never-announced-to-assistive-technology.md) | A change a program makes is never announced to assistive technology, against ADR-12 | open |
