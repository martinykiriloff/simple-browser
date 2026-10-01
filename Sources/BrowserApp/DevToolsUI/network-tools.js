// SimpleBrowser DevTools — Network power tools: request blocking, local
// overrides, search across every request, and "Copy for AI" (Markdown and
// HAR). Extends the Network panel (network.js) and adds three drawer panes.
"use strict";

(function () {
  const network = DevTools.panels.network;
  const copy = (text) => DevTools.rpc("Clipboard.write", { text }).catch(() => {});
  const note = (level, text) => DevTools.panels.console?.addLocal(level, text);

  // Chrome's pattern syntax: a substring of the URL, `*` matches anything.
  function patternRegex(pattern) {
    return new RegExp(pattern.split("*").map((p) => p.replace(/[.+?^${}()|[\]\\]/g, "\\$&")).join(".*"), "i");
  }

  // ---- request blocking ------------------------------------------------------------------------
  // Enforced natively by a WebKit content rule list on this tab, so every
  // resource type is blocked before it is requested, protocol or not.
  const SBBlocking = window.SBBlocking = {
    enabled: true,
    patterns: [],            // [{ pattern, enabled }]
    lastError: null,

    async start() {
      try {
        const saved = await DevTools.rpc("Settings.get", { key: "blockedPatterns" });
        if (saved) this.patterns = JSON.parse(saved);
        this.enabled = (await DevTools.rpc("Settings.get", { key: "blockingEnabled" })) !== "false";
      } catch (_) {}
      if (this.patterns.length) await this.apply();
    },

    active() { return this.enabled ? this.patterns.filter((p) => p.enabled).map((p) => p.pattern) : []; },

    async apply() {
      DevTools.rpc("Settings.set", { key: "blockedPatterns", value: JSON.stringify(this.patterns) }).catch(() => {});
      DevTools.rpc("Settings.set", { key: "blockingEnabled", value: String(this.enabled) }).catch(() => {});
      try { await DevTools.rpc("Network.setBlockedPatterns", { patterns: this.active() }); this.lastError = null; }
      catch (e) { this.lastError = e.message; }
      this.render();
      network.renderAll?.();
    },

    add(pattern) {
      pattern = String(pattern || "").trim();
      if (!pattern) return Promise.resolve();
      const existing = this.patterns.find((p) => p.pattern === pattern);
      if (existing) existing.enabled = true; else this.patterns.push({ pattern, enabled: true });
      this.enabled = true;
      return this.apply();
    },
    remove(pattern) { this.patterns = this.patterns.filter((p) => p.pattern !== pattern); return this.apply(); },
    setEnabled(on) { this.enabled = !!on; return this.apply(); },

    matches(url) { return this.active().some((p) => patternRegex(p).test(url)); },

    blockedCount(pattern) {
      const re = patternRegex(pattern);
      return Array.from(network.requests.values()).filter((r) => r.failure && re.test(r.url)).length;
    },

    render() {
      const list = $("#blocking-list");
      if (!list) return;
      $("#blocking-enabled").checked = this.enabled;
      list.textContent = "";
      list.classList.toggle("disabled", !this.enabled);
      if (!this.patterns.length) {
        list.appendChild(h("div", { class: "empty-state" }, "No request blocking patterns. Click + or right-click a request in the Network panel → Block request URL."));
      }
      for (const p of this.patterns) {
        const box = h("input", { type: "checkbox" });
        box.checked = p.enabled;
        box.addEventListener("change", () => { p.enabled = box.checked; this.apply(); });
        const text = h("span", { class: "pattern mono", title: "Double-click to edit" }, p.pattern);
        text.addEventListener("dblclick", () => inlineEdit(text, { initial: p.pattern, onCommit: (value) => {
          value = value.trim();
          if (!value) this.remove(p.pattern); else { p.pattern = value; this.apply(); }
        }, onCancel: () => this.render() }));
        const count = this.blockedCount(p.pattern);
        list.appendChild(h("div", { class: "block-row" + (p.enabled ? "" : " off") }, box, text,
          h("span", { class: "muted" }, count ? count + " blocked" : ""),
          h("span", { class: "remove", title: "Remove", onclick: () => this.remove(p.pattern) }, "✕")));
      }
      $("#blocking-status").textContent = this.lastError ? "⚠ " + this.lastError
        : `${this.active().length} pattern(s) active. Enforced by WebKit for every resource type while DevTools is open; matching requests fail as blocked.`;
    },

    initPane() {
      $("#blocking-enabled").addEventListener("change", (e) => this.setEnabled(e.target.checked));
      $("#blocking-clear").addEventListener("click", () => { this.patterns = []; this.apply(); });
      $("#blocking-add").addEventListener("click", () => {
        const input = h("input", { type: "text", class: "pattern-input mono", placeholder: "Text pattern to block matching requests; use * for wildcard" });
        const row = h("div", { class: "block-row" }, input);
        $("#blocking-list").prepend(row);
        input.focus();
        input.addEventListener("keydown", (e) => {
          if (e.key === "Enter") { e.preventDefault(); this.add(input.value); }
          if (e.key === "Escape") { e.preventDefault(); row.remove(); }
        });
        input.addEventListener("blur", () => { if (input.value.trim()) this.add(input.value); else row.remove(); });
      });
    },
  };

  Drawer.register("blocking", { title: "Network request blocking", init: () => SBBlocking.initPane(), show: () => SBBlocking.render() });

  // ---- local overrides -------------------------------------------------------------------------------
  // Answered through the inspector protocol's request interception: the
  // page never reaches the server for an overridden URL while DevTools is open.
  const SBOverrides = window.SBOverrides = {
    enabled: true,
    list: [],                // [{ url, status, mimeType, headersText, body, keepBody, enabled }]
    selected: 0,
    status: "",

    async start() {
      try {
        const saved = await DevTools.rpc("Settings.get", { key: "overrides" });
        if (saved) this.list = JSON.parse(saved);
        this.enabled = (await DevTools.rpc("Settings.get", { key: "overridesEnabled" })) !== "false";
      } catch (_) {}
      DevTools.on("Protocol.attached", () => { if (this.list.length) this.apply(); });
      if (this.list.length) this.apply();
    },

    parseHeaders(text) {
      const out = {};
      for (const line of String(text || "").split("\n")) {
        const i = line.indexOf(":");
        if (i > 0) out[line.slice(0, i).trim()] = line.slice(i + 1).trim();
      }
      return out;
    },

    async apply() {
      DevTools.rpc("Settings.set", { key: "overrides", value: JSON.stringify(this.list) }).catch(() => {});
      DevTools.rpc("Settings.set", { key: "overridesEnabled", value: String(this.enabled) }).catch(() => {});
      const overrides = this.enabled ? this.list.filter((o) => o.enabled && o.url).map((o) => ({
        url: o.url, status: +o.status || 200, mimeType: o.mimeType || "", headers: this.parseHeaders(o.headersText),
        body: o.keepBody ? "" : (o.body || ""), keepBody: !!o.keepBody, enabled: true,
      })) : [];
      try {
        const result = await DevTools.rpc("Network.setOverrides", { overrides });
        this.status = `${result.active} override(s) active. Matching requests are answered by DevTools and never reach the server.`;
      } catch (e) {
        this.status = "⚠ " + e.message + ". Overrides are kept and applied when the debugger connection is available.";
      }
      this.render();
      return this.status;
    },

    add(init = {}) {
      this.list.push(Object.assign({ url: "", status: 200, mimeType: "", headersText: "", body: "", keepBody: false, enabled: true }, init));
      this.selected = this.list.length - 1;
      this.enabled = true;
      return this.apply();
    },
    remove(index) { this.list.splice(index, 1); this.selected = Math.max(0, Math.min(this.selected, this.list.length - 1)); return this.apply(); },

    render() {
      const nav = $("#overrides-list"), editor = $("#overrides-editor");
      if (!nav) return;
      $("#overrides-enabled").checked = this.enabled;
      $("#overrides-status").textContent = this.status;
      nav.textContent = ""; editor.textContent = "";
      if (!this.list.length) {
        nav.appendChild(h("div", { class: "empty-state" }, "No overrides. Click +, or right-click a request in the Network panel → Override content."));
        return;
      }
      this.list.forEach((o, i) => {
        const box = h("input", { type: "checkbox" });
        box.checked = o.enabled;
        box.addEventListener("click", (e) => e.stopPropagation());
        box.addEventListener("change", () => { o.enabled = box.checked; this.apply(); });
        const item = h("div", { class: "app-item override-item" + (i === this.selected ? " selected" : "") + (o.enabled ? "" : " off"), title: o.url }, box, " ", o.url ? fileName(o.url) : "(new override)");
        item.addEventListener("click", () => { this.selected = i; this.render(); });
        nav.appendChild(item);
      });
      const o = this.list[this.selected];
      if (!o) return;
      const field = (label, el) => h("label", { class: "form-row" }, h("span", { class: "form-label" }, label), el);
      const url = h("input", { type: "text", class: "mono", value: o.url, placeholder: "https://example.com/api/* — the whole URL, * is a wildcard" });
      const status = h("input", { type: "number", class: "mono", value: String(o.status || 200), min: "100", max: "599" });
      const mime = h("input", { type: "text", class: "mono", value: o.mimeType || "", placeholder: "application/json" });
      const headers = h("textarea", { class: "mono", rows: "3", placeholder: "Header-Name: value (one per line)" });
      headers.value = o.headersText || "";
      const keep = h("input", { type: "checkbox" });
      keep.checked = !!o.keepBody;
      const body = h("textarea", { class: "mono", rows: "8", placeholder: "Response body" });
      body.value = o.body || "";
      body.disabled = keep.checked;
      keep.addEventListener("change", () => { body.disabled = keep.checked; });
      const save = h("button", { class: "text-button" }, "Save");
      save.addEventListener("click", () => {
        Object.assign(o, { url: url.value.trim(), status: +status.value || 200, mimeType: mime.value.trim(), headersText: headers.value, body: body.value, keepBody: keep.checked });
        this.apply();
      });
      const del = h("button", { class: "text-button" }, "Delete");
      del.addEventListener("click", () => this.remove(this.selected));
      editor.append(
        field("URL", url), field("Status", status), field("Content-Type", mime), field("Headers", headers),
        h("label", { class: "form-row check" }, h("span", { class: "form-label" }, ""), keep, " Keep the original body (the app fetches it), override status and headers only"),
        field("Body", body),
        h("div", { class: "form-row" }, h("span", { class: "form-label" }, ""), save, " ", del));
    },

    initPane() {
      $("#overrides-enabled").addEventListener("change", (e) => { this.enabled = e.target.checked; this.apply(); });
      $("#overrides-add").addEventListener("click", () => this.add());
    },
  };

  Drawer.register("overrides", { title: "Local overrides", init: () => SBOverrides.initPane(), show: () => SBOverrides.render() });

  // ---- search across requests ---------------------------------------------------------------------
  // Chrome's ⌘F in Network: URLs, request and response headers, payloads and bodies.
  const SBNetSearch = window.SBNetSearch = {
    results: [],
    generation: 0,

    matcher(query, caseSensitive, regex) {
      if (regex) {
        try { const re = new RegExp(query, caseSensitive ? "g" : "gi"); return (text) => { re.lastIndex = 0; return re.exec(text); }; }
        catch (_) { return null; }
      }
      const needle = caseSensitive ? query : query.toLowerCase();
      return (text) => {
        const i = (caseSensitive ? text : text.toLowerCase()).indexOf(needle);
        return i < 0 ? null : { index: i, 0: text.substr(i, needle.length) };
      };
    },

    // Bodies the inspector protocol still holds are read once, on demand.
    async loadBodies(requests, generation) {
      const missing = requests.filter((r) => r.responseBody == null && r.protocolRequestID && !r.bodyRequested && !/^(image|font|media|websocket)$/.test(r.resourceType)).slice(0, 150);
      await Promise.all(missing.map(async (r) => {
        r.bodyRequested = true;
        try {
          const updated = await DevTools.rpc("Network.getResponseBody", { id: r.id });
          if (generation === this.generation && updated && updated.responseBody != null) {
            updated.bodyRequested = true;
            network.requests.set(updated.id, updated);
          }
        } catch (_) {}
      }));
    },

    async run(query, { caseSensitive = false, regex = false } = {}) {
      const generation = ++this.generation;
      this.results = [];
      if (!query) { this.render(query); return this.results; }
      const match = this.matcher(query, caseSensitive, regex);
      if (!match) { this.render(query, "Invalid regular expression"); return this.results; }
      await this.loadBodies(Array.from(network.requests.values()), generation);
      if (generation !== this.generation) return this.results;
      for (const id of network.order) {
        const r = network.requests.get(id);
        if (!r) continue;
        const hits = [];
        const test = (where, text, line) => {
          const m = match(text);
          if (!m) return;
          const start = Math.max(0, m.index - 60);
          hits.push({ where, line, text: (start ? "…" : "") + text.slice(start, m.index + m[0].length + 100), match: m[0] });
        };
        test("URL", r.url);
        for (const [k, v] of Object.entries(r.requestHeaders || {})) test("Request header", k + ": " + v);
        for (const [k, v] of Object.entries(r.responseHeaders || {})) test("Response header", k + ": " + v);
        if (r.requestBody) test("Payload", r.requestBody);
        if (r.responseBody && !r.responseBody.startsWith("data:")) {
          const lines = r.responseBody.split("\n");
          for (let i = 0; i < lines.length && hits.filter((x) => x.where === "Response").length < 10; i++) test("Response", lines[i], i + 1);
        }
        if (hits.length) this.results.push({ id: r.id, url: r.url, hits });
      }
      this.render(query);
      return this.results;
    },

    render(query, error) {
      const box = $("#netsearch-results");
      if (!box) return;
      box.textContent = "";
      const total = this.results.reduce((s, r) => s + r.hits.length, 0);
      $("#netsearch-count").textContent = error || (query ? `${total} match${total === 1 ? "" : "es"} in ${this.results.length} request${this.results.length === 1 ? "" : "s"}` : "");
      for (const result of this.results) {
        const group = h("div", { class: "search-group" });
        group.appendChild(h("div", { class: "search-file", title: result.url }, fileName(result.url), h("span", { class: "muted" }, "  " + result.url)));
        for (const hit of result.hits) {
          const text = h("span", { class: "mono" });
          const i = hit.text.indexOf(hit.match);
          text.append(hit.text.slice(0, i), h("mark", {}, hit.match), hit.text.slice(i + hit.match.length));
          const row = h("div", { class: "search-hit" }, h("span", { class: "search-where" }, hit.where + (hit.line ? " " + hit.line : "")), text);
          row.addEventListener("click", () => {
            DevTools.showPanel("network");
            if (network.session) network.closeSession();      // results are from the live log
            network.select(result.id);
            network.setDetailTab(hit.where === "Response" ? "response" : hit.where === "Payload" ? "payload" : "headers");
            network.renderDetail();
          });
          group.appendChild(row);
        }
        box.appendChild(group);
      }
    },

    initPane() {
      const input = $("#netsearch-input");
      const go = () => this.run(input.value, { caseSensitive: $("#netsearch-case").checked, regex: $("#netsearch-regex").checked });
      input.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); go(); } });
      input.addEventListener("input", debounce(go, 300));
      $("#netsearch-case").addEventListener("change", go);
      $("#netsearch-regex").addEventListener("change", go);
    },
  };

  Drawer.register("search", { title: "Search", init: () => SBNetSearch.initPane(), show: () => $("#netsearch-input").focus() });

  // ---- Copy as… and Copy for AI ---------------------------------------------------------------------------
  // Request headers worth showing an assistant; the rest are counted, not listed.
  const KEY_REQUEST_HEADERS = /^(content-type|content-length|accept|accept-language|authorization|cookie|origin|referer|cache-control|pragma|if-none-match|if-modified-since|range|x-requested-with|x-[\w-]+)$/i;
  const KEY_RESPONSE_HEADERS = /^(content-type|content-length|content-encoding|cache-control|expires|etag|last-modified|age|vary|location|set-cookie|server-timing|www-authenticate|retry-after|access-control-[\w-]+|content-security-policy|strict-transport-security|x-[\w-]+)$/i;

  // Long arrays and strings in a JSON body, cut so its shape survives truncation.
  function shrinkJSON(value, depth = 0) {
    if (Array.isArray(value)) {
      const kept = value.slice(0, depth > 3 ? 1 : 3).map((v) => shrinkJSON(v, depth + 1));
      if (value.length > kept.length) kept.push(`… ${value.length - kept.length} more items`);
      return kept;
    }
    if (value && typeof value === "object") {
      const out = {};
      const keys = Object.keys(value);
      for (const k of keys.slice(0, 40)) out[k] = shrinkJSON(value[k], depth + 1);
      if (keys.length > 40) out["…"] = `${keys.length - 40} more keys`;
      return out;
    }
    if (typeof value === "string" && value.length > 300) return value.slice(0, 300) + `… (${value.length} chars)`;
    return value;
  }

  // A body for Markdown: [text, fence language, note].
  function bodyForAI(text, mime, max) {
    if (text == null) return [null, "", "not captured"];
    if (SBNetPreview.Body.isDataURL(text)) return [null, "", `binary ${SBNetPreview.Body.parseDataURL(text).mime}, ${formatBytes(SBNetPreview.Body.byteLength(text))}; not included`];
    if (text === "") return [null, "", "empty"];
    const lang = Markdown.langFor(mime) || (SBNetPreview.tryParseJSON(text) !== undefined ? "json" : "");
    const json = lang === "json" ? SBNetPreview.tryParseJSON(text) : undefined;
    if (json !== undefined) {
      const full = JSON.stringify(json, null, 2);
      if (full.length <= max) return [full, "json", ""];
      const shrunk = JSON.stringify(shrinkJSON(json), null, 2);
      return [Markdown.truncate(shrunk, max), "json", `JSON, ${formatBytes(text.length)}; long arrays and strings shortened`];
    }
    if (text.length <= max) return [text, lang, ""];
    // Head and tail: errors often sit at the end of a long text.
    const head = text.slice(0, Math.floor(max * 0.8)), tail = text.slice(-Math.floor(max * 0.2));
    return [`${head}\n… (${(text.length - head.length - tail.length).toLocaleString()} characters omitted) …\n${tail}`, lang, `${mime || "text"}, ${formatBytes(text.length)}; middle omitted`];
  }

  function keyHeaders(headers, pattern) {
    const lines = [];
    let omitted = 0;
    for (const name of Object.keys(headers || {}).sort()) {
      if (!pattern.test(name)) { omitted++; continue; }
      const value = String(headers[name]);
      if (/^(cookie)$/i.test(name)) lines.push(`${name}: <${SBNet.parseCookieHeader(value).map((c) => c.name).join(", ")} — values redacted>`);
      else if (/^set-cookie$/i.test(name)) for (const c of SBNet.parseSetCookies(value)) lines.push(`${name}: ${c.name}=<redacted>${c.raw.slice(c.raw.indexOf(";")).replace(/^[^;]*$/, "")}`);
      else lines.push(`${name}: ${Markdown.SECRET_HEADERS.test(name) ? "<redacted>" : value}`);
    }
    return { text: lines.join("\n"), omitted };
  }

  Object.assign(network, {
    // One request as Markdown: what an assistant needs to reason about it,
    // key headers only, secrets redacted, the body truncated with its shape kept.
    asMarkdown(r, { maxBody = 4000 } = {}) {
      const method = (r.method || "GET").toUpperCase();
      const ext = this.ext(r);
      const statusText = r.statusCode != null ? `${r.statusCode} ${SBNet.statusText(r, ext)}`.trim() : r.failure ? `failed (${r.failure})` : "no status observed";
      const out = [`## ${method} ${r.url} → ${statusText}`, ""];
      const facts = [`type ${r.resourceType}`];
      if (r.mimeType) facts.push(r.mimeType);
      if (r.transferSize != null) facts.push(`${formatBytes(r.transferSize)} transferred`);
      if (r.bodySize != null) facts.push(`${formatBytes(r.bodySize)} resource`);
      if (r.duration != null) facts.push(`${formatMs(r.duration)}`);
      if (r.protocolName || ext.protocol) facts.push(r.protocolName || ext.protocol);
      if (ext.remoteAddress) facts.push(`remote ${ext.remoteAddress}`);
      if (ext.source && ext.source !== "network") facts.push(`served from ${ext.source}`);
      out.push("- " + facts.join(" · "));
      const issues = SBNet.issues(r);
      out.push(`- Issues: ${issues.length ? issues.map((i) => i.text).join("; ") : "none"}`);
      const initiator = ext.initiator && this.initiatorFrames(ext.initiator)[0];
      if (initiator) out.push(`- Initiator: ${r.initiator || ext.initiator.type} at ${initiator.functionName || "(anonymous)"} (${initiator.url}:${initiator.lineNumber})`);
      else if (r.initiator) out.push(`- Initiator: ${r.initiator}`);
      const t = r.timing;
      if (t && t.responseEnd > 0) {
        const phase = (a, b) => (b > a ? formatMs((b - a) / 1000) : "0");
        out.push(`- Timing: queued ${phase(0, t.domainLookupStart || t.connectStart || t.requestStart)} · DNS ${phase(t.domainLookupStart, t.domainLookupEnd)} · connect ${phase(t.connectStart, t.connectEnd)} · waiting (TTFB) ${phase(t.requestStart, t.responseStart)} · download ${phase(t.responseStart, t.responseEnd)}`);
      }
      const serverTiming = SBNet.parseServerTiming(SBNet.header(r.responseHeaders, "server-timing"));
      if (serverTiming.length) out.push(`- Server-Timing: ${serverTiming.map((e) => `${e.description || e.name} ${e.duration != null ? e.duration + " ms" : ""}`.trim()).join(", ")}`);
      if (r.startedAt) out.push(`- Started: ${new Date(r.startedAt).toISOString()}`);
      if (window.SBBlocking && r.failure && SBBlocking.matches(r.url)) out.push("- Blocked by a DevTools request blocking pattern");
      const section = (title, body, lang) => { out.push("", `### ${title}`, Markdown.fence(body, lang)); };
      const req = keyHeaders(r.requestHeaders, KEY_REQUEST_HEADERS);
      if (req.text) section(`Request headers (key${req.omitted ? `; ${req.omitted} more omitted` : ""})`, req.text, "http");
      if (r.requestBody != null) {
        const type = SBNet.header(r.requestHeaders, "content-type") || "";
        const [text, lang, note] = bodyForAI(r.requestBody, type, maxBody);
        if (text != null) section(`Request payload${note ? ` (${note})` : ""}`, text, lang);
      }
      const res = keyHeaders(r.responseHeaders, KEY_RESPONSE_HEADERS);
      if (res.text) section(`Response headers (key${res.omitted ? `; ${res.omitted} more omitted` : ""})`, res.text, "http");
      const [text, lang, note] = bodyForAI(r.responseBody, r.mimeType, maxBody);
      if (text != null) section(`Response body${note ? ` (${note})` : r.mimeType ? ` (${r.mimeType})` : ""}`, text, lang);
      else out.push("", "### Response body", `(${note})`);
      return out.join("\n");
    },

    // The whole log as a table, failures spelled out underneath.
    summaryMarkdown() {
      const all = this.all();
      const failed = all.filter((r) => r.failure || r.statusCode >= 400);
      const bytes = all.reduce((s, r) => s + (r.transferSize || 0), 0);
      const out = [`# Network log — ${this.session ? this.session.name : DevTools.info.url || ""}`, "",
        `${all.length} requests · ${formatBytes(bytes)} transferred · ${failed.length} failed`, "",
        Markdown.table(["#", "Method", "Status", "Type", "Size", "Time", "URL", "Issues"], all.slice(0, 300).map((r, i) => [
          i + 1, (r.method || "GET").toUpperCase(), r.statusCode ?? (r.failure ? "(failed)" : ""), r.resourceType,
          formatBytes(r.transferSize ?? r.bodySize), formatMs(r.duration), r.url, SBNet.issues(r).map((x) => x.kind).join(", ")]))];
      if (all.length > 300) out.push("", `… ${all.length - 300} more requests not listed`);
      if (failed.length) {
        out.push("", "## Failed requests");
        for (const r of failed.slice(0, 50)) out.push(`- ${(r.method || "GET").toUpperCase()} ${r.statusCode ?? ""} ${r.url}${r.failure ? " — " + r.failure : ""}`);
      }
      return out.join("\n");
    },

    // "Explain failures": every failed, blocked or slow request, each with the details to fix it.
    async failuresMarkdown() {
      const list = this.all().filter((r) => SBNet.issues(r).some((i) => i.failure));
      const out = [`# Failed, blocked and slow requests — ${this.session ? this.session.name : DevTools.info.url || ""}`, "",
        list.length ? `${list.length} of ${this.all().length} requests have a problem.` : "No failed, blocked or slow requests."];
      for (const r of list.slice(0, 20)) out.push("", this.asMarkdown(await this.withBody(r), { maxBody: 1500 }));
      if (list.length > 20) out.push("", `… ${list.length - 20} more not shown`);
      return out.join("\n");
    },

    async withBody(r) {
      if ((r.responseBody != null && !this.isTruncated(r)) || !r.protocolRequestID || r.imported) return r;
      try { const updated = await DevTools.rpc("Network.getResponseBody", { id: r.id }); this.requests.set(updated.id, updated); return updated; }
      catch (_) { return r; }
    },

    // Chrome's "Copy as fetch (Node.js)": every header, cookies included.
    asNodeFetch(r) {
      const init = { headers: Object.fromEntries(this.replayHeaders(r)) };
      if (r.requestBody != null) init.body = r.requestBody;
      init.method = (r.method || "GET").toUpperCase();
      return "fetch(" + JSON.stringify(r.url) + ", " + JSON.stringify(init, null, 2) + ");";
    },

    asPowerShell(r) {
      const q = (s) => '"' + String(s).replace(/[`"$]/g, "`$&").replace(/\r/g, "`r").replace(/\n/g, "`n") + '"';
      const lines = ["$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession"];
      const ua = SBNet.header(r.requestHeaders, "user-agent");
      if (ua) lines.push(`$session.UserAgent = ${q(ua)}`);
      const args = [`Invoke-WebRequest -UseBasicParsing -Uri ${q(r.url)}`];
      const method = (r.method || "GET").toUpperCase();
      if (method !== "GET") args.push(`-Method ${q(method)}`);
      args.push("-WebSession $session");
      const headers = this.replayHeaders(r).filter(([k]) => !/^(user-agent|content-type)$/i.test(k));
      if (headers.length) args.push("-Headers @{\n" + headers.map(([k, v]) => `  ${q(k)}=${q(v)}`).join("\n") + "\n}");
      const type = SBNet.header(r.requestHeaders, "content-type");
      if (type) args.push(`-ContentType ${q(type)}`);
      if (r.requestBody != null) args.push(`-Body ${q(r.requestBody)}`);
      lines.push(args.join(" `\n"));
      return lines.join("\n");
    },

    // One request as a HAR 1.2 entry, the shape the app's exporter writes.
    harEntry(r) {
      const list = (headers) => Object.keys(headers || {}).sort().flatMap((name) => String(headers[name]).split(/^set-cookie$/i.test(name) ? "\n" : /$^/).map((value) => ({ name, value })));
      const t = r.timing;
      const phase = (a, b) => (t && a > 0 && b > 0 && b >= a ? b - a : -1);
      let query = [];
      try { query = Array.from(new URL(r.url).searchParams.entries()).map(([name, value]) => ({ name, value })); } catch (_) {}
      const body = r.responseBody;
      const isBinary = body != null && SBNetPreview.Body.isDataURL(body);
      const entry = {
        startedDateTime: new Date(r.startedAt || Date.now()).toISOString(),
        time: (r.duration || 0) * 1000,
        request: {
          method: (r.method || "GET").toUpperCase(), url: r.url, httpVersion: r.protocolName || "", cookies: SBNet.parseCookieHeader(SBNet.header(r.requestHeaders, "cookie")),
          headers: list(r.requestHeaders), queryString: query, headersSize: -1, bodySize: r.requestBody != null ? SBNetPreview.Body.byteLength(r.requestBody) : -1,
        },
        response: {
          status: r.statusCode || 0, statusText: SBNet.statusText(r, this.ext(r)), httpVersion: r.protocolName || "",
          cookies: SBNet.parseSetCookies(SBNet.header(r.responseHeaders, "set-cookie")).map((c) => ({ name: c.name, value: c.value, path: c.path || undefined, domain: c.domain || undefined, expires: c.expires || undefined, httpOnly: c.httpOnly, secure: c.secure, sameSite: c.sameSite || undefined })),
          headers: list(r.responseHeaders), redirectURL: SBNet.header(r.responseHeaders, "location") || "", headersSize: -1, bodySize: r.bodySize ?? -1,
          content: Object.assign({ size: r.bodySize ?? -1, mimeType: r.mimeType || "" }, body == null ? {} : isBinary ? { text: SBNetPreview.Body.base64(body) || "", encoding: "base64" } : { text: body }),
        },
        cache: {},
        timings: { blocked: t ? phase(t.fetchStart || 0.0001, t.domainLookupStart || t.connectStart || t.requestStart) : -1, dns: phase(t?.domainLookupStart, t?.domainLookupEnd), connect: phase(t?.connectStart, t?.connectEnd), ssl: phase(t?.secureConnectionStart, t?.connectEnd), send: 0, wait: phase(t?.requestStart, t?.responseStart), receive: phase(t?.responseStart, t?.responseEnd) },
        _resourceType: r.resourceType,
      };
      if (r.requestBody != null) entry.request.postData = { mimeType: SBNet.header(r.requestHeaders, "content-type") || "", text: r.requestBody };
      if (this.ext(r).remoteAddress) entry.serverIPAddress = String(this.ext(r).remoteAddress).replace(/:\d+$/, "");
      if (r.initiator) entry._initiator = { type: r.initiator };
      if (r.failure) entry._error = r.failure;
      return entry;
    },

    harFromRequests(list) {
      return { log: { version: "1.2", creator: { name: "SimpleBrowser", version: "0.1" }, pages: [], entries: list.map((r) => this.harEntry(r)) } };
    },

    allAsCurl() { return this.visibleRequests().map((r) => this.asCurl(r)).join(" ;\n"); },

    blockDomainPattern(url) { try { return new URL(url).host; } catch (_) { return url; } },
    blockURLPattern(url) { try { const u = new URL(url); return u.host + u.pathname + u.search; } catch (_) { return url; } },

    async overrideFrom(r, keepBody) {
      const full = await this.withBody(r);
      // Headers the engine recomputes for the body it is given are left out.
      const headersText = keepBody ? Object.entries(r.responseHeaders || {})
        .filter(([k]) => !/^(content-length|content-encoding|transfer-encoding|content-type)$/i.test(k))
        .map(([k, v]) => k + ": " + v).join("\n") : "";
      await SBOverrides.add({
        url: r.url.split("#")[0], status: r.statusCode || 200, mimeType: r.mimeType || "",
        headersText, keepBody, body: keepBody ? "" : (full.responseBody && !full.responseBody.startsWith("data:") ? full.responseBody : ""),
      });
      Drawer.show("overrides");
    },
  });

  // Chrome's Copy submenu: this request in every form, then the whole log.
  const baseCopyItems = network.copyItems;
  network.copyItems = function (r) {
    const items = baseCopyItems.call(this, r);
    const at = items.findIndex((i) => i.label === "Copy as fetch") + 1;
    items.splice(at, 0,
      { label: "Copy as fetch (Node.js)", action: () => copy(this.asNodeFetch(r)) },
      { label: "Copy as PowerShell", action: () => copy(this.asPowerShell(r)) });
    items.push(
      { label: "Copy as HAR entry", action: async () => copy(JSON.stringify(this.harEntry(await this.withBody(r)), null, 2)) },
      { label: "Copy as Markdown (for AI)", action: async () => copy(this.asMarkdown(await this.withBody(r))) },
      "-",
      { label: "Copy all URLs", action: () => copy(this.visibleRequests().map((x) => x.url).join("\n")) },
      { label: "Copy all as cURL", action: () => copy(this.allAsCurl()) },
      { label: "Copy all as HAR", action: async () => {
        if (this.session) { copy(JSON.stringify(this.harFromRequests(this.all()), null, 2)); return; }
        try { copy(await DevTools.rpc("Network.getHAR")); } catch (e) { note("error", e.message); }
      } },
      { label: "Copy all as Markdown summary", action: () => copy(this.summaryMarkdown()) },
      { label: "Copy failures for AI (Markdown)", action: async () => copy(await this.failuresMarkdown()) });
    return items;
  };

  const baseContextItems = network.contextItems;
  network.contextItems = function (r) {
    const items = baseContextItems.call(this, r);
    if (r.imported) return items;
    items.push("-",
      { label: "Block request URL", action: () => { SBBlocking.add(this.blockURLPattern(r.url)); Drawer.show("blocking"); } },
      { label: "Block request domain", action: () => { SBBlocking.add(this.blockDomainPattern(r.url)); Drawer.show("blocking"); } },
      { label: "Override content…", action: () => this.overrideFrom(r, false) },
      { label: "Override headers…", action: () => this.overrideFrom(r, true) });
    return items;
  };

  // ⌘F: in the response pane, find in it; anywhere else in Network, search every request.
  document.addEventListener("keydown", (e) => {
    if ((e.metaKey || e.ctrlKey) && !e.shiftKey && e.key === "f" && DevTools.activePanel === "network") {
      e.preventDefault();
      const inDetail = network.selectedId && (network.pointerInDetail || (document.activeElement && document.activeElement.closest && document.activeElement.closest("#network-detail")));
      if (inDetail && network.findInDetail()) return;
      Drawer.show("search");
    }
  });

  window.SBNetworkTools = {
    start() { SBBlocking.start(); SBOverrides.start(); },
  };
})();
