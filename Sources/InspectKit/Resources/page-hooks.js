// Keel inspector agent -- page-world hooks.
//
// Injected at .atDocumentStart into the PAGE world, because `console`,
// `fetch` and `XMLHttpRequest` are per-world objects: hooks in an isolated
// world would observe nothing (see agent.js). Running here means page script
// *can* in principle detect or replace these hooks, so the native side labels
// every event from this file `pageWorld`. Observations that must be
// trustworthy (errors, resource timing, DOM) come from the isolated world.
//
// This file also hosts the console's evaluation side: a registry of remote
// objects so the DevTools UI can expand values lazily, `Runtime.evaluate`
// with Chrome's command-line API ($0, $, $$, copy, …), and property
// enumeration.
//
// Contract: posts to webkit.messageHandlers.inspectorPage. The bridge
// reference and postMessage are captured before any page script runs, so
// later tampering with `window.webkit` does not silence this file.
(function () {
  "use strict";

  const TOKEN = "__TAB_TOKEN__";
  const bridge = window.webkit?.messageHandlers?.inspectorPage;
  if (!bridge) return;
  const send = bridge.postMessage.bind(bridge);

  const post = (kind, payload) => {
    try { send({ kind, source: "pageWorld", tabToken: TOKEN, t: Date.now(), ...payload }); }
    catch (_) { /* never let instrumentation break the page */ }
  };

  const BODY_LIMIT = 256 * 1024;
  const MESSAGE_LIMIT = 16 * 1024;
  const REGISTRY_LIMIT = 5000;

  // ---- remote objects -------------------------------------------------------
  const registry = new Map();
  let nextObjectId = 1;

  function retain(value) {
    const id = "o" + (nextObjectId++);
    registry.set(id, value);
    if (registry.size > REGISTRY_LIMIT) registry.delete(registry.keys().next().value);
    return id;
  }
  function resolve(objectId) {
    if (!registry.has(objectId)) throw new Error("Object was released");
    return registry.get(objectId);
  }

  function isNode(v) { return typeof Node !== "undefined" && v instanceof Node; }
  function className(v) {
    try {
      const proto = Object.getPrototypeOf(v);
      if (proto === null) return "Object";
      return (proto.constructor && proto.constructor.name) || Object.prototype.toString.call(v).slice(8, -1);
    } catch (_) { return "Object"; }
  }
  function subtypeOf(v) {
    if (v === null) return "null";
    if (Array.isArray(v)) return "array";
    if (isNode(v)) return "node";
    if (v instanceof Error) return "error";
    if (v instanceof Date) return "date";
    if (v instanceof RegExp) return "regexp";
    if (v instanceof Map) return "map";
    if (v instanceof Set) return "set";
    if (v instanceof WeakMap) return "weakmap";
    if (v instanceof WeakSet) return "weakset";
    if (v instanceof Promise) return "promise";
    if (ArrayBuffer.isView(v)) return "typedarray";
    if (v instanceof ArrayBuffer) return "arraybuffer";
    return undefined;
  }

  function describeNode(node) {
    if (node.nodeType === 1) {
      let s = "<" + node.localName;
      for (const a of node.attributes) s += " " + a.name + (a.value === "" ? "" : "=\"" + a.value + "\"");
      return s + ">";
    }
    if (node.nodeType === 3) return "#text " + JSON.stringify(String(node.data).slice(0, 80));
    if (node.nodeType === 9) return "#document";
    if (node.nodeType === 8) return "<!--" + String(node.data).slice(0, 80) + "-->";
    return node.nodeName;
  }

  // Chrome-style one-line description of any value.
  function describe(v) {
    const t = typeof v;
    if (t === "string") return v;
    if (t === "undefined") return "undefined";
    if (t === "number") return Object.is(v, -0) ? "-0" : String(v);
    if (t === "boolean" || t === "symbol") return String(v);
    if (t === "bigint") return String(v) + "n";
    if (v === null) return "null";
    if (t === "function") {
      let src = "";
      try { src = Function.prototype.toString.call(v); } catch (_) {}
      const isClass = /^class\b/.test(src);
      if (isClass) return "class " + (v.name || "") + " { … }";
      const m = src.match(/^(?:async\s*)?(?:function\s*\*?\s*)?([\w$]*)\s*\(([^)]*)\)/);
      const args = m ? m[2].replace(/\s+/g, " ").trim() : "";
      return "ƒ " + (v.name || (m && m[1]) || "") + "(" + args + ")";
    }
    const sub = subtypeOf(v);
    switch (sub) {
      case "array": return "Array(" + v.length + ")";
      case "node": return describeNode(v);
      case "error": return (v.name || "Error") + ": " + v.message + (v.stack ? "\n" + v.stack : "");
      case "date": return isNaN(v) ? "Invalid Date" : v.toString();
      case "regexp": return String(v);
      case "map": return "Map(" + v.size + ")";
      case "set": return "Set(" + v.size + ")";
      case "weakmap": return "WeakMap";
      case "weakset": return "WeakSet";
      case "promise": return "Promise";
      case "typedarray": return className(v) + "(" + v.length + ")";
      case "arraybuffer": return "ArrayBuffer(" + v.byteLength + ")";
      default: break;
    }
    if (typeof Window !== "undefined" && v instanceof Window) return "Window";
    const name = className(v);
    return name === "Object" ? "Object" : name;
  }

  // Short form used inside previews: nested objects collapse to their name.
  function describeShort(v) {
    const t = typeof v;
    if (t === "string") return quoteShort(v.length > 100 ? v.slice(0, 100) + "…" : v);
    if (t === "function") return "ƒ";
    if (t !== "object" || v === null) return describe(v);
    const sub = subtypeOf(v);
    if (sub === "array") return "Array(" + v.length + ")";
    if (sub === "node") return nodeLabel(v);
    if (sub === "error") return (v.name || "Error") + ": " + v.message;
    if (sub === "date" || sub === "regexp") return describe(v);
    if (sub === "map" || sub === "set" || sub === "typedarray" || sub === "arraybuffer") return describe(v);
    if (sub === "promise") return "Promise";
    const name = className(v);
    return name === "Object" ? "{…}" : name;
  }

  // 'text' as Chrome writes a string inside a preview.
  function quoteShort(s) {
    return "'" + String(s).replace(/\\/g, "\\\\").replace(/'/g, "\\'").replace(/\n/g, "\\n") + "'";
  }

  // div#id.class, the way Chrome names a node inside a preview.
  function nodeLabel(node) {
    if (node.nodeType !== 1) return describeNode(node);
    let s = node.localName;
    if (node.id) s += "#" + node.id;
    const cls = typeof node.className === "string" ? node.className.trim() : "";
    if (cls) s += "." + cls.split(/\s+/).join(".");
    return s;
  }

  // Promise states, learned by attaching handlers. Only promises the console
  // itself produced are tracked: a handler marks a rejection as handled,
  // which would hide the page's own "Uncaught (in promise)".
  const promiseStates = new WeakMap();
  function trackPromise(p) {
    if (promiseStates.has(p)) return;
    const record = { state: "pending" };
    promiseStates.set(p, record);
    try {
      Promise.prototype.then.call(p, (value) => { record.state = "fulfilled"; record.value = value; },
                                     (reason) => { record.state = "rejected"; record.value = reason; });
    } catch (_) {}
  }

  function preview(v) {
    const props = [];
    let overflow = false;
    try {
      const sub = subtypeOf(v);
      if (sub === "promise") {
        const record = promiseStates.get(v) || { state: "pending" };
        const p = { name: "<" + record.state + ">", type: record.state === "pending" ? "undefined" : typeof record.value, value: "" };
        if (record.state !== "pending") { p.value = describeShort(record.value); if (record.value !== null && typeof record.value === "object") p.subtype = subtypeOf(record.value); }
        if (record.value === null) p.subtype = "null";
        return { properties: [p], overflow: false };
      }
      if (sub === "node" || sub === "error" || sub === "regexp" || sub === "date") return { properties: [], overflow: false };
      if (sub === "map") {
        let i = 0;
        for (const [k, val] of v) { if (i++ >= 6) { overflow = true; break; } props.push({ name: describeShort(k), type: typeof val, subtype: subtypeOf(val), value: describeShort(val) }); }
        return { properties: props, overflow };
      }
      if (sub === "set") {
        let i = 0;
        for (const val of v) { if (i++ >= 6) { overflow = true; break; } props.push({ name: String(i - 1), type: typeof val, subtype: subtypeOf(val), value: describeShort(val) }); }
        return { properties: props, overflow };
      }
      const keys = sub === "array" || sub === "typedarray" ? Array.from({ length: Math.min(v.length, 100) }, (_, i) => String(i)) : Object.keys(v);
      const limit = sub === "array" || sub === "typedarray" ? 100 : 6;
      for (const key of keys) {
        if (props.length >= limit) { overflow = true; break; }
        let val;
        try {
          const d = Object.getOwnPropertyDescriptor(v, key);
          if (d && !("value" in d)) { props.push({ name: key, type: "accessor", value: "(...)" }); continue; }
          val = v[key];
        } catch (_) { val = undefined; }
        props.push({ name: key, type: typeof val, subtype: val === null ? "null" : typeof val === "object" ? subtypeOf(val) : undefined, value: describeShort(val) });
      }
      if (keys.length > props.length) overflow = true;
    } catch (_) {}
    return { properties: props, overflow };
  }

  function remote(v, withPreview, keep = true) {
    const t = typeof v;
    const out = { type: t, description: describe(v) };
    if (t === "object" || t === "function") {
      if (v === null) { out.subtype = "null"; return out; }
      out.subtype = t === "object" ? subtypeOf(v) : undefined;
      out.className = className(v);
      if (keep) out.objectId = retain(v);
      if (withPreview && t === "object" && !(typeof Window !== "undefined" && v instanceof Window)) out.preview = preview(v);
    }
    if (out.subtype === undefined) delete out.subtype;
    return out;
  }

  function getProperties({ objectId, ownOnly }) {
    const obj = resolve(objectId);
    const out = [];
    const seen = new Set();
    const add = (target, key, isOwn) => {
      const name = typeof key === "symbol" ? key.toString() : String(key);
      if (seen.has(name)) return;
      seen.add(name);
      let d;
      try { d = Object.getOwnPropertyDescriptor(target, key); } catch (_) { return; }
      if (!d) return;
      const entry = { name, isOwn, enumerable: !!d.enumerable };
      if ("value" in d) entry.value = remote(d.value, true);
      else {
        entry.isAccessor = true;
        entry.value = { type: "accessor", description: "(...)" };
        if (d.get) entry.getter = remote(d.get, false);
        if (d.set) entry.setter = remote(d.set, false);
      }
      out.push(entry);
    };
    const sub = subtypeOf(obj);
    if (sub === "map") {
      let i = 0;
      for (const [k, v] of obj) { out.push({ name: describeShort(k), isOwn: true, enumerable: true, value: remote(v, true), isEntry: true }); if (++i >= 1000) break; }
    } else if (sub === "set") {
      let i = 0;
      for (const v of obj) { out.push({ name: String(i), isOwn: true, enumerable: true, value: remote(v, true), isEntry: true }); if (++i >= 1000) break; }
    }
    let keys;
    try { keys = Reflect.ownKeys(obj); } catch (_) { keys = []; }
    for (const key of keys.slice(0, 1000)) add(obj, key, true);
    if (!ownOnly) {
      let proto = null;
      try { proto = Object.getPrototypeOf(obj); } catch (_) {}
      if (proto !== null && proto !== undefined) {
        out.push({ name: "[[Prototype]]", isOwn: false, enumerable: false, isInternal: true, value: remote(proto, false) });
      }
    }
    if (sub === "promise") {
      const record = promiseStates.get(obj) || { state: "pending" };
      out.push({ name: "[[PromiseState]]", isOwn: false, enumerable: false, isInternal: true, value: { type: "string", description: record.state } });
      out.push({ name: "[[PromiseResult]]", isOwn: false, enumerable: false, isInternal: true, value: remote(record.value, true) });
    }
    if (sub === "node" && obj.nodeType === 1) {
      out.push({ name: "[[Reveal in Elements]]", isOwn: false, enumerable: false, isInternal: true, isReveal: true, value: { type: "string", description: "" } });
    }
    return out;
  }

  function invokeGetter({ objectId, name }) {
    const obj = resolve(objectId);
    return remote(obj[name], true);
  }

  // ---- command line API -----------------------------------------------------------------------
  const selection = [];   // $0 … $4
  window.addEventListener("__sbSelect", (e) => {
    if (e.target && e.target.nodeType && selection[0] !== e.target) selection.unshift(e.target);
    selection.length = Math.min(selection.length, 5);
  }, true);

  let lastResult;
  const api = {
    get $0() { return selection[0]; }, get $1() { return selection[1]; }, get $2() { return selection[2]; },
    get $3() { return selection[3]; }, get $4() { return selection[4]; },
    get $_() { return lastResult; },
    $: (sel, root) => (root || document).querySelector(sel),
    $$: (sel, root) => Array.from((root || document).querySelectorAll(sel)),
    $x: (xpath, root) => {
      const r = document.evaluate(xpath, root || document, null, XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
      const out = []; for (let i = 0; i < r.snapshotLength; i++) out.push(r.snapshotItem(i)); return out;
    },
    keys: Object.keys, values: Object.values,
    dir: (v) => console.dir(v), dirxml: (v) => console.dirxml(v), table: (v) => console.table(v),
    clear: () => console.clear(),
    copy: (v) => { post("copy", { text: typeof v === "string" ? v : (isNode(v) ? v.outerHTML : safeJSON(v)) }); },
    inspect: (v) => { if (isNode(v)) { try { v.dispatchEvent(new CustomEvent("__sbReveal", { bubbles: false })); } catch (_) {} } },
    getEventListeners: () => ({}),
  };

  function safeJSON(v) {
    try { return JSON.stringify(v, null, 2); } catch (_) { return String(v); }
  }

  const evaluator = Function("__api", "__expr", "with (__api) { return eval(__expr); }");
  const asyncEvaluator = Function("__api", "__expr", "with (__api) { return eval('(async () => (' + __expr + '))()'); }");
  const asyncBlockEvaluator = Function("__api", "__expr", "with (__api) { return eval('(async () => { ' + __expr + ' })()'); }");

  async function evaluate({ expression, awaitPromise }) {
    let expr = String(expression);
    let value, wrapped = false;
    try {
      if (/^\s*(let|const)\s/.test(expr)) {
        // Chrome persists top-level let/const across console entries; a
        // global `var` is the closest an eval can get.
        value = (0, eval)(expr.replace(/^\s*(let|const)\s/, "var "));
      } else if (/^\s*(var|function|class)\s/.test(expr)) {
        value = (0, eval)(expr);
      } else {
        try {
          value = evaluator(api, expr);
        } catch (e) {
          if (e instanceof SyntaxError && /\bawait\b/.test(expr)) {
            try { value = asyncEvaluator(api, expr); }
            catch (_) { value = asyncBlockEvaluator(api, expr); }
            wrapped = true;
          } else throw e;
        }
      }
      // Like Chrome: a promise is awaited only when the input used `await`;
      // otherwise it is shown as a promise, with its state.
      if ((wrapped || awaitPromise === true) && value instanceof Promise) value = await value;
      else if (value instanceof Promise) { trackPromise(value); await null; await null; }
    } catch (error) {
      return { exceptionDetails: { text: describe(error), exception: remote(error, false) } };
    }
    lastResult = value;
    return { result: remote(value, true) };
  }

  // Names for the console's autocomplete. `object` (when given) is the
  // expression before the dot, already vetted by the UI as free of side
  // effects; otherwise the old single-string form is split here. Each name
  // comes with what it is, so the list can say "method" or "property".
  function completions({ expression, object, prefix: givenPrefix }) {
    let objectPath, prefix;
    if (object !== undefined) { objectPath = String(object); prefix = String(givenPrefix || ""); }
    else {
      const m = String(expression).match(/^\s*([\w$.\[\]'"]*?)\.?([\w$]*)$/);
      if (!m) return { names: [], prefix: "", types: {} };
      [, objectPath, prefix] = m;
      objectPath = objectPath.replace(/\.$/, "");
    }
    let target;
    try { target = objectPath ? evaluator(api, objectPath) : window; }
    catch (_) { return { names: [], prefix, types: {} }; }
    if (target === null || target === undefined) return { names: [], prefix, types: {} };
    if (typeof target !== "object" && typeof target !== "function") target = Object(target);
    const names = new Set();
    const types = {};
    if (!objectPath) {
      for (const k of ["$0", "$_", "$", "$$", "$x", "copy", "keys", "values", "dir", "inspect", "clear"]) if (k.startsWith(prefix)) { names.add(k); types[k] = "api"; }
      for (const k of ["const", "let", "var", "function", "class", "async", "await", "return", "typeof", "instanceof", "new", "this", "true", "false", "null", "undefined"]) if (k.startsWith(prefix)) { names.add(k); types[k] = "keyword"; }
    }
    let obj = target, depth = 0;
    try {
      while (obj && depth++ < 20 && names.size < 800) {
        for (const k of Object.getOwnPropertyNames(obj)) {
          if (typeof k !== "string" || !k.startsWith(prefix) || names.has(k)) continue;
          names.add(k);
          let kind = "property";
          try {
            const d = Object.getOwnPropertyDescriptor(obj, k);
            if (d && "value" in d) kind = typeof d.value === "function" ? (/^[A-Z]/.test(k) ? "class" : "method") : typeof d.value;
            else if (d) kind = "accessor";
          } catch (_) {}
          types[k] = kind;
        }
        obj = Object.getPrototypeOf(obj);
      }
    } catch (_) {}
    return { names: Array.from(names).sort(), prefix, types };
  }

  // The prompt's preview line: evaluated as the developer types, so it must
  // not change anything. The UI only sends expressions it has vetted (reads,
  // and calls to an allow-list of pure functions); nothing is retained and
  // `$_` is left alone.
  function evaluateEager({ expression }) {
    try {
      const v = evaluator(api, String(expression));
      if (v instanceof Promise) return { result: { type: "object", subtype: "promise", description: "Promise" } };
      return { result: remote(v, true, false) };
    } catch (error) {
      return { exceptionDetails: { text: describe(error).split("\n")[0] } };
    }
  }

  // "Store as global variable": temp1, temp2… as in Chrome.
  function storeAsGlobal(value) {
    let i = 1;
    while (("temp" + i) in window) i++;
    const name = "temp" + i;
    try { Object.defineProperty(window, name, { value, writable: true, configurable: true, enumerable: false }); }
    catch (_) { window[name] = value; }
    return name;
  }

  // A function's source, for a function expanded in the console.
  function functionSource({ objectId }) {
    const fn = resolve(objectId);
    if (typeof fn !== "function") throw new Error("Not a function");
    let text = "";
    try { text = Function.prototype.toString.call(fn); } catch (e) { text = String(e); }
    return { source: text.length > 20000 ? text.slice(0, 20000) + "\n…" : text, name: fn.name || "" };
  }

  // Live expressions: re-evaluated four times a second, so nothing is
  // retained (no object ids) and `$_` is left alone.
  function evaluateLive({ expression }) {
    try {
      const v = evaluator(api, String(expression));
      const out = { type: typeof v, description: describe(v) };
      if (v !== null && typeof v === "object") out.subtype = subtypeOf(v);
      else if (v === null) out.subtype = "null";
      return { result: out };
    } catch (error) {
      return { exceptionDetails: { text: describe(error) } };
    }
  }

  const runtime = {
    "Runtime.evaluateLive": evaluateLive,
    "Runtime.evaluate": evaluate,
    "Runtime.getProperties": getProperties,
    "Runtime.invokeGetter": invokeGetter,
    "Runtime.releaseObjects": () => { registry.clear(); return true; },
    "Runtime.getCompletions": completions,
    "Runtime.revealNode": ({ objectId }) => {
      const v = resolve(objectId);
      if (isNode(v)) { try { v.dispatchEvent(new CustomEvent("__sbReveal", { bubbles: false })); } catch (_) {} }
      return true;
    },
    "Runtime.evaluateEager": evaluateEager,
    "Runtime.getFunctionSource": functionSource,
    "Runtime.storeAsGlobal": ({ objectId, value }) => ({ name: storeAsGlobal(objectId ? resolve(objectId) : value) }),
    // The node the isolated world last marked (see `__sbMark` below).
    "Runtime.storeMarkedAsGlobal": () => {
      if (!marked || !marked.isConnected) throw new Error("The node is no longer in the document");
      return { name: storeAsGlobal(marked) };
    },
    "Runtime.highlightNode": ({ objectId }) => {
      const v = resolve(objectId);
      if (isNode(v)) { try { v.dispatchEvent(new CustomEvent("__sbHighlight", { bubbles: false })); } catch (_) {} }
      return true;
    },
    "Runtime.copy": ({ objectId }) => {
      const v = resolve(objectId);
      return typeof v === "string" ? v : (isNode(v) ? v.outerHTML : safeJSON(v));
    },
  };

  async function handle(method, params) {
    const fn = runtime[method];
    if (!fn) throw new Error("Unknown method " + method);
    const result = await fn(params || {});
    // Only JSON-safe values cross the bridge; this drops `undefined` fields.
    return result === undefined ? null : JSON.parse(JSON.stringify(result));
  }
  // The inspector protocol has node ids of its own. To find the protocol's id
  // for a node in our tree, the isolated world dispatches "__sbMark" at it (an
  // event's target is the same node in every world) and the protocol then
  // evaluates `__sbInspector.marked`. It only ever holds a node the page
  // could already reach.
  let marked = null;
  window.addEventListener("__sbMark", (e) => { marked = e.target && e.target.nodeType ? e.target : null; }, true);

  // The Elements tree's `event` badge: which nodes have listeners. Only the
  // page world sees addEventListener calls, so it counts them here and tells
  // the isolated world when a node gets its first listener or loses its last
  // (an event's target is the same node in every world). Nothing of ours
  // runs in the page when the tree is drawn.
  const listenerCounts = new WeakMap();
  try {
    const target = EventTarget.prototype;
    const addOriginal = target.addEventListener, removeOriginal = target.removeEventListener;
    const dispatch = EventTarget.prototype.dispatchEvent;
    const counted = (node) => node !== null && typeof node === "object" && typeof node.nodeType === "number";
    const tell = (node, type) => { try { dispatch.call(node, new CustomEvent(type, { bubbles: false })); } catch (_) {} };
    const hookedAdd = function addEventListener(type, listener) {
      try {
        if (listener && counted(this) && String(type).slice(0, 4) !== "__sb") {
          const n = (listenerCounts.get(this) || 0) + 1;
          listenerCounts.set(this, n);
          if (n === 1) tell(this, "__sbListenerAdded");
        }
      } catch (_) {}
      return addOriginal.apply(this, arguments);
    };
    const hookedRemove = function removeEventListener(type, listener) {
      try {
        const n = counted(this) ? listenerCounts.get(this) || 0 : 0;
        if (listener && n && String(type).slice(0, 4) !== "__sb") { listenerCounts.set(this, n - 1); if (n === 1) tell(this, "__sbListenersRemoved"); }
      } catch (_) {}
      return removeOriginal.apply(this, arguments);
    };
    Object.defineProperty(target, "addEventListener", { value: hookedAdd, writable: true, configurable: true, enumerable: true });
    Object.defineProperty(target, "removeEventListener", { value: hookedRemove, writable: true, configurable: true, enumerable: true });
  } catch (_) {}

  Object.defineProperty(window, "__sbInspector", {
    value: Object.freeze({ handle, get marked() { return marked; } }),
    enumerable: false, configurable: false, writable: false,
  });

  // ---- console --------------------------------------------------------------------------------------
  const levels = { debug: "debug", log: "info", info: "info", warn: "warn", error: "error", trace: "trace",
                   dir: "info", dirxml: "info", table: "info", group: "info", groupCollapsed: "info",
                   groupEnd: "info", clear: "info", count: "info", countReset: "info",
                   time: "info", timeEnd: "info", timeLog: "info", assert: "error" };
  const counters = new Map();
  const timers = new Map();

  function emit(name, args) {
    const type = name === "log" || name === "info" || name === "warn" || name === "error" || name === "debug" ? "log" : name;
    const payload = { level: levels[name], type, message: "", args: [], stack: [] };
    switch (name) {
      case "count": {
        const label = args.length ? describe(args[0]) : "default";
        counters.set(label, (counters.get(label) || 0) + 1);
        payload.message = label + ": " + counters.get(label);
        break;
      }
      case "countReset": counters.set(args.length ? describe(args[0]) : "default", 0); return;
      case "time": timers.set(args.length ? describe(args[0]) : "default", performance.now()); return;
      case "timeEnd": case "timeLog": {
        const label = args.length ? describe(args[0]) : "default";
        if (!timers.has(label)) { payload.level = "warn"; payload.message = "Timer '" + label + "' does not exist"; break; }
        payload.message = label + ": " + (performance.now() - timers.get(label)).toFixed(3) + " ms";
        if (name === "timeEnd") timers.delete(label);
        break;
      }
      case "assert": {
        if (args[0]) return;
        const rest = args.slice(1);
        payload.message = "Assertion failed" + (rest.length ? ": " + formatArgs(rest) : "");
        payload.args = rest.map((a) => remote(a, true));
        payload.stack = captureStack();
        break;
      }
      case "clear": payload.message = "Console was cleared"; break;
      case "table": {
        payload.message = formatArgs(args.slice(0, 1));
        payload.args = args.slice(0, 1).map((a) => remote(a, true));
        const table = tabulate(args[0], Array.isArray(args[1]) ? args[1] : null);
        if (table) payload.table = table;
        break;
      }
      default:
        payload.message = formatArgs(args);
        payload.args = args.map((a) => remote(a, true));
        if (name === "trace" || name === "error") payload.stack = captureStack();
        if (name === "trace" && !payload.message) payload.message = "console.trace";
    }
    post("console", payload);
  }

  for (const name of Object.keys(levels)) {
    const original = console[name];
    if (typeof original !== "function") continue;
    const wrapped = function (...args) {
      try { emit(name, args); } catch (_) {}
      return original.apply(this, args);
    };
    try { Object.defineProperty(console, name, { value: wrapped, writable: true, configurable: true }); }
    catch (_) { try { console[name] = wrapped; } catch (_) {} }
  }

  // The rejection reason is only readable from the world that created it,
  // which is why this listener is here and not in agent.js.
  window.addEventListener("unhandledrejection", (e) => {
    const reason = e.reason;
    const head = reason instanceof Error ? (reason.name || "Error") + ": " + reason.message : describe(reason);
    post("console", {
      level: "error", type: "log",
      message: "Uncaught (in promise) " + head,
      args: [remote(e.reason, true)],
      stack: e.reason && e.reason.stack ? String(e.reason.stack).split("\n") : [],
      uncaught: true,
    });
  });

  // ---- fetch ------------------------------------------------------------------------------------
  const nativeFetch = window.fetch;
  if (typeof nativeFetch === "function") {
    const hooked = function (input, init) {
      const startedAt = Date.now();
      const started = performance.now();
      let url = "", method = "GET";
      try {
        const raw = typeof input === "string" ? input
                  : (input instanceof URL) ? input.href
                  : (input && typeof input === "object") ? input.url : String(input);
        url = new URL(raw, location.href).href;
        method = String(init?.method || (input && typeof input === "object" && input.method) || "GET").toUpperCase();
      } catch (_) { url = String(input); }

      const base = {
        method, url, initiator: "fetch", startedAt,
        requestHeaders: headersToObject(init?.headers ?? (input && typeof input === "object" ? input.headers : undefined)),
        requestBody: typeof init?.body === "string" ? truncate(init.body, BODY_LIMIT)
                   : (init?.body instanceof URLSearchParams ? truncate(init.body.toString(), BODY_LIMIT) : undefined),
      };

      const promise = nativeFetch.apply(this, arguments);
      promise.then((response) => {
        const done = { ...base, status: response.status,
                       responseHeaders: headersToObject(response.headers),
                       duration: performance.now() - started };
        let clone;
        try { clone = response.clone(); }
        catch (_) { post("network", { ...done, bodyUnavailable: true }); return; }

        const type = (response.headers.get("content-type") || "").toLowerCase();
        if (type.includes("text/event-stream") || response.status === 204 || response.status === 304) {
          post("network", { ...done, bodyUnavailable: true });
        } else if (isTextual(type)) {
          clone.text().then((body) => {
            post("network", { ...done, bytes: body.length, responseBody: truncate(body, BODY_LIMIT) });
          }).catch(() => post("network", { ...done, bodyUnavailable: true }));
        } else {
          clone.arrayBuffer().then((buffer) => {
            post("network", { ...done, bytes: buffer.byteLength, bodyUnavailable: true });
          }).catch(() => post("network", { ...done, bodyUnavailable: true }));
        }
      }, (error) => {
        post("network", { ...base, failure: String(error && error.message || error),
                          duration: performance.now() - started });
      });
      return promise;
    };
    try { Object.defineProperty(window, "fetch", { value: hooked, writable: true, configurable: true }); }
    catch (_) { window.fetch = hooked; }
  }

  // ---- XMLHttpRequest ------------------------------------------------------------------------------
  const proto = XMLHttpRequest.prototype;
  const openOriginal = proto.open;
  const sendOriginal = proto.send;
  const setHeaderOriginal = proto.setRequestHeader;

  proto.open = function (method, url) {
    let absolute = String(url);
    try { absolute = new URL(String(url), location.href).href; } catch (_) {}
    this.__inspect = { method: String(method || "GET").toUpperCase(), url: absolute,
                       requestHeaders: {}, started: 0, startedAt: 0 };
    return openOriginal.apply(this, arguments);
  };

  proto.setRequestHeader = function (name, value) {
    if (this.__inspect) this.__inspect.requestHeaders[String(name)] = String(value);
    return setHeaderOriginal.apply(this, arguments);
  };

  proto.send = function (body) {
    const meta = this.__inspect;
    if (meta) {
      meta.started = performance.now();
      meta.startedAt = Date.now();
      meta.requestBody = typeof body === "string" ? truncate(body, BODY_LIMIT)
                       : (body instanceof URLSearchParams ? truncate(body.toString(), BODY_LIMIT) : undefined);
      this.addEventListener("loadend", () => {
        const textual = this.responseType === "" || this.responseType === "text";
        let responseBody, bytes;
        if (textual) {
          try { responseBody = this.responseText; bytes = responseBody.length; } catch (_) {}
        } else if (this.response instanceof ArrayBuffer) {
          bytes = this.response.byteLength;
        }
        const event = {
          method: meta.method, url: meta.url, initiator: "xmlhttprequest",
          startedAt: meta.startedAt, duration: performance.now() - meta.started,
          requestHeaders: meta.requestHeaders, requestBody: meta.requestBody,
          responseHeaders: parseRawHeaders(this.getAllResponseHeaders()),
          bytes,
        };
        if (this.status === 0) event.failure = "Request failed (network error, CORS, timeout or abort)";
        else event.status = this.status;
        if (responseBody !== undefined) event.responseBody = truncate(responseBody, BODY_LIMIT);
        else event.bodyUnavailable = true;
        post("network", event);
      });
    }
    return sendOriginal.apply(this, arguments);
  };

  // ---- helpers ------------------------------------------------------------------------------------
  // console.table: rows are the entries of the value, columns the union of
  // their keys (or "Value" for primitives), capped so a huge array cannot
  // flood the bridge.
  function tabulate(value, only) {
    if (value === null || typeof value !== "object") return null;
    const ROW_LIMIT = 200, COLUMN_LIMIT = 30;
    let entries;
    try { entries = value instanceof Map ? Array.from(value.entries()) : Object.entries(value); } catch (_) { return null; }
    const columns = [];
    let hasValueColumn = false;
    for (const [, row] of entries.slice(0, ROW_LIMIT)) {
      if (row !== null && typeof row === "object") {
        for (const key of Object.keys(row)) {
          if (only && !only.includes(key)) continue;
          if (!columns.includes(key) && columns.length < COLUMN_LIMIT) columns.push(key);
        }
      } else hasValueColumn = true;
    }
    const header = ["(index)"].concat(columns, hasValueColumn ? ["Value"] : []);
    const cell = (v) => v === undefined ? "" : (typeof v === "string" ? v : describeShort(v));
    const rows = entries.slice(0, ROW_LIMIT).map(([index, row]) => {
      const isObject = row !== null && typeof row === "object";
      const cells = [String(typeof index === "string" ? index : describeShort(index))];
      for (const key of columns) cells.push(isObject && key in row ? cell(row[key]) : "");
      if (hasValueColumn) cells.push(isObject ? "" : cell(row));
      return cells;
    });
    return { columns: header, rows, truncated: Math.max(0, entries.length - ROW_LIMIT) };
  }

  function isTextual(type) {
    return type.startsWith("text/") || type.includes("json") || type.includes("xml")
        || type.includes("javascript") || type.includes("x-www-form-urlencoded")
        || type.includes("graphql") || type === "";
  }

  function headersToObject(headers) {
    const out = {};
    if (!headers) return out;
    try {
      if (typeof headers.forEach === "function") { headers.forEach((v, k) => { out[k] = String(v); }); }
      else if (Array.isArray(headers)) { for (const [k, v] of headers) out[String(k)] = String(v); }
      else if (typeof headers === "object") { for (const k of Object.keys(headers)) out[k] = String(headers[k]); }
    } catch (_) {}
    return out;
  }

  function parseRawHeaders(raw) {
    const out = {};
    if (!raw) return out;
    for (const line of String(raw).split(/\r?\n/)) {
      const i = line.indexOf(":");
      if (i > 0) out[line.slice(0, i).trim().toLowerCase()] = line.slice(i + 1).trim();
    }
    return out;
  }

  function truncate(text, limit) {
    if (typeof text !== "string") return undefined;
    return text.length > limit ? text.slice(0, limit) + "…[truncated " + (text.length - limit) + " chars]" : text;
  }

  function captureStack() {
    try {
      // Drop every frame belonging to this file: injected scripts are named
      // "user-script:N" by WebKit, and how many of our frames sit on top
      // depends on which console method was called.
      return (new Error().stack || "").split("\n")
        .filter((line) => line && !/user-script:\d+/.test(line))
        .slice(0, 20);
    } catch (_) { return []; }
  }

  // console.log("%s is %d", "x", 3) style substitution, then the rest of the
  // arguments space-joined, the way a browser console renders them.
  function formatArgs(args) {
    if (!args.length) return "";
    let out = "";
    let rest = args;
    if (typeof args[0] === "string" && /%[sdifoOjc]/.test(args[0])) {
      let i = 1;
      out = args[0].replace(/%([sdifoOjc%])/g, (match, spec) => {
        if (spec === "%") return "%";
        if (spec === "c") { i++; return ""; }
        if (i >= args.length) return match;
        const v = args[i++];
        switch (spec) {
          case "s": return typeof v === "string" ? v : format(v, 1);
          case "d": case "i": return String(parseInt(v, 10));
          case "f": return String(parseFloat(v));
          default:  return format(v, 1);
        }
      });
      rest = args.slice(i);
      if (rest.length) out += " ";
    }
    out += rest.map((a) => format(a, 0)).join(" ");
    return out.length > MESSAGE_LIMIT ? out.slice(0, MESSAGE_LIMIT) + "…" : out;
  }

  function format(value, depth, seen) {
    const t = typeof value;
    if (t === "string") return depth === 0 ? value : JSON.stringify(value);
    if (t === "number" || t === "boolean" || t === "undefined" || t === "bigint" || t === "symbol") return describe(value);
    if (value === null) return "null";
    if (t === "function") return describe(value);
    if (value instanceof Error) {
      // JavaScriptCore's `stack` holds frames only, never the message.
      const head = (value.name || "Error") + ": " + value.message;
      return (value.stack && depth === 0) ? head + "\n" + String(value.stack) : head;
    }
    if (value instanceof Date) return isNaN(value) ? "Invalid Date" : value.toISOString();
    if (value instanceof RegExp) return String(value);
    if (isNode(value)) return describeNode(value);
    if (depth >= 3) return Array.isArray(value) ? "[…]" : "{…}";
    seen = seen || new WeakSet();
    if (seen.has(value)) return "[Circular]";
    seen.add(value);
    try {
      if (Array.isArray(value)) {
        const items = value.slice(0, 100).map((v) => format(v, depth + 1, seen));
        if (value.length > 100) items.push("…" + (value.length - 100) + " more");
        return "[" + items.join(", ") + "]";
      }
      if (value instanceof Map) {
        return "Map(" + value.size + ") {" + Array.from(value.entries()).slice(0, 50)
          .map(([k, v]) => format(k, depth + 1, seen) + " => " + format(v, depth + 1, seen)).join(", ") + "}";
      }
      if (value instanceof Set) {
        return "Set(" + value.size + ") {" + Array.from(value.values()).slice(0, 50)
          .map((v) => format(v, depth + 1, seen)).join(", ") + "}";
      }
      const keys = Object.keys(value);
      const name = className(value);
      const parts = keys.slice(0, 50).map((k) => k + ": " + format(value[k], depth + 1, seen));
      if (keys.length > 50) parts.push("…" + (keys.length - 50) + " more");
      return (name === "Object" ? "" : name + " ") + "{" + parts.join(", ") + "}";
    } catch (_) {
      return Object.prototype.toString.call(value);
    } finally {
      seen.delete(value);
    }
  }
})();
