# UTERM-068: Browser Content Blocking

**Status:** accepted
**Created:** 2026-11-26
**Updated:** 2026-11-26

## Dependencies

- [UTERM-005](UTERM-005-browser-applet.md) provides the WebKit browser and tab lifecycle.
- [UTERM-053](UTERM-053-browser-tab-work-never-grows-with-the-tab-count-on-the-main-thread.md) constrains per-tab
  work on the main thread. Installing rules for one tab must stay independent of the number of open tabs.
- [ADR-08](../adr/ADR-08-ui-responsiveness.md) governs responsiveness during list reads, downloads, conversion,
  and compilation.
- [ADR-07](../adr/ADR-07-failure-isolation.md) governs processing untrusted rule sources.

## Summary

Add ad blocking to the browser applet through WebKit content rule lists. Start with local WebKit JSON imports and
a temporary per-tab toggle. Use the same compilation and activation path for a bundled starter list, WebKit JSON
subscriptions, and supported EasyList-style filters.

## Motivation

Users need a way to block ads in Uniterm's browser with a starter list and add rules of their own. Each browser tab
already has a WebKit user content controller. A tab-local toggle lets the user recover a broken page while keeping
blocking active in other tabs.

## Design Decisions (Settled)

### All sources use WebKit content rule lists

Local WebKit JSON comes first. The bundled list and JSON subscriptions feed the same path. EasyList-style
sources go through conversion before WebKit compiles them. This order proves rule application before adding new
sources and gives the released feature a list that works out of the box.

**Decided by:** user, 2026-11-26

### The toggle lasts for the life of the tab

Each tab can bypass blocking independently. The toggle lives in tab runtime state. A rebuild of the same tab
retains its setting, and a tab restored after relaunch starts with the default policy.

**Decided by:** user, 2026-11-26

### Changes take effect on navigation

A toggle changes the policy for the next navigation, including a manual reload. The page stays in place until the
user navigates or reloads. A failed subscription update leaves the last working rules available.

**Decided by:** user, 2026-11-26

### When should subscriptions refresh?

Fetch on add, then check once per day while Uniterm is running. Check once when due after launch or wake. Use
conditional HTTP requests when the last accepted version has validators. Treat the accepted source bytes as
authoritative. Compile a replacement under a separate cache identifier. Publish the accepted version and its
source identity, cache reference, and validators as one durable change. A failed update retains the previous
rules and validators. Honor valid server retry delays and back off failed attempts across relaunch. Show the last
successful update and any current error. Navigation can use the last accepted rules while a check runs.

This keeps checking predictable and allows unchanged sources to return a small response.

**Decided by:** proposal-reviewer (autonomous), 2026-11-26

### Which EasyList-style features should the first release support?

Support network blocking, plain CSS hiding, and exceptions whose effects can be faithfully expressed in WebKit.
Exceptions apply within their source. An exception in one imported list cannot override blocking from another
list, including the starter list. Report unsupported filters with counts and examples. Skip an unsupported
positive rule. If an unsupported exception can affect supported rules, omit the affected rules when the effect
can be bounded. Reject the candidate when the effect cannot be bounded and keep any last accepted version.
Conversion stays declarative. Scriptlets and extended selector engines are outside this release.

This supports useful cosmetic coverage while preserving the intended scope of blocks and exceptions.

**Decided by:** proposal-reviewer (autonomous), 2026-11-26

### Which starter list should ship?

Generate an ad-only WebKit JSON starter list offline from a pinned EasyList snapshot. Pin the converter
revision and options. Ship the generated list as a separate resource with its source provenance, license,
and attribution. Use an EasyList snapshot eligible for redistribution under CC BY-SA. Normal builds and
M2 runtime use the checked-in JSON. The converter remains a maintainer tool until M4.

Release a candidate only after the exact packaged asset passes the supported macOS compatibility checks.
Keep related blocks and exceptions in one compiled list. If a later candidate fails, keep the previous
approved asset. If the first candidate cannot meet the checks or its redistribution terms, bring the starter
choice back to review before shipping it.

This uses a maintained source without an opaque prebuilt artifact or a new Uniterm-maintained filter list.

**Decided by:** proposal-reviewer (autonomous), 2026-11-26

### How does the first protected navigation wait for rules?

An allowed main-frame load in a tab with blocking enabled can wait asynchronously for a configured list to
be ready when it has no usable compiled version. Reuse a compatible last accepted version whenever available.
Bound the wait. On failure, show an actionable error so the user can retry or use the existing tab bypass and
navigate manually. Keep the existing page in place and never replay a declined or expired form submission.

This prevents silent unprotected first loads and keeps the rest of Uniterm usable during initialization.
An in-flight import or replacement does not make existing rules unavailable.

**Decided by:** proposal-reviewer (autonomous), 2026-11-26

### Where do imported and subscribed sources apply?

The browser owns one shared catalog and subscription schedule. A browser-wide list manager shows every source
and its status. Users add or remove their own sources there. The browser passes the shared policy explicitly
to new, restored, and pop-up tabs. Moving a tab between panes keeps that policy and the tab's temporary bypass.
Website data stores and clearing website data are independent of the rule catalog.

A tab reads the published list set when it next navigates. Adding, removing, or refreshing a source does not
require a synchronous sweep across open tabs.

**Decided by:** proposal-reviewer (autonomous), 2026-11-26

## Risks

- Medium likelihood, medium impact. A rule can break a site's resources or hide needed controls. Let the user
  bypass blocking in that tab and reload manually.
- Medium likelihood, medium impact. An interrupted download, invalid list, or compilation error can leave a
  subscription without a usable update. Validate a replacement before activating it and keep the last working
  rules on failure.
- High likelihood, medium impact. Some EasyList-style rules cannot be expressed in WebKit JSON. Test the chosen
  subset against representative inputs and report unsupported rules.
- Medium likelihood, medium impact. Large lists can slow navigation if tabs wait for compilation or list changes
  require a synchronous sweep of open tabs. Reuse compiled lists and check that list work leaves the UI responsive.
- Medium likelihood, medium impact. The public compile call parses JSON on the main run loop in current WebKit.
  Measure that synchronous work on the supported macOS baseline and bound input before handing it to WebKit.
- Medium likelihood, medium impact. WebKit installs rules on a live controller. Updating the controller before
  navigation can change requests from the current page. Prove the navigation boundary on the supported macOS
  baseline before relying on it.
- Medium likelihood, medium impact. A bundled snapshot can contain rules with incompatible terms or behavior.
  Check the exact inputs, attribution, conversion report, and deployed WebKit behavior before packaging.

## Milestones

### M1: Local WebKit JSON and per-tab control

**Status:** NOT STARTED

- A valid local list compiles and blocks a matching resource. An invalid list reports an error and leaves the
  active rules available.
- The imported JSON remains available to recompile, and a compiled list can be reused after relaunch.
- Changing one tab's toggle leaves other tabs and the current page alone. Manual reload and the next navigation
  apply the chosen policy.
- A pop-up uses the blocking policy for its own tab. A web view rebuilt for an existing tab applies that tab's
  policy before loading again.
- On supported macOS, an ordinary reload and an allowed main-frame navigation apply the chosen rules before
  new-document requests. Toggling without navigating leaves late requests from the current document under
  its existing policy. Existing navigation and form-resend checks still run.
- A canceled or failed navigation cannot leave a retained page under the wrong policy. Cover redirects, a
  download response, same-document history, and restored history in the macOS proof. Bring the navigation
  decision back for review before shipping if public WebKit APIs cannot uphold the reviewed behavior.
- A slow provisional load with the opposite blocking state preserves the outgoing document's policy through
  handoff or cancellation.
- Initial rule readiness gates the first allowed load, including a pop-up from a bypassed opener. A timeout,
  tab close, or newer navigation resolves an outstanding wait once and cannot send a stale request.
  Confirmed form resends pass the same readiness check and retain the existing confirmation.
- The browser-wide manager shows imported sources and lets the user remove them. An import in one pane is
  available to another on its next load, and clearing website data leaves the catalog available.
- A representative starter-list input and the largest admitted input fit the main-thread budget on the
  supported macOS baseline. Bound individual and aggregate input and stored data before handing lists to
  WebKit. If a required path cannot meet ADR-07 or ADR-08 in-process, establish containment or review an
  explicit deviation before implementation proceeds.

### M2: Bundled starter list

**Status:** NOT STARTED

- A clean installation blocks a resource covered by the starter list without a manual import.
- The starter list uses the same compilation and activation path as a custom list, and both sources can be active.
- On macOS 26.0, the exact packaged asset compiles, blocks the fixture on the first eligible navigation,
  honors a matching exception, and leaves unrelated content loadable. The UI remains responsive while the
  list initializes.
- The asset has reproducible inputs and conversion options, documented coverage and omissions, and verified
  licensing and attribution.

### M3: WebKit JSON subscriptions

**Status:** NOT STARTED

- A subscription fetches and refreshes a WebKit JSON list using the agreed update policy.
- A successfully compiled replacement applies on subsequent navigation. A failed fetch or compile keeps the
  last working rules available, including across relaunch.
- If a new response fails compilation, its HTTP validators do not supersede the last accepted version's.
  A 304 counts as validation only for a matching accepted version. An in-flight response cannot reactivate
  a removed subscription.
- An interruption between compilation and publication leaves the previously accepted version usable after
  relaunch. A missing or incompatible compiled cache can be rebuilt from its accepted source.
- A restart after publication but before cleanup keeps the accepted version. Storage bounds count staged and
  orphaned versions, and cleanup leaves any generation still in use available.

### M4: EasyList-style sources

**Status:** NOT STARTED

- A supported EasyList-style list converts to WebKit JSON and uses the same compilation and activation path.
- Representative tests cover request exceptions, a cosmetic exception beside an unrelated selector, and an
  unsupported exception that would otherwise leave a broader block active. Tests also cover independent
  sources and a conversion failure retaining the last accepted version.

## Decision Log

- 2026-11-26: Review start: four milestones, three settled decisions, four risks, and no live checks or row gates.
  Autonomous design review with one commit at the end. The draft is untracked at checkout HEAD `0bdd0f3`.
- 2026-11-26 — User approved the milestone order, a temporary per-tab toggle, and application on next navigation
  or manual reload. Persistent site exceptions, pane-wide overrides, automatic reload, and a combined reload
  command remain future ideas.
- 2026-11-26: (autonomous) Use daily conditional subscription checks, with validators tied to the last accepted rules.
- 2026-11-26: (autonomous) Convert representable request and plain CSS filters with source-local exceptions and
  diagnostics for unsupported filters.
- 2026-11-26: (autonomous) Ship native JSON generated offline from a pinned EasyList snapshot with an
  attribution and compatibility check.
- 2026-11-26: (autonomous) Bound first-load waiting for configured rules and offer retry or a deliberate tab bypass
  after failure.
- 2026-11-26: (autonomous) Own the source catalog browser-wide, independent of the website data store.

- 2026-11-26: Review gate: user approved all autonomous decisions and asked to test the public WebKit navigation boundary.

- 2026-11-26: User accepted the proposal with the M1 navigation proof in place.

### Navigation proof to date

A localhost probe using public WebKit APIs on macOS 26.7.3 tested three points for attaching a blocking list.
Attaching at navigation-action approval blocked an early image in the incoming page. If the replacement was
canceled at response policy, the retained page's fetch stayed blocked until the previous policy was restored.
Attaching at document commit let the early image reach the server. Attaching immediately before allowing the
main-frame response blocked the early image on navigation and manual reload. Canceling the response left
the retained page's fetch working. The outgoing page's fetch failed during provisional navigation even in the
unchanged-policy control, so that part of the test cannot establish isolation.

Response-time attachment is a candidate for subresources. The initial top-level request has already been
sent at that point. The full M1 proof still needs macOS 26.0 and must cover the top-level request policy,
history, redirects, pop-ups, and the outgoing page through a successful handoff.
- 2026-11-26: Scheduled as UTERM-068 M1-M4 in queue.md.

## References

- [EasyList repository licenses](https://easylist.to/pages/licence.html)
- [HTTP caching and validation](https://www.rfc-editor.org/rfc/rfc9111.html)
- [HTTP Retry-After semantics](https://www.rfc-editor.org/rfc/rfc9110.html#name-retry-after)
- [WebKit's rule-list store implementation](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/APIContentRuleListStore.cpp)
- [WebKit's content extension backend](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/contentextensions/ContentExtensionsBackend.cpp)
- [Apple's WebKit content rule list store](https://developer.apple.com/documentation/webkit/wkcontentruleliststore)
- [Apple's content blocker format](https://developer.apple.com/documentation/safariservices/creating-a-content-blocker)
- [AdGuard's Safari converter and limitations](https://github.com/AdguardTeam/SafariConverterLib)
