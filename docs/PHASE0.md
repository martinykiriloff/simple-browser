# Phase 0 — spike checklist

Two weeks. Throwaway code. The goal is to break the plan early.

Items 1, 2 and 3 can force a redesign. Do them first.

### 1. Sync XHR blocking against `WKURLSchemeHandler`

Prove the content process actually blocks on a synchronous `XMLHttpRequest` to a
custom scheme whose handler holds the task open without calling `didFinish()`.
Verify: the UI process stays responsive; resuming via a delayed `didFinish()`
continues execution; WebKit imposes no timeout on the held task.

**If this fails, the instrumented debugger fails**, and the Mac App Store build
has no debugger at all.

### 2. Direct `eval` scope capture

Instrument a bundled, minified, strict-mode ES module. At a breakpoint inside a
nested closure, read a `const` declared two scopes up via a direct `eval`
closure. Confirm it works in module context, not only classic scripts.

### 3. `loadSimulatedRequest` origin fidelity

Simulate a load of a real authenticated site. Verify cookies from
`WKHTTPCookieStore` are sent, `Set-Cookie` writes back, `document.origin` is
correct, and a subsequent same-origin `fetch` from page JS succeeds without CORS
errors.

### 4. Profile isolation

Two `WKWebsiteDataStore(forIdentifier:)` instances. Log into the same site in
each. Confirm zero cookie bleed and that data lands inside the sandbox container.

### 5. `interactionState` round-trip

Load a page, scroll, fill a form, navigate twice. Tear down the web view and
restore. Verify scroll position, form values and back-forward list all survive.

### 6. Rule-list splitting against real WebKit

Compile EasyList into three ≤150k lists via `BlockKit`, apply all three to one
`WKUserContentController`. Put an exception in split 2 and a block it should
cancel in split 1. Confirm the exception does **not** reach across lists — this
validates the replication requirement against the real engine, not just the
oracle.

### 7. Isolated world integrity — done, with a correction

Verified: page script cannot see the isolated world's message handler or
globals (`webkit.messageHandlers.inspector`, `__sbAgent`). But an isolated
world has its *own* `fetch`, `console` and `XMLHttpRequest`, so hooking them
there observes nothing. The hooks live in the page world (`page-hooks.js`)
and their events are labelled `pageWorld`; DOM, errors and resource timing
stay in the isolated world. See ARCHITECTURE.md → Dev tools.

### 8. Proxy coverage

`proxyConfigurations` → local NIO listener. Confirm CONNECT is visible for HTTPS
subresources and timing is extractable. **Most likely to disappoint** — measure
actual coverage before designing the network panel around it.

### 9. Extension host

Load uBlock Origin Lite via `WKWebExtension` from an `NSOpenPanel`-picked
directory with a security-scoped bookmark. Confirm it survives relaunch.

### 10. Memory baseline

20 live tabs vs 20 hibernated: RSS and process count. This number sets
`EvictionPolicy.liveBudget`.

### 11. Cascade probe

On a real site with a cross-origin stylesheet, enumerate `document.styleSheets`
and count how many throw on `.cssRules`. That ratio is the size of the native
refetch-and-reparse work.
