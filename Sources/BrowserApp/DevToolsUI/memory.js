// SimpleBrowser DevTools — Memory panel: JavaScriptCore heap snapshots
// (WebKit's Heap domain) summarised by class, with retained sizes from the
// dominator tree, comparison between two snapshots, and the JS heap size
// over time (Memory domain).
"use strict";

(function () {
  // ---- snapshot parsing --------------------------------------------------------------------------
  // JSC's snapshot: nodes are [id, size, classNameIndex, flags] and edges
  // [fromId, toId, typeIndex, dataIndex]; node id 0 is the root.
  function parseSnapshot(text) {
    const data = JSON.parse(text);
    const nodes = data.nodes, edges = data.edges, names = data.nodeClassNames;
    const N = nodes.length / 4;
    const ids = new Float64Array(N), sizes = new Float64Array(N), classes = new Int32Array(N), internal = new Uint8Array(N);
    const index = new Map();
    let total = 0;
    for (let i = 0; i < N; i++) {
      ids[i] = nodes[i * 4]; sizes[i] = nodes[i * 4 + 1]; classes[i] = nodes[i * 4 + 2]; internal[i] = nodes[i * 4 + 3] & 1;
      index.set(ids[i], i);
      total += sizes[i];
    }
    // Successors and predecessors in compressed rows.
    const E = edges.length / 4;
    const from = new Int32Array(E), to = new Int32Array(E);
    const outCount = new Int32Array(N + 1), inCount = new Int32Array(N + 1);
    let valid = 0;
    for (let e = 0; e < E; e++) {
      const a = index.get(edges[e * 4]), b = index.get(edges[e * 4 + 1]);
      if (a === undefined || b === undefined) continue;
      from[valid] = a; to[valid] = b; valid++;
      outCount[a + 1]++; inCount[b + 1]++;
    }
    for (let i = 0; i < N; i++) { outCount[i + 1] += outCount[i]; inCount[i + 1] += inCount[i]; }
    const succ = new Int32Array(valid), pred = new Int32Array(valid);
    const outFill = outCount.slice(0, N), inFill = inCount.slice(0, N);
    for (let e = 0; e < valid; e++) { succ[outFill[from[e]]++] = to[e]; pred[inFill[to[e]]++] = from[e]; }

    const root = index.has(0) ? index.get(0) : 0;
    const { idom, postorder, order } = dominators(N, root, outCount, succ, inCount, pred);
    // Retained size: each node's own size plus everything it dominates.
    const retained = Float64Array.from(sizes);
    for (const v of postorder) if (v !== root && idom[v] >= 0) retained[idom[v]] += retained[v];

    // Per class: count, shallow, and retained counted once per class (an
    // instance dominated by another instance of its class is already inside it).
    const summary = new Map();
    for (let i = 0; i < N; i++) {
      if (i === root) continue;
      const name = names[classes[i]] || "(unknown)";
      let entry = summary.get(name);
      if (!entry) { entry = { name, count: 0, shallow: 0, retained: 0, classIndex: classes[i] }; summary.set(name, entry); }
      entry.count++;
      entry.shallow += sizes[i];
      let dominatedBySame = false;
      for (let d = idom[i], steps = 0; d >= 0 && d !== root && steps < 64; d = idom[d], steps++) {
        if (classes[d] === classes[i]) { dominatedBySame = true; break; }
      }
      if (!dominatedBySame && order[i] >= 0) entry.retained += retained[i];
      else if (order[i] < 0) entry.retained += sizes[i];     // unreachable: only itself
    }
    return { ids, sizes, classes, internal, retained, names, total, nodeCount: N, edgeCount: valid, summary, idSet: null };
  }

  // Cooper, Harvey and Kennedy's iterative dominator algorithm over a DFS from the root.
  function dominators(N, root, outStart, succ, inStart, pred) {
    const order = new Int32Array(N).fill(-1);
    const postorder = [];
    const stack = [root], edgeAt = [outStart[root]];
    const visited = new Uint8Array(N);
    visited[root] = 1;
    while (stack.length) {
      const v = stack[stack.length - 1];
      const e = edgeAt[edgeAt.length - 1];
      if (e < outStart[v + 1]) {
        edgeAt[edgeAt.length - 1]++;
        const w = succ[e];
        if (!visited[w]) { visited[w] = 1; stack.push(w); edgeAt.push(outStart[w]); }
      } else {
        order[v] = postorder.length; postorder.push(v);
        stack.pop(); edgeAt.pop();
      }
    }
    const idom = new Int32Array(N).fill(-1);
    idom[root] = root;
    const intersect = (a, b) => {
      while (a !== b) {
        while (order[a] < order[b]) a = idom[a];
        while (order[b] < order[a]) b = idom[b];
      }
      return a;
    };
    let changed = true, rounds = 0;
    while (changed && rounds++ < 100) {
      changed = false;
      for (let k = postorder.length - 1; k >= 0; k--) {
        const v = postorder[k];
        if (v === root) continue;
        let next = -1;
        for (let p = inStart[v]; p < inStart[v + 1]; p++) {
          const u = pred[p];
          if (order[u] < 0 || idom[u] < 0) continue;
          next = next < 0 ? u : intersect(u, next);
        }
        if (next !== idom[v]) { idom[v] = next; changed = true; }
      }
    }
    idom[root] = -1;
    return { idom, postorder, order };
  }

  // What changed between two snapshots, per class: objects are matched by id.
  function compare(base, current) {
    if (!base.idSet) base.idSet = new Set(base.ids);
    if (!current.idSet) current.idSet = new Set(current.ids);
    const rows = new Map();
    const row = (name) => {
      if (!rows.has(name)) rows.set(name, { name, added: 0, deleted: 0, addedSize: 0, freedSize: 0 });
      return rows.get(name);
    };
    for (let i = 0; i < current.ids.length; i++) {
      if (!base.idSet.has(current.ids[i])) { const r = row(current.names[current.classes[i]] || "(unknown)"); r.added++; r.addedSize += current.sizes[i]; }
    }
    for (let i = 0; i < base.ids.length; i++) {
      if (!current.idSet.has(base.ids[i])) { const r = row(base.names[base.classes[i]] || "(unknown)"); r.deleted++; r.freedSize += base.sizes[i]; }
    }
    return Array.from(rows.values()).map((r) => Object.assign(r, { delta: r.added - r.deleted, sizeDelta: r.addedSize - r.freedSize }));
  }

  // ---- panel ---------------------------------------------------------------------------------------------
  const panel = {
    initialized: false,
    snapshots: [],
    selected: -1,
    view: "summary",
    sort: { key: "retained", desc: true },
    expanded: new Set(),
    samples: [],          // { t, js, total }
    gcs: [],
    tracking: false,
    trackingError: null,

    init() {
      $("#memory-snapshot").addEventListener("click", () => this.takeSnapshot());
      $("#memory-gc").addEventListener("click", () => this.collectGarbage());
      $("#memory-clear").addEventListener("click", () => { this.snapshots = []; this.selected = -1; this.render(); });
      $("#memory-copy").addEventListener("click", () => DevTools.rpc("Clipboard.write", { text: this.markdown() }));
      $("#memory-view").addEventListener("change", (e) => { this.view = e.target.value; this.render(); });
      $("#memory-base").addEventListener("change", () => this.render());
      $("#memory-filter").addEventListener("input", debounce(() => this.renderTable(), 120));
      DevTools.on("Protocol.event", ({ method, params }) => this.onProtocolEvent(method, params));
      DevTools.on("Protocol.attached", () => { if (DevTools.activePanel === "memory") this.startTracking(); });
      this.render();
    },

    show() { this.startTracking(); this.drawChart(); },
    hide() { this.stopTracking(); },

    // ---- heap size over time ------------------------------------------------------------------------
    async startTracking() {
      if (this.tracking) return;
      try {
        await DevTools.rpc("Protocol.send", { method: "Memory.startTracking" });
        this.tracking = true; this.trackingError = null;
      } catch (e) {
        // Already tracking (e.g. after a reconnect) is fine.
        if (/already/i.test(e.message)) this.tracking = true; else this.trackingError = e.message;
      }
      this.drawChart();
    },
    stopTracking() {
      if (!this.tracking) return;
      this.tracking = false;
      DevTools.rpc("Protocol.send", { method: "Memory.stopTracking" }).catch(() => {});
    },

    onProtocolEvent(method, params) {
      if (method === "Memory.trackingUpdate" && params.event) {
        const sizes = {};
        for (const c of params.event.categories || []) sizes[c.type] = c.size;
        const total = Object.values(sizes).reduce((s, v) => s + v, 0);
        this.samples.push({ t: params.event.timestamp, js: sizes.javascript || 0, total, sizes });
        if (this.samples.length > 600) this.samples.shift();
        if (DevTools.activePanel === "memory") this.drawChart();
      } else if (method === "Heap.garbageCollected" && params.collection) {
        this.gcs.push(params.collection);
        if (this.gcs.length > 200) this.gcs.shift();
      }
    },

    drawChart() {
      const canvas = $("#memory-chart"), readout = $("#memory-readout");
      if (!canvas) return;
      const width = canvas.clientWidth || 220, height = 70, dpr = devicePixelRatio || 1;
      canvas.width = width * dpr; canvas.height = height * dpr;
      const ctx = canvas.getContext("2d");
      ctx.scale(dpr, dpr);
      ctx.clearRect(0, 0, width, height);
      const last = this.samples[this.samples.length - 1];
      if (!last) {
        readout.textContent = this.trackingError ? "Heap size over time needs the inspector protocol: " + this.trackingError : "Waiting for samples…";
        return;
      }
      const recent = this.samples.slice(-120);
      const max = Math.max(...recent.map((s) => s.js), 1) * 1.15;
      const styles = getComputedStyle(document.documentElement);
      ctx.strokeStyle = styles.getPropertyValue("--accent").trim() || "#1a73e8";
      ctx.fillStyle = (styles.getPropertyValue("--accent-soft").trim() || "#d2e3fc");
      ctx.beginPath();
      recent.forEach((s, i) => {
        const x = (i / Math.max(1, recent.length - 1)) * width, y = height - (s.js / max) * (height - 4);
        if (i) ctx.lineTo(x, y); else ctx.moveTo(x, y);
      });
      ctx.lineTo(width, height); ctx.lineTo(0, height); ctx.closePath(); ctx.fill();
      ctx.beginPath();
      recent.forEach((s, i) => {
        const x = (i / Math.max(1, recent.length - 1)) * width, y = height - (s.js / max) * (height - 4);
        if (i) ctx.lineTo(x, y); else ctx.moveTo(x, y);
      });
      ctx.lineWidth = 1.5; ctx.stroke();
      readout.textContent = `JS heap ${formatBytes(last.js)} · page total ${formatBytes(last.total)}` + (this.gcs.length ? ` · ${this.gcs.length} GCs` : "");
    },

    // ---- snapshots -----------------------------------------------------------------------------------------
    async takeSnapshot() {
      const button = $("#memory-snapshot");
      button.disabled = true;
      $("#memory-status").textContent = "Taking heap snapshot…";
      try {
        const result = await DevTools.rpc("Protocol.send", { method: "Heap.snapshot" });
        $("#memory-status").textContent = "Building the dominator tree…";
        await new Promise((r) => setTimeout(r, 0));
        const started = performance.now();
        const snapshot = parseSnapshot(result.snapshotData);
        snapshot.title = "Snapshot " + (this.snapshots.length + 1);
        snapshot.timestamp = result.timestamp;
        snapshot.parseMs = performance.now() - started;
        this.snapshots.push(snapshot);
        this.selected = this.snapshots.length - 1;
        $("#memory-status").textContent = "";
        this.render();
        return snapshot;
      } catch (e) {
        $("#memory-status").textContent = "Heap snapshots need the inspector protocol: " + e.message;
        throw e;
      } finally {
        button.disabled = false;
      }
    },

    async collectGarbage() {
      try { await DevTools.rpc("Protocol.send", { method: "Heap.gc" }); Toast.show("Garbage collected"); }
      catch (e) { Toast.show("Collect garbage needs the inspector protocol: " + e.message); }
    },

    // ---- rendering ----------------------------------------------------------------------------------------------
    render() {
      const list = $("#memory-snapshots");
      list.textContent = "";
      if (!this.snapshots.length) list.appendChild(h("div", { class: "detail-note" }, "Take a heap snapshot to see which objects use memory, by constructor."));
      this.snapshots.forEach((s, i) => {
        const item = h("div", { class: "app-item" + (i === this.selected ? " selected" : "") }, s.title, h("span", { class: "muted" }, "  " + formatBytes(s.total)));
        item.addEventListener("click", () => { this.selected = i; this.render(); });
        list.appendChild(item);
      });
      const base = $("#memory-base");
      const previous = base.value;
      base.textContent = "";
      this.snapshots.forEach((s, i) => { if (i !== this.selected) base.appendChild(h("option", { value: String(i) }, "compared with " + s.title)); });
      if (previous && Array.from(base.options).some((o) => o.value === previous)) base.value = previous;
      else if (base.options.length) {
        // By default, compare with the snapshot before this one.
        const before = String(this.selected - 1);
        base.value = Array.from(base.options).some((o) => o.value === before) ? before : base.options[0].value;
      }
      base.hidden = this.view !== "comparison";
      this.renderTable();
    },

    rows() {
      const s = this.snapshots[this.selected];
      if (!s) return [];
      const filter = $("#memory-filter").value.trim().toLowerCase();
      let rows;
      if (this.view === "comparison") {
        const base = this.snapshots[+$("#memory-base").value];
        rows = base ? compare(base, s) : [];
      } else {
        rows = Array.from(s.summary.values());
      }
      if (filter) rows = rows.filter((r) => r.name.toLowerCase().includes(filter));
      const key = this.view === "comparison" && !["name", "added", "deleted", "delta", "addedSize", "freedSize", "sizeDelta"].includes(this.sort.key) ? "sizeDelta" : this.sort.key;
      // Deltas sort by magnitude, so the biggest changes either way come first.
      const magnitude = this.view === "comparison" ? Math.abs : (v) => v;
      rows.sort((a, b) => {
        const va = a[key], vb = b[key];
        const ascending = typeof va === "string" ? va.localeCompare(vb) : magnitude(va) - magnitude(vb);
        return this.sort.desc ? -ascending : ascending;
      });
      return rows;
    },

    renderTable() {
      const body = $("#memory-body");
      body.textContent = "";
      const s = this.snapshots[this.selected];
      if (!s) { body.appendChild(h("div", { class: "empty-state" }, "No heap snapshot selected.")); return; }
      const comparison = this.view === "comparison";
      if (comparison && this.snapshots.length < 2) { body.appendChild(h("div", { class: "empty-state" }, "Take a second snapshot to compare with.")); return; }
      const columns = comparison
        ? [["name", "Constructor"], ["added", "# New"], ["deleted", "# Deleted"], ["delta", "# Delta"], ["addedSize", "Alloc. Size"], ["freedSize", "Freed Size"], ["sizeDelta", "Size Delta"]]
        : [["name", "Constructor"], ["count", "Count"], ["shallow", "Shallow Size"], ["retained", "Retained Size"]];
      const table = h("table", { class: "data-table memory-table" });
      const head = h("tr");
      for (const [key, label] of columns) {
        const th = h("th", { "data-sort": key, class: this.sort.key === key ? "sorted" + (this.sort.desc ? " desc" : "") : "" }, label);
        th.addEventListener("click", () => {
          this.sort = this.sort.key === key ? { key, desc: !this.sort.desc } : { key, desc: key !== "name" };
          this.renderTable();
        });
        head.appendChild(th);
      }
      table.appendChild(h("thead", {}, head));
      const tbody = h("tbody");
      const pct = (v) => s.total ? " " + Math.round((v / s.total) * 100) + " %" : "";
      const signed = (n, f = String) => (n > 0 ? "+" : n < 0 ? "−" : "") + f(Math.abs(n));
      for (const r of this.rows().slice(0, 500)) {
        const tr = h("tr", { "data-class": r.name });
        if (comparison) {
          tr.append(h("td", { title: r.name }, r.name), h("td", { class: "num" }, String(r.added)), h("td", { class: "num" }, String(r.deleted)),
            h("td", { class: "num" }, signed(r.delta)), h("td", { class: "num" }, formatBytes(r.addedSize)), h("td", { class: "num" }, formatBytes(r.freedSize)),
            h("td", { class: "num" }, signed(r.sizeDelta, formatBytes)));
          tbody.appendChild(tr);
          continue;
        }
        const open = this.expanded.has(r.name);
        const name = h("td", { title: r.name }, h("span", { class: "tree-arrow" }, open ? "▼" : "▶"), " ", r.name, h("span", { class: "muted" }, " ×" + r.count));
        tr.append(name, h("td", { class: "num" }, String(r.count)), h("td", { class: "num" }, formatBytes(r.shallow) + pct(r.shallow)), h("td", { class: "num" }, formatBytes(r.retained) + pct(r.retained)));
        tr.addEventListener("click", () => { if (open) this.expanded.delete(r.name); else this.expanded.add(r.name); this.renderTable(); });
        tbody.appendChild(tr);
        if (open) {
          let shown = 0;
          for (let i = 0; i < s.ids.length && shown < 50; i++) {
            if (s.classes[i] !== r.classIndex) continue;
            shown++;
            tbody.appendChild(h("tr", { class: "instance" }, h("td", {}, "  " + r.name + " @" + s.ids[i] + (s.internal[i] ? " (internal)" : "")),
              h("td", {}, ""), h("td", { class: "num" }, formatBytes(s.sizes[i])), h("td", { class: "num" }, formatBytes(s.retained[i]))));
          }
          if (r.count > shown) tbody.appendChild(h("tr", { class: "instance" }, h("td", { colspan: "4", class: "muted" }, `  … ${r.count - shown} more`)));
        }
      }
      table.appendChild(tbody);
      body.appendChild(table);
      $("#memory-status").textContent = `${s.title}: ${s.nodeCount.toLocaleString()} objects, ${formatBytes(s.total)}`;
    },

    // The selected snapshot's top classes, for an assistant or a bug report.
    markdown() {
      const s = this.snapshots[this.selected];
      if (!s) return "No heap snapshot.";
      const top = Array.from(s.summary.values()).sort((a, b) => b.retained - a.retained).slice(0, 40);
      return [`# Heap snapshot — ${DevTools.info.url || ""}`, "", `${s.title}: ${s.nodeCount} objects, ${formatBytes(s.total)} total`, "",
        Markdown.table(["Constructor", "Count", "Shallow", "Retained"], top.map((r) => [r.name, r.count, formatBytes(r.shallow), formatBytes(r.retained)]))].join("\n");
    },
  };

  DevTools.register("memory", panel);
  window.SBHeapSnapshot = { parse: parseSnapshot, compare };
})();
