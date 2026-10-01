// SimpleBrowser JSON Viewer. Runs in its own isolated world when a document
// finishes loading; if the document is JSON (served as JSON, or a .json file
// shown as text), it replaces WebKit's plain-text rendering with a
// collapsible tree, a raw and a pretty view, a filter, and copyable paths.
(function () {
  "use strict";
  const type = (document.contentType || "").toLowerCase();
  const isJSONType = /^application\/(.+\+)?json$|^text\/json$|^application\/(manifest|ld)\+json$/.test(type);
  const pre = document.body && document.body.children.length === 1 && document.body.firstElementChild.localName === "pre" ? document.body.firstElementChild : null;
  const looksJSON = type === "text/plain" && pre && /\.json(\?|#|$)/i.test(location.pathname + location.search);
  if (!(isJSONType || looksJSON) || !document.body) return;
  const raw = pre ? pre.textContent : document.body.innerText;
  if (raw.length > 50 * 1024 * 1024) return;   // leave huge files to WebKit's text view
  let data;
  try { data = JSON.parse(raw); } catch (_) { return; }

  const host = document.createElement("div");
  host.id = "sb-json-viewer";
  const root = host.attachShadow({ mode: "open" });
  if (pre) pre.style.display = "none";
  document.body.appendChild(host);
  document.body.style.margin = "0";

  root.innerHTML = `
<style>
  :host { all: initial; display: block; }
  .wrap { --bg:#fff; --bar:#f6f7f8; --line:#e3e5e8; --text:#1f2328; --muted:#7a828c; --key:#881391; --str:#1a7f37; --num:#1750eb; --bool:#cf222e; --null:#7a828c; --hover:#f0f3f6; --accent:#0969da;
          font: 12.5px/1.55 ui-monospace, Menlo, monospace; color: var(--text); background: var(--bg); min-height: 100vh; }
  @media (prefers-color-scheme: dark) { .wrap { --bg:#16181d; --bar:#1e2127; --line:#2c3038; --text:#d7dae0; --muted:#8b929c; --key:#d2a8ff; --str:#7ee787; --num:#79c0ff; --bool:#ff7b72; --null:#8b929c; --hover:#22262d; --accent:#58a6ff; } }
  .bar { position: sticky; top: 0; z-index: 2; display: flex; gap: 6px; align-items: center; padding: 6px 10px; background: var(--bar); border-bottom: 1px solid var(--line); font: 12px -apple-system, system-ui, sans-serif; }
  .seg { display: inline-flex; border: 1px solid var(--line); border-radius: 6px; overflow: hidden; }
  .seg button, .btn { font: inherit; background: none; color: var(--text); border: 0; padding: 3px 10px; cursor: pointer; }
  .seg button.on { background: var(--accent); color: #fff; }
  .btn { border: 1px solid var(--line); border-radius: 6px; }
  .btn:hover, .seg button:not(.on):hover { background: var(--hover); }
  input { font: inherit; background: var(--bg); color: var(--text); border: 1px solid var(--line); border-radius: 6px; padding: 3px 8px; width: 220px; }
  .info { margin-left: auto; color: var(--muted); }
  .path { color: var(--muted); max-width: 40vw; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .body { padding: 8px 14px 40px; }
  .row { white-space: pre; padding-left: calc(var(--d) * 16px); cursor: default; border-radius: 3px; }
  .row:hover { background: var(--hover); }
  .row.hit { background: rgba(255, 200, 0, .22); }
  .tw { display: inline-block; width: 14px; color: var(--muted); cursor: pointer; user-select: none; }
  .k { color: var(--key); cursor: pointer; } .s { color: var(--str); } .n { color: var(--num); } .b { color: var(--bool); } .z { color: var(--null); }
  .s a { color: inherit; } .c { color: var(--muted); }
  .sum { color: var(--muted); font-style: italic; }
  pre.text { margin: 0; white-space: pre-wrap; word-break: break-word; }
  .toast { position: fixed; bottom: 14px; left: 50%; transform: translateX(-50%); background: #24292f; color: #fff; padding: 5px 12px; border-radius: 6px; font: 12px -apple-system, system-ui; opacity: 0; transition: opacity .2s; }
  .toast.on { opacity: 1; }
</style>
<div class="wrap">
  <div class="bar">
    <span class="seg"><button data-mode="tree" class="on">Viewer</button><button data-mode="pretty">Pretty</button><button data-mode="raw">Raw</button></span>
    <input type="search" placeholder="Filter keys and values" aria-label="Filter">
    <button class="btn" data-act="expand">Expand all</button>
    <button class="btn" data-act="collapse">Collapse all</button>
    <button class="btn" data-act="copy">Copy</button>
    <span class="path" title="Click a key to copy its path"></span>
    <span class="info"></span>
  </div>
  <div class="body"></div>
  <div class="toast"></div>
</div>`;

  const body = root.querySelector(".body");
  const info = root.querySelector(".info");
  const pathLabel = root.querySelector(".path");
  const toastEl = root.querySelector(".toast");
  const filter = root.querySelector("input");
  const expanded = new Set();
  let mode = "tree";

  const kind = (v) => v === null ? "null" : Array.isArray(v) ? "array" : typeof v;
  const size = (v) => Array.isArray(v) ? v.length : v && typeof v === "object" ? Object.keys(v).length : 0;
  const bytes = new Blob([raw]).size;
  info.textContent = `${kind(data)}${size(data) ? " · " + size(data) + (Array.isArray(data) ? " items" : " keys") : ""} · ${bytes < 1024 ? bytes + " B" : (bytes / 1024).toFixed(1) + " KB"}`;

  function toast(text) {
    toastEl.textContent = text; toastEl.classList.add("on");
    clearTimeout(toast.t); toast.t = setTimeout(() => toastEl.classList.remove("on"), 1200);
  }
  function copy(text, what) {
    navigator.clipboard.writeText(text).then(() => toast("Copied " + what)).catch(() => {
      const t = document.createElement("textarea"); t.value = text; root.appendChild(t); t.select(); document.execCommand("copy"); t.remove(); toast("Copied " + what);
    });
  }
  const pathOf = (parts) => parts.reduce((s, p) => typeof p === "number" ? `${s}[${p}]` : /^[A-Za-z_$][\w$]*$/.test(p) ? (s ? s + "." + p : p) : `${s}[${JSON.stringify(p)}]`, "");

  function scalar(v) {
    const span = document.createElement("span");
    switch (kind(v)) {
      case "string": {
        span.className = "s";
        if (/^https?:\/\/\S+$/.test(v)) {
          const a = document.createElement("a"); a.href = v; a.textContent = JSON.stringify(v); span.appendChild(a);
        } else span.textContent = JSON.stringify(v);
        break;
      }
      case "number": span.className = "n"; span.textContent = String(v); break;
      case "boolean": span.className = "b"; span.textContent = String(v); break;
      default: span.className = "z"; span.textContent = "null";
    }
    return span;
  }

  // Default: everything open to depth 2, or depth 1 for big documents.
  const defaultDepth = bytes > 2 * 1024 * 1024 ? 1 : 2;
  function isOpen(key, depth) { return expanded.has(key) ? true : expanded.has("!" + key) ? false : depth < defaultDepth; }

  function matches(v, key, q) {
    if (!q) return false;
    if (key != null && String(key).toLowerCase().includes(q)) return true;
    if (v !== null && typeof v !== "object") return String(v).toLowerCase().includes(q);
    return false;
  }
  function contains(v, q) {
    if (!q) return true;
    if (v !== null && typeof v === "object") return Object.entries(v).some(([k, x]) => matches(x, k, q) || contains(x, q));
    return String(v).toLowerCase().includes(q);
  }

  let rendered = 0;
  function render() {
    body.textContent = "";
    rendered = 0;
    if (mode !== "tree") {
      const p = document.createElement("pre"); p.className = "text";
      p.textContent = mode === "raw" ? raw : JSON.stringify(data, null, 2);
      body.appendChild(p);
      return;
    }
    const q = filter.value.trim().toLowerCase();
    const frag = document.createDocumentFragment();
    node(frag, data, null, [], 0, true, q);
    body.appendChild(frag);
  }

  function node(out, v, key, path, depth, last, q) {
    if (rendered > 40000) return;
    if (q && !matches(v, key, q) && !contains(v, q)) return;
    rendered++;
    const id = JSON.stringify(path);
    const row = document.createElement("div");
    row.className = "row" + (matches(v, key, q) ? " hit" : "");
    row.style.setProperty("--d", depth);
    const composite = v !== null && typeof v === "object";
    const open = composite && (q ? true : isOpen(id, depth));
    const twist = document.createElement("span"); twist.className = "tw";
    twist.textContent = composite && size(v) ? (open ? "▾" : "▸") : "";
    row.appendChild(twist);
    if (key !== null) {
      const k = document.createElement("span"); k.className = "k";
      k.textContent = typeof key === "number" ? String(key) : JSON.stringify(key);
      k.title = "Copy path " + pathOf(path);
      k.addEventListener("click", (e) => { e.stopPropagation(); copy(pathOf(path), pathOf(path)); });
      row.append(k, document.createTextNode(": "));
    }
    if (composite) {
      const isArray = Array.isArray(v);
      row.append(document.createTextNode(isArray ? "[" : "{"));
      if (!open || !size(v)) {
        const sum = document.createElement("span"); sum.className = "sum";
        sum.textContent = size(v) ? ` ${size(v)} ${isArray ? "items" : "keys"} ` : "";
        row.append(sum, document.createTextNode((isArray ? "]" : "}") + (last ? "" : ",")));
      }
      if (size(v)) row.addEventListener("click", () => {
        if (open) { expanded.delete(id); expanded.add("!" + id); } else { expanded.delete("!" + id); expanded.add(id); }
        render();
      });
    } else {
      row.appendChild(scalar(v));
      if (!last) row.append(document.createTextNode(","));
      row.addEventListener("dblclick", () => copy(typeof v === "string" ? v : JSON.stringify(v), "value"));
    }
    row.addEventListener("mouseenter", () => { pathLabel.textContent = pathOf(path) || "(root)"; });
    out.appendChild(row);
    if (composite && open && size(v)) {
      const entries = Array.isArray(v) ? v.map((x, i) => [i, x]) : Object.entries(v);
      entries.forEach(([k, x], i) => node(out, x, k, path.concat([k]), depth + 1, i === entries.length - 1, q));
      const close = document.createElement("div"); close.className = "row"; close.style.setProperty("--d", depth);
      close.innerHTML = '<span class="tw"></span>';
      close.append(document.createTextNode((Array.isArray(v) ? "]" : "}") + (last ? "" : ",")));
      out.appendChild(close);
    }
  }

  root.querySelectorAll(".seg button").forEach((b) => b.addEventListener("click", () => {
    mode = b.dataset.mode;
    root.querySelectorAll(".seg button").forEach((x) => x.classList.toggle("on", x === b));
    filter.disabled = mode !== "tree";
    render();
  }));
  root.querySelector('[data-act="expand"]').addEventListener("click", () => {
    expanded.clear();
    const walk = (v, path) => { if (v && typeof v === "object") { expanded.add(JSON.stringify(path)); for (const [k, x] of Array.isArray(v) ? v.map((x, i) => [i, x]) : Object.entries(v)) walk(x, path.concat([k])); } };
    walk(data, []);
    render();
  });
  root.querySelector('[data-act="collapse"]').addEventListener("click", () => {
    expanded.clear();
    const walk = (v, path) => { if (v && typeof v === "object") { expanded.add("!" + JSON.stringify(path)); for (const [k, x] of Array.isArray(v) ? v.map((x, i) => [i, x]) : Object.entries(v)) walk(x, path.concat([k])); } };
    walk(data, []); expanded.delete("![]"); expanded.add("[]");
    render();
  });
  root.querySelector('[data-act="copy"]').addEventListener("click", () => copy(mode === "raw" ? raw : JSON.stringify(data, null, 2), "JSON"));
  let timer = null;
  filter.addEventListener("input", () => { clearTimeout(timer); timer = setTimeout(render, 120); });
  // The page's data stays reachable for scripts and agents.
  document.documentElement.dataset.sbJsonViewer = "on";
  render();
})();
