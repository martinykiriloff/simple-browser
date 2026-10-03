// Keel DevTools — Snapshot panel: the exact text the `snapshot` tool hands
// an AI agent for this tab (the accessibility tree with refs, cut to the
// session's token budget and marked as untrusted page content), what it
// costs in tokens, and how that compares with dumping the whole DOM.
// Clicking a line with a ref rings that element on the page, the way an
// agent's target is shown.
"use strict";

(function () {
  const LINE = /^(\s*)- (\S+)(?: "((?:[^"\\]|\\.)*)")?.*?\[ref=(e\d+)\]/;
  const INTERACTIVE = new Set(["button", "link", "textbox", "searchbox", "checkbox", "radio", "combobox", "listbox", "option", "menuitem",
    "menuitemcheckbox", "menuitemradio", "slider", "spinbutton", "switch", "tab", "treeitem"]);

  const panel = window.SnapshotPanel = {
    initialized: false,
    data: null,
    interactiveOnly: false,
    selectedRef: null,
    stale: true,
    loading: false,
    refFilter: "",

    init() {
      $("#snapshot-refresh").addEventListener("click", () => this.load());
      $("#snapshot-interactive").addEventListener("change", (e) => { this.interactiveOnly = e.target.checked; this.load(); });
      $("#snapshot-copy").addEventListener("click", () => this.data && DevTools.rpc("Clipboard.write", { text: this.markdown() }));
      $("#snapshot-ref-filter").addEventListener("input", debounce((e) => { this.refFilter = e.target.value.toLowerCase(); this.renderRefs(); }, 80));
      $("#snapshot-text").addEventListener("click", (e) => {
        const line = e.target.closest(".snap-line[data-ref]");
        if (line) this.select(line.dataset.ref);
      });
      DevTools.on("Page.navigated", (p) => {
        if (p.phase === "committed") { this.stale = true; this.selectedRef = null; this.renderStats(); }
        if (p.phase === "finished" && DevTools.activePanel === "snapshot") this.load();
      });
    },

    show() { if (this.stale || !this.data) this.load(); },
    hide() { this.clearSpotlight(); },

    async load() {
      if (this.loading) return;
      this.loading = true;
      this.clearSpotlight();
      $("#snapshot-status").textContent = "Taking the snapshot…";
      try {
        this.data = await DevTools.rpc("Agent.snapshot", { interactiveOnly: this.interactiveOnly });
        this.data.lines = this.data.text.split("\n");
        this.data.refs = [];
        this.data.lines.forEach((text, index) => {
          const m = LINE.exec(text);
          if (m) this.data.refs.push({ ref: m[4], role: m[2], name: (m[3] || "").replace(/\\"/g, '"'), index, depth: m[1].length / 2 });
        });
        this.stale = false;
        $("#snapshot-status").textContent = "";
      } catch (err) {
        this.data = null;
        $("#snapshot-status").textContent = err.message;
      }
      this.loading = false;
      this.render();
    },

    render() {
      this.renderStats();
      this.renderText();
      this.renderRefs();
    },

    renderStats() {
      const el = $("#snapshot-stats");
      el.textContent = "";
      const d = this.data;
      if (!d) return;
      const pct = d.domTokens ? Math.max(1, Math.round((d.tokens / d.domTokens) * 100)) : null;
      el.appendChild(h("span", { class: "snap-tokens", title: "What the agent's context pays for this result, estimated the way the app counts tokens (~4 characters a token)" }, AgentPanel.formatTokens(d.tokens)));
      el.appendChild(h("span", { class: "muted" }, `${d.refs.length} refs · ${d.lines.length} lines`));
      if (pct != null) {
        el.appendChild(h("span", { class: "snap-vs", title: `document.documentElement.outerHTML: ${d.domChars.toLocaleString()} characters, ${d.domTokens.toLocaleString()} tokens` },
          `${pct}% of a full-DOM dump (${AgentPanel.formatTokens(d.domTokens)})`));
      }
      const used = Math.min(100, Math.round((d.treeTokens / d.budget) * 100));
      el.appendChild(h("span", { class: "snap-budget" + (d.truncated ? " over" : ""), title: d.session ? `The snapshot budget of session ${d.session}` : "The default snapshot budget of a new agent session" },
        h("span", { class: "snap-meter" }, h("i", { style: `width:${used}%` })),
        `Budget ${d.budget.toLocaleString()} · ${d.truncated ? "cut to fit" : used + "% used"}`));
      el.appendChild(h("span", { class: "muted" }, d.session ? `as session ${d.session}${d.client ? " (" + d.client + ")" : ""} receives it` : "as a new agent session would receive it"));
      if (this.stale) el.appendChild(h("span", { class: "snap-stale" }, "Page changed — refresh"));
    },

    renderText() {
      const body = $("#snapshot-text");
      body.textContent = "";
      const d = this.data;
      if (!d) { body.appendChild(h("div", { class: "empty-state" }, "No snapshot. Is a page loaded?")); return; }
      const refsByLine = new Map(d.refs.map((r) => [r.index, r]));
      const frag = document.createDocumentFragment();
      d.lines.forEach((text, index) => {
        const ref = refsByLine.get(index);
        const line = h("div", { class: "snap-line" + (ref ? " has-ref" : "") + (ref && ref.ref === this.selectedRef ? " selected" : ""), dataset: ref ? { ref: ref.ref } : null },
          h("span", { class: "snap-no" }, String(index + 1)));
        const content = h("span", { class: "snap-content" });
        if (ref) {
          const at = text.indexOf("[ref=" + ref.ref + "]");
          content.appendChild(document.createTextNode(text.slice(0, at)));
          content.appendChild(h("span", { class: "snap-ref" }, "[ref=" + ref.ref + "]"));
          content.appendChild(document.createTextNode(text.slice(at + ref.ref.length + 6)));
        } else {
          content.textContent = text;
        }
        line.appendChild(content);
        frag.appendChild(line);
      });
      body.appendChild(frag);
    },

    renderRefs() {
      const list = $("#snapshot-refs");
      list.textContent = "";
      const d = this.data;
      if (!d) return;
      const refs = d.refs.filter((r) => !this.refFilter || (r.ref + " " + r.role + " " + r.name).toLowerCase().includes(this.refFilter));
      $("#snapshot-ref-count").textContent = `${refs.length} of ${d.refs.length}`;
      for (const r of refs) {
        list.appendChild(h("div", { class: "snap-refrow" + (r.ref === this.selectedRef ? " selected" : "") + (INTERACTIVE.has(r.role) ? " interactive" : ""),
          title: "Ring this element on the page", onclick: () => this.select(r.ref, true) },
          h("span", { class: "snap-ref" }, r.ref), h("span", { class: "snap-role" }, r.role), h("span", { class: "snap-name" }, r.name)));
      }
    },

    async select(ref, scroll) {
      if (this.selectedRef === ref) { this.clearSpotlight(); this.renderSelection(); return; }
      this.selectedRef = ref;
      this.renderSelection(scroll);
      try {
        await DevTools.rpc("Agent.spotlight", { ref });
        $("#snapshot-status").textContent = "";
      } catch (err) {
        $("#snapshot-status").textContent = err.message;
      }
    },

    renderSelection(scroll) {
      for (const el of $$("#snapshot-text .snap-line.selected, #snapshot-refs .snap-refrow.selected")) el.classList.remove("selected");
      if (!this.selectedRef) return;
      const line = $(`#snapshot-text .snap-line[data-ref="${this.selectedRef}"]`);
      if (line) { line.classList.add("selected"); if (scroll) line.scrollIntoView({ block: "center" }); }
      for (const row of $$("#snapshot-refs .snap-refrow")) row.classList.toggle("selected", row.querySelector(".snap-ref").textContent === this.selectedRef);
    },

    clearSpotlight() {
      if (!this.selectedRef) return;
      this.selectedRef = null;
      DevTools.rpc("Agent.clearSpotlight").catch(() => {});
    },

    markdown() {
      const d = this.data;
      const pct = d.domTokens ? Math.round((d.tokens / d.domTokens) * 100) : null;
      return [`# Agent snapshot of ${d.url}`, "",
        `${d.tokens} tokens${pct != null ? ` (${pct}% of a full-DOM dump, ${d.domTokens} tokens)` : ""} · ${d.refs.length} refs · budget ${d.budget}${d.truncated ? " (cut to fit)" : ""}${this.interactiveOnly ? " · interactiveOnly" : ""}.`,
        "This is exactly what the `snapshot` tool returns to an agent for this tab. Refs (e.g. e14) are what click/fill take.", "",
        "```", d.text, "```", ""].join("\n");
    },
  };

  DevTools.register("snapshot", panel);
})();
