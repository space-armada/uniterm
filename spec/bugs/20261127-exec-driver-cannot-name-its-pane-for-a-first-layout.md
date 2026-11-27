# An exec driver cannot make its first layout, since nothing tells it its pane's number

**Status:** proposed. [UTERM-064](../proposals/UTERM-064-programs-name-what-they-act-on.md) settles the design in "The
own-tab alias for a caller with no source tab": the exec hello carries the driver's pane identity.
**Estimate:** small once UTERM-064 lands; the design call is settled there.

## Observed

Found by a design critique of UTERM-064 on 2026-11-27. A driver's first layout request must place the driver's own
pane, by its number, as `{"pane": N}`. Nothing the driver receives names that number, so a driver cannot write a valid
first layout unless the user puts the pane's number in its arguments by hand.

## Cause

- A first layout must place the pane it starts from, and refuses anything else: "a first layout places the pane it
  starts from once, and no other open pane" (`Packages/UnitermKit/Sources/PaneModel/PaneTree.swift:526-529`).
- The app's hello to the driver carries only the protocol version, the applet type, and the schema version
  (`Packages/UnitermKit/Sources/ExecDriver/ExecDriverChannel.swift:160-165`, `ExecProtocol.swift:112`).
- The driver's environment and argv name no pane (`ExecEnvironment.swift`), and the exec wire has no pane listing.
- The tests write the pane's raw value straight into the frame (`Tests/.../ExecLayoutTests.swift:50`, `398`), which a
  real driver cannot do.

## Repro

1. Declare an exec driver on an image viewer pane whose first message is a `layout` request.
2. Expected: the driver can name its own pane in the layout. Actual, as traced: it has no way to learn the pane's
   number, so its layout is refused.

## Fix

UTERM-064's settled decision: the exec hello carries the identity of the driver's pane, and the driver's `layout` and
`command` frames name their pane by it.
