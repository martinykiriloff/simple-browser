# SimpleBrowser

A native macOS browser. Swift above the engine, WebKit below it.

## Status

Early. `BlockKit`, `BrowserKit` and `InspectKit` are pure-Foundation packages
with no WebKit or AppKit dependency — they build and test anywhere a Swift
toolchain exists. `BrowserApp` is a single-window, single-profile shell with
working dev tools; tabs, hibernation, blocking and the proxy are not wired yet.

The partitioning algorithm in `BlockKit` has been verified against an oracle —
see [Verification](#verification).

## Browsing

Back, Forward, Reload and **Home** in the toolbar, plus an address bar that
takes a URL, a bare host, or a search. Home (also History → Home, ⇧⌘H) opens
the homepage set in **Settings** (⌘,): type a URL or a host such as
`example.com`, or use *Set to Current Page*. Left empty, Home opens the
default, `https://duckduckgo.com/`, which matches the default search engine.
The line under the field always says where Home will actually go; a search
phrase or a `javascript:` URL is not accepted as a homepage. ⇧⌘H also works
while the Settings window is in front: it sends the browser window behind it
home.

**New windows open with** (also in Settings) chooses what ⌘N, launch and a
click on the Dock icon start with: the homepage (the default) or an empty
page. Either way the keyboard stays in the address bar, so ⌘N and typing a
destination works while the homepage loads behind it.

```sh
scripts/test-ui.sh            # the app presses its own keys and buttons, then reports
```

macOS does not let an outside process press keys without the Accessibility
permission, so this test runs inside the app (`--ui-selftest <file>`). Key
presses are built as the window server builds them and sent through the main
menu, text goes through the field editor, and buttons perform their own
click, so the menu wiring, responder chain and delegates are what is tested.
It uses a scratch settings suite, so your own homepage is never touched. The
app takes focus for about half a minute, and the screen has to be unlocked:
macOS will not make a window key behind the lock screen, which the test
reports as an environment problem rather than a failure.

## Developer Tools

Our own DevTools, laid out and driven like Chrome's, docked to the page
(bottom, right, or a separate window). Shortcuts match Chrome: **⌥⌘I** toggles,
**⌥⌘J** opens the Console, **⌥⌘C** picks an element, **F12** toggles, and
right-click → *Inspect Element* opens the Elements panel on that node.

| Panel | What works |
|---|---|
| **Elements** | Live DOM tree with lazy loading, hover highlight with Chrome's box-model overlay, element picker, search (⌘F: text, selector or XPath), keyboard navigation, breadcrumbs. Edit attributes, text and outer HTML in place; delete, hide, scroll into view, copy selector, and **Break on…** subtree modifications, attribute modifications or node removal. **Styles** sidebar shows the cascade with overridden declarations struck through, inherited sections, media conditions, colour swatches, per-property enable/disable, in-place editing, adding properties and new rules, and **:hov** to force `:hover`, `:active`, `:focus` and the other states. **Computed** and **Layout** (box model). **Event Listeners**: every listener on the node (and, with *Ancestors*, up to the document and window), grouped by event, with handler name, capture/passive/once flags and a link to its source line; untick one to disable that listener without touching the page's code. |
| **Console** | Every level, `console.group`, `console.table`, repeat counters, uncaught errors and rejections with stacks linking into Sources, "Failed to load resource" for bad requests, filtering, preserve log, timestamps. Objects are expandable trees fetched lazily, like Chrome's. The prompt has history, autocomplete, top-level `await`, and the command-line API (`$0`–`$4`, `$`, `$$`, `$x`, `$_`, `copy`, `inspect`, `keys`, `values`). |
| **Sources** | Navigator grouped by origin, tabs, line numbers, syntax highlighting for JS, CSS, JSON and HTML (including embedded script and style), `{ }` pretty-print for minified JS, CSS and JSON, find in file, and links from console and network entries land on the line. **Source maps**: original files appear in the navigator, pauses, call stacks and console locations are shown at the original position, and a breakpoint set in an original file is placed at the right line and column of the bundle. **A real debugger**: click a line number for a breakpoint (persisted, survives reloads), right-click for a conditional breakpoint or a logpoint, pause, resume, step over / into / out (F8, F10, F11, ⇧F11 or ⌘\\, ⌘', ⌘;), pause on uncaught or all exceptions, `debugger;` statements, call stack, scope variables as lazy trees, watch expressions, and the Console evaluates in the selected frame while paused. **XHR/fetch breakpoints** (URL contains, or any request), **DOM breakpoints** and **Event Listener breakpoints** (mouse, keyboard, timers, animation frames and the rest) pause in the page's own code: the native function and our own hooks are left out of the call stack, and the banner names the node, URL or event. |
| **Network** | Every request from document start, merged from the two agents, WebKit's navigation response and, while DevTools is open, the inspector protocol: real status, request and response headers, and the response body exactly as the page received it, for every resource; WebSocket connections with a live Messages tab; type chips, text filter, sort, preserve log, **Disable cache** (while DevTools is open), right-click for **Copy as cURL / Copy as fetch / Copy URL / Copy response**, waterfall with DNS/connect/TLS/wait/download phases, and a detail pane with Headers, Payload, Preview (JSON tree, images), Response and Timing. HAR export. Where WebKit hides a body, *Fetch body again* re-requests it from the app with the profile's cookies. |
| **Performance** | **Record** (or *Reload and record*) captures a CPU profile and timeline: an event track (script, style, layout, paint), a zoomable flame chart, and Bottom-Up and Event Log tables; frames open their source. WebKit's sampler cannot see into optimised code, so script tasks are timed by the timeline and sparsely sampled stretches are drawn lighter and labelled as estimates. Plus FCP, LCP, CLS, INP, TTFB and long tasks as vitals, collected from document start for every page whether or not DevTools was open. |
| **Application** | Local and session storage (add, edit, delete, clear), cookies from the profile's cookie store including HttpOnly ones, IndexedDB names, page info. |
| **Device mode** | The phone icon gives the page a device's viewport (iPhone, Pixel, Galaxy, iPad presets, rotate) and user agent, centred on a backdrop. Media queries and UA sniffing respond; touch events and pixel ratio are not emulated. |

Not available because this WebKit does not offer them: network throttling
(`Network.setEmulatedConditions` is not in the protocol here) and a Service
Workers pane (no `ServiceWorker` domain).

Three things are structural differences from Chrome rather than features:
recording starts when the tab exists, not when the panel opens; the recording
outlives the document, so it spans reloads; and the observations that must be
trustworthy come from an isolated world page script cannot reach, while the
ones that cannot (console, fetch bodies) are labelled as such.

The UI is an HTML app in its own web view, exactly as Chrome's is, backed by
two injected agents (`InspectKit/Resources`) and a Swift controller
(`DevToolsController.swift`). That much uses public API only and ships
anywhere.

The debugger and the full network data come from the **WebKit Inspector
Protocol**, reached through `InspectorProtocolBridge.swift`: WebKit's own
inspector frontend is connected but never shown, and a shim in it relays
protocol messages to us. That is private API (`_WKInspector`), probed at
runtime: a Developer ID / DMG build gets it, and where it is missing the
Sources sidebar says so and everything else keeps working. While DevTools is
closed nothing is attached, so pages run at full speed.

```sh
scripts/test-devtools.sh      # runs every check below against the debug build
```

### Testing the DevTools

There is no XCTest on a Command Line Tools-only Mac, so the DevTools are
tested by a script that runs *inside* the DevTools UI, drives every panel
against a local fixture site, and writes a pass/fail report:

```sh
python3 Tests/Fixtures/devtools/server.py &
swift run SimpleBrowser --show-devtools \
  --devtools-script Tests/Fixtures/devtools/drive-all.js \
  --devtools-out /tmp/devtools-report.json --devtools-delay 4 http://127.0.0.1:8765/
cat /tmp/devtools-report.json     # "passed": true, "failures": []
```

Launch flags for driving the app from a script:

```sh
.build/debug/SimpleBrowser --show-devtools https://example.com
.build/debug/SimpleBrowser --dump-recording /tmp/rec.json https://example.com
.build/debug/SimpleBrowser --show-devtools --devtools-script drive.js --devtools-out out.json https://example.com
```

## Requirements

- macOS 15.4 or later (floor set by `WKWebExtension`)
- Swift 6.0 / Xcode 16.3 or later

## Build

```sh
swift build
swift test
```

## Architecture

```
BrowserApp          AppKit shell, SwiftUI panels          (not yet written)
  ├─ BrowserKit     Tab / Group / Window / Profile models, residency
  ├─ ProfileKit     Data-store lifecycle, config factory   (not yet written)
  ├─ BlockKit       filter parse → partition → compile
  ├─ InspectKit     agent bridge, recorder, debug backends
  ├─ NetProbe       loopback proxy                         (not yet written)
  └─ Persistence    GRDB, one database per profile         (not yet written)
```

Full design rationale in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## The four pillars

**Profiles.** `WKWebsiteDataStore(forIdentifier:)` gives per-profile isolation of
cookies, localStorage, IndexedDB, service workers and cache at the WebKit level.
A window belongs to exactly one profile.

**Tabs.** A live `WKWebView` costs several processes and 60–150 MB. Background
tabs hibernate: capture `interactionState`, snapshot, tear down the view.
Eviction policy is a pure function in `BrowserKit/EvictionPolicy.swift`.

**Blocking.** `WKContentRuleListStore` compiles rules to bytecode that runs in
WebKit's network process before dispatch. Faster than Chrome MV3 by
construction. The 150,000-rule cap forces partitioning; see below.

**Dev tools.** Injected agent split across an isolated `WKContentWorld`
(tamper-proof: DOM, errors, resource timing) and the page world (console,
fetch and XHR bodies), plus WebKit's Web Inspector, plus — later — a loopback
proxy for ground truth and a `DebugBackend` with two implementations.

## Verification

`BlockKit`'s partitioner is the one piece whose correctness was proven before it
was written. Two bugs were found and fixed at design time:

1. **Dropped whitelists.** `ignore-previous-rules` is scoped to its own compiled
   list. Slicing a rule set naively leaves exceptions in one chunk while the
   blocks they cancel land in another — whitelists fail silently. Every exception
   must be replicated into every chunk.

2. **Order inversion.** Hoisting exceptions to the tail changes meaning when an
   exception originally *preceded* an action rule. Safe at the ABP layer, where
   `@@` exceptions are position-independent; not safe at the WebKit-JSON layer,
   where order is significant. `partition` now rejects non-canonical input rather
   than silently reordering.

Both are locked down by `testNaiveSlicingBreaksWhitelists` and
`testNonCanonicalInputIsRejected`, plus a differential test running 3,000 random
rule sets × 15 probes against a single-list evaluation oracle.

## Distribution

Two builds, one codebase, split at the `DebugBackend` protocol:

| | Mac App Store | Developer ID (DMG) |
|---|---|---|
| Injected agent, proxy, blocking, profiles | yes | yes |
| Response bodies | instrumented mode only | MITM proxy, always |
| JS debugger | source instrumentation, 3–10× slower | `_WKInspector`, no cost |
| DOM / CSS cascade | reconstructed via CSSOM | `_WKInspector` |

## Licence

Not yet chosen.
