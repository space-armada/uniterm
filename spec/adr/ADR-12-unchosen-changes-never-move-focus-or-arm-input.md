# ADR-12: Unchosen Changes Never Move Focus or Arm Input

**Status:** retracted
**Date:** 2026-11-14

Retracted 2026-11-20. A program's operation is the same operation as the user's, and it behaves the same way. A pane
or tab a program opens takes focus exactly as one the user opens does. Every rule here treated a program's change
differently from the same change made by the user, so none of them stands.

## Context

Programs change what uniterm shows. A script opens a pane, applies a layout, or asks the user a form. A permission
question waits in Pending Requests. None of these changes is one the user chose at that moment.

The user's keystrokes are already in flight when such a change lands. Someone may be typing a `sudo` password in one
pane while a background script's form appears beside it. Someone may be filling one script's form when that script
ends and another script's form would take its place. Wherever the keyboard lands after the change, the next characters
and the next Return go there. A Return can confirm a question the user never read. Text can reach a program it was
not meant for.

Guarding only some keys does not close this. Each patch to which keys arm a surface left a neighboring key open.

## Decision

A change the user did not choose never moves keyboard focus, and never puts live input under the user's keystrokes.

- A pane, tab, or form that a program opens takes no focus. Focus stays where the user left it.
- When a program-driven change alters what a focused surface shows, the new content is inert. It goes live only on
  a deliberate choice made after the change. Input made before the change, and input that merely repeats or
  activates a default, never counts as that choice.
- An unchosen change never shows one program's input surface in place of another's. The user picks it. Only input
  that cannot continue work on the previous surface counts as choosing a different program's surface.

## Rationale

The trust boundary is the user's intent at the moment of a keystroke. A rule about which keys to guard leaves the
next key open. Holding focus still and keeping new content inert removes the whole class, since nothing the user did
not choose can receive their input. The cost is one deliberate input before the keyboard answers a program. That is
small next to a confirmation given by accident or a password typed into a script's field.

## Consequences

- A program can never rely on the keyboard answering it at once. A script that asks a question waits for the user to
  choose it.
- Every surface a program can open or change needs an inert state and a defined arming input.
- A multi-step flow can stay fast within one requester when the user resolved the previous step. The new content
  still ignores input from before it appeared.
- Announcing a change to assistive technology replaces moving focus to it. That keeps an unchosen change visible to
  VoiceOver users without stealing their keyboard.

## Alternatives Considered

- **Take focus on arrival.** Simplest, and it delivers the user's next keystrokes to whatever arrived.
- **Take focus after a short delay.** Guards only the keys that activate. Typed text still lands in the new surface,
  and the activating key that follows submits it.
- **Arm on any deliberate key, including Tab or a typed character.** A Tab or character the user meant for the
  surface that just closed arms the one that replaced it.

## References

- [UTERM-022](../proposals/UTERM-022-questions-applet.md): originating proposal, "Focus when a form arrives"
- [UTERM-004](../proposals/UTERM-004-control-and-trust.md): layouts leave focus where it was
- [ADR-09](ADR-09-control-authority-requires-authenticated-identity-and-explicit-scope.md): program effects need an
  explicit grant, and this ADR keeps the user's keystrokes out of what a program reaches without one
