# Architecture

## The one decision everything follows from

"Purely Swift" means Swift everywhere *above* the engine, WebKit below it.
Writing an HTML/CSS/JS engine is a Ladybird-scale project. `WKWebView` gives a
multi-process sandbox, JIT'd JavaScriptCore, and security patches from Apple at
zero maintenance cost. Everything worth differentiating on lives above that line.

## Module boundaries

Every module except `BrowserApp` is a Swift package with **no AppKit and no
WebKit dependency**. That is what makes them testable off-device, and it is not
an accident — it is the constraint that keeps the model layer honest.

No WebKit type is permitted in a persisted model. `interactionState` is opaque
`Data`. This is why `TabState` is `Codable` and `Sendable` for free.

## Profiles

`WKWebsiteDataStore(forIdentifier:)` is the isolation primitive. Each profile
owns a data store, a process pool, a SQLite database, a downloads directory, an
extension set, and a Keychain access group.

**Window ↔ profile is 1:1.** A window cannot mix profiles. The alternative —
per-tab profiles — makes "which identity am I browsing as" unanswerable at a
glance, which is the entire point of having profiles.

Never call `WKWebsiteDataStore.default()`. Not even in a spike.

## Tab residency

Live web views are expensive; the model treats residency as explicit state
rather than something emergent. `EvictionPolicy` is a pure function of
`(live tabs, active tab, memory pressure)` returning tabs to hibernate. Pinned
and active tabs are never evicted.

Hibernation captures `interactionState` (back-forward list, scroll, form state)
plus a snapshot image, then tears the view down. Restoration is visually
seamless.

## Blocking

Content rules compile to bytecode that runs in WebKit's network process before
dispatch — no per-request JavaScript. Architecturally faster than Chrome MV3.

Pipeline: fetch ABP lists → resolve `!#include` recursively → evaluate `!#if` for
`env_safari` / `adguard_ext_safari` → punycode domains → convert to
`ContentRule` → `canonicalized()` → `partition()` → compile off-main → cache by
SHA with ETag-driven incremental updates.

The partitioner's two hazards are documented in the README and locked down by
tests. Read `RulePartitioner`'s doc comment before changing it.

Cosmetic filtering uses `css-display-none`. Scriptlets and procedural filters
need `WKUserScript` at `.atDocumentStart`. Full uBO parity is not achievable;
`WKWebExtension` (macOS 15.4+) is the escape hatch for coverage.

## Dev tools

Observation sources fan into one `InspectorRecorder`, which starts with the
tab and outlives documents:

1. **Agent, isolated world** (`agent.js`) — a named `WKContentWorld` at
   document start. Page code cannot see or override it. It observes what is
   shared across worlds: the DOM (`MutationObserver`), uncaught exceptions
   (`error` events on `window`), and the complete resource-timing inventory
   of the document — every image, script, stylesheet, font, fetch and XHR,
   with timing and byte counts but no headers, methods or bodies.
2. **Agent, page world** (`page-hooks.js`) — `console`, `fetch` and
   `XMLHttpRequest` are *per-world objects*. Wrapping them in an isolated
   world observes nothing, so these hooks run in the page world, where they
   see console output and the status, headers and bodies of JS-initiated
   traffic. Page script could in principle detect or replace them. Events are
   labelled `pageWorld`; the bridge assigns the label from the handler a
   message arrived on, never from the payload.
3. **Navigation delegate** — timeline, redirects, errors.
4. **Proxy** — `proxyConfigurations`, no MITM in the MAS build. Complete
   request inventory including prefetch and beacons; no bodies. Not wired yet.

The network sources disagree by design, so `EventSource` is carried on every
event. When the isolated world counts 47 resources and the page hooks count
41, the UI says so rather than presenting a partial picture as complete.

### The DevTools UI

The panels are an HTML app (`BrowserApp/DevToolsUI`) in a second web view,
docked in an `NSSplitView` next to the page or in its own window. It talks to
`DevToolsController` over a script message handler with Chrome-style method
names, and the controller routes each call to where it can be answered:

- `DOM.*`, `CSS.*`, `Overlay.*`, `Storage.*` → `dom-agent.js` in the isolated
  world, which owns the node registry, the highlight overlay and the picker.
  The DOM and CSSOM are shared across worlds, so this is both complete and
  tamper-proof.
- `Runtime.*` → `page-hooks.js` in the page world, which keeps the remote
  object registry for lazy expansion and evaluates console input with the
  command-line API in scope. `$0` crosses worlds via a `CustomEvent`
  dispatched on the node: the event's target is the same node in every world.
- `Network.*`, `Console.*`, `Cookies.*` → the controller itself, from the
  recorder, `NetworkRequestLog` (which merges the two agents' views of one
  request) and `WKHTTPCookieStore`.

### The inspector protocol bridge

The debugger is the `InspectorBackend` half of the seam below, and it turned
out not to need a reimplementation of anything. `_WKInspector.connect`
creates WebKit's inspector frontend *without showing it*; that frontend is an
ordinary web view (`inspectorWebView`) whose script owns the protocol
connection to the page. `InspectorProtocolBridge` evaluates a shim in it that:

- sends our commands on `WI.mainTarget.connection`, with ids from a range the
  frontend never uses, and keeps those responses away from the frontend;
- copies every backend event to us over a script message handler;
- swallows `Debugger.paused` / `Debugger.resumed` before WebKit's frontend
  sees them, because it raises its own window on a pause.

`DevToolsController` attaches when DevTools opens, blackboxes our injected
agents (`^user-script:`) so stepping never enters them, deactivates
breakpoints and resumes when DevTools closes, and fails agent calls fast while
paused (page script cannot run, so they would otherwise hang). Scripts parsed
before we attached are recovered from the frontend's own table. The UI side is
`DevToolsUI/debugger.js`, speaking raw protocol through `Protocol.send`.

The same bridge feeds the Network panel (`Network.*` events become
`NetworkEvent`s with source `inspector`, merged with the agents' view of the
same request) and Sources (`Page.getResourceContent` returns the bytes the
engine loaded, which is what breakpoint line numbers refer to).

Two behaviours of WebKit that the DevTools are built around, both measured
rather than assumed:

- **A paused page dies in a hidden window.** WebKit suppresses the process of
  a page whose window is not visible, and a page paused in the debugger stops
  answering inspector messages about three seconds into that. The only
  effective lever is `pageVisibilityBasedProcessSuppressionEnabled = false`,
  and only at configuration time (`WebInspectorSPI.keepDebuggableWhenHidden`);
  changing it later, disabling App Nap and disabling window occlusion
  detection at runtime all do nothing. Cost: pages in hidden windows are not
  napped, which is tab hibernation's job anyway.
- **The sampling profiler cannot walk optimised code.** The first run of a hot
  loop yields a stack per millisecond; once it is JIT-compiled the same
  150 ms yields five. Having the debugger attached makes no difference.
  `profiler.js` therefore times script tasks from the `Timeline` domain and
  divides each task among the samples inside it, marking thin stretches as
  estimates.

Everything in the bridge is private API reached by selector with runtime
probes, plus WebKit-internal JavaScript names inside the shim. Both can change
in a macOS update; `scripts/test-devtools.sh` is the tripwire, and
`--protocol-probe <file>` dumps what the running WebKit exposes.

### Instrumented mode

For bodies without MITM: cancel the navigation, fetch natively, hand WebKit the
bytes via `loadSimulatedRequest`. Origin is derived from the URL, so cookies,
CORS and storage behave. Subresources go through a `WKURLSchemeHandler` after
HTML rewriting.

This reimplements a network stack — cookie sync, HSTS, redirects, auth
challenges, POST navigations — and loses HTTP/3. It also breaks CORS mode, SRI,
`import.meta.url` and `document.currentScript.src`. **So it is opt-in per origin
with an explicit reload**, never the default. The UI labels it an instrumented
run.

### The debugger seam

`DebugBackend` has two implementations. `InstrumentedBackend` rewrites JS,
pauses via synchronous XHR held open by a scheme handler, and reads scope
through direct `eval` closures — public API only, 3–10× slower. `InspectorBackend`
drives `_WKInspector` SPI — no cost, real JSC debugger, Developer ID builds only.

`InspectKit` never imports WebKit SPI directly. Injecting the backend at startup
is what keeps two distributions as one codebase.

Ship `isInspectable = true` and a "Debug in Safari" menu item regardless. When
instrumentation breaks a site, the user needs an out.

## Where this beats Chrome

Not on breadth. On four specifics Chrome is structurally unable to match:

- Native rendering — inspecting a janky page without the inspector itself janking
- Recordings that survive reload and relaunch, in SQLite
- **Diffing two recordings**
- One timeline correlated across every tab in a group

## Known hazards

- Google properties sniff for WebKit and serve degraded paths; a user-agent
  override table is permanent maintenance.
- DRM: FairPlay only. Widevine sites will not work.
- Private SPI breaks on macOS point releases — every SPI feature needs a runtime
  availability probe and a fallback.
- Password autofill means building or integrating a password manager.
- Local CA for the MITM proxy is opt-in per profile, never global.
