// SimpleBrowser developer extensions — page-world hooks, installed at
// document start when React Developer Tools or the dataLayer inspector is on.
//
// React: the same global hook React DevTools installs. React looks for
// `__REACT_DEVTOOLS_GLOBAL_HOOK__` as it loads, registers its renderer and
// reports every commit; the Components panel walks the fiber tree from the
// committed roots. dataLayer: every push to `window.dataLayer` (Google Tag
// Manager, gtag) is recorded with its time, including what was pushed before
// GTM loaded. Both are read on demand through `__sbDevExt.handle`; nothing is
// sent anywhere while DevTools is closed.
(function () {
  "use strict";
  if (window.__sbDevExt) return;
  const FLAGS = __SB_DEVEXT_FLAGS__;
  const handlers = {};

  // ---- values, for display ---------------------------------------------------------------------------------
  function preview(v, depth = 0, seen = new WeakSet()) {
    if (v === null || typeof v === "boolean" || typeof v === "number" || typeof v === "string") {
      return typeof v === "string" && v.length > 2000 ? v.slice(0, 2000) + "…" : (typeof v === "number" && !isFinite(v) ? { $t: "number", v: String(v) } : v);
    }
    if (v === undefined) return { $t: "undefined" };
    if (typeof v === "bigint") return { $t: "bigint", v: String(v) };
    if (typeof v === "symbol") return { $t: "symbol", v: String(v) };
    if (typeof v === "function") return { $t: "function", v: (v.displayName || v.name || "anonymous") + "()" };
    if (typeof Node !== "undefined" && v instanceof Node) {
      return { $t: "node", v: v.nodeType === 1 ? "<" + v.localName + (v.id ? "#" + v.id : "") + (v.classList && v.classList.length ? "." + [...v.classList].slice(0, 3).join(".") : "") + ">" : v.nodeName };
    }
    if (v && v.$$typeof && String(v.$$typeof).includes("react.element")) {
      return { $t: "react", v: "<" + componentName(v.type) + " />" };
    }
    if (seen.has(v)) return { $t: "circular" };
    if (depth > 5) return { $t: "more", v: Array.isArray(v) ? "Array(" + v.length + ")" : (v.constructor && v.constructor.name) || "Object" };
    seen.add(v);
    if (v instanceof Date) return { $t: "date", v: isNaN(v) ? "Invalid Date" : v.toISOString() };
    if (v instanceof RegExp) return { $t: "regexp", v: String(v) };
    if (v instanceof Error) return { $t: "error", v: v.name + ": " + v.message };
    if (v instanceof Map) return { $t: "map", v: Array.from(v.entries()).slice(0, 100).map(([k, x]) => [preview(k, depth + 1, seen), preview(x, depth + 1, seen)]) };
    if (v instanceof Set) return { $t: "set", v: Array.from(v).slice(0, 100).map((x) => preview(x, depth + 1, seen)) };
    if (typeof Promise !== "undefined" && v instanceof Promise) return { $t: "promise" };
    if (Array.isArray(v) || (typeof v === "object" && Object.prototype.toString.call(v) === "[object Arguments]")) {
      return Array.from(v).slice(0, 200).map((x) => preview(x, depth + 1, seen));
    }
    const out = {};
    let n = 0;
    for (const key of Object.keys(v)) {
      if (n++ >= 200) { out["…"] = { $t: "more", v: (Object.keys(v).length - 200) + " more" }; break; }
      let value;
      try { value = v[key]; } catch (e) { value = { $t: "error", v: "getter threw" }; }
      out[key] = preview(value, depth + 1, seen);
    }
    return out;
  }

  function componentName(type) {
    if (!type) return "Anonymous";
    if (typeof type === "string") return type;
    if (type.displayName) return type.displayName;
    if (type.name) return type.name;
    if (type.render) return "ForwardRef(" + (type.render.displayName || type.render.name || "") + ")";
    if (type.type) return "Memo(" + componentName(type.type) + ")";
    if (type._context) return (type._context.displayName || "Context") + ".Consumer";
    if (type.$$typeof && String(type.$$typeof).includes("provider")) return (type._context && type._context.displayName || "Context") + ".Provider";
    return "Anonymous";
  }

  // ---- React ------------------------------------------------------------------------------------------------------
  const react = { renderers: new Map(), roots: new Map(), commits: 0, lastCommit: 0 };
  if (FLAGS.react && !window.__REACT_DEVTOOLS_GLOBAL_HOOK__) {
    let nextRenderer = 1;
    const hook = {
      renderers: react.renderers,
      rendererInterfaces: new Map(),
      supportsFiber: true,
      isDisabled: false,
      inject(renderer) {
        const id = nextRenderer++;
        react.renderers.set(id, renderer);
        react.roots.set(id, new Set());
        return id;
      },
      getFiberRoots(id) { return react.roots.get(id) || new Set(); },
      onCommitFiberRoot(id, root) {
        const set = react.roots.get(id);
        if (!set) return;
        const current = root && root.current;
        if (current && current.child) set.add(root); else set.delete(root);
        react.commits++;
        react.lastCommit = Date.now();
      },
      onCommitFiberUnmount() {},
      onPostCommitFiberRoot() {},
      setStrictMode() {},
      checkDCE() {},
      on() {}, off() {}, emit() {}, sub() { return () => {}; },
    };
    try {
      Object.defineProperty(window, "__REACT_DEVTOOLS_GLOBAL_HOOK__", { value: hook, configurable: true, enumerable: false, writable: false });
    } catch (_) {}
  }

  // Fiber tags this panel distinguishes (React 16–19).
  const TAG = { function: 0, class: 1, root: 3, host: 5, text: 6, fragment: 7, mode: 8, consumer: 9, provider: 10, forwardRef: 11,
                profiler: 12, suspense: 13, memo: 14, simpleMemo: 15, lazy: 16, offscreen: 22, hostHoistable: 26, hostSingleton: 27 };
  const ids = new WeakMap();
  const byId = new Map();
  let nextFiberId = 1;

  function fiberId(fiber) {
    let id = ids.get(fiber) || (fiber.alternate && ids.get(fiber.alternate));
    if (!id) { id = nextFiberId++; }
    ids.set(fiber, id);
    if (fiber.alternate) ids.set(fiber.alternate, id);
    byId.set(id, fiber);
    return id;
  }

  function isHost(fiber) { return fiber.tag === TAG.host || fiber.tag === TAG.hostHoistable || fiber.tag === TAG.hostSingleton; }

  function fiberKind(fiber) {
    switch (fiber.tag) {
      case TAG.function: return "function";
      case TAG.class: return "class";
      case TAG.forwardRef: return "forwardRef";
      case TAG.memo: case TAG.simpleMemo: return "memo";
      case TAG.provider: return "provider";
      case TAG.consumer: return "consumer";
      case TAG.suspense: return "suspense";
      case TAG.profiler: return "profiler";
      case TAG.lazy: return "lazy";
      default: return isHost(fiber) ? "host" : null;
    }
  }

  function fiberName(fiber) {
    if (isHost(fiber)) return fiber.type;
    if (fiber.tag === TAG.suspense) return "Suspense";
    if (fiber.tag === TAG.profiler) return "Profiler";
    if (fiber.tag === TAG.provider) return ((fiber.type && (fiber.type._context || fiber.type).displayName) || "Context") + ".Provider";
    if (fiber.tag === TAG.consumer) return ((fiber.type && (fiber.type._context || fiber.type).displayName) || "Context") + ".Consumer";
    if (fiber.tag === TAG.simpleMemo) return "Memo(" + componentName(fiber.type) + ")";
    return componentName(fiber.type);
  }

  function rootFibers() {
    const out = [];
    for (const [rendererId, set] of react.roots) for (const root of set) if (root.current) out.push({ rendererId, root: root.current });
    if (!out.length) {
      // React loaded before the hook (or without DevTools support): find roots through the DOM.
      for (const el of document.querySelectorAll("body, body *")) {
        const key = Object.keys(el).find((k) => k.startsWith("__reactContainer$") || k === "_reactRootContainer");
        if (!key) continue;
        let container = el[key];
        if (container && container._internalRoot) container = container._internalRoot;
        const fiber = container && (container.current || (container.stateNode && container.stateNode.current) || container);
        if (fiber && fiber.child) out.push({ rendererId: 0, root: fiber.tag === TAG.root ? fiber : fiber });
        if (out.length > 20) break;
      }
    }
    return out;
  }

  /// The component tree, host elements left out unless asked for: what React DevTools shows.
  handlers["React.tree"] = ({ showHost = false, limit = 5000 } = {}) => {
    const nodes = [];
    byId.clear();
    const walk = (fiber, depth, parent) => {
      let f = fiber;
      while (f && nodes.length < limit) {
        const kind = fiberKind(f);
        const shown = kind && (showHost || kind !== "host");
        let nextParent = parent, nextDepth = depth;
        if (shown) {
          const id = fiberId(f);
          nodes.push({ id, name: fiberName(f), kind, key: f.key, depth, parent, hasSource: !!f._debugSource });
          nextParent = id; nextDepth = depth + 1;
        }
        if (f.child) walk(f.child, nextDepth, nextParent);
        f = f.sibling;
      }
    };
    for (const { root } of rootFibers()) walk(root.child, 0, null);
    return { nodes, truncated: nodes.length >= limit, roots: rootFibers().length };
  };

  handlers["React.status"] = () => {
    const versions = [];
    for (const renderer of react.renderers.values()) versions.push({ version: renderer.version, package: renderer.rendererPackageName, bundleType: renderer.bundleType });
    const roots = rootFibers().length;
    return { hooked: !!window.__REACT_DEVTOOLS_GLOBAL_HOOK__ && react.renderers.size > 0, detected: react.renderers.size > 0 || roots > 0, renderers: versions, roots, commits: react.commits, lastCommit: react.lastCommit };
  };

  function fiberFor(id) {
    const fiber = byId.get(Number(id));
    if (!fiber) throw new Error("That component is no longer mounted. Refresh the tree.");
    return fiber;
  }

  function hookList(fiber) {
    const out = [];
    let hook = fiber.memoizedState;
    let index = 0;
    const debugNames = (fiber._debugHookTypes || []);
    while (hook && typeof hook === "object" && "memoizedState" in hook && index < 100) {
      const state = hook.memoizedState;
      let kind = debugNames[index] || null;
      if (!kind) {
        if (hook.queue && hook.queue.dispatch) kind = hook.queue.lastRenderedReducer && hook.queue.lastRenderedReducer.name === "basicStateReducer" ? "useState" : "useReducer";
        else if (state && typeof state === "object" && "create" in state && "deps" in state) kind = "useEffect";
        else if (state && typeof state === "object" && !Array.isArray(state) && Object.keys(state).length === 1 && "current" in state) kind = "useRef";
        else if (Array.isArray(state) && state.length === 2 && (state[1] === null || Array.isArray(state[1]))) kind = "useMemo";
        else kind = "hook";
      }
      const editable = !!(hook.queue && hook.queue.dispatch);
      let value;
      if (kind === "useEffect" || kind === "useLayoutEffect" || kind === "useInsertionEffect") value = { $t: "effect", v: state && state.deps ? "deps: " + state.deps.length : "no deps" };
      else if (kind === "useMemo" || kind === "useCallback") value = preview(Array.isArray(state) ? state[0] : state);
      else if (kind === "useRef") value = preview(state && state.current);
      else value = preview(state);
      out.push({ index, kind, value, editable });
      hook = hook.next;
      index++;
    }
    return out;
  }

  function hostElement(fiber) {
    if (isHost(fiber)) return fiber.stateNode;
    let f = fiber.child;
    const stack = [];
    while (f) {
      if (isHost(f) && f.stateNode && f.stateNode.nodeType === 1) return f.stateNode;
      if (f.child) { if (f.sibling) stack.push(f.sibling); f = f.child; } else f = f.sibling || stack.pop();
    }
    return null;
  }

  function owners(fiber) {
    const out = [];
    let o = fiber._debugOwner;
    while (o && out.length < 20) {
      if (typeof o.tag === "number") out.push({ id: fiberId(o), name: fiberName(o) });
      else if (o.name) out.push({ id: null, name: o.name });   // React 19 server-component owner info
      o = o._debugOwner || o.owner;
    }
    return out;
  }

  handlers["React.inspect"] = ({ id }) => {
    const fiber = fiberFor(id);
    const isClass = fiber.tag === TAG.class;
    const props = {};
    for (const key of Object.keys(fiber.memoizedProps || {})) if (key !== "children" || typeof fiber.memoizedProps.children !== "object") props[key] = fiber.memoizedProps[key];
    if (fiber.memoizedProps && typeof fiber.memoizedProps.children === "object" && fiber.memoizedProps.children) props.children = { $t: "more", v: "children" };
    const el = hostElement(fiber);
    const source = fiber._debugSource ? { file: fiber._debugSource.fileName, line: fiber._debugSource.lineNumber, column: fiber._debugSource.columnNumber } : null;
    return {
      id: Number(id), name: fiberName(fiber), kind: fiberKind(fiber), key: fiber.key,
      props: preview(props), state: isClass ? preview(fiber.stateNode && fiber.stateNode.state) : null,
      hooks: fiber.tag === TAG.function || fiber.tag === TAG.forwardRef || fiber.tag === TAG.simpleMemo ? hookList(fiber) : [],
      context: isClass && fiber.stateNode && fiber.stateNode.context && Object.keys(fiber.stateNode.context).length ? preview(fiber.stateNode.context) : null,
      owners: owners(fiber), source,
      element: el ? preview(el) : null,
      selector: el ? selectorFor(el) : null,
      renderedBy: fiber._debugOwner ? fiberName(fiber._debugOwner) : null,
    };
  };

  function selectorFor(el) {
    if (el.id) return "#" + CSS.escape(el.id);
    const parts = [];
    let node = el;
    while (node && node.nodeType === 1 && parts.length < 8 && node !== document.documentElement) {
      let part = node.localName;
      const parent = node.parentElement;
      if (parent) {
        const same = Array.from(parent.children).filter((c) => c.localName === node.localName);
        if (same.length > 1) part += ":nth-of-type(" + (same.indexOf(node) + 1) + ")";
      }
      parts.unshift(part);
      if (node.id) { parts[0] = "#" + CSS.escape(node.id); break; }
      node = parent;
    }
    return parts.join(" > ");
  }

  let overlay = null;
  handlers["React.highlight"] = ({ id }) => {
    const el = hostElement(fiberFor(id));
    if (!el) return false;
    const r = el.getBoundingClientRect();
    if (!overlay) {
      overlay = document.createElement("div");
      overlay.setAttribute("data-sb-devext", "");
      overlay.style.cssText = "position:fixed;pointer-events:none;z-index:2147483647;background:rgba(97,218,251,.25);outline:2px solid #61dafb;border-radius:2px;transition:all .06s;font:11px -apple-system,system-ui;color:#fff";
    }
    const label = fiberName(fiberFor(id)) + "  " + Math.round(r.width) + "×" + Math.round(r.height);
    overlay.style.left = r.left + "px"; overlay.style.top = r.top + "px"; overlay.style.width = r.width + "px"; overlay.style.height = r.height + "px";
    overlay.innerHTML = "";
    const tag = document.createElement("span");
    tag.textContent = label;
    tag.style.cssText = "position:absolute;left:0;top:-18px;background:#20232a;padding:1px 5px;border-radius:3px;white-space:nowrap";
    overlay.appendChild(tag);
    if (!overlay.isConnected) document.documentElement.appendChild(overlay);
    return true;
  };
  handlers["React.unhighlight"] = () => { if (overlay) overlay.remove(); return true; };
  handlers["React.scrollIntoView"] = ({ id }) => { const el = hostElement(fiberFor(id)); if (el) el.scrollIntoView({ block: "center", behavior: "instant" }); return !!el; };

  /// The component that rendered the element a CSS selector finds (Elements → Components).
  handlers["React.fromSelector"] = ({ selector }) => {
    const el = document.querySelector(selector);
    if (!el) return null;
    let node = el, key = null;
    while (node && !(key = Object.keys(node).find((k) => k.startsWith("__reactFiber$") || k.startsWith("__reactInternalInstance$")))) node = node.parentElement;
    if (!node || !key) return null;
    let fiber = node[key];
    while (fiber && !fiberKind(fiber) || (fiber && fiberKind(fiber) === "host")) fiber = fiber.return;
    return fiber ? fiberId(fiber) : null;
  };

  /// Edits a useState / useReducer hook, or a class component's state, the way React DevTools does.
  handlers["React.setState"] = ({ id, hookIndex, path, value }) => {
    const fiber = fiberFor(id);
    const apply = (base) => {
      if (!path || !path.length) return value;
      const copy = Array.isArray(base) ? base.slice() : Object.assign({}, base);
      let target = copy;
      for (let i = 0; i < path.length - 1; i++) {
        target[path[i]] = Array.isArray(target[path[i]]) ? target[path[i]].slice() : Object.assign({}, target[path[i]]);
        target = target[path[i]];
      }
      target[path[path.length - 1]] = value;
      return copy;
    };
    if (fiber.tag === TAG.class && fiber.stateNode && fiber.stateNode.setState) {
      fiber.stateNode.setState(apply(fiber.stateNode.state));
      return true;
    }
    let hook = fiber.memoizedState;
    for (let i = 0; i < hookIndex && hook; i++) hook = hook.next;
    if (!hook || !hook.queue || !hook.queue.dispatch) throw new Error("That hook cannot be edited");
    hook.queue.dispatch(apply(hook.memoizedState));
    return true;
  };

  // ---- dataLayer -------------------------------------------------------------------------------------------------
  const layer = { events: [], next: 1, names: new Set() };
  const hooked = new WeakSet();

  function eventName(item) {
    if (item && typeof item === "object" && Object.prototype.toString.call(item) === "[object Arguments]") {
      const args = Array.from(item);
      return args[0] === "event" ? String(args[1]) : "gtag:" + String(args[0]);
    }
    if (item && typeof item === "object" && typeof item.event === "string") return item.event;
    if (typeof item === "function") return "(function)";
    return "(message)";
  }

  function record(name, item, origin) {
    if (layer.events.length > 2000) layer.events.splice(0, 500);
    const isArgs = item && typeof item === "object" && Object.prototype.toString.call(item) === "[object Arguments]";
    layer.events.push({
      i: layer.next++, t: Math.round(performance.now()), at: Date.now(), layer: name, origin,
      event: eventName(item), gtag: isArgs, data: preview(isArgs ? Array.from(item) : item), url: location.href,
    });
  }

  function hookArray(array, name) {
    if (!Array.isArray(array) || hooked.has(array)) return array;
    hooked.add(array);
    layer.names.add(name);
    for (const item of array) record(name, item, "before");
    let inner = array.push;   // GTM replaces push with its own; keep whichever is current underneath ours.
    const wrapped = function (...items) {
      for (const item of items) record(name, item, "push");
      return inner.apply(this, items);
    };
    try {
      Object.defineProperty(array, "push", { configurable: true, enumerable: false, get() { return wrapped; }, set(fn) { inner = fn; } });
    } catch (_) {}
    return array;
  }

  function watch(name) {
    let current = window[name];
    if (current) hookArray(current, name);
    try {
      Object.defineProperty(window, name, {
        configurable: true, enumerable: true,
        get() { return current; },
        set(value) { current = hookArray(value, name); },
      });
    } catch (_) {}
  }

  if (FLAGS.dataLayer) {
    watch("dataLayer");
    // Containers that rename their layer: gtm.js?id=…&l=<name>.
    new MutationObserver((records) => {
      for (const r of records) for (const n of r.addedNodes) {
        if (n.localName !== "script" || !n.src) continue;
        const m = n.src.match(/googletagmanager\.com\/gtm\.js\?[^#]*\bl=([A-Za-z_$][\w$]*)/);
        if (m && m[1] !== "dataLayer" && !layer.names.has(m[1])) watch(m[1]);
      }
    }).observe(document, { childList: true, subtree: true });
  }

  function containers() {
    const found = new Set();
    for (const s of document.scripts) {
      const m = (s.src || "").match(/[?&]id=((?:GTM|G|AW|UA|DC)-[A-Z0-9-]+)/i);
      if (m) found.add(m[1]);
    }
    if (window.google_tag_manager) for (const key of Object.keys(window.google_tag_manager)) if (/^(GTM|G|AW)-/.test(key)) found.add(key);
    return Array.from(found);
  }

  handlers["DataLayer.events"] = ({ after = 0 } = {}) => ({
    enabled: !!FLAGS.dataLayer, names: Array.from(layer.names), present: layer.names.size > 0,
    containers: containers(), events: layer.events.filter((e) => e.i > after),
  });
  handlers["DataLayer.clear"] = () => { layer.events = []; return true; };
  handlers["DataLayer.push"] = ({ name = "dataLayer", item }) => {
    if (!Array.isArray(window[name])) window[name] = [];
    window[name].push(item);
    return true;
  };
  handlers["DataLayer.state"] = ({ name = "dataLayer" } = {}) => {
    // GTM's merged model, as `google_tag_manager[id].dataLayer.get` sees it, where available.
    const model = {};
    for (const e of layer.events) if (e.layer === name && e.data && typeof e.data === "object" && !Array.isArray(e.data)) Object.assign(model, e.data);
    return preview(model);
  };

  Object.defineProperty(window, "__sbDevExt", {
    value: {
      handle(method, params) {
        const fn = handlers[method];
        if (!fn) throw new Error("Unknown method " + method);
        return JSON.parse(JSON.stringify(fn(params || {}) ?? null));
      },
    },
    enumerable: false, configurable: false, writable: false,
  });
})();
