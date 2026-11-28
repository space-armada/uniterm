# A loader variable reaches the hardened `uniterm` command on a Mac with SIP off

**Status:** proposed, see [UTERM-023](../proposals/UTERM-023-controller-runs-with-sip-off.md)
**Estimate:** small to medium; one design decision
**Triaged:** 2026-11-15 (does not reproduce on a Mac with SIP on; design call moved to a proposal)

## Observed

On PR 49's first CI run, `DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib` loaded GuardMalloc into the bundle's
`uniterm` command. GuardMalloc printed its banner from inside the process. Three tests caught it:

- `CommandHelperSandboxTests.testTheShippedCommandCarriesTheHardenedRuntimeAndRefusesInjection`
- `ControllerRunTests.testALoaderVariableRunsNoSubstituteCodeBeforeAdmission`
- `ControllerRunTests.testALoaderVariableNeverReachesTheNativeEntry`

The command's signature checks passed in the same run. It has the hardened runtime, and its entitlements let in no
loader variables. In both controller tests the command then saw the variable and refused the run with status 64. But
the library had already loaded by then.

The same builds pass all three tests on a Mac with SIP on. Both are signed ad hoc as "Sign to Run Locally".

## Cause

The kernel strips dyld variables from a hardened process only while System Integrity Protection is on. GitHub's macOS
runners turn SIP off. PR 49's second CI run printed "System Integrity Protection status: disabled." when the probes
skipped.

The app trusts a controller run only from the bundle's own command, matched by its code hash (UTERM-004, ADR-14). That
match proves nothing about code dyld loaded into the command first. With SIP off, a library a loader variable names
loads into the command. Only an Apple-signed library was seen loading. Whether library validation blocks others is
unchecked. The command refuses a controller run while such a variable is set. A declared script file, an undeclared
script, and `uniterm ask` are admitted with the library loaded.

## Repro

On a Mac with SIP off, build the app and run the command with the library:

    DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib uniterm.app/Contents/Helpers/uniterm --help

- Expected, per the controller trust contract: no GuardMalloc banner.
- Actual on CI: the banner prints.

## Fix

"Skip the dyld injection probes on a Mac with System Integrity Protection off" stops CI failing on this. It fixes
nothing in the product. This needs a design call. The candidates:

- Treat a Mac with SIP off as outside the threat model, and say so in UTERM-004 and ADR-10.
- Refuse controller runs, or every run that asks for a power, while SIP is off, and tell the user why.
- Warn on the consent sheet and in the Controllers window while SIP is off, and leave the choice to the user.

## Investigation notes

Triage run on 2026-11-15.

- This Mac has SIP on. The two controller tests pass here. The shipped-command test skips because
  `UNITERM_COMMAND_HELPER` is unset. So the bug cannot reproduce on this machine.
- The CI evidence above is specific and matches the SIP mechanism. The cause is taken as understood.
- The choice among the candidates is a design call that changes the trust contract. UTERM-023 holds it.
