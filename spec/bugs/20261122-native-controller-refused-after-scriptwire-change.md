# A native controller is refused at hello after any ScriptWire change

**Status:** proposed. [UTERM-063](../proposals/UTERM-063-outside-wires-stay-at-version-0.md) holds ScriptWire at version 0, so a change no longer refuses at hello, and its M2 fixes the refusal advice. [UTERM-056](../proposals/UTERM-056-native-controllers-across-scriptwire-versions.md), deferred, covers compatibility once ScriptWire is declared stable.
**Found:** 2026-11-22, during the UTERM-054 review
**Estimate:** large; three non-trivial design decisions. Whether native controllers are an outside wire under ADR-13, whether to add a version offer or keep exact match with an amended ADR, and whether to drop `native` entries. Each changes behavior users and controller authors can observe, and the first two change an ADR.

## Observed

A controller package whose entry is `native` runs its own signed executable. That executable opens its own ScriptWire
connection to the app. ScriptWire's hello accepts only the app's exact version. So when an app update changes
ScriptWire's version, every native controller built against the earlier version is refused at hello. The reverse also
fails: a native controller built against a newer version is refused by an older app.

The user is told "The uniterm command and the app come from different versions. Relaunch uniterm." A relaunch cannot
fix it, since the controller's executable carries its own copy of the wire.

## Cause

- `ControllerEntryKind.native` in `Packages/UnitermKit/Sources/ControllerPackage/ControllerDescriptor.swift:44`
- `ScriptControllers.adoptNativeRun` in `Packages/UnitermKit/Sources/ScriptHost/ScriptControllers.swift:437`, which
  adopts the native executable's own connection
- `ScriptProtocol.validateHello` in `Packages/UnitermKit/Sources/ScriptWire/ScriptProtocol.swift:947`, which refuses any
  version but `ScriptProtocol.version`
- `ScriptProtocol.mismatchText` at line 18 assumes both sides are the app and its bundled command

ADR-13 lets ScriptWire refuse every version but its own because "its two sides always ship together". A native
controller entry is a ScriptWire side that ships outside the bundle, so the premise does not hold for it.

## Repro

Build a native controller against ScriptWire version 14. Run it on an app whose ScriptWire is version 15. Expected
under ADR-13's intent for outside programs: it runs with what that version offers. Actual: the hello is refused, and
the message tells the user to relaunch.

## Fix

This needs a design call, and a change to ADR-13 is the user's to make:

- Give ScriptWire a version offer for native controllers, as UTERM-028 does for the exec wire, and treat native
  controllers as an outside wire under ADR-13.
- Keep exact match and amend ADR-13 to say native controllers must be rebuilt with each ScriptWire change. Fix the
  mismatch text so it tells a native controller's user to update the controller.
- Drop `native` entries and run controllers only through uniterm's own helper.

UTERM-054's capture calls change ScriptWire, so they hit this, as every ScriptWire change does today.

## Triage Notes

Checked 2026-11-23 against the current tree. The build passes. `ScriptProtocol.version` is 14, and both `validateHello` overloads at `ScriptProtocol.swift:947` and `:1202` still refuse any version but the exact one. `adoptNativeRun` adopts the native executable's own connection, so the refusal applies to it. `mismatchText` still tells the user to relaunch. No regression test exists. No native controller was built and run, so the repro is confirmed by tracing the code only.
