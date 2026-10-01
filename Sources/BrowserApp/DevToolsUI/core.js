// SimpleBrowser DevTools — core: transport, panels, shared widgets.
"use strict";

const DevTools = window.DevTools = {
  pending: new Map(),
  nextId: 1,
  listeners: new Map(),
  panels: {},
  activePanel: null,
  info: {},

  // Ring buffer of what the panels did, readable from a driver script.
  traceLog: [],
  trace(...parts) {
    this.traceLog.push((performance.now() | 0) + " " + parts.map((p) => typeof p === "string" ? p : JSON.stringify(p)).join(" "));
    if (this.traceLog.length > 500) this.traceLog.shift();
  },

  rpc(method, params = {}) {
    return new Promise((resolve, reject) => {
      const id = this.nextId++;
      this.pending.set(id, { resolve, reject });
      try {
        window.webkit.messageHandlers.devtools.postMessage({ id, method, params });
      } catch (e) {
        this.pending.delete(id);
        reject(e);
      }
    });
  },

  dispatch(message) {
    if (message.id != null) {
      const p = this.pending.get(message.id);
      if (!p) return;
      this.pending.delete(message.id);
      if (message.error != null) p.reject(new Error(message.error));
      else p.resolve(message.result);
      return;
    }
    if (message.method !== "DOM.mutated" && message.method !== "Network.requestAdded" && message.method !== "Network.requestUpdated" && message.method !== "Console.entryAdded" && message.method !== "Performance.entryAdded") {
      this.trace("event", message.method, message.params && message.params.phase ? message.params.phase : "");
    }
    const fns = this.listeners.get(message.method);
    if (fns) for (const fn of fns) { try { fn(message.params); } catch (e) { console.error(e); } }
  },

  on(method, fn) {
    if (!this.listeners.has(method)) this.listeners.set(method, []);
    this.listeners.get(method).push(fn);
  },

  register(name, panel) { this.panels[name] = panel; },

  showPanel(name) {
    if (!this.panels[name]) return;
    for (const tab of document.querySelectorAll("#tabs .tab")) tab.classList.toggle("active", tab.dataset.panel === name);
    for (const section of document.querySelectorAll(".panel")) section.classList.toggle("active", section.id === "panel-" + name);
    const previous = this.activePanel;
    this.activePanel = name;
    if (previous && this.panels[previous].hide) this.panels[previous].hide();
    const panel = this.panels[name];
    if (!panel.initialized) { panel.initialized = true; panel.init(); }
    if (panel.show) panel.show();
    try { localStorage.setItem("devtools.panel", name); } catch (_) {}
  },

  async start() {
    for (const tab of document.querySelectorAll("#tabs .tab")) {
      tab.addEventListener("click", () => this.showPanel(tab.dataset.panel));
    }
    Split.init();
    Theme.init();
    Popup.init();
    this.bindChrome();

    try { this.info = await this.rpc("DevTools.ready"); } catch (e) { this.info = {}; }
    Theme.apply(this.info.theme || "system");
    this.updateDockButtons(this.info.dockSide || "bottom");
    document.getElementById("more-webkit").hidden = !this.info.webkitInspectorAvailable;

    DeviceMode.restore(this.info.emulation);

    // The debugger listens from the start, whichever panel is showing: a
    // breakpoint can hit before Sources has ever been opened.
    if (window.SBDebugger) SBDebugger.init();
    if (window.SBCacheControl) SBCacheControl.start();
    if (window.Drawer) Drawer.init();
    if (window.SBNetworkTools) SBNetworkTools.start();
    if (window.CommandMenu) CommandMenu.init();

    let panel = "elements";
    try { panel = localStorage.getItem("devtools.panel") || panel; } catch (_) {}
    this.showPanel(this.panels[panel] ? panel : "elements");

    this.on("DevTools.showPanel", ({ panel }) => { if (panel) this.showPanel(panel); });
    this.on("DevTools.startInspectMode", () => { this.showPanel("elements"); this.panels.elements.setInspectMode(true); });
    this.on("Overlay.inspectNodeRequested", ({ nodeId }) => { this.showPanel("elements"); this.panels.elements.revealNode(nodeId, true); });
    this.on("Overlay.inspectModeCanceled", () => this.panels.elements.setInspectMode(false, true));
    this.on("Page.navigated", (p) => { if (p.title != null && this.activePanel) document.title = "DevTools — " + (p.title || p.url); });
  },

  bindChrome() {
    document.getElementById("btn-close").addEventListener("click", () => this.rpc("DevTools.close"));
    document.getElementById("btn-inspect").addEventListener("click", () => {
      this.showPanel("elements");
      this.panels.elements.setInspectMode(!this.panels.elements.inspecting);
    });
    for (const side of ["bottom", "right"]) {
      document.getElementById("btn-dock-" + side).addEventListener("click", () => this.setDockSide(side));
    }
    document.getElementById("btn-undock").addEventListener("click", () => this.setDockSide("undocked"));
    document.getElementById("btn-device").addEventListener("click", (e) => DeviceMode.toggleMenu(e.currentTarget));
    document.getElementById("btn-more").addEventListener("click", (e) => {
      Popup.toggle(document.getElementById("more-menu"), e.currentTarget);
    });
    for (const item of document.querySelectorAll("#more-menu [data-theme]")) {
      item.addEventListener("click", () => { Theme.apply(item.dataset.theme); this.rpc("Settings.set", { key: "theme", value: item.dataset.theme }); Popup.hideAll(); });
    }
    document.getElementById("more-webkit").addEventListener("click", () => { this.rpc("DevTools.openWebKitInspector"); Popup.hideAll(); });
    document.getElementById("more-command").addEventListener("click", () => { Popup.hideAll(); CommandMenu.open(">"); });
    document.getElementById("more-open-file").addEventListener("click", () => { Popup.hideAll(); CommandMenu.open(""); });
    document.getElementById("more-screenshot").addEventListener("click", () => { Popup.hideAll(); SBScreenshots.capture("viewport"); });

    document.addEventListener("keydown", (e) => {
      const meta = e.metaKey || e.ctrlKey;
      if (meta && (e.key === "[" || e.key === "]")) {
        const order = Array.from(document.querySelectorAll("#tabs .tab")).map((t) => t.dataset.panel);
        const i = order.indexOf(this.activePanel);
        this.showPanel(order[(i + (e.key === "]" ? 1 : order.length - 1)) % order.length]);
        e.preventDefault();
      } else if (meta && e.altKey && e.key.toLowerCase() === "i") {
        this.rpc("DevTools.close"); e.preventDefault();
      } else if (meta && e.altKey && e.key.toLowerCase() === "j") {
        this.showPanel("console"); e.preventDefault();
      } else if (meta && e.altKey && e.key.toLowerCase() === "c") {
        this.showPanel("elements"); this.panels.elements.setInspectMode(true); e.preventDefault();
      } else if (e.key === "Escape" && !e.target.closest("input, textarea, [contenteditable]")) {
        if (this.panels.elements && this.panels.elements.inspecting) this.panels.elements.setInspectMode(false);
        Popup.hideAll(); ContextMenu.hide();
      }
    });
  },

  setDockSide(side) {
    this.updateDockButtons(side);
    this.rpc("DevTools.setDockSide", { side });
  },

  updateDockButtons(side) {
    document.getElementById("btn-dock-bottom").classList.toggle("active", side === "bottom");
    document.getElementById("btn-dock-right").classList.toggle("active", side === "right");
    document.getElementById("btn-undock").classList.toggle("active", side === "undocked");
  },

  setBadges({ errors, warnings }) {
    const el = document.getElementById("badges");
    el.textContent = "";
    if (errors) el.appendChild(h("span", { class: "badge errors", title: errors + " errors" }, String(errors)));
    if (warnings) el.appendChild(h("span", { class: "badge warnings", title: warnings + " warnings" }, String(warnings)));
  },

  openSource(url, line, column) {
    this.showPanel("sources");
    this.panels.sources.open(url, line, column);
  },
};

// ---- DOM helpers -----------------------------------------------------------------------------
function h(tag, attrs, ...children) {
  const el = document.createElement(tag);
  if (attrs) for (const [k, v] of Object.entries(attrs)) {
    if (v == null || v === false) continue;
    if (k === "class") el.className = v;
    else if (k === "style") el.style.cssText = v;
    else if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
    else if (k === "dataset") Object.assign(el.dataset, v);
    else if (k === "text") el.textContent = v;
    else el.setAttribute(k, v === true ? "" : v);
  }
  for (const child of children.flat(Infinity)) {
    if (child == null || child === false) continue;
    el.appendChild(typeof child === "string" ? document.createTextNode(child) : child);
  }
  return el;
}
const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));

function debounce(fn, ms) {
  let t;
  return (...args) => { clearTimeout(t); t = setTimeout(() => fn(...args), ms); };
}

function formatBytes(n) {
  if (n == null) return "";
  if (n < 1024) return n + " B";
  if (n < 1024 * 1024) return (n / 1024).toFixed(1) + " kB";
  return (n / 1024 / 1024).toFixed(2) + " MB";
}
function formatMs(seconds) {
  if (seconds == null) return "";
  const ms = seconds * 1000;
  if (ms >= 1000) return (ms / 1000).toFixed(2) + " s";
  if (ms >= 10) return Math.round(ms) + " ms";
  return ms.toFixed(1) + " ms";
}
function formatTime(ms) {
  const d = new Date(ms);
  const p = (n, w = 2) => String(n).padStart(w, "0");
  return `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}.${p(d.getMilliseconds(), 3)}`;
}
function fileName(url) {
  try {
    const u = new URL(url);
    const name = u.pathname.split("/").filter(Boolean).pop() || u.host;
    return name + (u.search ? u.search.slice(0, 40) : "");
  } catch (_) { return url; }
}
function escapeHTML(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}
function tryPrettyJSON(text) {
  const trimmed = String(text).trim();
  if (!(trimmed.startsWith("{") || trimmed.startsWith("["))) return null;
  try { return JSON.stringify(JSON.parse(trimmed), null, 2); } catch (_) { return null; }
}

// ---- theme -------------------------------------------------------------------------------------
const Theme = {
  init() {},
  apply(theme) {
    if (theme === "light" || theme === "dark") document.documentElement.dataset.theme = theme;
    else delete document.documentElement.dataset.theme;
    for (const item of $$("#more-menu [data-theme]")) item.classList.toggle("checked", item.dataset.theme === theme);
  },
};

// ---- device mode ---------------------------------------------------------------------------------
// Viewport and user-agent emulation. The native side resizes the page view
// and centres it; media queries and UA sniffing respond as on the device.
const DeviceMode = {
  IPHONE: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
  IPAD: "Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
  ANDROID: "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Mobile Safari/537.36",
  current: null,
  landscape: false,

  devices() {
    return [
      { name: "iPhone SE", width: 375, height: 667, userAgent: this.IPHONE },
      { name: "iPhone 15 Pro", width: 393, height: 852, userAgent: this.IPHONE },
      { name: "iPhone 15 Pro Max", width: 430, height: 932, userAgent: this.IPHONE },
      { name: "Pixel 8", width: 412, height: 915, userAgent: this.ANDROID },
      { name: "Galaxy S20", width: 360, height: 800, userAgent: this.ANDROID },
      { name: "iPad Mini", width: 768, height: 1024, userAgent: this.IPAD },
      { name: "iPad Air", width: 820, height: 1180, userAgent: this.IPAD },
      { name: "Small laptop (no UA change)", width: 1024, height: 640, userAgent: "" },
    ];
  },

  restore(emulation) {
    if (emulation && emulation.name) { this.current = emulation; this.landscape = !!emulation.landscape; }
    this.updateButton();
  },

  updateButton() {
    const button = document.getElementById("btn-device");
    button.classList.toggle("active", !!this.current);
    button.title = this.current
      ? `Device: ${this.current.name} (${this.current.width} × ${this.current.height}). Click to change.`
      : "Toggle device toolbar";
  },

  toggleMenu(anchor) {
    const menu = document.getElementById("device-menu");
    menu.textContent = "";
    const item = (label, checked, action) => {
      const el = h("div", { class: "popup-item" + (checked ? " checked" : "") }, label);
      el.addEventListener("click", () => { Popup.hideAll(); action(); });
      menu.appendChild(el);
    };
    item("Responsive (device mode off)", !this.current, () => this.clear());
    menu.appendChild(h("div", { class: "popup-sep" }));
    for (const device of this.devices()) {
      item(`${device.name}  —  ${device.width} × ${device.height}`, this.current && this.current.name === device.name, () => this.set(device));
    }
    menu.appendChild(h("div", { class: "popup-sep" }));
    item("Rotate", this.landscape, () => { this.landscape = !this.landscape; if (this.current) this.set(this.devices().find((d) => d.name === this.current.name) || this.current); });
    Popup.toggle(menu, anchor);
  },

  set(device) {
    const width = this.landscape ? device.height : device.width;
    const height = this.landscape ? device.width : device.height;
    this.current = { name: device.name, width, height, userAgent: device.userAgent, landscape: this.landscape };
    this.updateButton();
    return DevTools.rpc("Emulation.setDevice", this.current);
  },

  clear() {
    this.current = null;
    this.updateButton();
    return DevTools.rpc("Emulation.clear");
  },
};

// ---- popups & context menus ----------------------------------------------------------------------
const Popup = {
  init() {
    document.addEventListener("mousedown", (e) => {
      if (!e.target.closest(".popup, #btn-more, #btn-device")) this.hideAll();
    });
  },
  toggle(menu, anchor) {
    if (!menu.hidden) { menu.hidden = true; return; }
    this.hideAll();
    const r = anchor.getBoundingClientRect();
    menu.hidden = false;
    menu.style.left = Math.min(r.left, innerWidth - menu.offsetWidth - 8) + "px";
    menu.style.top = (r.bottom + 2) + "px";
  },
  hideAll() { for (const p of $$(".popup")) p.hidden = true; },
};

const ContextMenu = {
  el: null,
  show(x, y, items) {
    this.hide();
    const menu = document.getElementById("context-menu");
    menu.textContent = "";
    for (const item of items) {
      if (item === "-") { menu.appendChild(h("div", { class: "sep" })); continue; }
      menu.appendChild(h("div", { class: "item", onclick: () => { this.hide(); item.action(); } }, item.label));
    }
    menu.hidden = false;
    menu.style.left = Math.min(x, innerWidth - menu.offsetWidth - 8) + "px";
    menu.style.top = Math.min(y, innerHeight - menu.offsetHeight - 8) + "px";
    const close = (e) => { if (!menu.contains(e.target)) this.hide(); };
    setTimeout(() => document.addEventListener("mousedown", close, { once: true }), 0);
  },
  hide() { document.getElementById("context-menu").hidden = true; },
};

// ---- split panes -----------------------------------------------------------------------------------
const Split = {
  init() {
    for (const divider of $$(".split-divider")) {
      const split = document.getElementById(divider.dataset.split);
      const side = split.querySelector(".split-side");
      const key = "devtools.split." + divider.dataset.split;
      try { const saved = localStorage.getItem(key); if (saved) side.style.width = saved + "px"; } catch (_) {}
      divider.addEventListener("mousedown", (e) => {
        e.preventDefault();
        const sideIsRight = side.compareDocumentPosition(divider) & Node.DOCUMENT_POSITION_PRECEDING;
        const startX = e.clientX, startW = side.getBoundingClientRect().width;
        const move = (ev) => {
          const delta = sideIsRight ? startX - ev.clientX : ev.clientX - startX;
          const w = Math.max(150, Math.min(split.getBoundingClientRect().width - 150, startW + delta));
          side.style.width = w + "px";
        };
        const up = () => {
          document.removeEventListener("mousemove", move); document.removeEventListener("mouseup", up);
          try { localStorage.setItem(key, String(parseInt(side.style.width, 10))); } catch (_) {}
        };
        document.addEventListener("mousemove", move); document.addEventListener("mouseup", up);
      });
    }
  },
};

// ---- subtabs (Styles/Computed, Headers/Preview/…) -------------------------------------------------------
function bindSubtabs(container, onChange) {
  for (const tab of $$(".subtab", container)) {
    tab.addEventListener("click", () => selectSubtab(container, tab.dataset.subpanel, onChange));
  }
}
function selectSubtab(container, name, onChange) {
  for (const tab of $$(".subtab", container)) tab.classList.toggle("active", tab.dataset.subpanel === name);
  const root = container.parentElement;
  for (const sub of $$(":scope > .subpanel", root)) sub.classList.toggle("active", sub.id === "subpanel-" + name);
  if (onChange) onChange(name);
}

// ---- inline editing ---------------------------------------------------------------------------------------
// Turns an element into an editor until Enter/blur (commit) or Escape (cancel).
function inlineEdit(el, { initial, onCommit, onCancel, multiline } = {}) {
  const original = el.textContent;
  el.contentEditable = "plaintext-only";
  if (initial != null) el.textContent = initial;
  el.classList.add("editing");
  el.focus();
  const range = document.createRange(); range.selectNodeContents(el);
  const sel = getSelection(); sel.removeAllRanges(); sel.addRange(range);
  let done = false;
  const finish = (commit) => {
    if (done) return; done = true;
    el.contentEditable = "false"; el.classList.remove("editing");
    el.removeEventListener("keydown", key); el.removeEventListener("blur", blur);
    const text = el.textContent;
    if (commit) onCommit(text);
    else { el.textContent = original; if (onCancel) onCancel(); }
  };
  const key = (e) => {
    if (e.key === "Enter" && !(multiline && e.shiftKey)) { e.preventDefault(); finish(true); }
    else if (e.key === "Escape") { e.preventDefault(); finish(false); }
    else if (e.key === "Tab") { e.preventDefault(); finish(true); }
    e.stopPropagation();
  };
  const blur = () => finish(true);
  el.addEventListener("keydown", key);
  el.addEventListener("blur", blur);
}

// ---- remote object tree --------------------------------------------------------------------------------------
// Renders RemoteObject values the way Chrome's console does: primitives
// coloured by type, objects with an inline preview and a lazy property tree.
const ObjectTree = {
  render(obj, { quoteStrings = true, expandable = true } = {}) {
    if (!obj) return h("span", { class: "v-undefined" }, "undefined");
    const t = obj.type, sub = obj.subtype;
    if (t === "string") return h("span", { class: "v-string" }, quoteStrings ? JSON.stringify(obj.description) : obj.description);
    if (t === "number" || t === "bigint") return h("span", { class: "v-number" }, obj.description);
    if (t === "boolean" || t === "symbol") return h("span", { class: "v-boolean" }, obj.description);
    if (t === "undefined") return h("span", { class: "v-undefined" }, "undefined");
    if (sub === "null") return h("span", { class: "v-null" }, "null");
    if (t === "accessor") return h("span", { class: "v-accessor" }, "(...)");
    if (t === "function") {
      const fn = h("span", { class: "v-function" }, obj.description);
      return expandable && obj.objectId ? this.expandableNode(obj, fn) : fn;
    }
    if (sub === "node") {
      const node = h("span", { class: "v-node", title: "Reveal in Elements panel",
        onclick: (e) => { e.stopPropagation(); DevTools.rpc("Runtime.revealNode", { objectId: obj.objectId }); } }, obj.description);
      return expandable && obj.objectId ? this.expandableNode(obj, node) : node;
    }
    if (sub === "error") {
      return h("span", { class: "v-error" }, obj.description);
    }
    const head = h("span", { class: "obj-desc" });
    if (sub === "array") head.appendChild(h("span", {}, "(" + (obj.description.match(/\((\d+)\)/) || [, "?"])[1] + ") "));
    else if (obj.description && obj.description !== "Object") head.appendChild(h("span", {}, obj.description + " "));
    head.appendChild(this.previewNode(obj));
    return expandable && obj.objectId ? this.expandableNode(obj, head) : head;
  },

  previewNode(obj) {
    const p = obj.preview;
    const isArray = obj.subtype === "array" || obj.subtype === "typedarray";
    if (!p) return h("span", { class: "obj-preview" }, isArray ? "[]" : "{}");
    const parts = [];
    for (const prop of p.properties) {
      const val = h("span", { class: "v-" + (prop.subtype === "null" ? "null" : prop.type) }, prop.value);
      if (prop.type === "object" && prop.subtype !== "null" && prop.subtype !== "node") val.className = "obj-desc";
      parts.push(isArray ? val : h("span", {}, h("span", { class: "obj-key" }, prop.name), ": ", val));
    }
    if (p.overflow) parts.push(h("span", {}, "…"));
    const out = h("span", { class: "obj-preview" }, isArray ? "[" : "{");
    parts.forEach((part, i) => { if (i) out.appendChild(document.createTextNode(", ")); out.appendChild(part); });
    out.appendChild(document.createTextNode(isArray ? "]" : "}"));
    return out;
  },

  expandableNode(obj, headContent) {
    const container = h("span", { class: "obj" });
    const toggle = h("span", { class: "obj-toggle" });
    const head = h("span", { class: "obj-head" }, toggle, headContent);
    const children = h("div", { class: "obj-children" });
    container.append(head, children);
    let loaded = false;
    toggle.addEventListener("click", async (e) => {
      e.stopPropagation();
      const open = container.classList.toggle("expanded");
      if (open && !loaded) {
        loaded = true;
        children.appendChild(h("div", { class: "obj-row muted" }, "Loading…"));
        try {
          const props = await DevTools.rpc("Runtime.getProperties", { objectId: obj.objectId });
          children.textContent = "";
          for (const prop of props) children.appendChild(this.propertyRow(obj, prop));
          if (!props.length) children.appendChild(h("div", { class: "obj-row muted" }, "No properties"));
        } catch (err) {
          children.textContent = "";
          children.appendChild(h("div", { class: "obj-row v-error" }, String(err.message || err)));
        }
      }
    });
    return container;
  },

  propertyRow(parent, prop) {
    const key = h("span", { class: "obj-key" + (prop.isInternal ? " internal" : prop.enumerable ? "" : " dim") }, prop.name);
    const row = h("div", { class: "obj-row" });
    if (prop.isReveal) {
      row.appendChild(h("span", { class: "link", onclick: () => DevTools.rpc("Runtime.revealNode", { objectId: parent.objectId }) }, "Reveal in Elements panel"));
      return row;
    }
    let value;
    if (prop.isAccessor) {
      value = h("span", { class: "v-accessor", title: "Invoke property getter" }, "(...)");
      value.addEventListener("click", async (e) => {
        e.stopPropagation();
        try {
          const result = await DevTools.rpc("Runtime.invokeGetter", { objectId: parent.objectId, name: prop.name });
          value.replaceWith(this.render(result));
        } catch (err) { value.replaceWith(h("span", { class: "v-error" }, "[Exception: " + err.message + "]")); }
      });
    } else {
      value = this.render(prop.value);
    }
    row.append(key, ": ", value);
    return row;
  },
};
