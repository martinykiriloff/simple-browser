// SimpleBrowser DevTools — Agent panel: what an AI agent connected over MCP
// (Settings → Developer) is doing in this tab. Every tool call with its
// arguments, how long it took, and what the agent was told back, including
// screenshots. The app pushes calls in as they finish (`AgentPanel.add`).
// Copy as Markdown gives the whole session for a bug report or to replay.
"use strict";

(function () {
  const AgentPanel = window.AgentPanel = {
    initialized: false,
    calls: [],
    client: null,
    filter: "",
    errorsOnly: false,
    expanded: new Set(),

    init() {
      $("#agent-clear").addEventListener("click", () => { this.calls = []; this.expanded.clear(); this.render(); });
      $("#agent-filter").addEventListener("input", (e) => { this.filter = e.target.value.toLowerCase(); this.render(); });
      $("#agent-errors").addEventListener("change", (e) => { this.errorsOnly = e.target.checked; this.render(); });
      $("#agent-copy").addEventListener("click", () => DevTools.rpc("Clipboard.write", { text: this.markdown() }));
      $("#agent-save").addEventListener("click", () => DevTools.rpc("DevTools.saveFile", { name: "agent-session.md", text: this.markdown() }));
      this.render();
    },

    show() { this.render(); },

    /// Called by the app: one finished tool call, or the whole history.
    add(call) {
      const list = Array.isArray(call) ? call : [call];
      for (const c of list) {
        if (this.calls.some((x) => x.id === c.id)) continue;
        this.calls.push(c);
        if (c.client) this.client = c.client;
      }
      if (this.calls.length > 1000) this.calls.splice(0, this.calls.length - 1000);
      this.updateBadge();
      if (this.initialized && DevTools.activePanel === "agent") this.render();
      return this.calls.length;
    },

    updateBadge() {
      const tab = document.querySelector('#tabs .tab[data-panel="agent"]');
      if (!tab) return;
      tab.hidden = false;
      const errors = this.calls.filter((c) => c.isError).length;
      tab.textContent = "Agent" + (this.calls.length ? ` (${this.calls.length}${errors ? ", " + errors + " ✗" : ""})` : "");
    },

    visible() {
      return this.calls.filter((c) => (!this.errorsOnly || c.isError) &&
        (!this.filter || c.tool.includes(this.filter) || JSON.stringify(c.arguments).toLowerCase().includes(this.filter) || (c.result || "").toLowerCase().includes(this.filter)));
    },

    render() {
      const body = $("#agent-list");
      if (!body) return;
      $("#agent-client").textContent = this.client ? `Connected: ${this.client}` : "";
      body.textContent = "";
      if (!this.calls.length) {
        body.appendChild(h("div", { class: "empty-state agent-empty" },
          h("div", { class: "agent-empty-title" }, "No agent has acted in this tab yet."),
          h("div", {}, "Turn on Settings → Developer → “Let AI agents control this browser over MCP”, add it to Claude Code, Cursor or Codex with the copied command, and every tool call the agent makes here shows up in this list: arguments, timing, and exactly what the agent was told.")));
        return;
      }
      const first = this.calls[0].time;
      for (const c of this.visible()) {
        const open = this.expanded.has(c.id);
        const row = h("div", { class: "agent-call" + (c.isError ? " agent-error" : "") + (open ? " open" : "") });
        const head = h("div", { class: "agent-head" },
          h("span", { class: "agent-arrow" }, open ? "▾" : "▸"),
          h("span", { class: "agent-time" }, "+" + ((c.time - first) / 1000).toFixed(1) + "s"),
          h("span", { class: "agent-tool" }, c.tool),
          h("span", { class: "agent-args" }, this.argsSummary(c.arguments)),
          h("span", { class: "agent-summary" }, (c.isError ? "✗ " : "") + this.firstLine(c.result)),
          h("span", { class: "agent-ms" }, c.ms + " ms"));
        head.addEventListener("click", () => { open ? this.expanded.delete(c.id) : this.expanded.add(c.id); this.render(); });
        row.appendChild(head);
        if (open) {
          const detail = h("div", { class: "agent-detail" });
          detail.appendChild(h("div", { class: "agent-label" }, "Arguments"));
          detail.appendChild(h("pre", { class: "code selectable" }, JSON.stringify(c.arguments, null, 2)));
          detail.appendChild(h("div", { class: "agent-label" }, "Result" + (c.isError ? " (error)" : "")));
          for (const image of c.images || []) detail.appendChild(h("img", { class: "agent-image", src: `data:${image.mimeType};base64,${image.data}` }));
          detail.appendChild(h("pre", { class: "code selectable agent-result" }, c.result || ""));
          const actions = h("div", { class: "agent-actions" });
          const copy = h("button", { class: "text-button" }, "Copy call");
          copy.addEventListener("click", (e) => { e.stopPropagation(); DevTools.rpc("Clipboard.write", { text: this.callMarkdown(c) }); });
          actions.appendChild(copy);
          const target = c.arguments && (c.arguments.selector || null);
          if (target) {
            const reveal = h("button", { class: "text-button" }, "Reveal element");
            reveal.addEventListener("click", async (e) => {
              e.stopPropagation();
              try {
                const { nodeIds } = await DevTools.rpc("DOM.performSearch", { query: target });
                if (nodeIds && nodeIds.length) { DevTools.showPanel("elements"); DevTools.panels.elements.revealNode(nodeIds[0], true); }
                else Toast.show("Nothing on the page matches " + target + " now");
              } catch (err) { Toast.show(err.message); }
            });
            actions.appendChild(reveal);
          }
          detail.appendChild(actions);
          row.appendChild(detail);
        }
        body.appendChild(row);
      }
      body.scrollTop = body.scrollHeight;
    },

    argsSummary(args) {
      if (!args) return "";
      const parts = [];
      for (const [k, v] of Object.entries(args)) {
        if (k === "tabId") continue;
        const text = typeof v === "string" ? JSON.stringify(v.length > 60 ? v.slice(0, 59) + "…" : v) : JSON.stringify(v);
        parts.push(k + ": " + (text.length > 70 ? text.slice(0, 69) + "…" : text));
      }
      return parts.join(", ");
    },

    firstLine(text) {
      const line = (text || "").split("\n").find((l) => l.trim()) || "";
      return line.length > 140 ? line.slice(0, 139) + "…" : line;
    },

    callMarkdown(c) {
      return [`### ${c.tool} ${c.isError ? "✗" : "✓"} (${c.ms} ms)`, "", "```json", JSON.stringify(c.arguments || {}, null, 2), "```", "",
        "```", (c.result || "").slice(0, 20000), "```", ""].join("\n");
    },

    markdown() {
      const out = [`# Agent session${this.client ? " — " + this.client : ""}`, "", `${this.calls.length} tool calls, ${this.calls.filter((c) => c.isError).length} errors.`, ""];
      for (const c of this.calls) out.push(this.callMarkdown(c));
      return out.join("\n");
    },
  };

  DevTools.register("agent", AgentPanel);
})();
