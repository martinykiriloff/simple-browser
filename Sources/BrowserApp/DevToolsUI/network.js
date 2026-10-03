// Keel DevTools — Network panel.
"use strict";

(function () {
  const TYPE_GROUPS = {
    all: null,
    fetch: new Set(["fetch", "xhr"]),
    document: new Set(["document"]),
    stylesheet: new Set(["stylesheet"]),
    script: new Set(["script"]),
    font: new Set(["font"]),
    image: new Set(["image"]),
    media: new Set(["media"]),
    websocket: new Set(["websocket"]),
    other: new Set(["other", "ping"]),
  };

  const STATUS_TEXT = {
    100: "Continue", 101: "Switching Protocols", 103: "Early Hints", 200: "OK", 201: "Created", 202: "Accepted", 203: "Non-Authoritative Information",
    204: "No Content", 205: "Reset Content", 206: "Partial Content", 207: "Multi-Status", 300: "Multiple Choices", 301: "Moved Permanently", 302: "Found",
    303: "See Other", 304: "Not Modified", 307: "Temporary Redirect", 308: "Permanent Redirect", 400: "Bad Request", 401: "Unauthorized",
    402: "Payment Required", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 406: "Not Acceptable", 407: "Proxy Authentication Required",
    408: "Request Timeout", 409: "Conflict", 410: "Gone", 411: "Length Required", 412: "Precondition Failed", 413: "Content Too Large", 414: "URI Too Long",
    415: "Unsupported Media Type", 416: "Range Not Satisfiable", 417: "Expectation Failed", 418: "I'm a teapot", 421: "Misdirected Request",
    422: "Unprocessable Content", 423: "Locked", 425: "Too Early", 426: "Upgrade Required", 428: "Precondition Required", 429: "Too Many Requests",
    431: "Request Header Fields Too Large", 451: "Unavailable For Legal Reasons", 500: "Internal Server Error", 501: "Not Implemented",
    502: "Bad Gateway", 503: "Service Unavailable", 504: "Gateway Timeout", 505: "HTTP Version Not Supported", 511: "Network Authentication Required",
  };

  // Columns, in Chrome's order. `hidden` ones are off until chosen from the header's context menu.
  const COLUMNS = [
    { id: "name", title: "Name", width: "26%", fixed: true },
    { id: "status", title: "Status", width: "92px" },
    { id: "method", title: "Method", width: "64px", hidden: true },
    { id: "domain", title: "Domain", width: "120px", hidden: true },
    { id: "type", title: "Type", width: "76px" },
    { id: "initiator", title: "Initiator", width: "90px" },
    { id: "protocol", title: "Protocol", width: "70px", hidden: true },
    { id: "remote", title: "Remote Address", width: "120px", hidden: true },
    { id: "cookies", title: "Cookies", width: "62px", hidden: true },
    { id: "setcookies", title: "Set-Cookies", width: "76px", hidden: true },
    { id: "priority", title: "Priority", width: "70px", hidden: true },
    { id: "size", title: "Size", width: "86px" },
    { id: "time", title: "Time", width: "70px" },
    { id: "waterfall", title: "Waterfall", width: "" },
  ];

  // Chrome's filter keys (`status-code:404`, `-domain:cdn.com`, `larger-than:100k`, …).
  const FILTER_KEYS = new Set(["domain", "status-code", "method", "mime-type", "larger-than", "is", "has-response-header", "has-request-header",
    "resource-type", "scheme", "url", "cookie-name", "set-cookie-name", "priority", "protocol", "remote-address"]);

  // ---- shared helpers (also used by network-preview.js and network-tools.js) --------------------------
  const SBNet = window.SBNet = {
    STATUS_TEXT,

    header(headers, name) {
      if (!headers) return undefined;
      if (headers[name] !== undefined) return headers[name];
      const lower = name.toLowerCase();
      for (const k of Object.keys(headers)) if (k.toLowerCase() === lower) return headers[k];
      return undefined;
    },

    statusText(r, extras) {
      if (r.statusText) return r.statusText;
      if (extras && extras.statusText) return extras.statusText;
      return STATUS_TEXT[r.statusCode] || "";
    },

    host(url) { try { return new URL(url).host; } catch (_) { return ""; } },

    // `a=1; b=2` → [{ name, value }]
    parseCookieHeader(value) {
      if (!value) return [];
      return String(value).split(/;\s*/).filter(Boolean).map((pair) => {
        const i = pair.indexOf("=");
        return i < 0 ? { name: "", value: pair.trim() } : { name: pair.slice(0, i).trim(), value: pair.slice(i + 1).trim() };
      });
    },

    // One or more Set-Cookie values (joined by newlines, or by commas the
    // way some engines fold them) → cookies with every attribute.
    parseSetCookies(value) {
      if (!value) return [];
      const lines = String(value).split(/\n/).flatMap((line) => line.split(/,(?=\s*[^;,=\s]+=)/));
      return lines.map((line) => line.trim()).filter(Boolean).map((line) => {
        const [pair, ...attrs] = line.split(/;\s*/);
        const eq = pair.indexOf("=");
        const cookie = { raw: line, name: eq < 0 ? "" : pair.slice(0, eq).trim(), value: eq < 0 ? pair.trim() : pair.slice(eq + 1).trim(),
          domain: "", path: "", expires: "", maxAge: "", httpOnly: false, secure: false, sameSite: "", partitioned: false, priority: "" };
        for (const attr of attrs) {
          const i = attr.indexOf("=");
          const key = (i < 0 ? attr : attr.slice(0, i)).trim().toLowerCase();
          const v = i < 0 ? "" : attr.slice(i + 1).trim();
          if (key === "domain") cookie.domain = v;
          else if (key === "path") cookie.path = v;
          else if (key === "expires") cookie.expires = v;
          else if (key === "max-age") cookie.maxAge = v;
          else if (key === "httponly") cookie.httpOnly = true;
          else if (key === "secure") cookie.secure = true;
          else if (key === "samesite") cookie.sameSite = v ? v[0].toUpperCase() + v.slice(1).toLowerCase() : "";
          else if (key === "partitioned") cookie.partitioned = true;
          else if (key === "priority") cookie.priority = v;
        }
        cookie.size = cookie.name.length + cookie.value.length;
        return cookie;
      });
    },

    // What a developer should know about a Set-Cookie.
    cookieIssues(c, url) {
      const issues = [];
      const https = /^https:/.test(url || "");
      if (c.sameSite === "None" && !c.secure) issues.push("SameSite=None without Secure: browsers reject this cookie");
      if (!c.secure) issues.push(https ? "No Secure attribute" : "No Secure attribute (and the response came over plain HTTP)");
      if (!c.sameSite) issues.push("No SameSite attribute: treated as SameSite=Lax");
      if (c.name.startsWith("__Secure-") && !c.secure) issues.push("__Secure- prefix requires Secure");
      if (c.name.startsWith("__Host-") && (!c.secure || c.domain || c.path !== "/")) issues.push("__Host- prefix requires Secure, Path=/ and no Domain");
      if (!c.httpOnly && /sess|token|auth|sid|jwt/i.test(c.name)) issues.push("Looks like a session cookie but is readable from JavaScript (no HttpOnly)");
      if (c.expires && Date.parse(c.expires) < Date.now()) issues.push("Expires is in the past: this deletes the cookie");
      if (c.maxAge !== "" && +c.maxAge <= 0) issues.push("Max-Age ≤ 0: this deletes the cookie");
      if (c.size > 4096) issues.push("Larger than 4096 bytes: browsers ignore it");
      return issues;
    },

    // `db;dur=53;desc="Database", app;dur=47.2` → [{ name, duration, description }]
    parseServerTiming(value) {
      if (!value) return [];
      const entries = [];
      for (const part of String(value).split(/,|\n(?=(?:[^"]*"[^"]*")*[^"]*$)/)) {
        const fields = part.split(";").map((f) => f.trim()).filter(Boolean);
        if (!fields.length) continue;
        const entry = { name: fields[0], duration: null, description: "" };
        for (const field of fields.slice(1)) {
          const i = field.indexOf("=");
          const key = (i < 0 ? field : field.slice(0, i)).trim().toLowerCase();
          let v = i < 0 ? "" : field.slice(i + 1).trim();
          if (v.startsWith('"')) v = v.replace(/^"|"$/g, "").replace(/\\(.)/g, "$1");
          if (key === "dur") entry.duration = parseFloat(v);
          else if (key === "desc") entry.description = v;
        }
        entries.push(entry);
      }
      return entries;
    },

    isFinished(r) { return r.statusCode != null || r.failure != null || r.duration != null || r.responseBody != null; },

    // Issues worth flagging: failed, blocked, CORS, 4xx/5xx, slow, large,
    // uncompressed text, static resources without caching headers.
    issues(r) {
      const out = [];
      const hdr = (n) => SBNet.header(r.responseHeaders, n);
      const hasResponseHeaders = Object.keys(r.responseHeaders || {}).length > 0;
      const blocked = r.failure && (/blocked/i.test(r.failure) || (window.SBBlocking && SBBlocking.matches(r.url)));
      if (blocked) out.push({ kind: "blocked", failure: true, text: "Blocked" + (window.SBBlocking && SBBlocking.matches(r.url) ? " by a DevTools request blocking pattern" : ": " + r.failure) });
      else if (r.failure && /cors|access-control|cross-origin|origin .* is not allowed/i.test(r.failure)) out.push({ kind: "cors", failure: true, text: "CORS: " + r.failure });
      else if (r.failure) out.push({ kind: "failed", failure: true, text: "Failed: " + r.failure });
      const origin = SBNet.header(r.requestHeaders, "origin");
      if (!r.failure && origin && hasResponseHeaders && /^(fetch|xhr)$/.test(r.resourceType) && SBNet.originOf(r.url) !== origin && !hdr("access-control-allow-origin")) {
        out.push({ kind: "cors", failure: true, text: `CORS: cross-origin response from ${SBNet.originOf(r.url)} has no Access-Control-Allow-Origin for ${origin}` });
      }
      if (r.statusCode >= 500) out.push({ kind: "5xx", failure: true, text: `Server error ${r.statusCode} ${STATUS_TEXT[r.statusCode] || ""}`.trim() });
      else if (r.statusCode >= 400) out.push({ kind: "4xx", failure: true, text: `Client error ${r.statusCode} ${STATUS_TEXT[r.statusCode] || ""}`.trim() });
      if (r.duration != null && r.duration > 1) out.push({ kind: "slow", failure: true, text: `Slow: ${formatMs(r.duration)}` });
      const size = r.bodySize ?? r.transferSize;
      if (size != null && size > 1024 * 1024) out.push({ kind: "large", text: `Large: ${formatBytes(size)}` });
      const mime = (r.mimeType || "").toLowerCase();
      if (hasResponseHeaders && size > 1400 && /^text\/|json|javascript|xml|svg|css/.test(mime) && !hdr("content-encoding") && r.statusCode < 300) {
        out.push({ kind: "uncompressed", text: `Uncompressed text (${formatBytes(size)}, no Content-Encoding)` });
      }
      if (hasResponseHeaders && r.statusCode >= 200 && r.statusCode < 300 && /^(script|stylesheet|image|font)$/.test(r.resourceType)
          && !hdr("cache-control") && !hdr("expires") && !hdr("etag") && !hdr("last-modified")) {
        out.push({ kind: "cache", text: "No caching headers (Cache-Control, Expires, ETag or Last-Modified)" });
      }
      return out;
    },

    originOf(url) { try { return new URL(url).origin; } catch (_) { return ""; } },
  };

  const panel = {
    initialized: false,
    requests: new Map(),
    order: [],
    filterText: "",
    filters: [],
    invert: false,
    explain: false,
    type: "all",
    actor: "all",
    preserve: false,
    recording: true,
    sort: { key: null, desc: false },
    selectedId: null,
    detailTab: "headers",
    renderTimer: null,
    extras: {},
    session: null,            // an imported HAR, shown read-only instead of the live log
    pageTiming: null,
    hidden: new Set(),
    rawSections: new Set(),
    headerFilter: "",
    pointerInDetail: false,

    init() {
      try {
        const saved = JSON.parse(localStorage.getItem("devtools.network.columns") || "null");
        this.hidden = new Set(saved || COLUMNS.filter((c) => c.hidden).map((c) => c.id));
      } catch (_) { this.hidden = new Set(COLUMNS.filter((c) => c.hidden).map((c) => c.id)); }
      $("#network-record").addEventListener("click", (e) => {
        this.recording = !this.recording;
        e.currentTarget.classList.toggle("on", this.recording);
        e.currentTarget.title = this.recording ? "Stop recording network log" : "Record network log";
      });
      $("#network-clear").addEventListener("click", () => this.clear());
      $("#network-filter").addEventListener("input", debounce(() => this.setFilter($("#network-filter").value), 100));
      $("#network-invert").addEventListener("change", (e) => { this.invert = e.target.checked; this.renderAll(); });
      $("#network-preserve").addEventListener("change", (e) => { this.preserve = e.target.checked; });
      $("#network-har").addEventListener("click", () => this.exportHAR());
      $("#network-import").addEventListener("click", () => this.importHARFromDisk());
      $("#network-explain").addEventListener("click", () => this.setExplain(!this.explain));
      $("#network-actor").addEventListener("change", (e) => { this.actor = e.target.value; this.renderAll(); });
      if (window.Actors) Actors.onChange(debounce(() => { if (!this.session) this.renderAll(); }, 150));
      for (const chip of $$("#network-types .chip[data-type]")) {
        chip.addEventListener("click", () => {
          for (const c of $$("#network-types .chip[data-type]")) c.classList.toggle("active", c === chip);
          this.type = chip.dataset.type;
          this.renderAll();
        });
      }
      this.renderHead();
      $("#network-table thead").addEventListener("click", (e) => {
        const th = e.target.closest("th[data-sort]");
        if (!th) return;
        const key = th.dataset.sort;
        if (this.sort.key === key) { if (this.sort.desc) this.sort = { key: null, desc: false }; else this.sort.desc = true; }
        else this.sort = { key, desc: false };
        this.renderHead();
        this.renderAll();
      });
      $("#network-table thead").addEventListener("contextmenu", (e) => { e.preventDefault(); ContextMenu.show(e.clientX, e.clientY, this.columnItems()); });
      $("#network-table tbody").addEventListener("click", (e) => {
        const row = e.target.closest("tr[data-id]");
        if (row) this.select(row.dataset.id);
      });
      $("#network-table tbody").addEventListener("contextmenu", (e) => {
        const row = e.target.closest("tr[data-id]");
        const r = row && this.get(row.dataset.id);
        if (!r) return;
        e.preventDefault();
        this.select(r.id);
        this.showMenu(e.clientX, e.clientY, this.contextItems(r));
      });
      $("#network-detail-close").addEventListener("click", () => this.closeDetail());
      for (const tab of $$("#network-detail-tabs .subtab")) {
        tab.addEventListener("click", () => { this.setDetailTab(tab.dataset.subpanel); this.renderDetail(); });
      }
      // ⌘F searches the response pane when that is where you are working.
      $("#network-detail").addEventListener("mousedown", () => { this.pointerInDetail = true; });
      $("#network-main").addEventListener("mousedown", () => { this.pointerInDetail = false; });
      document.addEventListener("keydown", (e) => {
        if (DevTools.activePanel !== "network" || (e.target.closest && e.target.closest("input, textarea, select"))) return;
        if (e.key === "ArrowDown" || e.key === "ArrowUp") {
          const rows = $$("#network-table tbody tr[data-id]");
          if (!rows.length) return;
          const i = rows.findIndex((r) => r.dataset.id === this.selectedId);
          const next = i < 0 ? rows[e.key === "ArrowDown" ? 0 : rows.length - 1] : rows[i + (e.key === "ArrowDown" ? 1 : -1)];
          if (next) { e.preventDefault(); this.select(next.dataset.id); next.scrollIntoView({ block: "nearest" }); }
        } else if (e.key === "Escape" && !(e.target.closest && e.target.closest(".popup, #context-menu"))) { this.closeDetail(); }
      });
      // Drop a .har anywhere on the panel to open it.
      const panelEl = $("#panel-network");
      panelEl.addEventListener("dragover", (e) => { if (Array.from(e.dataTransfer?.types || []).includes("Files")) { e.preventDefault(); panelEl.classList.add("nv-drop"); } });
      panelEl.addEventListener("dragleave", (e) => { if (e.target === panelEl || !panelEl.contains(e.relatedTarget)) panelEl.classList.remove("nv-drop"); });
      panelEl.addEventListener("drop", async (e) => {
        panelEl.classList.remove("nv-drop");
        const file = e.dataTransfer?.files?.[0];
        if (!file) return;
        e.preventDefault();
        try { this.importHAR(await file.text(), file.name); } catch (err) { this.notify(err.message); }
      });

      DevTools.on("Network.webSocketFrame", ({ requestId, frame }) => this.onWebSocketFrame(requestId, frame));
      DevTools.on("Network.requestAdded", ({ request }) => this.upsert(request));
      DevTools.on("Network.requestUpdated", ({ request }) => this.upsert(request));
      DevTools.on("Page.navigated", (p) => {
        if (p.phase === "started" && !this.preserve) this.clearLocal();
        this.pageTiming = null;
        setTimeout(() => this.loadPageTiming(), 1500);
      });
      DevTools.on("Recorder.cleared", () => this.clearLocal());
      this.load();
      this.loadPageTiming();
    },

    show() { this.renderAll(); this.loadExtras(); if (!this.pageTiming) this.loadPageTiming(); },

    notify(text) { if (window.Toast) Toast.show(text); else DevTools.panels.console?.addLocal("warn", text); },

    async load() {
      let list = [];
      try { list = await DevTools.rpc("Network.getRequests"); } catch (_) {}
      this.requests.clear(); this.order = [];
      for (const r of list) { this.requests.set(r.id, r); this.order.push(r.id); }
      this.renderAll();
      this.loadExtras();
    },

    // What the inspector protocol adds: initiator stacks, remote address, priority, cache source.
    loadExtras: debounce(async function () {
      try { panel.extras = (await DevTools.rpc("Network.getExtras")) || {}; } catch (_) { return; }
      if (DevTools.activePanel !== "network") return;
      const needed = ["remote", "priority"].some((c) => !panel.hidden.has(c));
      if (needed || panel.order.length < 300) panel.renderAll();
      if (panel.selectedId && (panel.detailTab === "headers" || panel.detailTab === "initiator")) panel.renderDetail();
    }, 400),

    ext(r) { return (r && (r.extras || (r.protocolRequestID && this.extras[r.protocolRequestID]))) || {}; },

    // DOMContentLoaded and load of the inspected page, for the summary bar and the waterfall.
    async loadPageTiming() {
      try {
        const r = await DevTools.rpc("Runtime.evaluateLive", { expression: "JSON.stringify((() => { const n = performance.getEntriesByType('navigation')[0]; return n ? { origin: performance.timeOrigin, dcl: n.domContentLoadedEventEnd, load: n.loadEventEnd } : null; })())" });
        const value = r && r.result && JSON.parse(r.result.description);
        if (value) { this.pageTiming = value; this.renderAll(); }
      } catch (_) {}
    },

    upsert(request) {
      const isNew = !this.requests.has(request.id);
      if (isNew && !this.recording) return;
      this.requests.set(request.id, request);
      if (isNew) this.order.push(request.id);
      if (!this.renderTimer) this.renderTimer = setTimeout(() => { this.renderTimer = null; this.renderAll(); }, 60);
      if (request.protocolRequestID) this.loadExtras();
      if (request.id === this.selectedId && !this.session) this.renderDetail();
    },

    clear() {
      if (this.session) { this.closeSession(); return; }
      DevTools.rpc("Network.clear").catch(() => {});
      this.clearLocal();
    },

    clearLocal() {
      this.requests.clear(); this.order = [];
      if (!this.session) this.closeDetail();
      this.renderAll();
    },

    // ---- the list: live, or an imported HAR -----------------------------------------
    get(id) { return this.session ? this.session.requests.get(id) : this.requests.get(id); },
    all() {
      if (this.session) return this.session.order.map((id) => this.session.requests.get(id));
      return this.order.map((id) => this.requests.get(id)).filter(Boolean);
    },

    // ---- filter syntax ---------------------------------------------------------------
    setFilter(text) {
      this.filterText = text;
      this.filters = this.parseFilter(text);
      this.renderAll();
    },

    parseFilter(text) {
      const out = [];
      for (const raw of String(text || "").match(/(?:[^\s"]+|"[^"]*")+/g) || []) {
        const negative = raw.length > 1 && raw.startsWith("-");
        const body = negative ? raw.slice(1) : raw;
        const regex = /^\/(.+)\/([imsu]*)$/.exec(body);
        if (regex) {
          try { out.push({ negative, regex: new RegExp(regex[1], regex[2] || "i") }); continue; } catch (_) {}
        }
        const kv = /^([a-z-]+):(.*)$/.exec(body);
        if (kv && FILTER_KEYS.has(kv[1])) { out.push({ negative, key: kv[1], value: kv[2].replace(/^"|"$/g, "") }); continue; }
        out.push({ negative, text: body.replace(/^"|"$/g, "").toLowerCase() });
      }
      return out;
    },

    matchesFilter(r, f) {
      if (f.regex) return f.regex.test(r.url);
      if (f.text != null) return r.url.toLowerCase().includes(f.text) || (r.mimeType || "").includes(f.text) || String(r.statusCode ?? "").includes(f.text);
      const v = f.value;
      const lower = v.toLowerCase();
      const wildcard = (pattern, s) => new RegExp("^" + pattern.split("*").map((p) => p.replace(/[.+?^${}()|[\]\\]/g, "\\$&")).join(".*") + "$", "i").test(s);
      switch (f.key) {
        case "domain": { const host = SBNet.host(r.url); return wildcard(v, host) || wildcard(v, host.replace(/:\d+$/, "")); }
        case "status-code": return /^\dxx$/i.test(v) ? Math.floor((r.statusCode || 0) / 100) === +v[0] : String(r.statusCode ?? "") === v;
        case "method": return (r.method || "GET").toLowerCase() === lower;
        case "mime-type": return (r.mimeType || "").toLowerCase() === lower || (r.mimeType || "").toLowerCase().includes(lower);
        case "larger-than": {
          const m = /^(\d+(?:\.\d+)?)\s*([kKmM]?)[bB]?$/.exec(v);
          if (!m) return true;
          const bytes = +m[1] * (m[2].toLowerCase() === "k" ? 1024 : m[2].toLowerCase() === "m" ? 1024 * 1024 : 1);
          return (r.transferSize ?? r.bodySize ?? 0) > bytes;
        }
        case "is": {
          const source = this.ext(r).source;
          if (lower === "running") return !SBNet.isFinished(r);
          if (lower === "from-cache") return /cache/.test(source || "") || (r.transferSize === 0 && r.bodySize > 0);
          if (lower === "failed") return !!r.failure || r.statusCode >= 400;
          if (lower === "blocked") return SBNet.issues(r).some((i) => i.kind === "blocked");
          if (lower === "slow") return (r.duration || 0) > 1;
          if (lower === "service-worker-served") return source === "service-worker";
          return false;
        }
        case "has-response-header": return SBNet.header(r.responseHeaders, v) !== undefined;
        case "has-request-header": return SBNet.header(r.requestHeaders, v) !== undefined;
        case "resource-type": return r.resourceType === lower;
        case "scheme": return r.url.toLowerCase().startsWith(lower + ":");
        case "url": return r.url.toLowerCase().includes(lower);
        case "cookie-name": return SBNet.parseCookieHeader(SBNet.header(r.requestHeaders, "cookie")).some((c) => c.name === v);
        case "set-cookie-name": return SBNet.parseSetCookies(SBNet.header(r.responseHeaders, "set-cookie")).some((c) => c.name === v);
        case "priority": return String(this.ext(r).priority || "").toLowerCase() === lower;
        case "protocol": return String(r.protocolName || this.ext(r).protocol || "").toLowerCase() === lower;
        case "remote-address": return String(this.ext(r).remoteAddress || "").includes(v);
      }
      return true;
    },

    passesText(r) {
      if (!this.filters.length) return true;
      const pass = this.filters.every((f) => this.matchesFilter(r, f) !== f.negative);
      return this.invert ? !pass : pass;
    },

    visibleRequests() {
      let list = this.all();
      const group = TYPE_GROUPS[this.type];
      if (group) list = list.filter((r) => group.has(r.resourceType));
      list = list.filter((r) => this.passesText(r));
      if (this.actor !== "all") list = list.filter((r) => this.actorOf(r) === this.actor);
      if (this.explain) list = list.filter((r) => SBNet.issues(r).some((i) => i.failure));
      if (this.sort.key) {
        const key = this.sort.key;
        list.sort((a, b) => { const va = this.sortValue(a, key), vb = this.sortValue(b, key); return (va < vb ? -1 : va > vb ? 1 : 0) * (this.sort.desc ? -1 : 1); });
      }
      return list;
    },

    // Who caused the request (actors.js); an imported HAR has no actors.
    actorOf(r) {
      return this.session || !window.Actors ? "page" : Actors.of(r.startedAt);
    },

    sortValue(r, key) {
      const ext = this.ext(r);
      switch (key) {
        case "name": return fileName(r.url).toLowerCase();
        case "status": return r.statusCode || (r.failure ? 999 : 0);
        case "method": return r.method || "GET";
        case "domain": return SBNet.host(r.url);
        case "type": return r.resourceType;
        case "initiator": return r.initiator || "";
        case "protocol": return r.protocolName || ext.protocol || "";
        case "remote": return ext.remoteAddress || "";
        case "cookies": return SBNet.parseCookieHeader(SBNet.header(r.requestHeaders, "cookie")).length;
        case "setcookies": return SBNet.parseSetCookies(SBNet.header(r.responseHeaders, "set-cookie")).length;
        case "priority": return { "very-low": 0, low: 1, medium: 2, high: 3, "very-high": 4 }[String(ext.priority || "").toLowerCase()] ?? -1;
        case "size": return r.transferSize ?? r.bodySize ?? -1;
        case "time": return r.duration ?? -1;
        case "waterfall": return r.startedAt;
      }
      return 0;
    },

    // ---- table ----------------------------------------------------------------------
    visibleColumns() { return COLUMNS.filter((c) => c.fixed || !this.hidden.has(c.id)); },

    renderHead() {
      const tr = h("tr");
      for (const c of this.visibleColumns()) {
        const th = h("th", { dataset: { sort: c.id, col: c.id }, style: c.width ? `width:${c.width}` : "", title: "Right-click to show or hide columns" }, c.title);
        if (this.sort.key === c.id) th.classList.add("sorted");
        if (this.sort.key === c.id && this.sort.desc) th.classList.add("desc");
        if (c.id === "waterfall") th.classList.add("waterfall-col");
        tr.appendChild(th);
      }
      const thead = $("#network-table thead");
      thead.textContent = "";
      thead.appendChild(tr);
    },

    columnItems() {
      const items = COLUMNS.filter((c) => !c.fixed).map((c) => ({
        label: (this.hidden.has(c.id) ? "  " : "✓ ") + c.title,
        action: () => this.setColumnVisible(c.id, this.hidden.has(c.id)),
      }));
      items.push("-", { label: "Reset columns", action: () => { this.hidden = new Set(COLUMNS.filter((c) => c.hidden).map((c) => c.id)); this.saveColumns(); } });
      return items;
    },

    setColumnVisible(id, visible) {
      if (visible) this.hidden.delete(id); else this.hidden.add(id);
      this.saveColumns();
      if (visible && (id === "remote" || id === "priority")) this.loadExtras();
    },

    saveColumns() {
      try { localStorage.setItem("devtools.network.columns", JSON.stringify(Array.from(this.hidden))); } catch (_) {}
      this.renderHead();
      this.renderAll();
    },

    renderAll() {
      const tbody = $("#network-table tbody");
      if (!tbody) return;
      const list = this.visibleRequests();
      const all = this.all();
      const start = Math.min(...all.map((r) => r.startedAt), Infinity);
      const end = Math.max(...all.map((r) => r.startedAt + (r.duration || 0) * 1000), start + 1);
      const span = Math.max(end - start, 1);
      const columns = this.visibleColumns();
      const marks = this.timingMarks(start);

      tbody.textContent = "";
      $("#network-table").classList.toggle("nv-explaining", this.explain);
      const frag = document.createDocumentFragment();
      for (const r of list) frag.appendChild(this.renderRow(r, columns, start, span, marks));
      tbody.appendChild(frag);
      if (!list.length) {
        const message = all.length ? (this.explain ? "No failed, blocked or slow requests. Nothing to explain." : "No requests match the filter")
          : this.session ? "This HAR file has no entries."
          : "Recording network activity… Requests appear here from the moment the page starts loading, whether or not DevTools was open.";
        tbody.appendChild(h("tr", {}, h("td", { colspan: String(columns.length), class: "muted", style: "text-align:center" }, message)));
      }
      this.renderSummary(list, all, span);
      this.renderExplainBar();
    },

    timingMarks(start) {
      const t = this.session ? this.session.pageTiming : this.pageTiming;
      if (!t || !isFinite(start)) return null;
      const out = {};
      if (t.dcl > 0) out.dcl = t.origin + t.dcl - start;
      if (t.load > 0) out.load = t.origin + t.load - start;
      return out;
    },

    renderSummary(list, all, span) {
      const status = $("#network-status");
      status.textContent = "";
      const transferred = all.reduce((s, r) => s + (r.transferSize || 0), 0);
      const resources = all.reduce((s, r) => s + (r.bodySize || 0), 0);
      const shownTransferred = list.reduce((s, r) => s + (r.transferSize || 0), 0);
      const shownResources = list.reduce((s, r) => s + (r.bodySize || 0), 0);
      const filtered = list.length !== all.length;
      const part = (text, cls, title) => status.appendChild(h("span", { class: "nv-sum " + (cls || ""), title: title || "" }, text));
      part(`${filtered ? list.length + " / " : ""}${all.length} requests`, "", "Requests shown / recorded");
      part(`${filtered ? formatBytes(shownTransferred) + " / " : ""}${formatBytes(transferred)} transferred`, "", "Bytes over the network (headers and encoded bodies)");
      part(`${filtered ? formatBytes(shownResources) + " / " : ""}${formatBytes(resources)} resources`, "", "Decoded size of the response bodies");
      if (all.length) part("Finish: " + formatMs(span / 1000), "", "From the first request's start to the last one's end");
      const t = this.session ? this.session.pageTiming : this.pageTiming;
      if (t && t.dcl > 0) part("DOMContentLoaded: " + formatMs(t.dcl / 1000), "nv-dcl", "DOMContentLoaded event, from navigation start");
      if (t && t.load > 0) part("Load: " + formatMs(t.load / 1000), "nv-load", "load event, from navigation start");
      if (this.session) part("Imported: " + this.session.name, "nv-imported");
    },

    renderExplainBar() {
      const bar = $("#network-explain-bar");
      $("#network-explain").classList.toggle("active", this.explain);
      bar.hidden = !this.explain;
      if (!this.explain) return;
      const counts = {};
      for (const r of this.all()) for (const i of SBNet.issues(r)) if (i.failure) counts[i.kind] = (counts[i.kind] || 0) + 1;
      const labels = { failed: "failed", blocked: "blocked", cors: "CORS", "4xx": "4xx", "5xx": "5xx", slow: "slow (> 1 s)" };
      bar.textContent = "";
      const summary = Object.keys(labels).filter((k) => counts[k]).map((k) => `${counts[k]} ${labels[k]}`).join(" · ") || "No failed, blocked or slow requests";
      const copyButton = h("button", { class: "text-button", title: "Copy these requests, explained, as Markdown for an AI assistant" }, "Copy for AI");
      copyButton.addEventListener("click", async () => { if (this.failuresMarkdown) { DevTools.rpc("Clipboard.write", { text: await this.failuresMarkdown() }); this.notify("Copied the failures as Markdown"); } });
      bar.append(h("span", { class: "nv-explain-title" }, "Explain failures:"), h("span", {}, summary), h("span", { class: "muted" }, "— the reason is under each name; select a request for details"), h("span", { class: "toolbar-spacer" }), copyButton);
    },

    setExplain(on) { this.explain = on; this.renderAll(); },

    statusCell(r) {
      const blocked = r.failure && (/^Blocked/.test(r.failure) || (window.SBBlocking && SBBlocking.matches(r.url)));
      if (r.statusCode == null) {
        if (r.failure) return h("span", { class: "nv-status-bad", title: r.failure }, blocked ? "(blocked)" : /cancel/i.test(r.failure) ? "(canceled)" : "(failed)");
        return h("span", { class: "muted", title: "Status not observable for this request type" }, SBNet.isFinished(r) ? "" : "(pending)");
      }
      const text = SBNet.statusText(r, this.ext(r));
      const cls = r.statusCode >= 400 ? "nv-status-bad" : r.statusCode >= 300 ? "nv-status-redirect" : r.statusCode >= 200 ? "nv-status-ok" : "nv-status-info";
      return h("span", { class: cls, title: `${r.statusCode} ${text}` }, String(r.statusCode), text ? h("span", { class: "nv-status-text" }, " " + text) : null);
    },

    sizeCell(r) {
      const source = this.ext(r).source;
      if (source === "memory-cache" || source === "disk-cache") return h("span", { class: "muted", title: formatBytes(r.bodySize) + " decoded" }, `(${source.replace("-", " ")})`);
      if (source === "service-worker") return h("span", { class: "muted" }, "(ServiceWorker)");
      return h("span", { title: r.bodySize != null ? `${formatBytes(r.transferSize)} transferred over network, resource size: ${formatBytes(r.bodySize)}` : "" }, formatBytes(r.transferSize ?? r.bodySize));
    },

    renderRow(r, columns, start, span, marks) {
      const issues = SBNet.issues(r);
      const failure = issues.some((i) => i.failure && i.kind !== "slow");
      const tr = h("tr", { class: (failure ? "failed" : "") + (r.id === this.selectedId ? " selected" : "") + (!SBNet.isFinished(r) ? " pending" : ""), dataset: { id: r.id } });
      const ext = this.ext(r);
      for (const c of columns) {
        let content, title = "";
        switch (c.id) {
          case "name": {
            content = h("div", { class: "name-cell", title: r.url + "\nObserved by: " + (r.sources || []).join(", ") }, h("span", { class: "nv-name" }, fileName(r.url)));
            if (r.sources && r.sources.length === 1 && r.sources[0] === "pageWorld") content.appendChild(h("span", { class: "src page", title: "Seen only by page-world hooks, which page script could tamper with" }, "page"));
            const actor = this.actorOf(r);
            if (actor !== "page") content.appendChild(Actors.badge(actor));
            if (this.explain) {
              const reason = issues.filter((i) => i.failure).map((i) => i.text).join(" · ");
              if (reason) content = h("div", { class: "nv-name-wrap" }, content, h("div", { class: "nv-reason", title: reason }, reason));
            }
            break;
          }
          case "status": content = this.statusCell(r); break;
          case "method": content = (r.method || "GET").toUpperCase(); break;
          case "domain": content = SBNet.host(r.url); break;
          case "type": content = r.resourceType; break;
          case "initiator": {
            const init = ext.initiator;
            const frame = init && this.initiatorFrames(init)[0];
            content = frame && frame.url ? h("span", { class: "link", title: `${frame.url}:${frame.lineNumber}`, onclick: (e) => { e.stopPropagation(); DevTools.openSource(frame.url, frame.lineNumber, frame.columnNumber); } }, `${fileName(frame.url)}:${frame.lineNumber}`)
              : init && init.url ? h("span", { title: init.url }, fileName(init.url) + (init.lineNumber ? ":" + init.lineNumber : "")) : (r.initiator || "");
            break;
          }
          case "protocol": content = r.protocolName || ext.protocol || ""; break;
          case "remote": content = ext.remoteAddress || ""; break;
          case "cookies": { const n = SBNet.parseCookieHeader(SBNet.header(r.requestHeaders, "cookie")).length; content = n ? String(n) : ""; break; }
          case "setcookies": { const n = SBNet.parseSetCookies(SBNet.header(r.responseHeaders, "set-cookie")).length; content = n ? String(n) : ""; break; }
          case "priority": content = ext.priority ? String(ext.priority)[0].toUpperCase() + String(ext.priority).slice(1) : ""; break;
          case "size": content = this.sizeCell(r); break;
          case "time": content = SBNet.isFinished(r) ? formatMs(r.duration) : "(pending)"; title = r.duration != null ? `Total duration ${formatMs(r.duration)}` : ""; break;
          case "waterfall": content = this.waterfall(r, start, span, marks); break;
        }
        tr.appendChild(h("td", { class: "col-" + c.id, title }, content));
      }
      return tr;
    },

    waterfall(r, start, span, marks) {
      const wf = h("div", { class: "waterfall" });
      const left = ((r.startedAt - start) / span) * 100;
      const total = (r.duration || 0) * 1000;
      const t = r.timing;
      const seg = (cls, from, to) => {
        if (to <= from) return;
        wf.appendChild(h("span", { class: cls, style: `left:${left + (from / span) * 100}%;width:${Math.max(0.3, ((to - from) / span) * 100)}%` }));
      };
      if (t && t.responseEnd > 0) {
        const connectStart = t.connectStart || t.requestStart, dnsStart = t.domainLookupStart || connectStart;
        seg("wf-blocked", t.fetchStart, dnsStart);
        seg("wf-dns", t.domainLookupStart, t.domainLookupEnd);
        seg("wf-connect", t.connectStart, t.secureConnectionStart || t.connectEnd);
        seg("wf-ssl", t.secureConnectionStart, t.secureConnectionStart ? t.connectEnd : 0);
        seg("wf-wait", t.requestStart, t.responseStart);
        seg("wf-receive", t.responseStart, t.responseEnd);
      } else {
        seg("wf-receive", 0, Math.max(total, 1));
      }
      if (marks) {
        if (marks.dcl != null && marks.dcl >= 0 && marks.dcl <= span) wf.appendChild(h("i", { class: "wf-mark dcl", style: `left:${(marks.dcl / span) * 100}%` }));
        if (marks.load != null && marks.load >= 0 && marks.load <= span) wf.appendChild(h("i", { class: "wf-mark load", style: `left:${(marks.load / span) * 100}%` }));
      }
      wf.title = formatMs(r.duration);
      return wf;
    },

    // ---- context menu with submenus ------------------------------------------------------
    // Like ContextMenu.show, plus items with `submenu` that open beside it (Chrome's Copy ▸).
    showMenu(x, y, items) {
      ContextMenu.hide();
      const menu = document.getElementById("context-menu");
      menu.textContent = "";
      const build = (target, list) => {
        for (const item of list) {
          if (item === "-") { target.appendChild(h("div", { class: "sep" })); continue; }
          if (item.submenu) {
            const sub = h("div", { class: "nv-submenu" });
            build(sub, item.submenu);
            target.appendChild(h("div", { class: "item nv-has-submenu" }, item.label, sub));
            continue;
          }
          target.appendChild(h("div", { class: "item", onclick: (e) => { e.stopPropagation(); ContextMenu.hide(); item.action(); } }, item.label));
        }
      };
      build(menu, items);
      menu.hidden = false;
      menu.style.left = Math.min(x, innerWidth - menu.offsetWidth - 8) + "px";
      menu.style.top = Math.min(y, innerHeight - menu.offsetHeight - 8) + "px";
      // Submenus open to the left when there is no room on the right.
      menu.classList.toggle("nv-flip", x + menu.offsetWidth * 2 > innerWidth);
      const close = (e) => { if (!menu.contains(e.target)) ContextMenu.hide(); };
      setTimeout(() => document.addEventListener("mousedown", close, { once: true }), 0);
    },

    // The whole right-click menu of a request. network-tools.js adds to it.
    contextItems(r) {
      const items = [{ label: "Copy", submenu: this.copyItems(r) }];
      const file = DevTools.panels.sources?.files?.has(r.url);
      if (file) items.push("-", { label: "Open in Sources panel", action: () => DevTools.openSource(r.url, 1, 0) });
      return items;
    },

    copyItems(r) {
      const copy = (text) => DevTools.rpc("Clipboard.write", { text }).catch(() => {});
      const items = [
        { label: "Copy URL", action: () => copy(r.url) },
        { label: "Copy as cURL", action: () => copy(this.asCurl(r)) },
        { label: "Copy as fetch", action: () => copy(this.asFetch(r)) },
      ];
      if (r.responseBody != null || r.protocolRequestID) {
        items.push({ label: "Copy response", action: async () => {
          let body = r.responseBody;
          if (body == null) { try { const updated = await DevTools.rpc("Network.getResponseBody", { id: r.id }); body = updated.responseBody; } catch (_) {} }
          if (body != null) copy(body); else this.notify("The response body of " + r.url + " is not available.");
        } });
      }
      return items;
    },

    // Headers the engine adds by itself and that make a replayed request wrong or noisy.
    replayHeaders(r) {
      return Object.entries(r.requestHeaders || {}).filter(([name]) => !/^(host|content-length|connection|:.*)$/i.test(name));
    },

    asCurl(r) {
      const quote = (text) => "'" + String(text).replace(/'/g, "'\\''") + "'";
      const parts = ["curl " + quote(r.url)];
      const method = (r.method || "GET").toUpperCase();
      if (method !== "GET" && !(method === "POST" && r.requestBody != null)) parts.push("-X " + method);
      for (const [name, value] of this.replayHeaders(r)) parts.push("-H " + quote(name + ": " + value));
      if (r.requestBody != null) parts.push("--data-raw " + quote(r.requestBody));
      return parts.join(" \\\n  ");
    },

    asFetch(r) {
      const init = { method: (r.method || "GET").toUpperCase() };
      const headers = Object.fromEntries(this.replayHeaders(r).filter(([name]) => !/^(cookie|user-agent|referer|origin|accept-encoding|sec-.*)$/i.test(name)));
      if (Object.keys(headers).length) init.headers = headers;
      if (r.requestBody != null) init.body = r.requestBody;
      return "fetch(" + JSON.stringify(r.url) + ", " + JSON.stringify(init, null, 2) + ");";
    },

    // ---- imported HAR (read-only session) ----------------------------------------------
    async importHARFromDisk() {
      let file;
      try { file = await DevTools.rpc("DevTools.openFile", { extensions: ["har", "json"] }); } catch (e) { this.notify(e.message); return; }
      if (file && file.text != null) { try { this.importHAR(file.text, file.name); } catch (e) { this.notify(e.message); } }
    },

    importHAR(text, name = "import.har") {
      let har;
      try { har = JSON.parse(text); } catch (e) { throw new Error("Not a HAR file: " + e.message); }
      const entries = har && har.log && Array.isArray(har.log.entries) ? har.log.entries : null;
      if (!entries) throw new Error("Not a HAR file: no log.entries");
      const requests = new Map(), order = [];
      entries.forEach((e, i) => { const r = this.fromHAREntry(e, i); requests.set(r.id, r); order.push(r.id); });
      const page = (har.log.pages || [])[0];
      let pageTiming = null;
      if (page && page.pageTimings) {
        const origin = Date.parse(page.startedDateTime);
        const t = page.pageTimings;
        if (isFinite(origin) && (t.onContentLoad > 0 || t.onLoad > 0)) pageTiming = { origin, dcl: t.onContentLoad > 0 ? t.onContentLoad : 0, load: t.onLoad > 0 ? t.onLoad : 0 };
      }
      this.session = { name, requests, order, pageTiming, creator: har.log.creator && har.log.creator.name };
      this.closeDetail();
      this.renderSessionBar();
      this.renderAll();
      return this.session;
    },

    fromHAREntry(e, i) {
      const req = e.request || {}, res = e.response || {}, content = res.content || {};
      const headers = (list) => {
        const out = {};
        for (const { name, value } of list || []) {
          if (name == null) continue;
          const key = String(name);
          if (key.startsWith(":")) continue;
          out[key] = out[key] != null ? out[key] + "\n" + value : String(value ?? "");
        }
        return out;
      };
      const mime = (content.mimeType || "").split(";")[0].trim().toLowerCase();
      let body = content.text != null ? String(content.text) : null;
      if (body != null && content.encoding === "base64") {
        if (/^(text\/|application\/(json|javascript|xml|.*\+json|.*\+xml))/.test(mime)) {
          try { body = new TextDecoder().decode(Uint8Array.from(atob(body), (c) => c.charCodeAt(0))); } catch (_) { body = `data:${mime || "application/octet-stream"};base64,${body}`; }
        } else body = `data:${mime || "application/octet-stream"};base64,${body}`;
      }
      if (body === "" && !(content.size > 0) && res.status !== 200) body = null;
      const t = e.timings || {};
      const ms = (v) => (typeof v === "number" && v > 0 ? v : 0);
      let at = 0;
      const step = (v) => { const from = at; at += ms(v); return [from, at]; };
      const blocked = step(t.blocked), dns = step(t.dns), connect = step(t.connect), send = step(t.send), wait = step(t.wait), receive = step(t.receive);
      const ssl = ms(t.ssl);
      const timing = at > 0 ? {
        fetchStart: 0, domainLookupStart: ms(t.dns) ? dns[0] : 0, domainLookupEnd: ms(t.dns) ? dns[1] : 0,
        connectStart: ms(t.connect) ? connect[0] : 0, secureConnectionStart: ssl ? connect[1] - ssl : 0, connectEnd: ms(t.connect) ? connect[1] : 0,
        requestStart: send[0] || blocked[1], responseStart: wait[1], responseEnd: receive[1],
      } : null;
      const resourceType = e._resourceType || (/html/.test(mime) ? "document" : /css/.test(mime) ? "stylesheet" : /javascript/.test(mime) ? "script"
        : /^image\//.test(mime) ? "image" : /font/.test(mime) ? "font" : /^(audio|video)\//.test(mime) ? "media" : /json|xml|text/.test(mime) ? "fetch" : "other");
      const transfer = res._transferSize ?? (res.bodySize >= 0 ? res.bodySize + Math.max(0, res.headersSize || 0) : null);
      return {
        id: "har-" + i, url: req.url || "", method: req.method || "GET", statusCode: res.status || null, statusText: res.statusText || "",
        initiator: e._initiator ? (e._initiator.type || "") : "", mimeType: mime || null, resourceType,
        requestHeaders: headers(req.headers), responseHeaders: headers(res.headers),
        requestBody: req.postData && req.postData.text != null ? String(req.postData.text) : null,
        responseBody: body, responseBodyIsRefetched: false,
        failure: e._error || (res.status === 0 && !body ? (res._error || "Failed") : null),
        startedAt: Date.parse(e.startedDateTime) || 0, duration: e.time >= 0 ? e.time / 1000 : null,
        transferSize: transfer, bodySize: content.size >= 0 ? content.size : null,
        protocolName: res.httpVersion || req.httpVersion || null, timing,
        sources: ["har"], eventIDs: [], imported: true,
        extras: { remoteAddress: e.serverIPAddress ? e.serverIPAddress + (e.connection && /^\d+$/.test(e.connection) ? "" : "") : undefined, priority: e._priority, initiator: e._initiator && e._initiator.stack ? { type: e._initiator.type, stackTrace: e._initiator.stack } : e._initiator && e._initiator.url ? e._initiator : undefined },
      };
    },

    closeSession() {
      this.session = null;
      this.closeDetail();
      this.renderSessionBar();
      this.renderAll();
    },

    renderSessionBar() {
      const bar = $("#network-session-bar");
      bar.hidden = !this.session;
      bar.textContent = "";
      if (!this.session) return;
      const back = h("button", { class: "text-button" }, "Back to live log");
      back.addEventListener("click", () => this.closeSession());
      bar.append(h("span", {}, "Viewing ", h("b", {}, this.session.name), ` — ${this.session.order.length} requests${this.session.creator ? " from " + this.session.creator : ""}, read-only.`), h("span", { class: "muted" }, "The live log keeps recording."), h("span", { class: "toolbar-spacer" }), back);
    },

    exportHAR() {
      if (this.session && this.harFromRequests) {
        DevTools.rpc("DevTools.saveFile", { name: this.session.name.replace(/(\.har)?$/, ".har"), text: JSON.stringify(this.harFromRequests(this.all()), null, 2) }).catch((err) => this.notify(err.message));
        return;
      }
      DevTools.rpc("Network.exportHAR").catch((err) => this.notify(err.message));
    },

    // ---- detail ----------------------------------------------------------------------------
    select(id) {
      this.selectedId = id;
      for (const row of $$("#network-table tbody tr")) row.classList.toggle("selected", row.dataset.id === id);
      $("#network-detail").hidden = false;
      $("[data-split=network-split]").hidden = false;
      $("#network-table").classList.add("narrow");
      const r = this.get(id) || {};
      const isSocket = r.resourceType === "websocket";
      $('#network-detail-tabs [data-subpanel="messages"]').hidden = !isSocket;
      const hasCookies = !!(SBNet.header(r.requestHeaders, "cookie") || SBNet.header(r.responseHeaders, "set-cookie"));
      $('#network-detail-tabs [data-subpanel="cookies"]').hidden = !hasCookies;
      if (isSocket) this.setDetailTab("messages");
      else if (this.detailTab === "messages" || (this.detailTab === "cookies" && !hasCookies)) this.setDetailTab("headers");
      this.renderDetail();
    },

    setDetailTab(name) {
      this.detailTab = name;
      for (const t of $$("#network-detail-tabs .subtab")) t.classList.toggle("active", t.dataset.subpanel === name);
    },

    closeDetail() {
      this.selectedId = null;
      this.activeView = null;
      $("#network-detail").hidden = true;
      $("[data-split=network-split]").hidden = true;
      $("#network-table").classList.remove("narrow");
      for (const row of $$("#network-table tbody tr.selected")) row.classList.remove("selected");
    },

    renderDetail() {
      const r = this.get(this.selectedId);
      const body = $("#network-detail-body");
      // Keep the reading position when the same pane re-renders (a body or extras arriving).
      const key = this.selectedId + "/" + this.detailTab;
      const scroll = this.lastDetailKey === key ? body.scrollTop : 0;
      this.lastDetailKey = key;
      body.textContent = "";
      body.className = "scroll";
      delete body.dataset.previewKind;
      this.activeView = null;
      if (!r) return;
      switch (this.detailTab) {
        case "headers": this.renderHeaders(r, body); break;
        case "payload": this.renderPayload(r, body); break;
        case "preview": this.renderPreview(r, body); break;
        case "response": this.renderResponse(r, body); break;
        case "initiator": this.renderInitiator(r, body); break;
        case "timing": this.renderTiming(r, body); break;
        case "cookies": this.renderCookies(r, body); break;
        case "messages": this.renderMessages(r, body); break;
      }
      body.scrollTop = scroll;
    },

    // ⌘F in the detail pane: the pane's own find, if it has one.
    findInDetail() {
      const json = this.activeView && this.activeView.jsonView;
      if (json && json.searchInput) { json.searchInput.focus(); json.searchInput.select(); return true; }
      const view = this.activeView && (this.activeView.view || this.activeView);
      if (!view || typeof view.openFind !== "function") return false;
      view.openFind();
      return true;
    },

    section(title, rows, open = true, extra) {
      const s = h("div", { class: "detail-section" + (open ? "" : " collapsed") });
      const head = h("div", { class: "detail-head" }, title, extra ? h("span", { class: "nv-head-extra", onclick: (e) => e.stopPropagation() }, extra) : null);
      head.addEventListener("click", () => s.classList.toggle("collapsed"));
      s.append(head, h("div", { class: "detail-body" }, rows));
      return s;
    },

    kv(k, v, cls) { return h("div", { class: "kv" }, h("span", { class: "k" }, k), h("span", { class: "v " + (cls || "") }, v)); },

    // ---- Headers -------------------------------------------------------------------------------
    NOTABLE: [
      [/^(cache-control|expires|etag|last-modified|age|pragma|vary|if-none-match|if-modified-since)$/i, "cache"],
      [/^(set-cookie|cookie)$/i, "cookie"],
      [/^(access-control-.*|origin|timing-allow-origin|cross-origin-.*)$/i, "CORS"],
      [/^content-security-policy(-report-only)?$/i, "CSP"],
      [/^content-encoding$/i, "encoding"],
      [/^strict-transport-security$/i, "HSTS"],
    ],

    linkify(name, value, base) {
      const link = (url, text) => {
        let abs = url;
        try { abs = new URL(url, base).href; } catch (_) { return text; }
        const logged = this.all().find((x) => x.url === abs);
        return h("a", { href: abs, class: "link", title: logged ? "Show this request" : "Open " + abs, onclick: (e) => { if (logged) { e.preventDefault(); this.select(logged.id); } } }, text);
      };
      const lower = name.toLowerCase();
      if (lower === "link") {
        const out = [];
        let last = 0;
        const re = /<([^>]+)>/g;
        let m;
        while ((m = re.exec(value))) { out.push(value.slice(last, m.index), "<", link(m[1], m[1]), ">"); last = m.index + m[0].length; }
        out.push(value.slice(last));
        return out;
      }
      if (/^(location|content-location|referer|origin|access-control-allow-origin|refresh|report-uri)$/.test(lower) || /^https?:\/\/\S+$/.test(value)) {
        const m = /(https?:\/\/[^\s;,"]+|^\/[^\s;,"]*)/.exec(value);
        if (m) return [value.slice(0, m.index), link(m[1], m[1]), value.slice(m.index + m[1].length)];
      }
      return value;
    },

    headerRows(headers, base) {
      const filter = this.headerFilter.toLowerCase();
      const rows = [];
      for (const name of Object.keys(headers).sort()) {
        const raw = String(headers[name]);
        const values = /^set-cookie$/i.test(name) ? raw.split("\n") : [raw];
        for (const value of values) {
          if (filter && !(name.toLowerCase().includes(filter) || value.toLowerCase().includes(filter))) continue;
          const notable = this.NOTABLE.find(([re]) => re.test(name));
          const copy = h("button", { class: "nv-copy", title: `Copy “${name}: ${value.length > 60 ? value.slice(0, 60) + "…" : value}”` }, "Copy");
          copy.addEventListener("click", (e) => { e.stopPropagation(); DevTools.rpc("Clipboard.write", { text: `${name}: ${value}` }); this.notify("Header copied"); });
          const row = h("div", { class: "kv nv-header" + (notable ? " nv-notable" : ""), dataset: { header: name.toLowerCase() } },
            h("span", { class: "k" }, name, notable ? h("span", { class: "nv-tag nv-tag-" + notable[1].toLowerCase(), title: "Notable: " + notable[1] }, notable[1]) : null),
            h("span", { class: "v" }, this.linkify(name, value, base)), copy);
          row.addEventListener("contextmenu", (e) => {
            e.preventDefault(); e.stopPropagation();
            ContextMenu.show(e.clientX, e.clientY, [
              { label: "Copy header", action: () => DevTools.rpc("Clipboard.write", { text: `${name}: ${value}` }) },
              { label: "Copy header name", action: () => DevTools.rpc("Clipboard.write", { text: name }) },
              { label: "Copy header value", action: () => DevTools.rpc("Clipboard.write", { text: value }) },
            ]);
          });
          rows.push(row);
        }
      }
      return rows;
    },

    rawHeaders(firstLine, headers) {
      const lines = [firstLine];
      for (const name of Object.keys(headers).sort()) for (const value of String(headers[name]).split(/^set-cookie$/i.test(name) ? "\n" : /$^/)) lines.push(`${name}: ${value}`);
      return lines.join("\n");
    },

    rawToggle(id) {
      const box = h("input", { type: "checkbox" });
      box.checked = this.rawSections.has(id);
      box.addEventListener("change", () => { if (box.checked) this.rawSections.add(id); else this.rawSections.delete(id); this.renderDetail(); });
      return h("label", { class: "check nv-raw", title: "Show the headers as HTTP/1.1 text" }, box, "Raw");
    },

    renderHeaders(r, body) {
      const ext = this.ext(r);
      const bar = h("div", { class: "nv-bar nv-sticky" });
      const filter = h("input", { type: "search", class: "nv-find-input", placeholder: "Filter headers", value: this.headerFilter });
      filter.addEventListener("input", debounce(() => { this.headerFilter = filter.value; const pos = filter.selectionStart; this.renderDetail(); const again = $("#network-detail-body .nv-bar input"); if (again) { again.focus(); again.setSelectionRange(pos, pos); } }, 120));
      bar.append(filter);
      if (r.imported) bar.append(h("span", { class: "muted" }, "From the imported HAR"));
      body.appendChild(bar);

      const statusText = SBNet.statusText(r, ext);
      const statusLine = r.statusCode != null ? `${r.statusCode} ${statusText}`.trim() : (r.failure || "(not observable)");
      const general = [
        this.kv("Request URL", this.linkify("url", r.url, r.url)),
        this.kv("Request Method", (r.method || "GET").toUpperCase()),
        this.kv("Status Code", statusLine, r.statusCode ? (r.statusCode < 400 ? (r.statusCode >= 300 ? "status-redirect" : "status-ok") : "status-bad") : (r.failure ? "status-bad" : "")),
      ];
      if (ext.remoteAddress) general.push(this.kv("Remote Address", String(ext.remoteAddress)));
      const referrerPolicy = SBNet.header(r.responseHeaders, "referrer-policy");
      if (referrerPolicy) general.push(this.kv("Referrer Policy", referrerPolicy));
      if (r.mimeType) general.push(this.kv("Content-Type", r.mimeType));
      if (r.protocolName || ext.protocol) general.push(this.kv("Protocol", r.protocolName || ext.protocol));
      if (ext.priority) general.push(this.kv("Priority", String(ext.priority)));
      if (ext.source && ext.source !== "network") general.push(this.kv("Served from", { "memory-cache": "memory cache", "disk-cache": "disk cache", "service-worker": "service worker" }[ext.source] || ext.source));
      if (ext.redirects && ext.redirects.length) general.push(this.kv("Redirected from", ext.redirects.map((x) => `${x.status} ${x.url}`).join("\n")));
      const sourceNames = { agent: "isolated-world agent (resource timing)", pageWorld: "page-world hook (fetch/XHR)", navigationDelegate: "navigation response (status and headers from WebKit)", inspector: "WebKit inspector protocol (status, headers, body)", har: "imported HAR file" };
      general.push(this.kv("Observed by", (r.sources || []).map((s) => sourceNames[s] || s).join(", ")));
      const issues = SBNet.issues(r);
      if (issues.length) general.push(this.kv("Issues", h("span", {}, issues.map((i) => h("div", { class: "nv-issue" + (i.failure ? " bad" : "") }, i.text)))));
      const filterText = this.headerFilter.toLowerCase();
      const visibleGeneral = filterText ? general.filter((row) => row.textContent.toLowerCase().includes(filterText)) : general;
      body.appendChild(this.section("General", visibleGeneral.length ? visibleGeneral : [h("div", { class: "detail-note" }, "No match")]));

      const path = (() => { try { const u = new URL(r.url); return u.pathname + u.search; } catch (_) { return r.url; } })();
      const responseCount = Object.keys(r.responseHeaders || {}).length;
      const requestCount = Object.keys(r.requestHeaders || {}).length;
      const version = /^h2|http\/2/i.test(r.protocolName || "") ? "HTTP/2" : /^h3/i.test(r.protocolName || "") ? "HTTP/3" : "HTTP/1.1";
      const noteText = r.imported ? "The HAR file has no response headers for this request."
        : "This request finished before DevTools was open, so it was seen only through resource timing (sizes and timing, no headers). Reload with DevTools open to capture headers for every resource.";
      const responseBody = !responseCount ? [h("div", { class: "detail-note" }, noteText)]
        : this.rawSections.has("response") ? [h("pre", { class: "code nv-raw-text" }, this.rawHeaders(`${version} ${statusLine}`, r.responseHeaders))]
        : this.headerRows(r.responseHeaders, r.url);
      body.appendChild(this.section(`Response Headers (${responseCount})`, responseBody.length ? responseBody : [h("div", { class: "detail-note" }, "No match")], true, responseCount ? this.rawToggle("response") : null));
      const requestBody = !requestCount ? [h("div", { class: "detail-note" }, "Provisional headers: no request headers were observed. Page script set none, or the request was not made by page script and the inspector protocol was not attached.")]
        : this.rawSections.has("request") ? [h("pre", { class: "code nv-raw-text" }, this.rawHeaders(`${(r.method || "GET").toUpperCase()} ${path} ${version}`, Object.assign({ Host: SBNet.host(r.url) }, ...Object.entries(r.requestHeaders).filter(([k]) => k.toLowerCase() !== "host").map(([k, v]) => ({ [k]: v })))))]
        : this.headerRows(r.requestHeaders, r.url);
      body.appendChild(this.section(`Request Headers (${requestCount})`, requestBody.length ? requestBody : [h("div", { class: "detail-note" }, "No match")], true, requestCount ? this.rawToggle("request") : null));
    },

    // ---- Payload --------------------------------------------------------------------------------
    renderPayload(r, body) {
      let params = [];
      try { params = Array.from(new URL(r.url).searchParams.entries()); } catch (_) {}
      if (params.length) {
        let encoded = false;
        const area = h("div");
        const draw = () => {
          area.textContent = "";
          const search = (() => { try { return new URL(r.url).search.slice(1); } catch (_) { return ""; } })();
          area.appendChild(encoded ? h("pre", { class: "code" }, search) : SBNetPreview.formTable(params));
        };
        const toggle = h("span", { class: "link nv-head-link" }, "view source");
        toggle.addEventListener("click", () => { encoded = !encoded; toggle.textContent = encoded ? "view parsed" : "view source"; draw(); });
        draw();
        body.appendChild(this.section(`Query String Parameters (${params.length})`, [area], true, toggle));
      }
      if (r.requestBody != null) {
        const rawType = SBNet.header(r.requestHeaders, "content-type") || "";
        const type = rawType.toLowerCase();
        let source = false, rendered = null, title = "Request Payload";
        const area = h("div");
        if (type.includes("x-www-form-urlencoded")) {
          const pairs = Array.from(new URLSearchParams(r.requestBody).entries());
          rendered = () => SBNetPreview.formTable(pairs); title = `Form Data (${pairs.length})`;
        } else if (type.startsWith("multipart/")) {
          const parts = SBNetPreview.parseMultipart(r.requestBody, rawType);
          if (parts) { rendered = () => SBNetPreview.multipartTable(parts); title = `Form Data (multipart, ${parts.length} part${parts.length === 1 ? "" : "s"})`; }
        } else {
          const json = SBNetPreview.tryParseJSON(r.requestBody);
          if (json !== undefined && json !== null && typeof json === "object") rendered = () => new SBNetPreview.JSONView(json, { expandDepth: 2, toolbar: false }).el;
        }
        const draw = () => { area.textContent = ""; area.appendChild(source || !rendered ? h("pre", { class: "code" }, tryPrettyJSON(r.requestBody) || r.requestBody) : rendered()); };
        const toggle = rendered ? h("span", { class: "link nv-head-link" }, "view source") : null;
        if (toggle) toggle.addEventListener("click", () => { source = !source; toggle.textContent = source ? "view parsed" : "view source"; draw(); });
        draw();
        body.appendChild(this.section(title, [area], true, toggle));
      }
      if (!params.length && r.requestBody == null) body.appendChild(h("div", { class: "detail-note" }, (r.method || "GET").toUpperCase() === "GET" ? "This request has no payload." : "No payload was observed for this request (it may have been a stream or a Blob)."));
    },

    // ---- bodies ---------------------------------------------------------------------------
    // The page hooks keep at most 256 KB of a body; the engine keeps all of it.
    isTruncated(r) { return typeof r.responseBody === "string" && /\u2026\[truncated \d+ chars\]$/.test(r.responseBody.slice(-64)); },

    bodyOrFetchNote(r, body, then) {
      if (r.responseBody != null && this.isTruncated(r) && r.protocolRequestID && !r.fullBodyRequested) {
        r.fullBodyRequested = true;
        body.appendChild(h("div", { class: "detail-note" }, "Loading the full response body…"));
        DevTools.rpc("Network.getResponseBody", { id: r.id }).then((updated) => {
          updated.bodyRequested = updated.fullBodyRequested = true;
          this.requests.set(updated.id, updated);
          if (this.selectedId === updated.id) this.renderDetail();
        }).catch(() => { if (this.selectedId === r.id) this.renderDetail(); });
        return;
      }
      if (r.responseBody != null) {
        if (this.isTruncated(r)) body.appendChild(h("div", { class: "nv-notice" }, "Only the first 256 KB of this body was kept (it was read by the page hooks). Use Fetch body again from a reload with DevTools open for all of it."));
        then(r.responseBody);
        return;
      }
      if (r.imported) { body.appendChild(h("div", { class: "detail-note" }, "The HAR file has no body for this request.")); return; }
      // The inspector protocol kept the bytes the page received: read them
      // once, on demand, without asking the server again.
      if (r.protocolRequestID && !r.bodyRequested) {
        r.bodyRequested = true;
        body.appendChild(h("div", { class: "detail-note" }, "Loading response body…"));
        DevTools.rpc("Network.getResponseBody", { id: r.id }).then((updated) => {
          updated.bodyRequested = true;
          this.requests.set(updated.id, updated);
          if (this.selectedId === updated.id) this.renderDetail();
        }).catch(() => { if (this.selectedId === r.id) this.renderDetail(); });
        return;
      }
      const note = h("div", { class: "detail-note" });
      note.appendChild(document.createTextNode(r.statusCode === 204 || r.statusCode === 304 || r.statusCode === 101 ? `A ${r.statusCode} response has no body.`
        : r.sources.includes("pageWorld")
          ? "The body was not readable in the page (binary or streaming)."
          : r.protocolRequestID
            ? "The engine no longer holds this body."
            : "This request finished before DevTools was open, so only its timing was recorded. Reload with DevTools open to capture status, headers and bodies for every resource."));
      const button = h("button", { class: "text-button" }, "Fetch body again");
      button.addEventListener("click", async () => {
        button.disabled = true; button.textContent = "Fetching…";
        try {
          const updated = await DevTools.rpc("Network.refetch", { id: r.id });
          this.requests.set(updated.id, updated);
          this.renderDetail();
        } catch (err) { note.appendChild(h("div", { class: "v-error" }, err.message)); button.disabled = false; button.textContent = "Fetch body again"; }
      });
      note.appendChild(button);
      body.appendChild(note);
    },

    refetchedNote(r) {
      return r.responseBodyIsRefetched ? h("div", { class: "detail-note" }, "This body was fetched again by the app with the profile's cookies. It may differ from what the page received.") : null;
    },

    renderPreview(r, body) {
      this.bodyOrFetchNote(r, body, (text) => {
        const note = this.refetchedNote(r);
        if (note) body.appendChild(note);
        if (text === "") { body.appendChild(h("div", { class: "detail-note" }, "This response has an empty body.")); return; }
        try { this.activeView = SBNetPreview.renderPreview(r, text, body); }
        catch (err) { body.appendChild(h("div", { class: "detail-note" }, "Could not preview this response: " + err.message)); body.appendChild(h("pre", { class: "code" }, String(text).slice(0, 100000))); }
      });
    },

    renderResponse(r, body) {
      this.bodyOrFetchNote(r, body, (text) => {
        const note = this.refetchedNote(r);
        if (note) body.appendChild(note);
        if (text === "") { body.appendChild(h("div", { class: "detail-note" }, "This response has an empty body.")); return; }
        this.activeView = SBNetPreview.renderResponse(r, text, body);
      });
    },

    // ---- Initiator ------------------------------------------------------------------------------
    initiatorFrames(init) {
      const frames = [];
      let trace = init && init.stackTrace;
      while (trace) {
        const list = Array.isArray(trace) ? trace : trace.callFrames || [];
        for (const f of list) if (f && f.url && !/^user-script:/.test(f.url)) frames.push(f);
        trace = !Array.isArray(trace) && trace.parentStackTrace;
      }
      return frames;
    },

    renderInitiator(r, body) {
      const ext = this.ext(r);
      const init = ext.initiator;
      const pageURL = DevTools.info.url || "";
      const sourceLink = (url, line, column) => h("span", { class: "link", onclick: () => DevTools.openSource(url, line || 1, column || 0) }, `${fileName(url)}${line ? ":" + line : ""}`);
      // Chain: the document, the resource that asked (parser or script), this request.
      const chain = [];
      if (pageURL && pageURL !== r.url) chain.push({ url: pageURL, label: "document" });
      const frames = this.initiatorFrames(init);
      const parentURL = (init && init.url) || (frames[0] && frames[0].url);
      if (parentURL && parentURL !== pageURL && parentURL !== r.url) chain.push({ url: parentURL, label: init.type === "parser" ? "parser" : "script" });
      chain.push({ url: r.url, label: "this request", self: true });
      const chainEl = h("div", { class: "nv-chain" }, chain.map((c, i) => {
        const logged = this.all().find((x) => x.url === c.url && !c.self);
        const name = logged ? h("span", { class: "link", title: c.url, onclick: () => this.select(logged.id) }, fileName(c.url)) : h("span", { title: c.url, class: c.self ? "nv-chain-self" : "" }, fileName(c.url));
        return h("div", { class: "nv-chain-item", style: `--depth:${i}` }, name, h("span", { class: "muted" }, "  " + c.label));
      }));
      body.appendChild(this.section("Request initiator chain", [chainEl]));

      const facts = [this.kv("Initiator type", r.initiator || (init && init.type) || "other")];
      if (init && init.type) facts.push(this.kv("Engine initiator", init.type + (init.type === "parser" ? " (found while parsing the document)" : init.type === "script" ? " (requested by script)" : "")));
      if (init && init.url) facts.push(this.kv("Initiated at", sourceLink(init.url, init.lineNumber, init.columnNumber)));
      body.appendChild(this.section("Initiator", facts));

      if (frames.length) {
        const rows = frames.slice(0, 60).map((f) => h("div", { class: "nv-frame-row" }, h("span", { class: "nv-fn" }, f.functionName || "(anonymous)"), h("span", { class: "muted" }, " @ "), sourceLink(f.url, f.lineNumber, f.columnNumber)));
        body.appendChild(this.section("Request call stack", rows));
      } else {
        body.appendChild(h("div", { class: "detail-note" }, r.imported ? "The HAR file has no call stack for this request."
          : r.protocolRequestID ? "No JavaScript call stack: this request was not started by script (or the engine kept none)."
          : "No call stack: the inspector protocol was not attached when this request started. Reload with DevTools open to capture initiator stacks."));
      }
      const children = this.all().filter((x) => {
        if (x.id === r.id) return false;
        const i = this.ext(x).initiator;
        return i && (i.url === r.url || this.initiatorFrames(i).some((f) => f.url === r.url));
      });
      if (children.length) {
        body.appendChild(this.section(`Requests initiated by this one (${children.length})`, children.slice(0, 100).map((x) => h("div", { class: "nv-frame-row" }, h("span", { class: "link", title: x.url, onclick: () => this.select(x.id) }, fileName(x.url)), h("span", { class: "muted" }, "  " + x.resourceType)))));
      }
    },

    // ---- Timing ------------------------------------------------------------------------------------
    renderTiming(r, body) {
      const all = this.all();
      const base = Math.min(...all.map((x) => x.startedAt), r.startedAt);
      const t = r.timing;
      const queuedAt = r.startedAt - base;
      // Resource timing is relative to the request's start.
      const startedAt = queuedAt + (t && t.responseEnd > 0 ? Math.max(0, t.domainLookupStart || t.connectStart || t.requestStart || t.fetchStart || 0) : 0);
      body.appendChild(h("div", { class: "nv-timing-head" }, `Queued at ${formatMs(queuedAt / 1000)}`, h("br"), `Started at ${formatMs(startedAt / 1000)}`,
        h("span", { class: "muted" }, " (from the first request in the log)")));
      if (!t || !(t.responseEnd > 0)) {
        body.appendChild(h("div", { class: "detail-note" }, r.duration != null
          ? `Total: ${formatMs(r.duration)}. Phase breakdown needs resource timing, which was not available for this request${(r.sources || []).includes("agent") ? " (cross-origin without Timing-Allow-Origin)" : ""}.`
          : "No timing information."));
      } else {
        const zero = 0;
        const dnsStart = t.domainLookupStart || t.connectStart || t.requestStart;
        const phases = [
          ["Queueing / stalled", t.fetchStart, dnsStart, "wf-blocked"],
          ["DNS lookup", t.domainLookupStart, t.domainLookupEnd, "wf-dns"],
          ["Initial connection", t.connectStart, t.secureConnectionStart || t.connectEnd, "wf-connect"],
          ["SSL", t.secureConnectionStart, t.secureConnectionStart ? t.connectEnd : 0, "wf-ssl"],
          ["Waiting for server response", t.requestStart, t.responseStart, "wf-wait"],
          ["Content download", t.responseStart, t.responseEnd, "wf-receive"],
        ];
        const total = Math.max(t.responseEnd - zero, 0.001);
        for (const [label, from, to, cls] of phases) {
          const dur = Math.max(0, to - from);
          const row = h("div", { class: "timing-row" }, h("span", { class: "label" }, label));
          const wrap = h("div", { class: "bar-wrap" });
          if (to > from) wrap.appendChild(h("div", { class: "bar " + cls, style: `left:${((from - zero) / total) * 100}%;width:${(dur / total) * 100}%` }));
          row.append(wrap, h("span", { class: "ms" }, (to > from || from > 0) ? dur.toFixed(2) + " ms" : "—"));
          body.appendChild(row);
        }
        body.appendChild(h("div", { class: "timing-row" }, h("span", { class: "label" }, "Total"), h("div", { class: "bar-wrap", style: "background:none" }), h("span", { class: "ms" }, total.toFixed(2) + " ms")));
      }
      const serverTiming = SBNet.parseServerTiming(SBNet.header(r.responseHeaders, "server-timing"));
      if (serverTiming.length) {
        const max = Math.max(...serverTiming.map((e) => e.duration || 0), 0.001);
        const rows = serverTiming.map((e) => h("div", { class: "timing-row nv-server-timing" },
          h("span", { class: "label", title: e.name }, e.description || e.name, e.description ? h("span", { class: "muted" }, " " + e.name) : null),
          h("div", { class: "bar-wrap" }, e.duration != null ? h("div", { class: "bar nv-st-bar", style: `left:0;width:${(e.duration / max) * 100}%` }) : null),
          h("span", { class: "ms" }, e.duration != null ? e.duration.toFixed(2) + " ms" : "—")));
        body.appendChild(h("div", { class: "nv-timing-sub" }, "Server Timing", h("span", { class: "muted" }, "  from the server's Server-Timing header")));
        for (const row of rows) body.appendChild(row);
      } else {
        body.appendChild(h("div", { class: "detail-note" }, "No Server-Timing header. A server can add one (Server-Timing: db;dur=53;desc=\"Database\") to show its own phases here."));
      }
    },

    // ---- Cookies --------------------------------------------------------------------------------------
    async renderCookies(r, body) {
      const requestCookies = SBNet.parseCookieHeader(SBNet.header(r.requestHeaders, "cookie"));
      const responseCookies = SBNet.parseSetCookies(SBNet.header(r.responseHeaders, "set-cookie"));
      const yes = (v) => v ? "✓" : "";
      if (requestCookies.length) {
        let store = [];
        if (!r.imported) { try { store = await DevTools.rpc("Cookies.list"); } catch (_) {} }
        if (this.selectedId !== r.id || this.detailTab !== "cookies") return;
        const rows = requestCookies.map((c) => {
          const known = store.find((s) => s.name === c.name) || {};
          return h("tr", {}, h("td", { class: "mono" }, c.name), h("td", { class: "mono", title: c.value }, c.value), h("td", {}, known.domain || ""), h("td", {}, known.path || ""),
            h("td", {}, known.expires ? new Date(known.expires).toISOString() : known.name ? "Session" : ""), h("td", {}, String(c.name.length + c.value.length)),
            h("td", {}, yes(known.httpOnly)), h("td", {}, yes(known.secure)), h("td", {}, known.sameSite || ""));
        });
        body.appendChild(this.section(`Request Cookies (${requestCookies.length})`, [h("table", { class: "data-table nv-table nv-cookies selectable" },
          h("thead", {}, h("tr", {}, ["Name", "Value", "Domain", "Path", "Expires", "Size", "HttpOnly", "Secure", "SameSite"].map((t) => h("th", {}, t)))), h("tbody", {}, rows))]));
      }
      if (responseCookies.length) {
        const allIssues = [];
        const rows = responseCookies.map((c) => {
          const issues = SBNet.cookieIssues(c, r.url);
          for (const i of issues) allIssues.push(`${c.name}: ${i}`);
          return h("tr", { class: issues.length ? "nv-cookie-issue" : "" },
            h("td", { class: "mono" }, issues.length ? h("span", { class: "nv-warn", title: issues.join("\n") }, "⚠ ") : null, c.name),
            h("td", { class: "mono", title: c.value }, c.value), h("td", {}, c.domain), h("td", {}, c.path),
            h("td", {}, c.maxAge !== "" ? `Max-Age=${c.maxAge}` : c.expires || "Session"), h("td", {}, String(c.size)),
            h("td", {}, yes(c.httpOnly)), h("td", {}, yes(c.secure)), h("td", {}, c.sameSite), h("td", {}, yes(c.partitioned)), h("td", {}, c.priority));
        });
        body.appendChild(this.section(`Response Cookies (${responseCookies.length})`, [h("table", { class: "data-table nv-table nv-cookies selectable" },
          h("thead", {}, h("tr", {}, ["Name", "Value", "Domain", "Path", "Expires / Max-Age", "Size", "HttpOnly", "Secure", "SameSite", "Partitioned", "Priority"].map((t) => h("th", {}, t)))), h("tbody", {}, rows)),
          allIssues.length ? h("div", { class: "nv-cookie-issues" }, allIssues.map((i) => h("div", { class: "nv-issue" }, "⚠ " + i))) : null]));
      } else if (SBNet.header(r.responseHeaders, "set-cookie") === undefined && Object.keys(r.responseHeaders || {}).length) {
        body.appendChild(h("div", { class: "detail-note" }, "No Set-Cookie in this response (WebKit does not report Set-Cookie to page script, so fetch/XHR responses seen only by the page hooks cannot show it)."));
      }
      if (!requestCookies.length && !responseCookies.length) body.appendChild(h("div", { class: "detail-note" }, "This request has no cookies."));
    },

    // ---- WebSocket frames ---------------------------------------------------------
    async renderMessages(r, body) {
      const table = h("table", { class: "data-table ws-table" },
        h("thead", {}, h("tr", {}, h("th", { style: "width:24px" }, ""), h("th", {}, "Data"), h("th", { style: "width:70px" }, "Length"), h("th", { style: "width:100px" }, "Time"))),
        h("tbody", { id: "ws-frames" }));
      body.appendChild(table);
      let frames = [];
      if (!r.imported) { try { frames = await DevTools.rpc("Network.getWebSocketFrames", { id: r.id }); } catch (_) {} }
      if (this.selectedId !== r.id || this.detailTab !== "messages") return;
      const tbody = $("#ws-frames");
      if (!tbody) return;
      tbody.textContent = "";
      for (const frame of frames) tbody.appendChild(this.frameRow(frame));
      if (!frames.length) tbody.appendChild(h("tr", {}, h("td", { colspan: "4", class: "muted", style: "text-align:center" }, "No messages yet")));
    },

    frameRow(frame) {
      const arrow = { sent: "↑", received: "↓", error: "✕", closed: "■" }[frame.direction] || "";
      const isBinary = frame.opcode === 2;
      return h("tr", { class: "ws-" + frame.direction },
        h("td", { class: "ws-arrow" }, arrow),
        h("td", { title: frame.data, class: "selectable" }, isBinary ? "Binary message" : frame.data),
        h("td", {}, frame.length != null ? formatBytes(frame.length) : ""),
        h("td", {}, formatTime(frame.time)));
    },

    onWebSocketFrame(requestId, frame) {
      const r = this.get(this.selectedId);
      if (!r || r.protocolRequestID !== requestId || this.detailTab !== "messages") return;
      const tbody = $("#ws-frames");
      if (!tbody) return;
      if (tbody.querySelector("td[colspan]")) tbody.textContent = "";
      tbody.appendChild(this.frameRow(frame));
      tbody.lastElementChild.scrollIntoView({ block: "nearest" });
    },
  };

  // JSON preview tree for response bodies.
  const JSONTree = {
    render(value, key) {
      const isObj = value !== null && typeof value === "object";
      if (!isObj) {
        const row = h("div", { class: "obj-row" });
        if (key != null) row.append(h("span", { class: "obj-key" }, String(key)), ": ");
        row.appendChild(this.leaf(value));
        return row;
      }
      const isArray = Array.isArray(value);
      const keys = isArray ? value.map((_, i) => i) : Object.keys(value);
      const container = h("div", { class: "obj expanded" });
      const toggle = h("span", { class: "obj-toggle" });
      const head = h("div", { class: "obj-row obj-head" }, toggle);
      if (key != null) head.append(h("span", { class: "obj-key" }, String(key)), ": ");
      head.appendChild(h("span", { class: "obj-desc" }, isArray ? `Array(${value.length})` : `{${keys.length}}`));
      const children = h("div", { class: "obj-children" });
      container.append(head, children);
      let built = false;
      const build = () => { if (built) return; built = true; for (const k of keys.slice(0, 500)) children.appendChild(this.render(value[k], k)); if (keys.length > 500) children.appendChild(h("div", { class: "obj-row muted" }, `… ${keys.length - 500} more`)); };
      head.addEventListener("click", () => { container.classList.toggle("expanded"); build(); });
      if (key == null || keys.length <= 20) build(); else container.classList.remove("expanded");
      return container;
    },
    leaf(v) {
      if (v === null) return h("span", { class: "v-null" }, "null");
      if (typeof v === "string") return h("span", { class: "v-string" }, JSON.stringify(v));
      if (typeof v === "number") return h("span", { class: "v-number" }, String(v));
      if (typeof v === "boolean") return h("span", { class: "v-boolean" }, String(v));
      return h("span", {}, String(v));
    },
  };

  DevTools.register("network", panel);
  window.JSONTree = JSONTree;      // also used by the Application panel

  // "Disable cache" applies while DevTools is open, whether or not this panel
  // has been shown, so it lives outside the panel's lazy init. WebKit forgets
  // it with the protocol connection, and the app turns it off when DevTools
  // hides; both bring it back here.
  window.SBCacheControl = {
    disabled: false,
    async start() {
      const box = $("#network-disable-cache");
      try { this.disabled = (await DevTools.rpc("Settings.get", { key: "disableCache" })) === "true"; } catch (_) {}
      box.checked = this.disabled;
      box.addEventListener("change", () => {
        this.disabled = box.checked;
        DevTools.rpc("Settings.set", { key: "disableCache", value: String(this.disabled) }).catch(() => {});
        this.apply();
      });
      DevTools.on("Protocol.attached", () => this.apply());
      DevTools.on("Protocol.shown", () => this.apply());
      this.apply();
    },
    apply() {
      return DevTools.rpc("Protocol.send", { method: "Network.setResourceCachingDisabled", params: { disabled: this.disabled } }).catch(() => {});
    },
  };
})();
