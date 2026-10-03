// Keel DevTools — PHP: the server side of each request, for Laravel
// and any PHP app with Clockwork or Laravel Debugbar installed (they mark
// responses with X-Clockwork-Id / phpdebugbar-id; the profile is fetched by
// the app, with the page's cookies). Overview, database queries with N+1
// detection, logs, timeline, views, and the Xdebug triggers the "Xdebug
// helper" extensions set: debug, profile and trace cookies for this site.
"use strict";

(function () {
  const header = (headers, name) => {
    for (const k of Object.keys(headers || {})) if (k.toLowerCase() === name) return headers[k];
    return null;
  };
  const ms = (v) => v == null || isNaN(v) ? "—" : v >= 1000 ? (v / 1000).toFixed(2) + " s" : (Math.round(v * 10) / 10) + " ms";

  /// Clockwork's and Debugbar's shapes, read into one.
  function normalizeClockwork(d) {
    const queries = (d.databaseQueries || []).map((q) => ({ sql: q.query, ms: q.duration, connection: q.connection, file: q.file, line: q.line, model: q.model }));
    return {
      tool: "Clockwork", method: d.method, uri: d.uri, controller: d.controller, status: d.responseStatus,
      duration: d.responseDuration, memory: d.memoryUsage, time: d.time ? new Date(d.time * 1000) : null,
      queries, dbTime: d.databaseDuration ?? queries.reduce((s, q) => s + (q.ms || 0), 0),
      logs: (d.log || []).map((l) => ({ level: l.level, message: l.message, context: l.context, file: l.file, line: l.line })),
      timeline: Object.values(d.timelineData || {}).map((t) => ({ label: t.description || t.name, start: t.start, end: t.end, ms: t.duration })),
      views: (d.viewsData || []).map((v) => ({ name: v.data ? v.data.name || v.description : v.description, data: v.data })),
      events: d.events || [], cache: d.cacheQueries || [], session: d.sessionData, auth: d.authenticatedUser, route: d.routes,
      raw: d,
    };
  }
  function normalizeDebugbar(d) {
    const statements = (d.queries && d.queries.statements) || [];
    const parseMs = (s) => s == null ? null : typeof s === "number" ? s * 1000 : /ms/.test(s) ? parseFloat(s) : /μs|us/.test(s) ? parseFloat(s) / 1000 : parseFloat(s) * 1000;
    return {
      tool: "Laravel Debugbar", method: d.__meta && d.__meta.method, uri: d.__meta && d.__meta.uri, controller: d.route && (d.route.controller || d.route.uses),
      status: null, duration: d.time && parseMs(d.time.duration), memory: d.memory && d.memory.peak_usage, memoryText: d.memory && d.memory.peak_usage_str,
      time: d.__meta && d.__meta.datetime ? new Date(d.__meta.datetime) : null,
      queries: statements.map((q) => ({ sql: q.sql, ms: parseMs(q.duration), connection: q.connection, file: q.backtrace && q.backtrace[0] && q.backtrace[0].name, line: q.backtrace && q.backtrace[0] && q.backtrace[0].line })),
      dbTime: d.queries && parseMs(d.queries.accumulated_duration),
      logs: ((d.messages && d.messages.messages) || []).map((m) => ({ level: m.label, message: m.message })).concat(((d.exceptions && d.exceptions.exceptions) || []).map((e) => ({ level: "exception", message: e.type + ": " + e.message, file: e.file, line: e.line }))),
      timeline: ((d.time && d.time.measures) || []).map((t) => ({ label: t.label, start: t.relative_start * 1000, end: (t.relative_start + t.duration) * 1000, ms: t.duration * 1000 })),
      views: ((d.views && d.views.templates) || []).map((v) => ({ name: v.name, data: v.params })),
      events: (d.event && d.event.measures) || [], cache: (d.cache && d.cache.measures) || [], session: d.session, auth: d.auth, route: d.route,
      raw: d,
    };
  }

  const panel = {
    initialized: false,
    requests: [],
    profiles: new Map(),
    selected: null,
    tab: "overview",
    xdebug: {},

    init() {
      $("#php-refresh").addEventListener("click", () => this.refresh());
      for (const b of $$("#php-xdebug button")) b.addEventListener("click", () => this.toggleXdebug(b.dataset.mode));
      const key = $("#php-idekey");
      try { key.value = localStorage.getItem("devtools.xdebugKey") || "PHPSTORM"; } catch (_) { key.value = "PHPSTORM"; }
      key.addEventListener("change", () => { try { localStorage.setItem("devtools.xdebugKey", key.value); } catch (_) {} });
    },

    show() { this.refresh(); },

    async refresh() {
      try { this.xdebug = await DevTools.rpc("PHP.xdebug"); } catch (_) { this.xdebug = {}; }
      for (const b of $$("#php-xdebug button")) b.classList.toggle("active", !!this.xdebug[b.dataset.mode]);
      $("#php-host").textContent = this.xdebug.host ? "for " + this.xdebug.host : "";
      let all = [];
      try { all = await DevTools.rpc("Network.getRequests"); } catch (_) {}
      this.requests = all.filter((r) => header(r.responseHeaders, "x-clockwork-id") || header(r.responseHeaders, "phpdebugbar-id"));
      this.renderList();
      if (!this.selected && this.requests.length) this.select(this.requests[this.requests.length - 1]);
    },

    async toggleXdebug(mode) {
      const on = !this.xdebug[mode];
      try { this.xdebug = await DevTools.rpc("PHP.setXdebug", { mode, on, ideKey: $("#php-idekey").value }); }
      catch (e) { Toast.show(e.message); return; }
      for (const b of $$("#php-xdebug button")) b.classList.toggle("active", !!this.xdebug[b.dataset.mode]);
      Toast.show(`Xdebug ${mode} ${on ? "on" : "off"} for ${this.xdebug.host || "this site"} — reload to apply`);
    },

    renderList() {
      const list = $("#php-list");
      list.textContent = "";
      if (!this.requests.length) {
        list.appendChild(SBExt.empty("No PHP profiles on this page yet.",
          "Install Clockwork (composer require itsgoingd/clockwork) or Laravel Debugbar (composer require barryvdh/laravel-debugbar --dev) in the app, then reload.",
          "The Xdebug buttons above work without either: they set XDEBUG_SESSION / XDEBUG_PROFILE / XDEBUG_TRACE for this site, like the Xdebug helper extensions."));
        $("#php-detail").textContent = "";
        return;
      }
      for (const r of this.requests.slice().reverse()) {
        const profile = this.profiles.get(r.id);
        const path = (() => { try { const u = new URL(r.url); return u.pathname + u.search; } catch (_) { return r.url; } })();
        const row = h("div", { class: "php-row" + (this.selected === r.id ? " selected" : "") },
          h("span", { class: "php-method" }, r.method || "GET"),
          h("span", { class: "php-status " + ((r.statusCode || 0) >= 400 ? "bad" : "") }, String(r.statusCode ?? "")),
          h("span", { class: "php-path mono" }, path),
          h("span", { class: "muted" }, profile && profile.queries ? `${profile.queries.length} queries · ${ms(profile.duration)}` : ms(r.duration != null ? r.duration * 1000 : null)));
        row.addEventListener("click", () => this.select(r));
        list.appendChild(row);
      }
    },

    async select(r) {
      this.selected = r.id;
      this.renderList();
      const detail = $("#php-detail");
      let profile = this.profiles.get(r.id);
      if (!profile) {
        detail.textContent = "Loading the profile…";
        try {
          const origin = new URL(r.url).origin;
          const clockwork = header(r.responseHeaders, "x-clockwork-id");
          if (clockwork) {
            const base = header(r.responseHeaders, "x-clockwork-path") || "/__clockwork/";
            const res = await DevTools.rpc("PHP.fetch", { url: origin + base + encodeURIComponent(clockwork) + "/extended" });
            let data;
            try { data = JSON.parse(res.text); } catch (_) {
              const plain = await DevTools.rpc("PHP.fetch", { url: origin + base + encodeURIComponent(clockwork) });
              data = JSON.parse(plain.text);
            }
            profile = normalizeClockwork(Array.isArray(data) ? data[0] : data);
          } else {
            const id = header(r.responseHeaders, "phpdebugbar-id");
            const res = await DevTools.rpc("PHP.fetch", { url: origin + "/_debugbar/open?op=get&id=" + encodeURIComponent(id) });
            profile = normalizeDebugbar(JSON.parse(res.text));
          }
          this.profiles.set(r.id, profile);
          this.renderList();
        } catch (e) {
          detail.textContent = "";
          detail.appendChild(SBExt.empty("Could not load the profile.", e.message, "Clockwork keeps a limited history; reload the page to profile again."));
          return;
        }
      }
      this.renderDetail(profile);
    },

    renderDetail(p) {
      const detail = $("#php-detail");
      detail.textContent = "";
      const duplicates = this.duplicates(p.queries);
      const tabs = [["overview", "Overview"], ["database", `Database (${p.queries.length})`], ["logs", `Logs (${p.logs.length})`], ["timeline", "Timeline"], ["views", `Views (${p.views.length})`], ["raw", "Raw"]];
      const bar = h("div", { class: "subtabs php-tabs" }, ...tabs.map(([id, label]) => {
        const b = h("button", { class: "subtab" + (this.tab === id ? " active" : "") }, label);
        b.addEventListener("click", () => { this.tab = id; this.renderDetail(p); });
        return b;
      }), h("span", { class: "toolbar-spacer" }), (() => {
        const copy = h("button", { class: "text-button", title: "Copy this request's server profile as Markdown" }, "Copy for AI");
        copy.addEventListener("click", () => SBExt.copy(this.markdown(p, duplicates), "Profile copied"));
        return copy;
      })());
      const body = h("div", { class: "scroll php-body" });
      detail.append(bar, body);
      switch (this.tab) {
        case "overview": {
          const kv = (k, v) => v == null || v === "" ? null : h("div", { class: "kv" }, h("span", { class: "k" }, k), h("span", { class: "v mono selectable" }, String(v)));
          body.append(kv("Profiler", p.tool), kv("Request", `${p.method || ""} ${p.uri || ""}`), kv("Controller", p.controller), kv("Status", p.status),
            kv("Duration", ms(p.duration)), kv("Database", `${p.queries.length} queries in ${ms(p.dbTime)}`), kv("Memory", p.memoryText || (p.memory ? (p.memory / 1048576).toFixed(1) + " MB" : null)),
            kv("Time", p.time && p.time.toLocaleString()), kv("User", p.auth && (p.auth.email || p.auth.name || p.auth.id)));
          if (duplicates.length) body.appendChild(h("div", { class: "php-warning" }, `Possible N+1: ${duplicates.length} query shape${duplicates.length === 1 ? "" : "s"} repeated — see Database.`));
          const errors = p.logs.filter((l) => /error|critical|alert|emergency|exception/i.test(l.level || ""));
          if (errors.length) body.appendChild(h("div", { class: "php-warning bad" }, `${errors.length} error log entr${errors.length === 1 ? "y" : "ies"} — see Logs.`));
          break;
        }
        case "database": {
          const slow = new Set(p.queries.slice().sort((a, b) => (b.ms || 0) - (a.ms || 0)).slice(0, 3).filter((q) => (q.ms || 0) > 5));
          const dupShapes = new Map(duplicates.map((d) => [d.shape, d.count]));
          const table = h("table", { class: "data-table php-queries" }, h("thead", {}, h("tr", {}, h("th", {}, "Query"), h("th", { style: "width:80px" }, "Time"), h("th", { style: "width:200px" }, "Where"))));
          const tb = h("tbody");
          for (const q of p.queries) {
            const shape = this.shape(q.sql);
            tb.appendChild(h("tr", { class: (slow.has(q) ? "php-slow " : "") + (dupShapes.has(shape) ? "php-dup" : "") },
              h("td", { class: "mono selectable php-sql" }, q.sql, dupShapes.has(shape) ? h("span", { class: "php-badge" }, "×" + dupShapes.get(shape)) : null),
              h("td", { class: "mono" }, ms(q.ms)),
              h("td", { class: "mono muted" }, q.file ? `${String(q.file).split("/").slice(-2).join("/")}:${q.line ?? ""}` : (q.connection || ""))));
          }
          table.appendChild(tb);
          body.append(h("div", { class: "muted php-summary" }, `${p.queries.length} queries · ${ms(p.dbTime)}${duplicates.length ? ` · ${duplicates.length} repeated shape(s) highlighted` : ""}`), table);
          break;
        }
        case "logs":
          if (!p.logs.length) body.appendChild(SBExt.empty("Nothing was logged."));
          for (const l of p.logs) {
            body.appendChild(h("div", { class: "php-log php-" + String(l.level || "info").toLowerCase() },
              h("span", { class: "php-level" }, l.level || "log"), h("span", { class: "mono selectable" }, typeof l.message === "string" ? l.message : JSON.stringify(l.message)),
              l.file ? h("span", { class: "muted mono" }, ` ${String(l.file).split("/").pop()}:${l.line ?? ""}`) : null));
          }
          break;
        case "timeline": {
          const items = p.timeline.filter((t) => t.ms != null);
          if (!items.length) { body.appendChild(SBExt.empty("No timeline was recorded.")); break; }
          const start = Math.min(...items.map((t) => t.start ?? 0)), end = Math.max(...items.map((t) => (t.end ?? (t.start + t.ms)))) || 1;
          for (const t of items) {
            const left = ((t.start ?? start) - start) / (end - start) * 100, width = Math.max(0.5, (t.ms / ((end - start) || 1)) * 100);
            body.appendChild(h("div", { class: "timing-row" }, h("span", { class: "label" }, t.label), h("div", { class: "bar-wrap" }, h("div", { class: "bar wf-wait", style: `left:${left}%;width:${width}%` })), h("span", { class: "ms" }, ms(t.ms))));
          }
          break;
        }
        case "views":
          if (!p.views.length) body.appendChild(SBExt.empty("No views were rendered."));
          for (const v of p.views) body.appendChild(h("div", { class: "php-view" }, h("div", { class: "mono" }, v.name || "(view)"), v.data ? SBExt.tree(v.data, 0) : null));
          break;
        default:
          body.appendChild(SBExt.tree(p.raw, 1));
      }
    },

    /// A query with its literals replaced: the same shape many times in one request is the N+1 signature.
    shape(sql) {
      return String(sql || "").replace(/'(?:[^'\\]|\\.)*'/g, "?").replace(/\b\d+(\.\d+)?\b/g, "?").replace(/\(\s*\?(\s*,\s*\?)*\s*\)/g, "(?)").replace(/\s+/g, " ").trim();
    },
    duplicates(queries) {
      const counts = new Map();
      for (const q of queries) { const s = this.shape(q.sql); counts.set(s, (counts.get(s) || 0) + 1); }
      return Array.from(counts).filter(([, n]) => n >= 3).map(([shape, count]) => ({ shape, count })).sort((a, b) => b.count - a.count);
    },

    markdown(p, duplicates) {
      const out = [`## ${p.method || ""} ${p.uri || ""} — server profile (${p.tool})`, "",
        `- Controller: ${p.controller || "?"}`, `- Duration: ${ms(p.duration)}`, `- Database: ${p.queries.length} queries, ${ms(p.dbTime)}`];
      if (duplicates.length) { out.push("", "### Repeated query shapes (possible N+1)"); for (const d of duplicates.slice(0, 5)) out.push(`- ×${d.count}: \`${d.shape.slice(0, 300)}\``); }
      const slow = p.queries.slice().sort((a, b) => (b.ms || 0) - (a.ms || 0)).slice(0, 5);
      if (slow.length) { out.push("", "### Slowest queries"); for (const q of slow) out.push(`- ${ms(q.ms)} \`${String(q.sql).slice(0, 400)}\`${q.file ? ` (${q.file}:${q.line})` : ""}`); }
      const errors = p.logs.filter((l) => /error|critical|exception/i.test(l.level || ""));
      if (errors.length) { out.push("", "### Errors"); for (const l of errors.slice(0, 10)) out.push(`- [${l.level}] ${typeof l.message === "string" ? l.message : JSON.stringify(l.message)}`); }
      return out.join("\n");
    },
  };

  DevTools.register("php", panel);
  window.SBPHP = panel;
})();
