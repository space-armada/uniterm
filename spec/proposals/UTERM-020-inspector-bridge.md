# UTERM-020: Inspector Bridge

**Status:** accepted
**Created:** 2026-11-11
**Updated:** 2026-11-27

## Dependencies

- UTERM-019, for controller tabs' capabilities, page events, permissions, and trusted input
- UTERM-005 M8 and UTERM-004 M6, through UTERM-019

## Impacts

- UTERM-019 — "Capabilities": the set gains private-API capabilities, reported from this proposal's startup probe.
- UTERM-019 — "Page events": the buffer gains console, exception, and network event types.
- UTERM-019 — "Trusted input": script evaluation with a user gesture falls under browser input.

## Summary

Controller scripts get console output, network traffic with bodies, request interception, emulation, and debugging in
their own browser tabs. These reach past public WebKit API. uniterm gets them by driving a hidden Web Inspector
frontend, and by calling a few private WebKit methods directly. A compatibility layer fails closed: a missing method
turns a capability off, and recoverable runtime failures reach the script as errors. Fixed native private calls retain
the explicitly bounded app-crash exposure under "Native private-call failures", approved at the review gate.

## Motivation

UTERM-019 covers what public WebKit API allows. The findings note, `spec/reports/20261111-wkwebview-automation-vs-cdp.md`,
lists what it cannot reach: every request and response with bodies, interception and mocking, throttling, console
output from workers, the debugger and profilers, CSS matched rules, and timezone emulation. Those are the parts of the
Chrome DevTools Protocol that make a browser debuggable from a script.

WebKit's own Web Inspector already speaks a protocol with all of them. `-[WKWebView _inspector]` returns a
`_WKInspector`, and its `inspectorWebView` returns the inspector frontend, a WKWebView owned by uniterm's process. A
bridge script in that frontend could send protocol commands and receive events. The note's probe found these names on
macOS 26.6.2. Nobody has tried the bridge yet.

uniterm will not ship on the App Store, so private API is acceptable on that ground.

## Design Decisions (Settled)

### Scope

Decision: every command acts only on a tab the controller opened, as UTERM-019 "Scope of every command" defines it. A
tab a page opens from a controller tab belongs to no controller.

### What scripts see

Decision: typed commands for each area, plus raw protocol passthrough behind its own permission.

- Console, network observation, network control, emulation, and debugging each get typed commands with schemas.
  uniterm's command names stay fixed when WebKit's protocol changes underneath them.
- A raw command sends one inspector protocol message to a controller tab and returns the reply. Its approval review says
  it grants the admitted inspector powers in that tab, including what the other permissions gate. Unknown effect
  scopes are refused under "Effective target scope". Amended 2026-11-11; see Decision Log.
- Raw replies are page-controlled data, validated for size and shape like any other reply.

Rationale: typed commands keep the permission split meaningful and hide WebKit's churn. The raw command reaches what
nobody has curated yet, such as most debugger detail, for a controller the user trusts that far.

### Permissions

Decision: five new typed permissions plus one for raw, each separate, per ADR-09.

- Browser console covers console messages and exceptions, including workers whose exclusive scope is established
  under "Effective target scope". Amended 2026-11-11; see Decision Log.
- Browser network read covers observing requests and responses, and reading bodies.
- Browser network control covers interception, mocking, throttling, and cache control.
- Browser debug covers the debugger, profilers, heap, and CSS matched rules.
- Browser emulation covers timezone and device-scale overrides.
- Browser inspector raw covers admitted raw protocol passthrough under "Effective target scope". Its review states
  that it includes the other inspector powers, but never other targets or unverified effect scopes.
- Script evaluation with a user gesture falls under UTERM-019's browser input. It grants the same real user activation
  that synthesized input does.
- An approval stored before these permissions existed covers none of them.

Rationale: ADR-09 makes each power its own permission. Bodies can hold credentials, so reading them is its own grant.
Interception can change what the user's signed-in session sends, so it is separate from reading.

### Fallback order

Decision: if a route fails, the next one is tried in this order.

1. The hidden inspector frontend bridge.
2. Safari's remote-inspector protocol to `webinspectord`. It likely requires an Apple-only entitlement.
3. Only the private methods uniterm calls directly, per "Direct private methods". Console, network bodies,
   interception, throttling, and debugging are deferred.
4. A local proxy that terminates TLS with a uniterm CA the user trusts. This is a last resort and needs its own
   decision before anyone builds it.

If both transport proofs fail, direct methods remain eligible under their own gates. M5 through M9 stay NOT STARTED
until the user decides what to defer or redesign. Milestones never take a `deferred` status. That later decision uses
the following revisit hook; this review does not drop or defer any milestone. Amended 2026-11-11; see Decision Log.

**Revisit:** when a macOS release changes `_WKInspector` or the inspector frontend; on or after 2027-06-15 (the
expected first beta of the next macOS release)

Rationale: the bridge is in-process and needs no entitlement. `webinspectord` is the route Safari itself uses. A
trusted CA could vouch for any site on the Mac if its key leaked, so it comes last.

### Direct private methods

Decision: the direct route does not depend on a successful inspector transport. Each method remains conditional on
tested compatibility and demonstrated tab scope; timezone follows "Timezone scope". Amended 2026-11-11; see Decision Log.

- `_setResourceLoadDelegate:` observes every resource load, without bodies and without modifying anything.
- `_evaluateJavaScript:withSourceURL:inFrame:inContentWorld:withUserGesture:completionHandler:` runs script with user
  activation.
- `_WKProcessPoolConfiguration.timeZoneOverride` is a candidate for timezone, only under "Timezone scope".
  Amended 2026-11-11; see Decision Log.
- `_setOverrideDeviceScaleFactor:` sets the device scale.

### The private API boundary

Decision: one module owns every private WebKit call, and a make check fails the build when another module reaches
private WebKit API.

- The module holds the startup probe, every guarded call, and the bridge script.
- It exposes uniterm's own interface to the browser applet. The applet never names a private selector.
- The check follows the pattern of `check-ghosttykit-imports`.

Rationale: ADR-01 wraps libghostty, an unstable dependency, behind uniterm's own protocol in one module. Private WebKit
API is less stable than libghostty, and uniterm cannot pin it, since WebKit ships with macOS.

### Compatibility

Decision: private API fails closed.

- Every private call checks `respondsToSelector:`, or the class or symbol lookup, before calling. Nothing links against
  a private symbol, so a removed one cannot stop the app from launching.
- Startup checks local classes, selector type encodings, and the tested adapter record. It reports build support into
  UTERM-019's capabilities set. Live protocol readiness follows "Protocol drift". Amended 2026-11-11; see Decision Log.
- An unavailable capability or recoverable private failure returns a structured error naming the capability. Native
  traps remain the bounded exception under "Native private-call failures". Amended 2026-11-11; see Decision Log.
- The local name, ABI, and manifest checks take milliseconds and run with the unit tests. Live protocol validation
  is asynchronous and belongs to connection readiness, not the startup probe.
- Behavioral smoke tests drive real web views in their own make target, not on every test run. They are meant for each
  new macOS beta and point release, since a probe cannot catch a method whose signature or meaning changed.

### Isolation

Decision: the bridge adds no helper process, and keeps page data out of uniterm's process except as bounded messages.

- The frontend's JavaScript runs in a WebKit content process, as the browser's own pages do. M1 proves this before
  anything builds on it. If it is false, ADR-07 needs an exception stated with its bound, and the work stops for a
  decision.
- No bridge call blocks the main thread, per ADR-08. Body size and event volume are bounded before they reach it.
- Janet stays in the existing helper, per ADR-10.

### What is never restored

Decision: interception rules, throttling, overrides, breakpoints, and raw subscriptions are never saved in the layout,
per ADR-03. They end with the run or the tab.

### Untested macOS builds

Whether private capabilities turn off on a macOS build that the smoke tests have not passed on. Candidates: off until
the smoke tests record a pass for that build, or on with a warning.

Decision: private capabilities are off unless the app bundles a successful smoke-test record for the exact macOS
build, WebKit version, CPU architecture, and adapter revision. Results are per capability and include all prerequisites.
The record identifies the adapter code actually shipped. Startup still checks local names and Objective-C method type
encodings before allowing a private call. A missing record or check reports the capability unavailable with its reason.
There is no warning-only override. Public capabilities are unaffected.

The smoke-test target records synthetic fixtures and results for release maintainers. It is run in a disposable test
app, never automatically inside the user's running app on an unknown build. Passing records ship with an app update.
This adds compatibility records and a release-maintenance obligation to the existing smoke tests.

Rationale: a selector can keep its name while its signature or behavior changes. Enabling first and warning cannot
protect a running terminal session from that failure. Converged in one critic pass.

### Raw events

Whether events from raw subscriptions land in UTERM-019's per-tab buffer, or in a buffer of their own.

Decision: raw subscriptions use a separate ring for each run, tab, and bridge session. Its read command requires
browser inspector raw at admission and completion. It has its own cursor and dropped count. Typed inspector events
enter the typed buffer only under their typed permission. Raw authority can read the raw representation instead.

The raw ring retains at most 1,024 events or 1 MiB of serialized event data, whichever comes first. One raw event is at
most 16 KiB. Aggregate raw retention is at most 8 MiB per run. Oversized and evicted events increment visible dropped
counts with reasons. Reads fit the serialized byte limit of the whole wire reply and leave unread events behind the
cursor. There are at most 32 subscriptions and one pending raw read per tab. Teardown discards the ring.

The bridge bounds admission before host decoding. Raw traffic cannot consume admission reserved for typed events and
host cleanup. This does not promise priority between different typed event kinds. Oversized raw replies use the bounded
result path under "Response bodies"; raw events are dropped with accounting rather than stored as unbounded payloads.

Rationale: sharing the ring lets raw traffic evict navigation history. Per-subscription rings duplicate retention with
no current need. Converged in two critic passes.

### Web Inspector on a controller tab

What happens when the user opens Web Inspector on a controller tab while the hidden frontend is connected. Candidates:
refuse the user's inspector while a controller holds the tab, end the controller's bridge and tell it, or show the
user's inspector and keep both if WebKit allows it.

Decision: the user's inspector takes precedence. Opening it stops command admission to the hidden bridge, cleans up
its debugger and network state, and invalidates its requests, result references, and subscriptions. Pending calls get
a bridge-ended error. The user inspector opens after bounded cleanup confirms the old session is no longer active.

A failed cleanup shows a stopped/recovery state instead of claiming a safe handoff. It never automatically reloads or
replays a form. The controller can reconnect only by an explicit command after the user's inspector closes. The host
rejects late messages from the old bridge generation. Direct capabilities do not reacquire the inspector implicitly.

Rationale: refusing the inspector leaves the user waiting on the controller. Sharing one frontend gives both parties
control of the same debugger and domains. Converged in one critic pass; handoff races become M1 and M9 checks.

### Response bodies

How large a body may be, and how it reaches the script. Candidates: inline in the event up to a limit, or fetched on
request by a request ID while WebKit still holds it.

Decision: events contain metadata and opaque request references, never inline response bodies. Fetching a body
requires network read. A reference binds the run, tab, bridge session, navigation generation, and protocol target.
A missing or evicted WebKit body returns an expired-result error. Fetch never repeats the network request.

A fetched body is at most 8 MiB decoded. Retained text, binary, and base64 representations count toward a 32 MiB per-run
budget, including in-flight chunks and temporary copies owned by the adapter. One transfer is active per tab. The
frontend retains it for at most 30 seconds from creation, or until explicit release. Closing, revoking, replacing the
view, or ending the session invalidates it immediately.

Chunks carry at most 16 KiB of decoded data. JSON and base64 overhead count toward the existing 32 KiB argument and
64 KiB control-message limits. The full reply fits ScriptWire's reply payload limit. Only bounded chunks cross into
the app. Bulk decoding and slicing happen in the frontend's content process. The host independently validates each
chunk's size, shape, reference, offset, and remaining quota before forwarding it.

Profiles, heap snapshots, and oversized raw command results use the same bounded result path and per-run budget.
Their retained representation is capped at 8 MiB per result. No sensitive temporary files or filesystem grants are
introduced. Integration reuses UTERM-019's eventual large-result mechanism if it satisfies these bounds; this proposal
does not decide how UTERM-019's snapshots, PDFs, or JavaScript values work.

WebKit may materialize the whole protocol result internally before the frontend can reject it. M1 measures whether
WebKit routes that data through uniterm's process. Chunking after an unbounded host callback is not sufficient. A route
that cannot bound host ingress does not enable bulk results and stops for a design decision before claiming M6/M8.

Rationale: lazy fetch preserves the event budget and fits the existing wire without discarding useful bounded bodies.
The fixed limits are explicit product bounds, not measured WebKit thresholds. Converged in one critic pass; ingress and
aggregate-accounting caveats become M1/M6 checks.

### A paused page

What happens when the debugger pauses a page and the script stops responding. Candidates: resume at run end only, resume
after a timeout, or let the user resume from the pane.

Decision: every debugger pause has a fixed 30-second deadline measured by a host timer independent of the script.
The pane immediately offers Resume and Stop. A heartbeat or another controller call cannot extend the deadline.

Deadline, user Resume/Stop, run end, revocation, or bridge loss resumes the page and removes the bridge's breakpoints
and pause-on-start state. Deadline or user recovery disables controller debugging for that session so a recurring
breakpoint cannot pause it again. Reconnection requires an explicit command. Raw debugger calls follow the same rule.
Pending command replies never block the host timer or recovery controls.

If cleanup cannot confirm a resume, the bridge ends and the pane shows the stopped state with explicit tab recovery.
It never reloads or replays a form automatically. Recovery and resume act on the old session only; they cannot affect
a replacement web view or the user's inspector.

Rationale: run-end cleanup leaves a live but unresponsive controller's page paused. User recovery alone requires
attention. The deadline supplies unattended recovery without taking that control away. Converged in one critic pass;
recurring breakpoints become an M8 check.

### Timezone scope

`timeZoneOverride` sits on the process pool configuration, so it may apply to every page, not one tab. Candidates:
offer it only when no user tab would be affected, give controller tabs their own configuration if WebKit allows it, or
use the inspector protocol's override instead if it is per page.

Decision: timezone is available only through a route proven to affect the addressed controller tab alone. Prefer a
per-target protocol override when the shipped schema and behavioral tests establish it. A process-configuration route
is allowed only when tests prove isolation despite WebKit's process sharing and reuse. A fresh process-pool object is
not proof. The browser keeps its existing shared website data store and logins.

The tests cover two controller tabs with different zones, existing and later user tabs, navigation, process reuse,
view replacement, and teardown. No user tab or other controller changes zone. If neither route passes, timezone reports
unavailable and returns a structured error. Existing tabs are not silently recreated to apply it. This qualifies
"Direct private methods": timezone is a candidate there, not a promise that process-pool configuration is tab-local.

Rationale: having no user tab now does not protect a later one. A new profile changes the settled storage behavior.
The safe result can be unavailability when the platform cannot honor tab scope. Converged in one critic pass.

### Effective target scope

How raw commands and worker observation/control preserve the tab-only boundary when WebKit exposes shared targets or
state. Candidates: validate routing identifiers only; admit commands only with an established effect scope and teardown
contract; or put controller tabs in new isolated profiles.

Decision: a routing ID alone is insufficient. Typed and raw methods are admitted only when the tested adapter has an
established effect-scope and teardown contract for them. Unknown or unconfineable methods return an error before
effects. Raw parameters stay protocol-shaped; the adapter need not provide typed wrappers for every accepted method.

The router owns protocol request IDs and subscriptions. Nested Target and Worker messages are unwrapped and checked.
Every referenced target must remain a live, owned descendant of the addressed tab. No page-created popup, other tab,
global store administration, or unknown target is reachable. Enabling instrumentation or pausing on attachment also
requires this check. Navigation, scheme, and native-handoff safeguards still apply through raw commands, as the rules
every tab follows. Amended 2026-11-21; see Decision Log.

Shared storage effects of ordinary page operations retain the browser's existing semantics. Tab ownership is not
storage isolation. Raw permission cannot expand origin/storage authority beyond operations attributable to the tab.
Worker events and debugging require provable attribution and exclusive effect scope. A shared/service worker with
other clients or unknown ownership is unavailable. Ownership is checked again as clients and targets change.

Every admitted stateful method has a verified reset on session end. Calls that can install untracked persistent
inspector state are refused. Session teardown ends admission first, cancels pending work, resets debugger/network/
emulation state, and invalidates references before the user's inspector or a new session can take ownership.

Rationale: unrestricted forwarding cannot establish tab-only effects in shared storage or worker contexts. New profiles
would change shared logins without solving target association. Converged in one critic pass. This narrows the blanket
raw and worker promises and was approved at the final review gate.

### Native private-call failures

Whether "never crashes the app" can cover an ABI-compatible private method that traps or corrupts native state.
Candidates: retain the unconditional guarantee; state an ADR-07 exception for the unavoidable in-process WebKit calls,
with tested-build admission and explicit residual risk; or redesign browser hosting in another process.

Decision: recoverable private failures return structured errors. An ABI-compatible native trap or memory corruption
cannot be safely converted to one. The fixed native call sites that address the app-owned WKWebView are a stated
ADR-07 exception, approved at the final review gate. A helper cannot call methods on that view across a process boundary.
Moving the view would require a separate browser-rendering and input-hosting design.

The exception covers only the native compatibility adapter. It accepts no caller-named selector, symbol, pointer, or
FFI operation. Tested-build admission and ABI/name checks guard each fixed call site. Arguments and messages are
bounded. Missing names and incompatible signatures are refused without calling the method. Recoverable protocol,
WebKit completion, validation, and timeout failures become errors. A residual native defect can still end the app.

Frontend JavaScript remains outside the app. This exception does not permit unbounded page data to traverse the app or
relax the M1 ingress proof. Uniterm does not run unknown-build behavioral probes inside the user's app.

Rationale: keeping the unconditional no-crash promise is false for native traps. Remoting browser hosting adds an
unproven architecture outside this review's scope. Converged in one critic pass. The residual risk is recorded as
medium likelihood and high impact; the user approved replacing the earlier guarantee at the review gate.

### Versioned contracts

Decision: the new commands, event kinds, result references, and six permission meanings use UTERM-019's versioned
browser schema, descriptor, and API contracts. Unknown permissions never inherit an older approval. Stored policies
cannot authorize a meaning they did not approve. Result references are opaque, ephemeral, and valid only in their
own run and session; they are not persisted data formats.

The app and its command/helper can skew during an in-place bundle update. An old helper against a new app, or a new
helper against an old app, is refused by name before effects, since a wire, API, or schema this build does not know is
an unknown name. The wire, the API, and the schemas are at version 0 under UTERM-063, so nothing bumps. No new frame
kind or larger frame is introduced here. A wire change found necessary during integration lands in place, takes a new
name for a changed meaning, and is refused by name in both directions. It cannot silently reinterpret a message.
Amended 2026-11-27; see Decision Log.

WebKit and the app also update independently. Old adapter/new WebKit and new adapter/old WebKit are both eligible only
for a passing exact tuple and successful connection validation. Otherwise private support is unavailable. Public
operations keep their own support rules. No deployment order or production deployment gate is required.

Rationale: platform version checks do not substitute for caller compatibility or permission semantics. This makes
explicit the existing rejection rules across the units this proposal joins.

### Protocol drift

How the startup probe detects inspector protocol changes. Candidates: read the protocol definitions the frontend loads
and check each command uniterm uses, or send a harmless command per domain at first use.

Decision: startup reports build support from the tested adapter record and local name and ABI checks. It never starts
an inspector or waits for WebKit. Session readiness is separate from that immutable support set.

On connection, the adapter asynchronously compares available frontend registration metadata against its expected used
methods, request parameter categories and optionality, reply/event field names, and target applicability. Missing or
incompatible metadata fails readiness. M1 establishes what the shipped frontend actually exposes. The adapter does
not assume it exposes recursively typed reply/event definitions: upstream InspectorBackend.js does not.

The adapter owns complete recursive schemas for curated command arguments, actual replies, and event values. Every
actual message is validated against those schemas at the boundary. Invalid data fails and invalidates the affected
session. A bounded non-mutating handshake checks the live route. Behavioral smoke tests cover semantics the metadata
cannot prove. Raw envelopes and target wrappers still receive shape, size, and effect-scope validation.

No inspector-backed command executes before readiness succeeds. Each new inspector session or replacement target
validates again. A late completion cannot ready its replacement. Direct native commands use local compatibility and
scope checks without opening an inspector. Errors name the affected capability without changing the startup support set.

Rationale: requiring full live type definitions would unnecessarily disable frontends exposing only shallow
registrations. A harmless command alone misses drift elsewhere. Registration checks plus actual-value validation are
attainable and complementary. Reopened once and converged in one critic pass on new source evidence; the original
question converged in two passes. Amended 2026-11-11; see Decision Log.

## Design Decisions (Open)

None.

## Risks

- **Raw or worker effects escape the controller tab** — likelihood: medium, impact: high. A routed command can touch
  shared browser storage or a worker used by another tab. Mitigation: "Effective target scope" must establish effect
  confinement before admission; routing IDs alone do not prove it.
- **A tested native private call still traps in the app** — likelihood: medium, impact: high. Names and ABI checks
  cannot catch every semantic change or native defect. The higher likelihood is used because no runtime safety proof
  exists. Mitigation: tested-build admission, restricted fixed call sites, and bounded inputs reduce exposure. The
  residual in-process exposure was explicitly accepted at the review gate under "Native private-call failures".
- **A macOS update removes private capability availability** — likelihood: high, impact: medium. An untested tuple is
  intentionally disabled until an app update supplies passing records. Mitigation: release smoke tests cover each
  supported build; errors name the unsupported tuple and preserve public automation.
- **Unbounded protocol materialization crosses the host** — likelihood: medium, impact: high. Frontend slicing alone
  cannot bound WebKit's internal routing. Mitigation: M1 measures oversized messages before any bulk capability is
  enabled; a failing route stops for a design decision.
- **The automation foundation changes during implementation** — likelihood: high, impact: medium. UTERM-019's
  permission descriptor, asynchronous commands, and large-result contract are still in design. Mitigation: integrate
  against its settled contract, reuse compatible result transfer, and recheck admission and wire limits in M3.

- **A macOS update breaks a private path in a way the probe cannot see** — likelihood: high, impact: medium. A method
  keeps its name and changes its meaning. Mitigation: smoke tests run on each beta and point release. Recoverable
  failures return errors. The native-trap residual is listed separately.
- **The bridge depends on the inspector frontend's internal JavaScript** — likelihood: high, impact: medium. That code
  has no contract at all. Mitigation: the bridge lives in the one private module, and the probe checks for the objects
  it uses.
- **Network read hands a controller the user's credentials** — likelihood: medium, impact: high. Bodies and headers can
  hold tokens. Mitigation: network read is its own permission, its review says so, and it covers only controller tabs.
- **Interception can change what a signed-in session sends** — likelihood: medium, impact: high. Mitigation: network
  control is its own permission, limited to controller tabs.
- **Raw passthrough grants all admitted inspector powers** — likelihood: medium, impact: high. Accepted: its review
  says so, and "Effective target scope" refuses methods whose effects or teardown are not established.
- **Both connection proofs fail** — likelihood: medium, impact: high. Most of this proposal would then be undone.
  Mitigation: connection proofs come first, and "Fallback order" preserves a user decision before any deferral.
- **The capability names become a published contract** — likelihood: high, impact: medium. Mitigation: names are
  append-only and never change meaning, as UTERM-019 "Capability names and the unavailable error" settles. Amended
  2026-11-11; see Decision Log.

## Milestones

### M1: Hidden inspector connection adapter

**Status:** NOT STARTED

Starts after UTERM-019 M1. Implements the first private-module connection slice and proves the route before dependent
features. A failed proof records the error and keeps its capability unavailable; it does not ship an unverified path.

- A hidden inspector frontend connects to a controller tab without showing a window, or the result is recorded
- A bridge script in the frontend sends one protocol command and receives its reply and one event, or the result is
  recorded
- Whether the frontend's JavaScript runs outside uniterm's process is recorded, with how it was measured
- Whether the user can still open Web Inspector on that tab is recorded
- The result and the macOS build are recorded in the As built block, and the user rules on the next step
- A user opening Web Inspector stops hidden-session admission before cleanup; late replies cannot revive it
- Oversized protocol bodies are measured at the host boundary; full results never enter host callbacks before slicing
- The frontend cannot receive a controller message from the inspected page, another view, or an old session
- Targets are owned before instrumentation is enabled; replacement targets require fresh validation
- The shipped frontend exposes the registration metadata the adapter needs, or connection reports unavailable

### M2: Remote-inspector transport fallback

**Status:** NOT STARTED

Implements the alternate connection route only if M1 shows the hidden bridge cannot work. Otherwise the user decides
whether to drop it. No drop is authorized by this review.

- Whether uniterm can connect to `webinspectord` and reach its own web views is recorded, with the error if it cannot
- The user rules on the next step

### M3: Private API module and compatibility

**Status:** NOT STARTED

- One module holds every private WebKit call, and a make check fails when another module reaches private WebKit API
- The startup probe reports each private capability into the capabilities set
- A capability whose name is missing reports off, and its command returns a structured error
- A recoverable private failure returns a structured error; missing or mismatched native methods are never invoked
- The name probes run with the unit tests in milliseconds
- A separate make target runs the behavioral smoke tests
- Unknown build tuples and failed prerequisite checks keep each affected capability off
- The shipped adapter revision and architecture match the smoke-test record
- An inspector-backed command cannot run before readiness; late validation cannot ready a replacement session
- Missing/incompatible registration metadata and recursive malformed values invalidate the session before delivery

### M4: Direct private methods

**Status:** NOT STARTED

- Resource-load observation reports each load of a controller tab as a page event, without bodies
- Script evaluation with a user gesture opens a pop-up that untrusted script cannot
- Device-scale overrides apply only to their tab; timezone passes "Timezone scope" or reports unavailable
- Each has a smoke test
- Timezone isolation passes every scenario in "Timezone scope", or the capability stays unavailable
- User-gesture evaluation requires browser input

### M5: Console and exceptions

**Status:** NOT STARTED

- Console messages and uncaught exceptions appear as page events, including only workers admitted by "Effective
  target scope"
- Event volume past the bound drops the oldest events and counts them
- A smoke test covers both
- An event read cannot expose retained console data after its console grant is revoked
- A worker with other clients or uncertain ownership produces no controller-visible data

### M6: Network observation

**Status:** NOT STARTED

- Every request and response of a controller tab appears as a page event with its headers
- A script with network read gets a response body within the size limit
- Bodies past the limit are refused with a structured error and never reach the main thread whole
- A smoke test covers a page, a subresource, and a fetch
- Body expiry and eviction never repeat a request; stale run, tab, target, or navigation references are refused
- Concurrent tabs, encoding copies, and queued chunks stay inside the aggregate transfer budget
- An event read cannot expose retained network data after its network-read grant is revoked

### M7: Network control

**Status:** NOT STARTED

- A script intercepts a request and lets it continue, changes it, or answers it with a mock
- Throttling and cache control apply to the controller tab only
- Interception rules end with the run
- A smoke test covers each
- An unanswered interception continues unmodified within 30 seconds under a host-owned timer; late answers fail
- Stop, revocation, tab/view replacement, and bridge loss release pending interceptions and remove rules,
  throttling, and cache overrides without replaying a request
- Shared targets and other tabs retain their settings when controller network state is reset

### M8: Debugging

**Status:** NOT STARTED

- A script sets a breakpoint, receives the pause as an event, and resumes
- A profile and a heap snapshot return within their size limits
- CSS matched rules return for a node
- A paused page follows the rule settled under "A paused page"
- A recurring breakpoint cannot re-pause the page after deadline or user recovery
- The pause timer and pane controls work while the controller stops reading events
- Debugger effects cannot pause another tab or shared worker; user-gesture evaluation actions require browser input

### M9: Raw protocol passthrough

**Status:** NOT STARTED

- An admitted raw command sends one scoped protocol message and returns its reply; unknown effect scopes are refused
- A controller without browser inspector raw gets a structured error
- An oversized or malformed raw reply is refused with a structured error
- Raw floods cannot exhaust typed/control ingress or evict typed history through raw retention
- Raw read replies fit the serialized wire limit and preserve the cursor for unread events
- A pending raw read rechecks its grant and session at completion; subscription churn releases all quota
- Nested raw messages cannot address other tabs, origins, global storage administration, or unknown targets
- Stateful raw methods without verified session reset are refused before effects

## Decision Log

- 2026-11-11: Drafted from the findings note `spec/reports/20261111-wkwebview-automation-vs-cdp.md`, after UTERM-019.
  The user chose typed commands plus a raw escape, five permissions plus raw, and one private module with a make
  check. The user set the fallback order: the bridge, then `webinspectord`, then direct private methods. A uniterm CA
  proxy comes last, since the user is wary of installing one.
- 2026-11-11: Placing user-gesture script under browser input was a best guess in the permission options. The user
  chose that option. The "Isolation" points come from the ADR check. The user approved the outline that listed them.
- 2026-11-11: ADR check: ADR-07 and ADR-08 need the frontend's process and the main thread's load addressed, which
  "Isolation" does. ADR-09 shapes "Permissions". ADR-01's pattern shapes "The private API boundary". Possible ADR
  candidate: private WebKit as a dependency, mirroring ADR-01. A related "no private API in shipping code" candidate
  was declined before, so it is not raised.
- 2026-11-11: Review start: 9 milestones, 9 settled decisions, 7 risks, no `**Live after:**` lines or row gates; out
  of scope: user-owned tabs, a new helper process, restored inspector state, and a TLS proxy without a separate
  decision. Proposal at commit `Draft the inspector bridge for controller tabs`. The user requested autonomous
  review and one commit at the end.
- 2026-11-11: (autonomous, addition) Untested macOS builds: enable private capabilities only for a bundled passing
  macOS/WebKit/architecture/adapter tuple, with local name and ABI checks. Adds release-maintained compatibility
  records; smoke tests run in a disposable test app. Converged in one pass.
- 2026-11-11: (autonomous) Timezone scope: require demonstrated tab-only behavior with shared storage unchanged, or
  report unavailable. Converged in 1 pass.
- 2026-11-11: (autonomous) A paused page: combine a 30-second absolute deadline, immediate pane recovery, and
  cleanup independent of the script. Converged in 1 pass.
- 2026-11-11: (autonomous) Response bodies: fetch by scoped reference and transfer bounded chunks within existing
  wire limits; share the path with profiles, heap, and raw results. Converged in 1 pass.
- 2026-11-11: (autonomous) Web Inspector on a controller tab: yield the hidden bridge to the user after cleanup;
  reject old-generation work. Converged in 1 pass.
- 2026-11-11: (autonomous) Raw events: use a separate bounded ring, independent cursor and drops, and reserved
  typed/control admission. Converged in 2 passes.
- 2026-11-11: (autonomous) Protocol drift: keep startup support local and immutable; validate full curated schemas
  and live readiness per session. Converged in 2 passes.
- 2026-11-11: Coherence review: routed abandoned-interception recovery to M7 and permission rechecks on retained
  typed events to M5/M6. Opened effective target scope and native private-call failures for design review. Added
  risks for shared targets, native crashes, compatibility-record availability, host ingress, and the in-flight
  foundation.
- 2026-11-11: (autonomous) Native private-call failures: replace unconditional crash recovery with recoverable
  errors and an explicit bounded ADR-07 native-call exception. Converged in one pass. Final gate approval is pending
  for the guarantee change and medium-likelihood/high-impact native crash residual. M3 and the compatibility risk
  are amended.
- 2026-11-11: (autonomous) Effective target scope: admit methods only with established effect scope and teardown;
  validate nested targets and exclusive worker attribution. Converged in one pass. Narrows blanket raw/worker
  coverage; final gate approval is pending. This does not change the browser's shared website data store.
- 2026-11-11: Reopened Protocol drift once: upstream InspectorBackend registrations retain shallow request
  signatures and reply/event names, not complete referenced schemas. The prior requirement to inspect complete
  loaded definitions needs a realizable validation contract. Source: WebKit's InspectorBackend.js, checked
  2026-11-11.
- 2026-11-11: Format correction: M1/M2 name connection-adapter implementation slices with their existing proof
  checks, rather than design-only spikes. Fallback failure leaves later milestones NOT STARTED pending a user
  decision; `deferred` is a proposal status, not a milestone status. No milestone was dropped or deferred.
- 2026-11-11: (autonomous) Risk review: the five new risks use explicit mitigations. Native trap likelihood remains
  medium conservatively because no in-process containment proof exists; the residual goes to the final gate.
- 2026-11-11: (autonomous) Risk review: recorded both app/helper skew directions and both adapter/WebKit directions.
  Unsupported meanings fail before effects; no new wire frame, saved reference, or deployment ordering is
  introduced.
- 2026-11-11: (autonomous) Protocol drift re-settled: compare available live registration metadata and recursively
  validate actual messages against adapter-owned schemas. Full live reply/event types are not assumed. Converged in
  one pass on WebKit source evidence; the complete-schema introspection requirement is replaced, not deferred.
- 2026-11-11: ADR candidate (cuts across the system): unstable private WebKit details stay behind a uniterm-owned
  boundary for every caller. Declined: the user chose no ADR on 2026-11-11. Architecture: browser and future
  integrations must obey the boundary.
  Decision: one enforced module owns private API. Record: the boundary holds whichever transport succeeds.

- 2026-11-11: Coherence review converged in two whole-proposal passes: one full review and one re-check. The re-check
  found no design defects or further additions. Protocol drift reopened once on new source evidence and re-converged.
  Sixteen grouped implementation findings are covered by checks in M1 and M3-M9: compatibility prerequisites, session
  generations, host ingress, bulk accounting, inspector handoff, raw admission, reply bytes/cursors, pending raw reads,
  repeated pauses, timezone isolation, abandoned interceptions, retained-event permissions, nested/shared targets,
  metadata/value validation, input authority, and frontend message origin. No milestone or deployment gate was added.

- 2026-11-11: Review gate: kept all decisions. The user kept the compatibility-record addition, approved narrowed
  raw/worker coverage, and approved the bounded native-call exception and its residual app-crash risk. Nothing reopened.
- 2026-11-11: The user accepted the proposal and declined an ADR. Acceptance does not schedule any milestone.
- 2026-11-11: Risks amended: the capability-name mitigation said the names follow `uniterm/api-version`. UTERM-019
  settled append-only names instead, with no schema bump. UTERM-019 "Result encoding" also settled the byte type that
  carries this proposal's 16 KiB body chunks, which a 4096-byte script string could not.
- 2026-11-21: Amended "Effective target scope" and the M4 user-gesture check. ADR-12 was retracted on 2026-11-20, and
  UTERM-037 applied that to the browser's remote commands. A program's operation is the same operation as the user's.
  The text said "Navigation, scheme, focus, and native-handoff safeguards still apply through raw commands", and M4
  said user-gesture evaluation "obeys the focused-pane restriction". UTERM-019 no longer restricts input to an unfocused
  pane, so that clause is gone. The raw-command safeguards no longer name focus. They name the scheme and handoff
  rules every tab follows. (work-queue best guess)
- 2026-11-22: Scheduled as UTERM-020 M1-M9 in queue.md.
- 2026-11-27: Brought in line with UTERM-063 at the user's direction. The skew paragraph said an old helper or app
  "refuses an unsupported wire/API/schema or permission version before effects", and that a wire change "takes the
  existing version handshake and rejection rule in both directions". External versions stay at 0 and carry no
  handshake offer, so it now says an unknown name is refused by name and a changed meaning takes a new name.

## References

- [WebKit InspectorBackend](https://github.com/WebKit/WebKit/blob/main/Source/WebInspectorUI/UserInterface/Protocol/InspectorBackend.js):
  upstream registration metadata, checked 2026-11-11; shipped behavior remains an M1 check
- [WebKit Network protocol](https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/inspector/protocol/Network.json):
  body fetch and interception shapes, checked 2026-11-11
- [WebKit process-pool configuration](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/_WKProcessPoolConfiguration.h):
  timezone candidate and process-pool deprecation, checked 2026-11-11
- [WebKit Target protocol](https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/inspector/protocol/Target.json):
  nested targets and worker types, checked 2026-11-11

- Findings note: `spec/reports/20261111-wkwebview-automation-vs-cdp.md`
- [ADR-01](../adr/ADR-01-libghostty-behind-terminal-surface-protocol.md): the pattern for an unstable dependency
- [ADR-03](../adr/ADR-03-restored-state-never-runs-a-program.md): nothing a controller sets is restored
- [ADR-07](../adr/ADR-07-failure-isolation.md): failure isolation
- [ADR-08](../adr/ADR-08-ui-responsiveness.md): no main-thread wait
- [ADR-09](../adr/ADR-09-control-authority-requires-authenticated-identity-and-explicit-scope.md): each power is its
  own permission
- [ADR-10](../adr/ADR-10-app-unsandboxed-helpers-sandboxed.md): no new helper
