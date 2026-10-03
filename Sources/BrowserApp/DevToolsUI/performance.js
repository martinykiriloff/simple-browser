// Keel DevTools — Performance panel: web vitals and a timeline of
// what the agent observed for the current document.
"use strict";

(function () {
  const panel = {
    initialized: false,
    entries: [],
    navigations: [],
    renderTimer: null,

    init() {
      SBProfiler.init();
      $("#perf-reload").addEventListener("click", async () => {
        this.entries = []; this.render();
        // Record the load itself: start, reload, and stop once the page settles.
        await SBProfiler.start();
        await DevTools.rpc("Page.reload");
        if (SBProfiler.recording) setTimeout(() => SBProfiler.stop(), 3000);
      });
      $("#perf-clear").addEventListener("click", () => { this.entries = []; this.render(); });
      DevTools.on("Performance.entryAdded", ({ entry, sequence }) => { this.entries.push(Object.assign({ sequence }, entry)); this.scheduleRender(); });
      DevTools.on("Page.navigated", (p) => {
        if (p.phase === "started") { this.entries = []; this.navigations = [p]; this.scheduleRender(); }
        else this.navigations.push(p);
      });
      DevTools.on("Network.requestAdded", () => this.scheduleRender());
      this.load();
    },

    show() { this.render(); SBProfiler.draw(); },

    async load() {
      let list = [];
      try { list = await DevTools.rpc("Performance.getEntries"); } catch (_) {}
      let lastStart = -1;
      list.forEach((item, i) => { if (item.kind === "navigation" && item.phase === "started") lastStart = i; });
      this.entries = [];
      this.navigations = [];
      for (const item of list.slice(Math.max(0, lastStart))) {
        if (item.kind === "performance") this.entries.push(Object.assign({ sequence: item.sequence }, item.entry));
        else this.navigations.push(item);
      }
      this.render();
    },

    scheduleRender() {
      if (this.renderTimer || DevTools.activePanel !== "performance") return;
      this.renderTimer = setTimeout(() => { this.renderTimer = null; this.render(); }, 200);
    },

    vital(name, value, unit, thresholds, hint) {
      let cls = "";
      if (value != null && thresholds) cls = value <= thresholds[0] ? "good" : value <= thresholds[1] ? "meh" : "poor";
      const text = value == null ? "—" : unit === "ms" ? (value >= 1000 ? (value / 1000).toFixed(2) + " s" : Math.round(value) + " ms") : unit === "" ? value.toFixed(3) : String(value);
      return h("div", { class: "vital " + cls }, h("div", { class: "name" }, name), h("div", { class: "value" }, text), hint ? h("div", { class: "hint" }, hint) : null);
    },

    render() {
      const vitals = $("#vitals");
      vitals.textContent = "";
      const by = (type) => this.entries.filter((e) => e.entryType === type);
      const fcp = by("paint").find((e) => e.name === "first-contentful-paint");
      const lcpList = by("largest-contentful-paint");
      const lcp = lcpList[lcpList.length - 1];
      const cls = by("layout-shift").filter((e) => !(e.detail || "").includes("had recent input")).reduce((s, e) => s + (e.value || 0), 0);
      const interactions = [...by("first-input"), ...by("event")];
      const inp = interactions.length ? Math.max(...interactions.map((e) => e.duration)) : null;
      const tasks = by("longtask");
      const network = DevTools.panels.network ? Array.from(DevTools.panels.network.requests.values()) : [];
      const doc = network.find((r) => r.resourceType === "document" && r.timing);
      const ttfb = doc && doc.timing.responseStart > 0 ? doc.timing.responseStart : null;

      vitals.appendChild(this.vital("First Contentful Paint", fcp ? fcp.startTime : null, "ms", [1800, 3000]));
      vitals.appendChild(this.vital("Largest Contentful Paint", lcp ? lcp.startTime : null, "ms", [2500, 4000], lcp && lcp.detail ? lcp.detail.slice(0, 60) : null));
      vitals.appendChild(this.vital("Cumulative Layout Shift", by("layout-shift").length ? cls : (fcp ? 0 : null), "", [0.1, 0.25]));
      vitals.appendChild(this.vital("Interaction to Next Paint", inp, "ms", [200, 500], interactions.length ? interactions.length + " slow interaction(s)" : "no slow interactions yet"));
      vitals.appendChild(this.vital("Time to First Byte", ttfb, "ms", [800, 1800]));
      vitals.appendChild(this.vital("Long tasks", tasks.length ? tasks.length : (fcp ? 0 : null), "count", [0, 3], tasks.length ? Math.round(tasks.reduce((s, t) => s + t.duration, 0)) + " ms blocked" : null));

      // Timeline: marks for paints, bars for long tasks and network requests.
      const timeline = $("#perf-timeline");
      timeline.textContent = "";
      const navStart = this.navigations.find((n) => n.phase === "started")?.timestamp;
      const end = Math.max(5000, ...this.entries.map((e) => e.startTime + e.duration), ...network.map((r) => (navStart ? r.startedAt - navStart : 0) + (r.duration || 0) * 1000));
      const x = (ms) => (Math.max(0, ms) / end) * 100;
      if (navStart) {
        network.slice(0, 200).forEach((r, i) => {
          const start = r.startedAt - navStart;
          if (start < 0 || start > end) return;
          timeline.appendChild(h("div", { class: "req", title: fileName(r.url), style: `left:${x(start)}%;width:${Math.max(0.2, x((r.duration || 0) * 1000))}%;top:${14 + (i % 14) * 3}px` }));
        });
      }
      for (const t of tasks) timeline.appendChild(h("div", { class: "task", title: "Long task " + Math.round(t.duration) + " ms", style: `left:${x(t.startTime)}%;width:${Math.max(0.3, x(t.duration))}%` }));
      const marks = [];
      if (fcp) marks.push(["FCP", fcp.startTime, "#4caf50"]);
      if (lcp) marks.push(["LCP", lcp.startTime, "#1a73e8"]);
      for (const [label, at, color] of marks) timeline.appendChild(h("div", { class: "mark", style: `left:${x(at)}%;background:${color}` }, h("span", {}, label + " " + Math.round(at) + " ms")));
      timeline.appendChild(h("div", { class: "mark", style: "right:0;background:transparent" }, h("span", { style: "left:auto;right:4px" }, Math.round(end) + " ms")));

      const tbody = $("#perf-table tbody");
      tbody.textContent = "";
      const rows = this.entries.slice().sort((a, b) => a.startTime - b.startTime);
      for (const e of rows) {
        let detail = e.name;
        if (e.entryType === "layout-shift") detail = "score " + (e.value || 0).toFixed(4) + (e.detail ? " · " + e.detail : "");
        else if (e.detail) detail += " · " + e.detail;
        tbody.appendChild(h("tr", {}, h("td", {}, Math.round(e.startTime) + " ms"), h("td", {}, e.entryType), h("td", { title: detail }, detail), h("td", {}, e.duration ? Math.round(e.duration) + " ms" : "")));
      }
      if (!rows.length) tbody.appendChild(h("tr", {}, h("td", { colspan: "4", class: "muted", style: "text-align:center" }, "No performance entries for this document yet.")));
    },
  };

  DevTools.register("performance", panel);
})();
