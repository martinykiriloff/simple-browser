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

  // ---- Copy for AI -----------------------------------------------------------------------------------------
  Object.assign(network, {
    // One request as Markdown: what an assistant needs to reason about it,
    // secrets redacted, the body truncated.
    asMarkdown(r, { maxBody = 4000 } = {}) {
      const status = r.statusCode != null ? String(r.statusCode) : (r.failure ? "failed: " + r.failure : "unknown");
      const out = [`## ${(r.method || "GET").toUpperCase()} ${status} ${r.url}`, ""];
      const facts = [`Type: ${r.resourceType}`];
      if (r.mimeType) facts.push(`MIME: ${r.mimeType}`);
      if (r.transferSize != null || r.bodySize != null) facts.push(`Size: ${formatBytes(r.transferSize ?? r.bodySize)}`);
      if (r.duration != null) facts.push(`Time: ${formatMs(r.duration)}`);
      if (r.protocolName) facts.push(`Protocol: ${r.protocolName}`);
      if (r.initiator) facts.push(`Initiator: ${r.initiator}`);
      out.push("- " + facts.join(" · "));
      if (r.startedAt) out.push(`- Started: ${new Date(r.startedAt).toISOString()}`);
      if (window.SBBlocking && r.failure && SBBlocking.matches(r.url)) out.push("- Blocked by a DevTools request blocking pattern");
      const section = (title, body, lang) => { out.push("", `### ${title}`, Markdown.fence(body, lang)); };
      if (Object.keys(r.requestHeaders || {}).length) section("Request headers", Markdown.headers(r.requestHeaders), "http");
      if (r.requestBody != null) {
        const type = Object.entries(r.requestHeaders || {}).find(([k]) => k.toLowerCase() === "content-type")?.[1] || "";
        section("Request payload", Markdown.truncate(tryPrettyJSON(r.requestBody) || r.requestBody, maxBody), Markdown.langFor(type) || (tryPrettyJSON(r.requestBody) ? "json" : ""));
      }
      if (Object.keys(r.responseHeaders || {}).length) section("Response headers", Markdown.headers(r.responseHeaders), "http");
      if (r.responseBody != null && !r.responseBody.startsWith("data:")) {
        const pretty = tryPrettyJSON(r.responseBody);
        section(`Response body${r.responseBody.length > maxBody ? ` (first ${maxBody} characters)` : ""}`, Markdown.truncate(pretty || r.responseBody, maxBody), Markdown.langFor(r.mimeType) || (pretty ? "json" : ""));
      } else if (r.responseBody != null) {
        out.push("", "### Response body", `(binary, ${r.mimeType || "image"}; not included)`);
      } else {
        out.push("", "### Response body", "(not captured)");
      }
      return out.join("\n");
    },

    // The whole log as a table, failures spelled out underneath.
    summaryMarkdown() {
      const all = this.order.map((id) => this.requests.get(id)).filter(Boolean);
      const failed = all.filter((r) => r.failure || r.statusCode >= 400);
      const bytes = all.reduce((s, r) => s + (r.transferSize || 0), 0);
      const out = [`# Network log — ${DevTools.info.url || ""}`, "",
        `${all.length} requests · ${formatBytes(bytes)} transferred · ${failed.length} failed`, "",
        Markdown.table(["#", "Method", "Status", "Type", "Size", "Time", "URL"], all.slice(0, 300).map((r, i) => [
          i + 1, (r.method || "GET").toUpperCase(), r.statusCode ?? (r.failure ? "(failed)" : ""), r.resourceType,
          formatBytes(r.transferSize ?? r.bodySize), formatMs(r.duration), r.url]))];
      if (all.length > 300) out.push("", `… ${all.length - 300} more requests not listed`);
      if (failed.length) {
        out.push("", "## Failed requests");
        for (const r of failed.slice(0, 50)) out.push(`- ${(r.method || "GET").toUpperCase()} ${r.statusCode ?? ""} ${r.url}${r.failure ? " — " + r.failure : ""}`);
      }
      return out.join("\n");
    },

    async withBody(r) {
      if (r.responseBody != null || !r.protocolRequestID) return r;
      try { const updated = await DevTools.rpc("Network.getResponseBody", { id: r.id }); this.requests.set(updated.id, updated); return updated; }
      catch (_) { return r; }
    },

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

  const originalCopyItems = network.copyItems;
  network.copyItems = function (r) {
    const items = originalCopyItems.call(this, r);
    items.push("-",
      { label: "Copy as Markdown (for AI)", action: async () => copy(this.asMarkdown(await this.withBody(r))) },
      { label: "Copy all as Markdown summary", action: () => copy(this.summaryMarkdown()) },
      { label: "Copy all as HAR", action: async () => { try { copy(await DevTools.rpc("Network.getHAR")); } catch (e) { note("error", e.message); } } },
      "-",
      { label: "Block request URL", action: () => { SBBlocking.add(this.blockURLPattern(r.url)); Drawer.show("blocking"); } },
      { label: "Block request domain", action: () => { SBBlocking.add(this.blockDomainPattern(r.url)); Drawer.show("blocking"); } },
      { label: "Override content…", action: () => this.overrideFrom(r, false) },
      { label: "Override headers…", action: () => this.overrideFrom(r, true) });
    return items;
  };

  document.addEventListener("keydown", (e) => {
    if ((e.metaKey || e.ctrlKey) && !e.shiftKey && e.key === "f" && DevTools.activePanel === "network") {
      e.preventDefault();
      Drawer.show("search");
    }
  });

  window.SBNetworkTools = {
    start() { SBBlocking.start(); SBOverrides.start(); },
  };
})();
