// Keel DevTools — Audits panel: Lighthouse-style checks for
// accessibility, SEO, best practices and performance, scored per category.
// DOM checks run in the isolated world (tools-agent.js); network, console and
// vitals checks use what DevTools already recorded. Every finding links to its
// node in Elements or its request in Network, and the report exports as JSON
// or Markdown for agents.
"use strict";

(function () {
  const CATEGORIES = [
    ["performance", "Performance"], ["accessibility", "Accessibility"], ["bestPractices", "Best practices"], ["seo", "SEO"],
  ];

  // Lighthouse-like metric curve: 1 at zero, 0.9 at "good", 0.5 at "poor", falling after.
  function metricScore(value, good, poor) {
    if (value == null) return null;
    if (value <= good) return 1 - 0.1 * (value / good);
    if (value <= poor) return 0.9 - 0.4 * ((value - good) / (poor - good));
    return Math.max(0, 0.5 * (poor / value) - 0.05);
  }
  const ms = (v) => v == null ? "—" : v >= 1000 ? (v / 1000).toFixed(1) + " s" : Math.round(v) + " ms";

  const panel = {
    initialized: false,
    report: null,
    running: false,
    expanded: new Set(),

    init() {
      $("#audits-run").addEventListener("click", () => this.run({ reload: $("#audits-reload").checked }).catch(() => {}));
      $("#audits-copy-md").addEventListener("click", () => this.report && DevTools.rpc("Clipboard.write", { text: this.markdown() }));
      $("#audits-copy-json").addEventListener("click", () => this.report && DevTools.rpc("Clipboard.write", { text: this.json() }));
      $("#audits-save").addEventListener("click", () => this.report && DevTools.rpc("DevTools.saveFile", { name: this.fileName("json"), text: this.json() }));
      $("#audits-save-md").addEventListener("click", () => this.report && DevTools.rpc("DevTools.saveFile", { name: this.fileName("md"), text: this.markdown() }));
      this.render();
    },

    fileName(ext) {
      let host = "page";
      try { host = new URL(this.report.url).host; } catch (_) {}
      return `audit-${host}-${this.report.fetchedAt.slice(0, 19).replace(/[:T]/g, "-")}.${ext}`;
    },

    async run({ reload = false } = {}) {
      if (this.running) return this.report;
      this.running = true;
      $("#audits-run").disabled = true;
      const status = $("#audits-status");
      try {
        if (reload) {
          status.textContent = "Reloading the page…";
          await DevTools.rpc("Page.reload");
          await new Promise((r) => setTimeout(r, 3500));
        }
        status.textContent = "Auditing…";
        const dom = await DevTools.rpc("Audit.run");
        const extra = await this.collect();
        this.report = this.build(dom, extra);
        status.textContent = "";
        this.render();
        return this.report;
      } catch (e) {
        status.textContent = "Audit failed: " + e.message;
        throw e;
      } finally {
        this.running = false;
        $("#audits-run").disabled = false;
      }
    },

    // What the other panels recorded: requests, console messages, vitals.
    async collect() {
      const requests = Array.from(DevTools.panels.network.requests.values());
      let consoleItems = DevTools.panels.console.initialized ? DevTools.panels.console.entries.map((i) => i.entry) : null;
      if (!consoleItems) { try { consoleItems = (await DevTools.rpc("Console.getEntries")).map((i) => i.entry); } catch (_) { consoleItems = []; } }
      let perf = [];
      try {
        const list = await DevTools.rpc("Performance.getEntries");
        let start = 0;
        list.forEach((item, i) => { if (item.kind === "navigation" && item.phase === "started") start = i; });
        perf = list.slice(start).filter((i) => i.kind === "performance").map((i) => i.entry);
      } catch (_) {}
      return { requests, consoleItems, perf };
    },

    build(dom, { requests, consoleItems, perf }) {
      const requestItem = (r, detail) => ({ requestId: r.id, url: r.url, detail: detail || "" });
      const byUrl = (url) => requests.find((r) => r.url === url);
      const doc = requests.find((r) => r.resourceType === "document");

      // ---- performance ----
      const by = (type) => perf.filter((e) => e.entryType === type);
      const fcp = by("paint").find((e) => e.name === "first-contentful-paint")?.startTime;
      const lcpList = by("largest-contentful-paint");
      const lcp = lcpList.length ? lcpList[lcpList.length - 1].startTime : null;
      const shifts = by("layout-shift").filter((e) => !(e.detail || "").includes("had recent input"));
      const cls = shifts.reduce((s, e) => s + (e.value || 0), 0);
      const tasks = by("longtask");
      const tbt = tasks.reduce((s, t) => s + Math.max(0, t.duration - 50), 0);
      const interactions = [...by("first-input"), ...by("event")];
      const inp = interactions.length ? Math.max(...interactions.map((e) => e.duration)) : null;
      const ttfb = doc && doc.timing && doc.timing.responseStart > 0 ? doc.timing.responseStart : null;
      const metric = (id, title, value, good, poor, weight, display, description) => {
        const score = metricScore(value, good, poor);
        return { id, title, description, weight, score, passed: score != null && score >= 0.9, notApplicable: value == null, displayValue: display, items: [], numericValue: value };
      };
      const perfAudits = [
        metric("first-contentful-paint", "First Contentful Paint", fcp, 1800, 3000, 10, ms(fcp), "When the first text or image is painted."),
        metric("largest-contentful-paint", "Largest Contentful Paint", lcp, 2500, 4000, 25, ms(lcp), "When the largest text or image is painted."),
        metric("total-blocking-time", "Total Blocking Time", tasks.length || fcp != null ? tbt : null, 200, 600, 30, ms(tbt), "Sum of the time over 50 ms of every long task: how long the main thread could not answer input."),
        metric("cumulative-layout-shift", "Cumulative Layout Shift", fcp != null || shifts.length ? cls : null, 0.1, 0.25, 25, cls.toFixed(3), "How much visible content moved without user input."),
        metric("server-response-time", "Time to First Byte", ttfb, 800, 1800, 10, ms(ttfb), "How long the server took to start answering the document request."),
      ];
      if (inp != null) perfAudits.push(metric("interaction-to-next-paint", "Interaction to Next Paint", inp, 200, 500, 0, ms(inp), "The slowest interaction so far (field metric; not scored)."));
      const facts = dom.performance;
      const diagnostic = (id, title, failureTitle, description, items, opts = {}) =>
        Object.assign({ id, title: items.length ? failureTitle : title, description, weight: 0, score: items.length ? 0 : 1, passed: !items.length, items, total: items.length }, opts);
      perfAudits.push(diagnostic("render-blocking-resources", "No render-blocking resources", "Eliminate render-blocking resources",
        "Scripts without async or defer and stylesheets in <head> delay the first paint.",
        facts.renderBlocking.map((b) => { const r = byUrl(b.url); return Object.assign({}, b, r ? { requestId: r.id, detail: `${b.kind}, ${formatBytes(r.transferSize ?? r.bodySize)}, ${formatMs(r.duration)}` } : { detail: b.kind }); })));
      perfAudits.push(diagnostic("uses-responsive-images", "Images are properly sized", "Properly size images",
        "Images much larger than they are shown waste bytes and decoding time.", facts.oversizedImages));
      const bigImages = requests.filter((r) => r.resourceType === "image" && (r.transferSize ?? r.bodySize ?? 0) > 100 * 1024);
      perfAudits.push(diagnostic("large-images", "No images over 100 kB", "Large images",
        "Images over 100 kB; compress them or use a modern format.", bigImages.map((r) => requestItem(r, formatBytes(r.transferSize ?? r.bodySize)))));
      const totalBytes = requests.reduce((s, r) => s + (r.transferSize || r.bodySize || 0), 0);
      const biggest = requests.slice().sort((a, b) => (b.transferSize || b.bodySize || 0) - (a.transferSize || a.bodySize || 0)).slice(0, 10);
      perfAudits.push(Object.assign(diagnostic("total-byte-weight", "Avoids enormous network payloads", "Avoid enormous network payloads",
        "The total size of every request; large payloads cost users money and time.", totalBytes > 1600 * 1024 ? biggest.map((r) => requestItem(r, formatBytes(r.transferSize ?? r.bodySize))) : []),
        { displayValue: `Total size was ${formatBytes(totalBytes)} in ${requests.length} requests` }));
      perfAudits.push(Object.assign(diagnostic("dom-size", "Avoids an excessive DOM size", "Avoid an excessive DOM size",
        "Large DOMs cost memory, style and layout time.", facts.domSize > 1400 ? [{ detail: facts.domSize + " elements" }] : []), { displayValue: facts.domSize + " elements" }));
      perfAudits.push(diagnostic("long-tasks", "No long main-thread tasks", "Avoid long main-thread tasks",
        "Tasks over 50 ms block input.", tasks.slice(0, 20).map((t) => ({ detail: `at ${ms(t.startTime)}: ${ms(t.duration)}` })), { displayValue: tasks.length + " long task(s)" }));

      // ---- best practices: add console and network evidence ----
      const best = dom.bestPractices.map((a) => Object.assign({}, a));
      const errors = consoleItems.filter((e) => e.level === "error");
      const failedRequests = requests.filter((r) => r.failure || r.statusCode >= 400);
      const consoleAudit = {
        id: "errors-in-console", title: "No browser errors logged to the console", failureTitle: "Browser errors were logged to the console",
        description: "Errors in the console (uncaught exceptions, console.error, failed requests) point at problems to fix.", weight: 1,
        items: [...errors.slice(0, 20).map((e) => ({ detail: e.message.slice(0, 200), url: e.stack && e.stack[0] && e.stack[0].url || "", line: e.stack && e.stack[0] && e.stack[0].line, console: true })),
                ...failedRequests.slice(0, 10).map((r) => requestItem(r, "Failed to load resource: " + (r.failure || "status " + r.statusCode)))],
      };
      consoleAudit.total = errors.length + failedRequests.length;
      consoleAudit.passed = consoleAudit.total === 0;
      best.push(consoleAudit);
      const deprecations = best.find((a) => a.id === "deprecations");
      const warned = consoleItems.filter((e) => e.level === "warn" && /deprecat/i.test(e.message));
      if (deprecations && warned.length) {
        deprecations.items = deprecations.items.concat(warned.slice(0, 10).map((e) => ({ detail: e.message.slice(0, 200), console: true })));
        deprecations.passed = false;
      }
      const mixed = best.find((a) => a.id === "mixed-content");
      if (mixed && !mixed.notApplicable) {
        const insecure = requests.filter((r) => r.url.startsWith("http:"));
        mixed.items = mixed.items.concat(insecure.slice(0, 20).map((r) => requestItem(r, "requested over HTTP")));
        mixed.passed = mixed.items.length === 0;
      }

      // ---- SEO: headers and status of the document ----
      const seo = dom.seo.map((a) => Object.assign({}, a));
      if (doc) {
        const robotsHeader = Object.entries(doc.responseHeaders || {}).find(([k]) => k.toLowerCase() === "x-robots-tag");
        const crawlable = seo.find((a) => a.id === "is-crawlable");
        if (robotsHeader && /noindex|none/i.test(robotsHeader[1]) && crawlable) { crawlable.items.push(requestItem(doc, "X-Robots-Tag: " + robotsHeader[1])); crawlable.passed = false; }
        seo.push({ id: "http-status-code", title: "Page has a successful HTTP status code", failureTitle: "Page has an unsuccessful HTTP status code",
          description: "Pages with error status codes may not be indexed.", weight: 1, passed: !(doc.statusCode >= 400),
          items: doc.statusCode >= 400 ? [requestItem(doc, "status " + doc.statusCode)] : [], notApplicable: doc.statusCode == null });
      }

      const finish = (audits) => audits.map((a) => {
        const out = Object.assign({}, a);
        if (out.score == null && !out.notApplicable) out.score = out.passed ? 1 : 0;
        if (out.failureTitle && !out.passed) out.title = out.failureTitle;
        delete out.failureTitle;
        out.total = out.total ?? out.items.length;
        return out;
      });
      const category = (id, title, audits) => {
        audits = finish(audits);
        const scored = audits.filter((a) => !a.notApplicable && a.weight > 0 && a.score != null);
        const weight = scored.reduce((s, a) => s + a.weight, 0);
        const score = weight ? Math.round((scored.reduce((s, a) => s + a.weight * a.score, 0) / weight) * 100) : null;
        return { id, title, score, audits };
      };
      return {
        url: dom.url, title: dom.title, fetchedAt: dom.fetchedAt, userAgent: dom.userAgent, viewport: dom.viewport,
        categories: [
          category("performance", "Performance", perfAudits),
          category("accessibility", "Accessibility", dom.accessibility),
          category("bestPractices", "Best practices", best),
          category("seo", "SEO", seo),
        ],
      };
    },

    audit(id, categoryId) {
      for (const c of this.report?.categories || []) if (!categoryId || c.id === categoryId) { const a = c.audits.find((x) => x.id === id); if (a) return a; }
      return null;
    },

    // ---- rendering ------------------------------------------------------------------------------------
    render() {
      const body = $("#audits-body");
      body.textContent = "";
      for (const id of ["audits-copy-md", "audits-copy-json", "audits-save", "audits-save-md"]) $("#" + id).disabled = !this.report;
      if (!this.report) {
        body.appendChild(h("div", { class: "empty-state" }, h("div", {}, "Audit this page for performance, accessibility, best practices and SEO."),
          h("div", { class: "muted", style: "margin-top:6px" }, "Checks run in an isolated world the page cannot see; every finding links to its node or request.")));
        return;
      }
      const gauges = h("div", { class: "audit-gauges" });
      for (const c of this.report.categories) gauges.appendChild(this.gauge(c, () => $("#audit-cat-" + c.id)?.scrollIntoView({ block: "start" })));
      body.appendChild(gauges);
      body.appendChild(h("div", { class: "audit-meta muted" }, `${this.report.url} · ${new Date(this.report.fetchedAt).toLocaleString()} · ${this.report.viewport.width}×${this.report.viewport.height}`));
      for (const c of this.report.categories) body.appendChild(this.renderCategory(c));
    },

    scoreClass(score) { return score == null ? "na" : score >= 90 ? "pass" : score >= 50 ? "average" : "fail"; },

    gauge(c, onclick) {
      const pct = c.score ?? 0;
      return h("div", { class: "audit-gauge " + this.scoreClass(c.score), onclick },
        h("div", { class: "ring", style: `--pct:${pct}` }, h("span", {}, c.score == null ? "–" : String(c.score))),
        h("div", { class: "label" }, c.title));
    },

    renderCategory(c) {
      const section = h("div", { class: "audit-category", id: "audit-cat-" + c.id });
      section.appendChild(h("div", { class: "audit-category-head" }, this.gauge(c), h("div", { class: "title" }, c.title)));
      const failed = c.audits.filter((a) => !a.notApplicable && !a.passed);
      const passed = c.audits.filter((a) => !a.notApplicable && a.passed);
      const na = c.audits.filter((a) => a.notApplicable);
      if (c.id === "performance") {
        const metrics = h("div", { class: "audit-metrics" });
        for (const a of c.audits.filter((x) => x.weight > 0 || x.id === "interaction-to-next-paint")) {
          metrics.appendChild(h("div", { class: "audit-metric " + (a.notApplicable ? "na" : a.score >= 0.9 ? "pass" : a.score >= 0.5 ? "average" : "fail") },
            h("div", { class: "name" }, a.title), h("div", { class: "value" }, a.displayValue || "—")));
        }
        section.appendChild(metrics);
      }
      const list = (title, audits, open) => {
        if (!audits.length) return;
        const group = h("div", { class: "audit-group" + (open ? " open" : "") });
        const head = h("div", { class: "audit-group-head" }, `${title} (${audits.length})`);
        head.addEventListener("click", () => group.classList.toggle("open"));
        group.appendChild(head);
        for (const a of audits) group.appendChild(this.renderAudit(c, a));
        section.appendChild(group);
      };
      list(c.id === "performance" ? "Diagnostics and metrics to improve" : "Failed audits", failed, true);
      list("Passed audits", passed, false);
      list("Not applicable", na, false);
      return section;
    },

    renderAudit(c, a) {
      const key = c.id + "/" + a.id;
      const state = a.notApplicable ? "na" : a.passed ? "pass" : (a.score != null && a.score >= 0.5 ? "average" : "fail");
      const row = h("div", { class: "audit " + state + (this.expanded.has(key) ? " open" : ""), "data-audit": a.id, "data-category": c.id });
      const head = h("div", { class: "audit-head" }, h("span", { class: "audit-icon" }), h("span", { class: "audit-title" }, a.title),
        a.displayValue ? h("span", { class: "audit-display" }, a.displayValue) : (a.total ? h("span", { class: "audit-display" }, a.total + (a.total === 1 ? " item" : " items")) : null));
      head.addEventListener("click", () => { row.classList.toggle("open"); if (row.classList.contains("open")) this.expanded.add(key); else this.expanded.delete(key); });
      row.appendChild(head);
      const details = h("div", { class: "audit-details" }, h("div", { class: "audit-description" }, a.description || ""));
      if (a.items.length) {
        const table = h("div", { class: "audit-items" });
        for (const it of a.items) table.appendChild(this.renderItem(it));
        if (a.total > a.items.length) table.appendChild(h("div", { class: "muted audit-item" }, `… ${a.total - a.items.length} more`));
        details.appendChild(table);
      }
      row.appendChild(details);
      return row;
    },

    renderItem(it) {
      const row = h("div", { class: "audit-item" });
      if (it.nodeId != null) {
        const link = h("span", { class: "audit-node link", title: "Reveal in Elements panel" }, it.snippet || it.selector);
        link.addEventListener("click", () => this.reveal(it));
        link.addEventListener("mouseenter", () => DevTools.rpc("Overlay.highlightNode", { nodeId: it.nodeId }).catch(() => {}));
        link.addEventListener("mouseleave", () => DevTools.rpc("Overlay.hideHighlight").catch(() => {}));
        row.append(link, h("span", { class: "audit-selector muted" }, it.selector || ""));
      } else if (it.requestId) {
        const link = h("span", { class: "link", title: "Show in Network panel" }, fileName(it.url));
        link.addEventListener("click", () => this.reveal(it));
        row.append(link, h("span", { class: "muted audit-selector" }, it.url));
      } else if (it.console) {
        const link = h("span", { class: "link" }, "Console");
        link.addEventListener("click", () => DevTools.showPanel("console"));
        row.appendChild(link);
      }
      if (it.detail) row.appendChild(h("span", { class: "audit-item-detail" }, it.detail));
      return row;
    },

    // A finding's node in Elements, or its request in Network.
    async reveal(it) {
      if (it.nodeId != null) {
        DevTools.showPanel("elements");
        await DevTools.panels.elements.revealNode(it.nodeId);
      } else if (it.requestId) {
        DevTools.showPanel("network");
        DevTools.panels.network.select(it.requestId);
      }
    },

    // ---- export -------------------------------------------------------------------------------------------
    json() { return JSON.stringify(this.report, null, 2); },

    markdown() {
      const r = this.report;
      const out = [`# Audit report — ${r.title || r.url}`, "", `- URL: ${r.url}`, `- Run: ${r.fetchedAt}`, `- Viewport: ${r.viewport.width}×${r.viewport.height} @${r.viewport.devicePixelRatio}x`, ""];
      out.push(Markdown.table(["Category", "Score"], r.categories.map((c) => [c.title, c.score ?? "n/a"])), "");
      for (const c of r.categories) {
        out.push(`## ${c.title}: ${c.score ?? "n/a"}`, "");
        if (c.id === "performance") {
          for (const a of c.audits.filter((x) => x.weight > 0 || x.id === "interaction-to-next-paint")) out.push(`- ${a.title}: ${a.displayValue}`);
          out.push("");
        }
        const failed = c.audits.filter((a) => !a.notApplicable && !a.passed);
        if (!failed.length) { out.push("All audits passed.", ""); continue; }
        for (const a of failed) {
          out.push(`### ✗ ${a.title}${a.displayValue ? " — " + a.displayValue : ""}`, "", a.description || "");
          for (const it of a.items) {
            const where = it.selector ? "`" + it.selector + "`" : it.url ? it.url : "";
            const html = it.snippet ? " `" + it.snippet.replace(/`/g, "'") + "`" : "";
            out.push(("- " + where + html + (it.detail ? " — " + it.detail : "")).replace(/^- \s+/, "- "));
          }
          if (a.total > a.items.length) out.push(`- … ${a.total - a.items.length} more`);
          out.push("");
        }
        const passed = c.audits.filter((a) => !a.notApplicable && a.passed);
        if (passed.length) out.push(`Passed: ${passed.map((a) => a.title).join("; ")}`, "");
      }
      return out.join("\n");
    },
  };

  DevTools.register("audits", panel);
})();
