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

Pipeline, as built (`BlockKit/FilterParser`, `BlockKit/RuleSetBuilder`,
`BrowserApp/ContentBlocker`): fetch ABP lists with `If-None-Match` → check the
hiding selectors against WebKit's CSS parser → convert to `ContentRule`, in
canonical order → lists of 30,000 action rules, each ending with every
exception → compile → keep, named by a fingerprint of the list files and the
converter's version, so an unchanged set is looked up, never compiled again.
Not built: `!#include` and `!#if` (EasyList and EasyPrivacy use neither), and
punycode conversion (filters with non-ASCII domains are left out).

A filter with no type option becomes two rules: every resource type but
`document`, and `document` for third-party loads only. WebKit's `document`
is also the page itself, which ABP's default excludes; without this a filter
such as `/ads/` makes any site with `/ads/` in its address unreachable.

Measured WebKit behaviour the design depends on:

- **An invalid selector is not a compile error.** WebKit compiles a
  `css-display-none` rule without parsing its selector. A selector its CSS
  parser rejects then makes the rule hide nothing, and so does every selector
  sharing that rule. Hence `SelectorValidator`: each selector is tried with
  `querySelector` in an empty, offline page before any are put together.
  Unchecked selectors get a rule each.
- **Blocked loads are reported twice.** The navigation delegate's private
  `_webView:contentRuleListWithIdentifier:performedAction:forURL:` fires for
  the preload scanner's request and again for the parser's. The shield counts
  addresses, not calls.
- **Rule lists can be swapped on a live `WKUserContentController`**, and the
  change holds for the navigation being decided. That is how blocking is
  switched off per site: by the site of the page a tab is about to show.

The partitioner's two hazards are documented in the README and locked down by
tests. Read `RulePartitioner`'s doc comment before changing it.

Cosmetic filtering uses `css-display-none`. Scriptlets and procedural filters
need `WKUserScript` at `.atDocumentStart` and are not built yet; they are
counted as skipped. Full uBO parity is not achievable;
`WKWebExtension` (macOS 15.4+) is the escape hatch for coverage.

## Permissions

`BrowserKit/SitePermissions` holds choices by origin and decides a request
(`PermissionDecision`); `PermissionsController` is one tab's questions,
pop-up bar and capture indicator; `CertificateStore` holds certificate
problems and the exceptions made from them, in memory.

Measured WebKit behaviour:

- **`mediaDevicesEnabled` is off in this app by default.** Pages then have
  no `navigator.mediaDevices`. It is set on for every tab.
- **Whether a user opened a window is private.** `WKNavigationAction`'s
  `_isUserInitiated` is read by name; where it cannot be read nothing is
  held back.
- **The warning page takes the site's place in history** by
  `location.replace`, evaluated from the app, which a page's
  Content-Security-Policy does not apply to.
- **Not established:** what makes WebKit pass a page's `getUserMedia`
  request to the app. On 2026-09-28 it did in three runs, then stopped for
  the rest of the evening, in quiet runs and in front, with pretend devices
  and real, in normal and private windows; the request stays pending and
  the delegate is not called. Occlusion and window activity were each tried
  as the cause and neither was. The feature self-test reports the camera as
  not tested when this happens.

## Reader

`ReaderAgent/reader-agent.js` runs in its own isolated world, main frame
only. Detection is Mozilla's `isProbablyReaderable`. Extraction scores
containers by their paragraphs, then **copies** the winner into a new
document through an allow-list of elements and attributes; nothing is
cleaned in place, so what the agent does not know about cannot survive.

The article is served at `simplebrowser://reader/<token>?url=<article>` by
the same scheme handler as the start page, under a Content-Security-Policy
of `default-src 'none'` plus images and inline style. The token names an
article held in memory; a Reader address whose article is gone (a restored
session) answers with a redirect to the article. Everywhere the app asks
"what page is this tab on", a Reader page answers with its article's
address: the address bar, bookmarks, zoom, the session.

Measured WebKit behaviour:

- **Scroll position is lost on Back from a page of our own scheme, if the
  page was left within about a second of scrolling.** Between two http pages
  it is kept. `ReaderController` records the position as Reader is entered
  and puts it back if WebKit has not.
- **`WKFrameInfo` is stale after an app-initiated load.** A navigation
  action's `sourceFrame.request` and `.securityOrigin` still describe the
  page shown before. Decisions about who is asking go by `webView.url`.

Find uses `_findString:options:maxCount:` and `_WKFindDelegate` (private,
probed) for counts, the match index and frames; the public
`find(_:configuration:)` is the fallback and reports only found or not.

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
