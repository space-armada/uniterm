# ADR-17: One Thing Reads the Same Everywhere

**Status:** proposed
**Date:** 2026-11-26

## Context

uniterm names the same action or object in several places. The main menu, the command palette, right-click menus,
pop-up menus, and markers such as badges and outlines can each show it. Each place is built by its own code, so each
can drift to its own wording.

When the wording drifts, the user has to learn two names for one thing. A search in the palette for the word the menu
uses finds nothing. An App Shortcuts remap matches a menu item by its title, so it cannot follow a command whose title
changes from place to place. The user also cannot tell whether two differently worded items do the same thing.

A rule about where an action may appear is a separate question. Some actions belong in the menu only, some in the
palette only, and some in a right-click menu only. This ADR does not decide that.

## Principles

- **P1**: Wherever uniterm shows the same action or the same object, it uses the same words. That covers the main
  menu, the palette, right-click menus, pop-up menus, and markers. One thing then has one name to learn, to search
  for, and to remap. Two wordings would leave the user unsure whether they mean one thing or two.
- **P2**: Two items that do the same thing read the same, even when different code provides them. What the user sees is
  the action, not the code behind it. Different words would suggest a difference that does not exist.

## Carve-outs

- **C1** (relaxes P1 and P2): A place whose context does not make the target or scope obvious may add the words that
  supply it. One example is an action on "this pane" shown where it is not clear which pane that is. The added words
  name what the context would otherwise have said. Leaving them out would make the item ambiguous, and being clear
  outranks being identical.

## Consequences

- An action shown in several places takes its words from one source, or every place must be checked against the others.
- Existing titles that differ between places need a review. Each one either changes to match, or names the context C1
  lets it add.
- Renaming an action renames it everywhere at once. An App Shortcuts remap of the old title stops matching in every
  place, not in one.
- Nothing here requires an action to appear in more than one place.

## Alternatives Considered

- **Let each place word an action for its own setting.** Each item reads well alone, but the user must learn every
  variant, and a search or a remap finds only one of them.
- **Show every action in every place, so the wording follows from one list.** That would put actions where they do not
  belong. Where an action appears is a separate decision from how it reads.

## References

- `spec/bugs/20261126-file-menu-shows-two-open-items-for-viewers.md`, whose fix raised this rule
