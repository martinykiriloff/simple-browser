// SimpleBrowser DevTools — Network panel.
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

  const panel = {
    initialized: false,
    requests: new Map(),
    order: [],
    filterText: "",
    type: "all",
    preserve: false,
    recording: true,
    sort: { key: null, desc: false },
    selectedId: null,
    detailTab: "headers",
    renderTimer: null,

    init() {
      $("#network-record").addEventListener("click", (e) => {
        this.recording = !this.recording;
        e.currentTarget.classList.toggle("on", this.recording);
        e.currentTarget.title = this.recording ? "Stop recording network log" : "Record network log";
      });
      $("#network-clear").addEventListener("click", () => this.clear());
      $("#network-filter").addEventListener("input", debounce(() => { this.filterText = $("#network-filter").value.toLowerCase(); this.renderAll(); }, 100));
      $("#network-preserve").addEventListener("change", (e) => { this.preserve = e.target.checked; });
      $("#network-har").addEventListener("click", () => DevTools.rpc("Network.exportHAR").catch((err) => DevTools.panels.console?.addLocal("error", err.message)));
      for (const chip of $$("#network-types .chip")) {
        chip.addEventListener("click", () => {
          for (const c of $$("#network-types .chip")) c.classList.toggle("active", c === chip);
          this.type = chip.dataset.type;
          this.renderAll();
        });
      }
      for (const th of $$("#network-table th[data-sort]")) {
        th.addEventListener("click", () => {
          const key = th.dataset.sort;
          if (this.sort.key === key) { if (this.sort.desc) this.sort = { key: null, desc: false }; else this.sort.desc = true; }
          else this.sort = { key, desc: false };
          for (const other of $$("#network-table th")) { other.classList.toggle("sorted", other.dataset.sort === this.sort.key); other.classList.toggle("desc", other.dataset.sort === this.sort.key && this.sort.desc); }
          this.renderAll();
        });
      }
      $("#network-table tbody").addEventListener("click", (e) => {
        const row = e.target.closest("tr");
        if (row) this.select(row.dataset.id);
      });
      $("#network-table tbody").addEventListener("contextmenu", (e) => {
        const row = e.target.closest("tr");
        const r = row && this.requests.get(row.dataset.id);
        if (!r) return;
        e.preventDefault();
        ContextMenu.show(e.clientX, e.clientY, this.copyItems(r));
      });
      $("#network-detail-close").addEventListener("click", () => this.closeDetail());
      for (const tab of $$("#network-detail-tabs .subtab")) {
        tab.addEventListener("click", () => {
          for (const t of $$("#network-detail-tabs .subtab")) t.classList.toggle("active", t === tab);
          this.detailTab = tab.dataset.subpanel;
          this.renderDetail();
        });
      }
      document.addEventListener("keydown", (e) => {
        if (DevTools.activePanel !== "network" || e.target.closest("input, textarea")) return;
        if (e.key === "ArrowDown" || e.key === "ArrowUp") {
          const rows = $$("#network-table tbody tr");
          const i = rows.findIndex((r) => r.dataset.id === this.selectedId);
          const next = rows[i + (e.key === "ArrowDown" ? 1 : -1)];
          if (next) { e.preventDefault(); this.select(next.dataset.id); next.scrollIntoView({ block: "nearest" }); }
        } else if (e.key === "Escape") { this.closeDetail(); }
      });

      DevTools.on("Network.webSocketFrame", ({ requestId, frame }) => this.onWebSocketFrame(requestId, frame));
      DevTools.on("Network.requestAdded", ({ request }) => this.upsert(request));
      DevTools.on("Network.requestUpdated", ({ request }) => this.upsert(request));
      DevTools.on("Page.navigated", (p) => { if (p.phase === "started" && !this.preserve) this.clearLocal(); });
      DevTools.on("Recorder.cleared", () => this.clearLocal());
      this.load();
    },

    show() { this.renderAll(); },

    async load() {
      let list = [];
      try { list = await DevTools.rpc("Network.getRequests"); } catch (_) {}
      this.requests.clear(); this.order = [];
      for (const r of list) { this.requests.set(r.id, r); this.order.push(r.id); }
      this.renderAll();
    },

    upsert(request) {
      const isNew = !this.requests.has(request.id);
      if (isNew && !this.recording) return;
      this.requests.set(request.id, request);
      if (isNew) this.order.push(request.id);
      if (!this.renderTimer) this.renderTimer = setTimeout(() => { this.renderTimer = null; this.renderAll(); }, 60);
      if (request.id === this.selectedId) this.renderDetail();
    },

    clear() {
      DevTools.rpc("Network.clear").catch(() => {});
      this.clearLocal();
    },

    clearLocal() {
      this.requests.clear(); this.order = [];
      this.closeDetail();
      this.renderAll();
    },

    // ---- table ----------------------------------------------------------------------
    visibleRequests() {
      let list = this.order.map((id) => this.requests.get(id)).filter(Boolean);
      const group = TYPE_GROUPS[this.type];
      if (group) list = list.filter((r) => group.has(r.resourceType));
      if (this.filterText) list = list.filter((r) => r.url.toLowerCase().includes(this.filterText) || (r.mimeType || "").includes(this.filterText) || String(r.statusCode || "").includes(this.filterText));
      if (this.sort.key) {
        const key = this.sort.key;
        const value = (r) => ({
          name: fileName(r.url).toLowerCase(), status: r.statusCode || (r.failure ? 999 : 0), type: r.resourceType,
          initiator: r.initiator || "", size: r.transferSize ?? r.bodySize ?? -1, time: r.duration ?? -1,
        })[key];
        list.sort((a, b) => { const va = value(a), vb = value(b); return (va < vb ? -1 : va > vb ? 1 : 0) * (this.sort.desc ? -1 : 1); });
      }
      return list;
    },

    renderAll() {
      const tbody = $("#network-table tbody");
      const list = this.visibleRequests();
      const all = this.order.map((id) => this.requests.get(id)).filter(Boolean);
      const start = Math.min(...all.map((r) => r.startedAt), Infinity);
      const end = Math.max(...all.map((r) => r.startedAt + (r.duration || 0) * 1000), start + 1);
      const span = Math.max(end - start, 1);

      tbody.textContent = "";
      for (const r of list) tbody.appendChild(this.renderRow(r, start, span));
      if (!list.length) tbody.appendChild(h("tr", {}, h("td", { colspan: "7", class: "muted", style: "text-align:center" }, all.length ? "No requests match the filter" : "Recording network activity… Requests appear here from the moment the page starts loading, whether or not DevTools was open.")));

      const transferred = all.reduce((s, r) => s + (r.transferSize || 0), 0);
      const resources = all.reduce((s, r) => s + (r.bodySize || 0), 0);
      const finish = all.length ? formatMs(span / 1000) : "";
      $("#network-status").textContent = `${list.length}${list.length !== all.length ? " / " + all.length : ""} requests   |   ${formatBytes(transferred)} transferred   |   ${formatBytes(resources)} resources   |   Finish: ${finish}`;
    },

    // ---- copy ------------------------------------------------------------------------------------
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
          if (body != null) copy(body); else DevTools.panels.console?.addLocal("warn", "The response body of " + r.url + " is not available.");
        } });
      }
      const file = DevTools.panels.sources?.files?.has(r.url);
      if (file) items.push("-", { label: "Open in Sources panel", action: () => DevTools.openSource(r.url, 1, 0) });
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

    renderRow(r, start, span) {
      const tr = h("tr", { class: (r.failure || r.statusCode >= 400 ? "failed" : "") + (r.id === this.selectedId ? " selected" : ""), dataset: { id: r.id } });
      const name = h("div", { class: "name-cell", title: r.url + "\nObserved by: " + r.sources.join(", ") }, h("span", { style: "overflow:hidden;text-overflow:ellipsis" }, fileName(r.url)));
      if (r.sources.length === 1 && r.sources[0] === "pageWorld") name.appendChild(h("span", { class: "src page", title: "Seen only by page-world hooks, which page script could tamper with" }, "page"));
      tr.appendChild(h("td", {}, name));
      const status = r.statusCode != null ? String(r.statusCode) : (r.failure ? "(failed)" : "");
      tr.appendChild(h("td", { title: r.statusCode == null && !r.failure ? "Status not observable for this request type" : "" }, status));
      tr.appendChild(h("td", {}, r.resourceType));
      tr.appendChild(h("td", {}, r.initiator || ""));
      tr.appendChild(h("td", { title: r.bodySize != null ? formatBytes(r.bodySize) + " decoded" : "" }, formatBytes(r.transferSize ?? r.bodySize)));
      tr.appendChild(h("td", {}, formatMs(r.duration)));
      tr.appendChild(h("td", {}, this.waterfall(r, start, span)));
      return tr;
    },

    waterfall(r, start, span) {
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
      wf.title = formatMs(r.duration);
      return wf;
    },

    // ---- detail ----------------------------------------------------------------------------
    select(id) {
      this.selectedId = id;
      for (const row of $$("#network-table tbody tr")) row.classList.toggle("selected", row.dataset.id === id);
      $("#network-detail").hidden = false;
      $("[data-split=network-split]").hidden = false;
      $("#network-table").classList.add("narrow");
      const isSocket = (this.requests.get(id) || {}).resourceType === "websocket";
      const messagesTab = $('#network-detail-tabs [data-subpanel="messages"]');
      messagesTab.hidden = !isSocket;
      if (isSocket) this.setDetailTab("messages");
      else if (this.detailTab === "messages") this.setDetailTab("headers");
      this.renderDetail();
    },

    setDetailTab(name) {
      this.detailTab = name;
      for (const t of $$("#network-detail-tabs .subtab")) t.classList.toggle("active", t.dataset.subpanel === name);
    },

    closeDetail() {
      this.selectedId = null;
      $("#network-detail").hidden = true;
      $("[data-split=network-split]").hidden = true;
      $("#network-table").classList.remove("narrow");
      for (const row of $$("#network-table tbody tr.selected")) row.classList.remove("selected");
    },

    renderDetail() {
      const r = this.requests.get(this.selectedId);
      const body = $("#network-detail-body");
      body.textContent = "";
      if (!r) return;
      switch (this.detailTab) {
        case "headers": this.renderHeaders(r, body); break;
        case "payload": this.renderPayload(r, body); break;
        case "preview": this.renderPreview(r, body); break;
        case "response": this.renderResponse(r, body); break;
        case "timing": this.renderTiming(r, body); break;
        case "messages": this.renderMessages(r, body); break;
      }
    },

    section(title, rows, open = true) {
      const s = h("div", { class: "detail-section" + (open ? "" : " collapsed") });
      const head = h("div", { class: "detail-head" }, title);
      head.addEventListener("click", () => s.classList.toggle("collapsed"));
      s.append(head, h("div", { class: "detail-body" }, rows));
      return s;
    },

    kv(k, v, cls) { return h("div", { class: "kv" }, h("span", { class: "k" }, k), h("span", { class: "v " + (cls || "") }, v)); },

    renderHeaders(r, body) {
      const general = [
        this.kv("Request URL", r.url),
        this.kv("Request Method", r.method || "(not observable)"),
        this.kv("Status Code", r.statusCode != null ? String(r.statusCode) : (r.failure || "(not observable)"), r.statusCode ? (r.statusCode < 400 ? "status-ok" : "status-bad") : (r.failure ? "status-bad" : "")),
      ];
      if (r.mimeType) general.push(this.kv("Content-Type", r.mimeType));
      if (r.protocolName) general.push(this.kv("Protocol", r.protocolName));
      const sourceNames = { agent: "isolated-world agent (resource timing)", pageWorld: "page-world hook (fetch/XHR)", navigationDelegate: "navigation response (status and headers from WebKit)", inspector: "WebKit inspector protocol (status, headers, body)" };
      general.push(this.kv("Observed by", r.sources.map((s) => sourceNames[s] || s).join(", ")));
      body.appendChild(this.section("General", general));
      const headerRows = (headers) => Object.keys(headers).sort().map((k) => this.kv(k, headers[k]));
      const note = h("div", { class: "detail-note" }, "This request finished before DevTools was open, so it was seen only through resource timing (sizes and timing, no headers). Reload with DevTools open to capture headers for every resource.");
      body.appendChild(this.section(`Response Headers (${Object.keys(r.responseHeaders).length})`, Object.keys(r.responseHeaders).length ? headerRows(r.responseHeaders) : [note]));
      body.appendChild(this.section(`Request Headers (${Object.keys(r.requestHeaders).length})`, Object.keys(r.requestHeaders).length ? headerRows(r.requestHeaders) : [h("div", { class: "detail-note" }, "No request headers were set by page script, or the request was not made by page script.")]));
    },

    renderPayload(r, body) {
      let params = [];
      try { params = Array.from(new URL(r.url).searchParams.entries()); } catch (_) {}
      if (params.length) body.appendChild(this.section(`Query String Parameters (${params.length})`, params.map(([k, v]) => this.kv(k, v))));
      if (r.requestBody != null) {
        const type = (r.requestHeaders["content-type"] || r.requestHeaders["Content-Type"] || "").toLowerCase();
        let rows;
        if (type.includes("x-www-form-urlencoded")) {
          rows = Array.from(new URLSearchParams(r.requestBody).entries()).map(([k, v]) => this.kv(k, v));
          body.appendChild(this.section("Form Data", rows));
        } else {
          body.appendChild(this.section("Request Payload", [h("pre", { class: "code" }, tryPrettyJSON(r.requestBody) || r.requestBody)]));
        }
      }
      if (!params.length && r.requestBody == null) body.appendChild(h("div", { class: "detail-note" }, "This request has no payload."));
    },

    bodyOrFetchNote(r, body, then) {
      if (r.responseBody != null) { then(r.responseBody); return; }
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
      note.appendChild(document.createTextNode(r.sources.includes("pageWorld")
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
        if (text.startsWith("data:image/")) { body.appendChild(h("img", { class: "preview-img", src: text })); return; }
        const trimmed = text.trim();
        if ((trimmed.startsWith("{") || trimmed.startsWith("["))) {
          try { body.appendChild(JSONTree.render(JSON.parse(trimmed))); return; } catch (_) {}
        }
        body.appendChild(h("pre", { class: "code" }, text));
      });
    },

    renderResponse(r, body) {
      this.bodyOrFetchNote(r, body, (text) => {
        const note = this.refetchedNote(r);
        if (note) body.appendChild(note);
        if (text.startsWith("data:image/")) { body.appendChild(h("img", { class: "preview-img", src: text })); return; }
        const pretty = tryPrettyJSON(text);
        const pre = h("pre", { class: "code" }, text);
        if (pretty && pretty !== text) {
          const toggle = h("button", { class: "text-button", style: "margin:6px 8px" }, "{ } Pretty print");
          let on = false;
          toggle.addEventListener("click", () => { on = !on; pre.textContent = on ? pretty : text; });
          body.appendChild(toggle);
        }
        body.appendChild(pre);
      });
    },

    // ---- WebSocket frames ---------------------------------------------------------
    async renderMessages(r, body) {
      const table = h("table", { class: "data-table ws-table" },
        h("thead", {}, h("tr", {}, h("th", { style: "width:24px" }, ""), h("th", {}, "Data"), h("th", { style: "width:70px" }, "Length"), h("th", { style: "width:100px" }, "Time"))),
        h("tbody", { id: "ws-frames" }));
      body.appendChild(table);
      let frames = [];
      try { frames = await DevTools.rpc("Network.getWebSocketFrames", { id: r.id }); } catch (_) {}
      if (this.selectedId !== r.id || this.detailTab !== "messages") return;
      const tbody = $("#ws-frames");
      if (!tbody) return;
      tbody.textContent = "";
      for (const frame of frames) tbody.appendChild(this.frameRow(frame));
      if (!frames.length) tbody.appendChild(h("tr", {}, h("td", { colspan: "4", class: "muted", style: "text-align:center" }, "No messages yet")));
    },

    frameRow(frame) {
      const arrow = { sent: "\u2191", received: "\u2193", error: "\u2715", closed: "\u25A0" }[frame.direction] || "";
      const isBinary = frame.opcode === 2;
      return h("tr", { class: "ws-" + frame.direction },
        h("td", { class: "ws-arrow" }, arrow),
        h("td", { title: frame.data, class: "selectable" }, isBinary ? "Binary message" : frame.data),
        h("td", {}, frame.length != null ? formatBytes(frame.length) : ""),
        h("td", {}, formatTime(frame.time)));
    },

    onWebSocketFrame(requestId, frame) {
      const r = this.requests.get(this.selectedId);
      if (!r || r.protocolRequestID !== requestId || this.detailTab !== "messages") return;
      const tbody = $("#ws-frames");
      if (!tbody) return;
      if (tbody.querySelector("td[colspan]")) tbody.textContent = "";
      tbody.appendChild(this.frameRow(frame));
      tbody.lastElementChild.scrollIntoView({ block: "nearest" });
    },

    renderTiming(r, body) {
      const t = r.timing;
      if (!t || !(t.responseEnd > 0)) {
        body.appendChild(h("div", { class: "detail-note" }, r.duration != null
          ? `Total: ${formatMs(r.duration)}. Phase breakdown needs resource timing, which was not available for this request${r.sources.includes("agent") ? " (cross-origin without Timing-Allow-Origin)" : ""}.`
          : "No timing information."));
        return;
      }
      const dnsStart = t.domainLookupStart || t.connectStart || t.requestStart;
      const phases = [
        ["Queueing / stalled", t.fetchStart, dnsStart, "wf-blocked"],
        ["DNS lookup", t.domainLookupStart, t.domainLookupEnd, "wf-dns"],
        ["Initial connection", t.connectStart, t.secureConnectionStart || t.connectEnd, "wf-connect"],
        ["SSL", t.secureConnectionStart, t.secureConnectionStart ? t.connectEnd : 0, "wf-ssl"],
        ["Waiting for server response", t.requestStart, t.responseStart, "wf-wait"],
        ["Content download", t.responseStart, t.responseEnd, "wf-receive"],
      ];
      const total = t.responseEnd;
      for (const [label, from, to, cls] of phases) {
        const dur = Math.max(0, to - from);
        const row = h("div", { class: "timing-row" }, h("span", { class: "label" }, label));
        const wrap = h("div", { class: "bar-wrap" });
        if (to > from) wrap.appendChild(h("div", { class: "bar " + cls, style: `left:${(from / total) * 100}%;width:${(dur / total) * 100}%` }));
        row.append(wrap, h("span", { class: "ms" }, (to > from || from > 0) ? dur.toFixed(2) + " ms" : "—"));
        body.appendChild(row);
      }
      body.appendChild(h("div", { class: "timing-row" }, h("span", { class: "label" }, "Total"), h("div", { class: "bar-wrap", style: "background:none" }), h("span", { class: "ms" }, total.toFixed(2) + " ms")));
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
