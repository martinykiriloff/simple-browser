// SimpleBrowser inspector agent -- isolated-world observer.
//
// Injected at .atDocumentStart into a NAMED WKContentWorld, never the page
// world. Page script cannot see, override or restore anything in here.
//
// What an isolated world can and cannot observe, and why this file is shaped
// the way it is:
//
//   - The DOM is shared across worlds, so MutationObserver and window-level
//     `error` events work and are tamper-proof.
//   - `performance` reflects the same document, so PerformanceObserver gives a
//     complete subresource inventory (every img, script, css, fetch, xhr)
//     with timing and byte counts -- but no headers, methods or bodies.
//   - `console`, `fetch` and `XMLHttpRequest` are *separate objects* in an
//     isolated world. Wrapping them here would observe nothing. Those hooks
//     live in page-hooks.js, which runs in the page world and is therefore
//     tamperable; the native side labels its events `pageWorld` so the UI can
//     say which observations are trustworthy.
//
// Loaded after dom-agent.js, whose node registry it shares so DOM mutation
// events name the same node ids the Elements panel shows.
//
// Contract: posts to webkit.messageHandlers.inspector (registered in this
// world only). Every payload carries { kind, source, tabToken, t }.
(function () {
  "use strict";

  const TOKEN = "__TAB_TOKEN__";           // substituted at injection time
  const bridge = window.webkit?.messageHandlers?.inspector;
  if (!bridge) return;
  const send = bridge.postMessage.bind(bridge);
  const agent = window.__sbAgent;

  const post = (kind, payload) => {
    try { send({ kind, source: "agent", tabToken: TOKEN, t: Date.now(), ...payload }); }
    catch (_) { /* never let instrumentation break the page */ }
  };

  // ---- uncaught exceptions ----------------------------------------------
  // ErrorEvent is dispatched on the shared window object, so listeners from
  // this world fire for exceptions thrown by page script. `e.error` is
  // withheld across worlds; message/filename/line/column are not.
  window.addEventListener("error", (e) => {
    post("console", {
      level: "error",
      message: String(e.message || "Uncaught error"),
      url: e.filename || undefined,
      line: e.lineno || undefined,
      column: e.colno || undefined,
      uncaught: true,
    });
  }, true);

  // ---- performance ------------------------------------------------------
  // Chrome needs DevTools open before it collects any of this. We collect
  // unconditionally, from document start, for every tab.
  const timeOrigin = performance.timeOrigin || (Date.now() - performance.now());

  const observe = (type, handler) => {
    try {
      new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) handler(entry);
      }).observe({ type, buffered: true });
    } catch (_) { /* entry type unsupported on this WebKit build */ }
  };

  // Resource timing is the complete network inventory for this document,
  // including requests page-world hooks never see (images, stylesheets,
  // scripts, fonts, iframes). No headers, no bodies, no method.
  const resource = (entry, initiator) => {
    const rel = (v) => (typeof v === "number" && v > 0) ? v - entry.startTime : 0;
    post("network", {
      url: entry.name,
      initiator: initiator || entry.initiatorType || "other",
      startedAt: timeOrigin + entry.startTime,
      duration: entry.duration,
      transferSize: entry.transferSize,
      encodedBodySize: entry.encodedBodySize,
      decodedBodySize: entry.decodedBodySize,
      status: typeof entry.responseStatus === "number" && entry.responseStatus > 0
        ? entry.responseStatus : undefined,
      protocol: entry.nextHopProtocol || undefined,
      deliveryType: entry.deliveryType || undefined,
      timing: {
        fetchStart: rel(entry.fetchStart),
        domainLookupStart: rel(entry.domainLookupStart),
        domainLookupEnd: rel(entry.domainLookupEnd),
        connectStart: rel(entry.connectStart),
        secureConnectionStart: rel(entry.secureConnectionStart),
        connectEnd: rel(entry.connectEnd),
        requestStart: rel(entry.requestStart),
        responseStart: rel(entry.responseStart),
        responseEnd: rel(entry.responseEnd),
      },
    });
  };
  observe("resource", (entry) => resource(entry));
  observe("navigation", (entry) => resource(entry, "navigation"));

  for (const type of ["largest-contentful-paint", "layout-shift", "longtask",
                      "paint", "first-input", "event"]) {
    observe(type, (entry) => {
      const extra = {};
      if (type === "layout-shift") { extra.value = entry.value; extra.hadRecentInput = entry.hadRecentInput; }
      if (type === "largest-contentful-paint") { extra.size = entry.size; extra.url = entry.url || undefined; }
      if (type === "event" && entry.duration < 100) return;   // only slow interactions
      post("performance", {
        name: entry.name, entryType: entry.entryType,
        startTime: entry.startTime, duration: entry.duration, ...extra,
      });
    });
  }

  // ---- DOM ----------------------------------------------------------------
  // Coalesced on a short timer and capped: a mutation storm must not become
  // a message storm. The count of dropped records is reported so the UI
  // never presents a partial picture as complete. A timer rather than
  // requestAnimationFrame because rAF stops when the window is occluded or
  // the display is asleep, and the recording must not.
  const BATCH_LIMIT = 200;
  const FLUSH_DELAY_MS = 50;
  let pending = [];
  let dropped = 0;
  let scheduled = false;

  const flush = () => {
    scheduled = false;
    if (!pending.length && !dropped) return;
    post("dom", { mutations: pending, dropped });
    pending = [];
    dropped = 0;
  };

  const describeNode = (node) => {
    if (!node) return "";
    if (node.nodeType === 1) {
      let s = node.localName;
      if (node.id) s += "#" + node.id;
      const cls = typeof node.className === "string" ? node.className.trim() : "";
      if (cls) s += "." + cls.split(/\s+/).slice(0, 3).join(".");
      return s;
    }
    if (node.nodeType === 3) return "#text";
    if (node.nodeType === 9) return "#document";
    return node.nodeName || "#node";
  };

  const isOurs = (node) => agent ? agent.isOurs(node) : false;
  const touchesOurs = (record) => {
    if (isOurs(record.target)) return true;
    if (record.type !== "childList") return false;
    for (const n of record.addedNodes) if (isOurs(n)) return true;
    for (const n of record.removedNodes) if (isOurs(n)) return true;
    return false;
  };
  const nodeID = (node) => agent ? agent.nodeId(node) : 0;

  const observer = new MutationObserver((records) => {
    for (const r of records) {
      if (touchesOurs(r)) continue;
      if (pending.length >= BATCH_LIMIT) { dropped++; continue; }
      const m = { kind: r.type, target: describeNode(r.target), nodeID: nodeID(r.target) };
      if (r.type === "attributes") m.attribute = r.attributeName;
      if (r.type === "childList") { m.added = r.addedNodes.length; m.removed = r.removedNodes.length; }
      pending.push(m);
    }
    if (!scheduled) { scheduled = true; setTimeout(flush, FLUSH_DELAY_MS); }
  });
  observer.observe(document, { childList: true, subtree: true,
                               attributes: true, characterData: true });
  document.addEventListener("visibilitychange", () => { if (document.hidden) flush(); });

  post("navigation", { phase: "agentReady", url: location.href });
})();
