// Keel DevTools — CPU profile and timeline recording for the
// Performance panel: an event track, a flame chart and a bottom-up table.
//
// Data comes from WebKit's sampling profiler (`ScriptProfiler`, a stack trace
// about every millisecond while it can walk the stack) and its `Timeline`
// domain (layout, paint, style recalculation, script tasks), on one clock.
// The two are reconciled in build(): see the note on estimated frames.
"use strict";

const Profiler = window.SBProfiler = {
  recording: false,
  samples: [],
  records: [],
  profile: null,            // { nodes, maxDepth, start, end, events, functions }
  view: { start: 0, end: 1 },
  table: "bottomup",
  ROW: 17,
  TRACK_ROWS: 3,
  hitRegions: [],

  CATEGORIES: {
    scripting: { label: "Scripting", color: "#f2c037" },
    rendering: { label: "Rendering", color: "#9b7fe6" },
    painting:  { label: "Painting",  color: "#71b363" },
    other:     { label: "Other",     color: "#b0b0b0" },
  },
  TYPE_CATEGORY: {
    EvaluateScript: "scripting", FunctionCall: "scripting", TimerFire: "scripting", EventDispatch: "scripting",
    FireAnimationFrame: "scripting", ObserverCallback: "scripting", ProbeSample: "scripting", ConsoleProfile: "scripting",
    RecalculateStyles: "rendering", Layout: "rendering", InvalidateLayout: "rendering", ScheduleStyleRecalculation: "rendering",
    Paint: "painting", Composite: "painting", RenderingFrame: "painting",
  },

  init() {
    $("#perf-record").addEventListener("click", () => this.recording ? this.stop() : this.start());
    for (const tab of $$("#perf-tabs .subtab")) {
      tab.addEventListener("click", () => {
        for (const t of $$("#perf-tabs .subtab")) t.classList.toggle("active", t === tab);
        this.table = tab.dataset.view;
        this.renderTable();
      });
    }
    DevTools.on("Protocol.event", ({ method, params }) => {
      if (method === "Timeline.eventRecorded" && this.recording) this.records.push(params.record);
      else if (method === "ScriptProfiler.trackingComplete") this.onComplete(params);
    });

    const canvas = $("#perf-chart");
    canvas.addEventListener("wheel", (e) => this.onWheel(e), { passive: false });
    canvas.addEventListener("mousedown", (e) => this.onDragStart(e));
    canvas.addEventListener("mousemove", (e) => this.onHover(e));
    canvas.addEventListener("mouseleave", () => { $("#perf-tooltip").hidden = true; });
    canvas.addEventListener("click", (e) => this.onClick(e));
    canvas.addEventListener("dblclick", () => { if (this.profile) { this.view = { start: this.profile.start, end: this.profile.end }; this.draw(); } });
    new ResizeObserver(() => { if (this.profile && DevTools.activePanel === "performance") this.draw(); }).observe($("#perf-chart-wrap"));
  },

  // ---- recording --------------------------------------------------------------------
  async start() {
    if (!window.SBDebugger || !SBDebugger.available) {
      DevTools.panels.console?.addLocal("warn", "Recording needs the debugger connection, which is not available.");
      return;
    }
    this.samples = []; this.records = []; this.completed = null;
    // A breakpoint hitting mid-recording would freeze the page and wreck the
    // timings, so breakpoints are inactive while recording (the debugger
    // itself stays attached; measured, it does not affect sample yield).
    await SBDebugger.send("Debugger.setBreakpointsActive", { active: false }).catch(() => {});
    try {
      await SBDebugger.send("Timeline.start", {});
      await SBDebugger.send("ScriptProfiler.startTracking", { includeSamples: true });
    } catch (e) {
      DevTools.panels.console?.addLocal("error", "Could not start recording: " + e.message);
      await SBDebugger.send("Debugger.setBreakpointsActive", { active: SBDebugger.active }).catch(() => {});
      return;
    }
    this.recording = true;
    const button = $("#perf-record");
    button.classList.add("on"); button.innerHTML = "&#9632;"; button.title = "Stop recording";
  },

  async stop() {
    if (!this.recording) return;
    const button = $("#perf-record");
    button.classList.remove("on"); button.innerHTML = "&#9679;"; button.title = "Record a CPU profile and timeline";
    this.completion = new Promise((resolve) => { this.resolveCompletion = resolve; });
    // Independent: a slow profiler must not leave the timeline running.
    for (const command of ["ScriptProfiler.stopTracking", "Timeline.stop"]) {
      try { await SBDebugger.send(command, {}); }
      catch (e) { DevTools.panels.console?.addLocal("warn", command + ": " + e.message); }
    }
    // The samples arrive in a trailing event; do not wait forever for it.
    await Promise.race([this.completion, new Promise((r) => setTimeout(r, 5000))]);
    this.recording = false;
    await SBDebugger.send("Debugger.setBreakpointsActive", { active: SBDebugger.active }).catch(() => {});
    this.build();
  },

  onComplete(params) {
    this.samples = ((params.samples || {}).stackTraces || []).filter((t) => t.timestamp > 0);
    if (this.resolveCompletion) this.resolveCompletion();
  },

  // ---- analysis ------------------------------------------------------------------------
  // WebKit's sampler cannot walk optimised machine code. Measured: the first
  // run of a hot loop (still in the interpreter tiers) yields a stack per
  // millisecond; once it is compiled, the same 150 ms yields five. So the
  // sampler is weakest exactly on hot code. The timeline, however,
  // knows exactly when each script task started and ended, and a task is by
  // definition continuous execution. So each task's duration is divided
  // among the samples that fall inside it (every moment takes the stack of
  // its nearest sample), and stretches backed by little evidence are marked
  // as estimates instead of being presented as measurements.
  build() {
    const samples = this.samples;
    const deltas = [];
    for (let i = 1; i < samples.length; i++) deltas.push(samples[i].timestamp - samples[i - 1].timestamp);
    deltas.sort((a, b) => a - b);
    const interval = deltas.length ? Math.min(Math.max(deltas[Math.floor(deltas.length / 4)], 0.0002), 0.005) : 0.001;
    const ESTIMATE_BEYOND = 0.008;   // one sample vouching for more than this is an estimate

    const events = [];
    const walk = (record, depth) => {
      if (record.endTime != null && record.endTime > record.startTime) {
        events.push({ type: record.type, category: this.TYPE_CATEGORY[record.type] || "other", start: record.startTime, end: record.endTime, depth, data: record.data || {} });
      }
      for (const child of record.children || []) walk(child, depth + 1);
    };
    for (const record of this.records) walk(record, 0);

    const keyOf = (f) => (f.sourceID || "") + ":" + f.line + ":" + f.column + ":" + f.name;
    const stackOf = (sample) => (sample.stackFrames || []).slice().reverse().filter((f) => !(f.url || "").startsWith("user-script:"));

    // 1. Segments: [start, end) intervals, each with one stack.
    const segments = [];
    const tasks = events.filter((e) => e.depth === 0 && e.category === "scripting").sort((a, b) => a.start - b.start);
    const claimed = new Set();
    for (const task of tasks) {
      const inside = [];
      samples.forEach((sample, index) => { if (sample.timestamp >= task.start && sample.timestamp <= task.end) { inside.push(sample); claimed.add(index); } });
      if (!inside.length) {
        // Not one stack for this task. The timeline still names the script
        // and line it entered at, which beats an empty chart.
        const entry = this.entryPoint(task);
        if (entry && task.end - task.start > 0.001) {
          segments.push({ start: task.start, end: task.end, estimated: true, task,
                          stack: [{ name: entry.name, url: entry.url, line: entry.line, column: entry.column, sourceID: "timeline" }] });
        }
        continue;
      }
      inside.forEach((sample, i) => {
        const from = i === 0 ? task.start : (inside[i - 1].timestamp + sample.timestamp) / 2;
        const to = i === inside.length - 1 ? task.end : (sample.timestamp + inside[i + 1].timestamp) / 2;
        if (to > from) segments.push({ start: from, end: to, stack: stackOf(sample), estimated: to - from > ESTIMATE_BEYOND, task });
      });
    }
    // Samples the timeline has no task for stand alone, one interval each.
    samples.forEach((sample, index) => {
      if (!claimed.has(index)) segments.push({ start: sample.timestamp, end: sample.timestamp + interval, stack: stackOf(sample), estimated: false, task: null });
    });
    segments.sort((a, b) => a.start - b.start);

    // 2. Frames: consecutive segments sharing a stack prefix extend the same boxes.
    const nodes = [];
    const functions = new Map();
    let open = [];
    let previous = null;
    let estimated = 0;
    const close = (depth, at) => {
      while (open.length > depth) {
        const n = open.pop();
        n.end = at;
        n.estimated = n.estimatedTime > (n.end - n.start) / 2;
      }
    };
    for (const segment of segments) {
      const contiguous = previous && previous.task === segment.task && segment.start - previous.end < 1e-6;
      if (!contiguous) close(0, previous ? previous.end : segment.start);
      let common = 0;
      while (common < open.length && common < segment.stack.length && open[common].key === keyOf(segment.stack[common])) common++;
      close(common, segment.start);
      for (let d = common; d < segment.stack.length; d++) {
        const f = segment.stack[d];
        const node = { key: keyOf(f), name: f.name || "(anonymous)", url: f.url || "", line: f.line, column: f.column, depth: d, start: segment.start, end: segment.end, estimatedTime: 0, estimated: false };
        open.push(node); nodes.push(node);
      }
      const length = segment.end - segment.start;
      for (const node of open) { node.end = segment.end; if (segment.estimated) node.estimatedTime += length; }
      if (segment.estimated) estimated += length;
      const seen = new Set();
      segment.stack.forEach((f, d) => {
        const key = keyOf(f);
        let fn = functions.get(key);
        if (!fn) { fn = { key, name: f.name || "(anonymous)", url: f.url || "", line: f.line, column: f.column, self: 0, total: 0, estimated: 0 }; functions.set(key, fn); }
        if (d === segment.stack.length - 1) { fn.self += length; if (segment.estimated) fn.estimated += length; }
        if (!seen.has(key)) { fn.total += length; seen.add(key); }
      });
      previous = segment;
    }
    close(0, previous ? previous.end : 0);

    const times = nodes.map((n) => n.start).concat(events.map((e) => e.start));
    const ends = nodes.map((n) => n.end).concat(events.map((e) => e.end));
    const start = times.length ? Math.min(...times) : 0;
    const end = ends.length ? Math.max(...ends) : start + 0.001;
    this.profile = {
      nodes, events, start, end, interval,
      maxDepth: nodes.reduce((m, n) => Math.max(m, n.depth), 0),
      functions: Array.from(functions.values()).sort((a, b) => b.self - a.self),   // after estimates
      sampleCount: samples.length,
      estimated,
    };
    this.view = { start, end };
    this.render();
  },

  // Where a script task entered JavaScript, from the timeline's own records.
  entryPoint(task) {
    const records = [];
    const collect = (record) => { records.push(record); for (const child of record.children || []) collect(child); };
    for (const record of this.records) if (record.startTime === task.start && record.endTime === task.end) collect(record);
    const withScript = records.find((r) => r.data && (r.data.scriptName || r.data.url));
    if (!withScript) return null;
    const url = withScript.data.scriptName || withScript.data.url || "";
    const line = withScript.data.scriptLine || withScript.data.lineNumber || 0;
    return { name: "(" + (withScript.type === "EvaluateScript" ? "script" : "function") + " at " + (url ? fileName(url) : "anonymous") + (line ? ":" + line : "") + ")", url, line, column: withScript.data.scriptColumn || 0 };
  },

  // ---- rendering -------------------------------------------------------------------------
  render() {
    $("#perf-recording").hidden = !this.profile;
    if (!this.profile) return;
    const p = this.profile;
    const totals = { scripting: 0, rendering: 0, painting: 0, other: 0 };
    for (const e of p.events) if (e.depth === 0) totals[e.category] += e.end - e.start;
    const summary = $("#perf-summary");
    summary.textContent = "";
    summary.appendChild(h("span", {}, h("b", {}, this.ms(p.end - p.start)), " recorded"));
    summary.appendChild(h("span", {}, h("b", {}, String(p.sampleCount)), " samples at ~", this.ms(p.interval)));
    if (p.estimated > 0) {
      summary.appendChild(h("span", { title: "WebKit's sampler cannot see into optimised code, so hot functions get few samples. Script tasks are timed exactly by the timeline; within a task, stretches with few samples take the stack of the nearest sample. Those frames are drawn lighter." },
        h("b", {}, this.ms(p.estimated)), " estimated"));
    }
    for (const [key, cat] of Object.entries(this.CATEGORIES)) {
      summary.appendChild(h("span", {}, h("span", { class: "swatch", style: "background:" + cat.color }), cat.label + " ", h("b", {}, this.ms(totals[key]))));
    }
    this.draw();
    this.renderTable();
  },

  ms(seconds) {
    const ms = seconds * 1000;
    return ms >= 1000 ? (ms / 1000).toFixed(2) + " s" : ms >= 10 ? Math.round(ms) + " ms" : ms.toFixed(1) + " ms";
  },

  color(node) {
    let hash = 0;
    const text = node.url || node.name;
    for (let i = 0; i < text.length; i++) hash = (hash * 31 + text.charCodeAt(i)) | 0;
    return `hsl(${Math.abs(hash) % 360}, 62%, ${node.url ? 72 : 80}%)`;
  },

  draw() {
    const p = this.profile;
    if (!p) return;
    const wrap = $("#perf-chart-wrap");
    const canvas = $("#perf-chart");
    const width = Math.max(100, wrap.clientWidth);
    const trackHeight = this.TRACK_ROWS * this.ROW + 22;
    const height = trackHeight + (p.maxDepth + 2) * this.ROW + 8;
    const ratio = window.devicePixelRatio || 1;
    canvas.width = width * ratio; canvas.height = height * ratio;
    canvas.style.width = width + "px"; canvas.style.height = height + "px";
    const ctx = canvas.getContext("2d");
    ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
    ctx.clearRect(0, 0, width, height);
    const css = getComputedStyle(document.documentElement);
    const textColor = css.getPropertyValue("--text-soft").trim() || "#5f6368";
    const gridColor = css.getPropertyValue("--border-soft").trim() || "#e0e0e0";
    const span = Math.max(this.view.end - this.view.start, 1e-6);
    const x = (t) => ((t - this.view.start) / span) * width;
    this.hitRegions = [];

    // time ruler
    ctx.font = "10px -apple-system, system-ui, sans-serif";
    ctx.textBaseline = "middle";
    const step = this.niceStep(span / 8);
    ctx.strokeStyle = gridColor; ctx.fillStyle = textColor; ctx.lineWidth = 1;
    for (let t = Math.ceil(this.view.start / step) * step; t < this.view.end; t += step) {
      const px = Math.round(x(t)) + 0.5;
      ctx.beginPath(); ctx.moveTo(px, 0); ctx.lineTo(px, height); ctx.stroke();
      ctx.fillText(this.ms(t - p.start), px + 3, 8);
    }

    const drawBox = (item, top, fill, label) => {
      const left = Math.max(x(item.start), -2), right = Math.min(x(item.end), width + 2);
      const w = right - left;
      if (w < 0.4 || right < 0 || left > width) return;
      ctx.fillStyle = fill;
      ctx.globalAlpha = item.estimated ? 0.45 : 1;
      ctx.fillRect(left, top, Math.max(w - 0.5, 0.5), this.ROW - 2);
      ctx.globalAlpha = 1;
      if (w > 28 && label) {
        ctx.fillStyle = "#202124";
        ctx.save(); ctx.beginPath(); ctx.rect(left, top, w - 2, this.ROW - 2); ctx.clip();
        ctx.fillText(label, left + 4, top + (this.ROW - 2) / 2);
        ctx.restore();
      }
      this.hitRegions.push({ left, right, top, bottom: top + this.ROW - 2, item });
    };

    // event track
    ctx.fillStyle = textColor;
    for (const e of p.events) {
      if (e.depth >= this.TRACK_ROWS) continue;
      drawBox(e, 18 + e.depth * this.ROW, this.CATEGORIES[e.category].color, e.type.replace(/([a-z])([A-Z])/g, "$1 $2"));
    }
    // flame chart
    ctx.strokeStyle = gridColor;
    ctx.beginPath(); ctx.moveTo(0, trackHeight - 2.5); ctx.lineTo(width, trackHeight - 2.5); ctx.stroke();
    for (const n of p.nodes) drawBox(n, trackHeight + n.depth * this.ROW, this.color(n), n.estimated ? n.name + " (estimated)" : n.name);
  },

  niceStep(raw) {
    const power = Math.pow(10, Math.floor(Math.log10(raw)));
    const unit = raw / power;
    return (unit < 1.5 ? 1 : unit < 3.5 ? 2 : unit < 7.5 ? 5 : 10) * power;
  },

  // ---- interaction --------------------------------------------------------------------------
  hit(e) {
    const rect = $("#perf-chart").getBoundingClientRect();
    const px = e.clientX - rect.left, py = e.clientY - rect.top;
    for (let i = this.hitRegions.length - 1; i >= 0; i--) {
      const r = this.hitRegions[i];
      if (px >= r.left && px <= r.right && py >= r.top && py <= r.bottom) return { region: r, px, py };
    }
    return null;
  },

  onHover(e) {
    const tip = $("#perf-tooltip");
    const found = this.hit(e);
    if (!found || this.dragging) { tip.hidden = true; return; }
    const item = found.region.item;
    tip.textContent = "";
    tip.appendChild(h("div", { class: "fn" }, (item.name || item.type) + (item.estimated ? "  (estimated)" : "")));
    tip.appendChild(h("div", { class: "muted" }, this.ms(item.end - item.start) + (item.url ? "  ·  " + fileName(item.url) + ":" + item.line : item.category ? "  ·  " + this.CATEGORIES[item.category].label : "")));
    tip.hidden = false;
    const wrap = $("#perf-chart-wrap");
    tip.style.left = Math.min(found.px + 12, wrap.clientWidth - tip.offsetWidth - 8) + "px";
    tip.style.top = (found.py + 14) + "px";
  },

  onClick(e) {
    if (this.moved) return;
    const found = this.hit(e);
    if (found && found.region.item.url) DevTools.openSource(found.region.item.url, found.region.item.line, found.region.item.column);
  },

  onWheel(e) {
    if (!this.profile) return;
    e.preventDefault();
    const rect = $("#perf-chart").getBoundingClientRect();
    const span = this.view.end - this.view.start;
    const total = this.profile.end - this.profile.start;
    if (Math.abs(e.deltaX) > Math.abs(e.deltaY)) {
      const shift = (e.deltaX / rect.width) * span;
      this.setView(this.view.start + shift, this.view.end + shift);
      return;
    }
    const focus = this.view.start + ((e.clientX - rect.left) / rect.width) * span;
    const factor = Math.exp(e.deltaY * 0.004);
    const next = Math.min(Math.max(span * factor, this.profile.interval * 4), total);
    const ratio = (focus - this.view.start) / span;
    this.setView(focus - next * ratio, focus + next * (1 - ratio));
  },

  setView(start, end) {
    const p = this.profile;
    const span = end - start;
    if (start < p.start) { start = p.start; end = start + span; }
    if (end > p.end) { end = p.end; start = Math.max(p.start, end - span); }
    this.view = { start, end };
    this.draw();
  },

  onDragStart(e) {
    if (!this.profile) return;
    const canvas = $("#perf-chart");
    const startX = e.clientX, origin = { ...this.view };
    this.dragging = true; this.moved = false;
    canvas.classList.add("dragging");
    const move = (ev) => {
      const dx = ev.clientX - startX;
      if (Math.abs(dx) > 2) this.moved = true;
      const shift = -(dx / canvas.getBoundingClientRect().width) * (origin.end - origin.start);
      this.setView(origin.start + shift, origin.end + shift);
    };
    const up = () => {
      this.dragging = false; canvas.classList.remove("dragging");
      document.removeEventListener("mousemove", move); document.removeEventListener("mouseup", up);
      setTimeout(() => { this.moved = false; }, 0);
    };
    document.addEventListener("mousemove", move); document.addEventListener("mouseup", up);
  },

  // ---- tables ----------------------------------------------------------------------------------
  renderTable() {
    const table = $("#perf-profile-table");
    const head = table.querySelector("thead"), body = table.querySelector("tbody");
    head.textContent = ""; body.textContent = "";
    const p = this.profile;
    if (!p) return;
    if (this.table === "bottomup") {
      head.appendChild(h("tr", {}, h("th", {}, "Self Time"), h("th", {}, "Total Time"), h("th", {}, "Function")));
      const max = p.functions.length ? p.functions[0].self : 1;
      for (const fn of p.functions.slice(0, 200)) {
        const where = fn.url ? h("span", { class: "link", onclick: () => DevTools.openSource(fn.url, fn.line, fn.column) }, "  " + fileName(fn.url) + ":" + fn.line) : null;
        body.appendChild(h("tr", {},
          h("td", { class: "num", title: fn.estimated ? this.ms(fn.estimated) + " of this is estimated: the sampler lost the stack in optimised code" : "" },
            (fn.estimated ? "~" : "") + this.ms(fn.self), h("span", { class: "bar", style: `width:${Math.round((fn.self / max) * 40)}px` })),
          h("td", { class: "num" }, this.ms(fn.total)),
          h("td", {}, h("span", { class: "mono" }, fn.name), where)));
      }
      if (!p.functions.length) body.appendChild(h("tr", {}, h("td", { colspan: "3", class: "muted", style: "text-align:center" }, "No JavaScript ran during the recording.")));
    } else {
      head.appendChild(h("tr", {}, h("th", {}, "Start"), h("th", {}, "Duration"), h("th", {}, "Event")));
      for (const e of p.events.filter((ev) => ev.depth === 0).sort((a, b) => a.start - b.start).slice(0, 500)) {
        body.appendChild(h("tr", {},
          h("td", { class: "num" }, this.ms(e.start - p.start)),
          h("td", { class: "num" }, this.ms(e.end - e.start)),
          h("td", {}, h("span", { class: "swatch", style: "display:inline-block;width:9px;height:9px;margin-right:6px;background:" + this.CATEGORIES[e.category].color }), e.type.replace(/([a-z])([A-Z])/g, "$1 $2"))));
      }
    }
  },
};
