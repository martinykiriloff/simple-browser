// SimpleBrowser DevTools — dataLayer: every push to `window.dataLayer` (Google
// Tag Manager and gtag), recorded from document start, beside the GA4 hits
// the page actually sent. Filter, inspect each push as a tree, see the
// merged model, push a test event, export everything as JSON.
"use strict";

(function () {
  const call = (method, params = {}) => DevTools.rpc("DataLayer.call", { method, params });
  const GA_HIT = /^https:\/\/(?:[\w-]+\.)?(?:google-analytics\.com|analytics\.google\.com)\/(?:g\/collect|j\/collect|collect|mp\/collect)/;

  const panel = {
    initialized: false,
    events: [],
    hits: [],
    selected: null,
    filter: "",
    showHits: true,
    timer: null,
    containers: [],

    init() {
      $("#dl-clear").addEventListener("click", async () => { await call("DataLayer.clear").catch(() => {}); this.events = []; this.selected = null; this.render(); });
      $("#dl-filter").addEventListener("input", (e) => { this.filter = e.target.value.toLowerCase(); this.render(); });
      $("#dl-hits").addEventListener("change", (e) => { this.showHits = e.target.checked; this.render(); });
      $("#dl-model").addEventListener("click", () => this.showModel());
      $("#dl-push").addEventListener("click", () => this.pushTest());
      $("#dl-copy").addEventListener("click", () => SBExt.copy(JSON.stringify(this.events.map((e) => ({ event: e.event, time: e.t, data: SBExt.display(e.data) })), null, 2), "dataLayer copied as JSON"));
    },

    show() {
      this.refresh();
      clearInterval(this.timer);
      this.timer = setInterval(() => this.refresh(), 1000);
    },
    hide() { clearInterval(this.timer); },

    async detect() {
      if (!SBExt.enabled("dataLayer")) { SBExt.showTab("datalayer", false); return false; }
      try {
        const state = await call("DataLayer.events", { after: 1e12 });
        SBExt.showTab("datalayer", !state.__missing && state.present);
        return state.present;
      } catch (_) { return false; }
    },

    async refresh() {
      let state;
      try { state = await call("DataLayer.events", { after: 0 }); } catch (e) { return; }
      if (state.__missing) {
        $("#dl-list").textContent = "";
        $("#dl-list").appendChild(SBExt.empty("The dataLayer inspector is off for this tab.", "Turn it on in Develop → Developer Extensions, then open a new tab."));
        return;
      }
      const changed = state.events.length !== this.events.length || (state.events.length && state.events[state.events.length - 1].i !== this.events[this.events.length - 1]?.i);
      this.events = state.events;
      this.containers = state.containers;
      this.names = state.names;
      await this.loadHits();
      if (changed || !this.rendered) this.render();
    },

    /// GA4 / Universal Analytics hits from the network log, read into events.
    async loadHits() {
      let requests = [];
      try { requests = await DevTools.rpc("Network.getRequests"); } catch (_) {}
      const hits = [];
      for (const r of requests) {
        if (!GA_HIT.test(r.url)) continue;
        const params = new URLSearchParams(r.url.split("?")[1] || "");
        const bodyLines = (r.requestBody || "").split("\n").filter(Boolean);
        const batches = bodyLines.length ? bodyLines.map((line) => new URLSearchParams(line)) : [new URLSearchParams()];
        for (const extra of batches) {
          const all = new URLSearchParams(params);
          for (const [k, v] of extra) all.set(k, v);
          const data = {};
          for (const [k, v] of all) data[k] = v;
          const name = all.get("en") || all.get("t") || "hit";
          hits.push({ i: "hit-" + r.id + "-" + hits.length, hit: true, event: name, at: Date.parse(r.startedAt) || 0, tid: all.get("tid"), status: r.statusCode, data, url: r.url });
        }
      }
      this.hits = hits;
    },

    rows() {
      const q = this.filter;
      const rows = this.events.map((e) => ({ ...e, hit: false }));
      if (this.showHits) rows.push(...this.hits);
      rows.sort((a, b) => (a.at || 0) - (b.at || 0));
      return q ? rows.filter((r) => r.event.toLowerCase().includes(q) || JSON.stringify(r.data).toLowerCase().includes(q)) : rows;
    },

    render() {
      this.rendered = true;
      const chips = $("#dl-containers");
      chips.textContent = "";
      for (const id of this.containers) chips.appendChild(h("span", { class: "dl-chip", title: "Tag container on this page" }, id));
      if (this.names && this.names.length > 1) chips.appendChild(h("span", { class: "muted" }, "layers: " + this.names.join(", ")));
      const list = $("#dl-list");
      list.textContent = "";
      const rows = this.rows();
      if (!rows.length) {
        list.appendChild(SBExt.empty(this.events.length || this.hits.length ? "Nothing matches the filter." : "No dataLayer pushes yet.",
          "Pushes to window.dataLayer (Google Tag Manager, gtag) appear here from the moment the page starts, along with the GA4 hits it sends."));
        $("#dl-detail").textContent = "";
        return;
      }
      const start = rows[0].at || 0;
      for (const r of rows) {
        const keys = r.hit ? Object.keys(r.data).filter((k) => /^(ep|epn|up)\./.test(k)).map((k) => k.replace(/^(ep|epn|up)\./, "")) :
          (r.data && typeof r.data === "object" && !Array.isArray(r.data) ? Object.keys(r.data).filter((k) => k !== "event") : []);
        const row = h("div", { class: "dl-row" + (r.i === this.selected ? " selected" : "") + (r.hit ? " dl-hit" : "") + (r.event.startsWith("gtm.") ? " dl-gtm" : "") },
          h("span", { class: "dl-time mono" }, "+" + (((r.at || 0) - start) / 1000).toFixed(2) + "s"),
          h("span", { class: "dl-kind" }, r.hit ? "GA4 hit" : r.gtag ? "gtag" : r.origin === "before" ? "initial" : "push"),
          h("span", { class: "dl-event" }, r.event),
          h("span", { class: "dl-keys muted" }, keys.slice(0, 8).join(", ") + (keys.length > 8 ? "…" : "")),
          r.hit && r.tid ? h("span", { class: "dl-chip" }, r.tid) : null);
        row.addEventListener("click", () => { this.selected = r.i; this.render(); });
        list.appendChild(row);
      }
      const chosen = rows.find((r) => r.i === this.selected);
      const detail = $("#dl-detail");
      detail.textContent = "";
      if (chosen) {
        const copy = h("button", { class: "text-button" }, "Copy JSON");
        copy.addEventListener("click", () => SBExt.copy(JSON.stringify(SBExt.display(chosen.data), null, 2)));
        detail.append(h("div", { class: "react-detail-head" }, h("span", { class: "dl-event" }, chosen.event), h("span", { class: "react-detail-tools" }, copy)));
        if (chosen.hit) detail.appendChild(this.hitTable(chosen));
        else detail.appendChild(SBExt.tree(chosen.data, 3));
      } else {
        detail.appendChild(SBExt.empty("Select a push to see what it carried."));
      }
    },

    hitTable(hit) {
      const names = { en: "event name", tid: "measurement ID", cid: "client ID", sid: "session ID", dl: "page location", dt: "page title", dr: "referrer", ul: "language", sr: "screen", _p: "page load ID" };
      const table = h("table", { class: "data-table dl-table" }, h("thead", {}, h("tr", {}, h("th", {}, "Parameter"), h("th", {}, "Value"))));
      const body = h("tbody");
      for (const [k, v] of Object.entries(hit.data)) {
        body.appendChild(h("tr", {}, h("td", { class: "mono", title: names[k] || "" }, k + (names[k] ? "  (" + names[k] + ")" : "")), h("td", { class: "mono selectable" }, v)));
      }
      table.appendChild(body);
      return h("div", {}, h("div", { class: "muted dl-hit-status" }, `HTTP ${hit.status ?? "?"} · ${hit.url.split("?")[0]}`), table);
    },

    async showModel() {
      const model = await call("DataLayer.state", { name: (this.names && this.names[0]) || "dataLayer" }).catch((e) => ({ error: e.message }));
      const detail = $("#dl-detail");
      detail.textContent = "";
      detail.append(h("div", { class: "react-detail-head" }, h("span", { class: "dl-event" }, "Merged model"), h("span", { class: "muted" }, " every push folded together, as GTM's variables read it")),
        SBExt.tree(model, 2));
    },

    pushTest() {
      // An editor in the detail pane: DevTools has no prompt().
      const detail = $("#dl-detail");
      detail.textContent = "";
      const editor = h("textarea", { class: "react-input mono dl-editor", spellcheck: "false" });
      editor.value = '{\n  "event": "devtools_test",\n  "source": "SimpleBrowser"\n}';
      const push = h("button", { class: "text-button primary" }, "Push");
      const status = h("span", { class: "muted" });
      push.addEventListener("click", async () => {
        let item;
        try { item = JSON.parse(editor.value); } catch (e) { status.textContent = "Not valid JSON: " + e.message; return; }
        try { await call("DataLayer.push", { name: (this.names && this.names[0]) || "dataLayer", item }); }
        catch (e) { status.textContent = e.message; return; }
        status.textContent = "Pushed";
        setTimeout(() => this.refresh(), 150);
      });
      detail.append(h("div", { class: "react-detail-head" }, h("span", { class: "dl-event" }, "Push a test event")), editor, h("div", { class: "dl-push-row" }, push, status));
      editor.focus();
    },
  };

  DevTools.register("datalayer", panel);
  window.SBDataLayer = panel;
})();
