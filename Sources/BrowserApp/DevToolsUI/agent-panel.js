// Keel DevTools — Agent panel: what an AI agent connected over MCP
// (Settings → Developer) is doing in this tab. Every tool call with its
// arguments, how long it took, and what the agent was told back, including
// screenshots. The app pushes calls in as they finish (`AgentPanel.add`).
// Copy for AI gives the whole session as Markdown, for a bug report or to replay.
// The header names the trust-layer session (id, elapsed time, mode) and
// any approval it is waiting on; each call has a status dot and the tokens
// its result cost the agent.
"use strict";

(function () {
  const AgentPanel = window.AgentPanel = {
    initialized: false,
    calls: [],
    client: null,
    filter: "",
    errorsOnly: false,
    expanded: new Set(),
    session: null,            // the tab's live session from the app, if any
    ticker: null,

    init() {
      $("#agent-clear").addEventListener("click", () => { this.calls = []; this.expanded.clear(); this.render(); });
      $("#agent-filter").addEventListener("input", (e) => { this.filter = e.target.value.toLowerCase(); this.render(); });
      $("#agent-errors").addEventListener("change", (e) => { this.errorsOnly = e.target.checked; this.render(); });
      $("#agent-copy").addEventListener("click", () => DevTools.rpc("Clipboard.write", { text: this.markdown() }));
      $("#agent-save").addEventListener("click", () => DevTools.rpc("DevTools.saveFile", { name: "agent-session.md", text: this.markdown() }));
      this.render();
    },

    show() {
      this.render();
      this.refreshSession();
      clearInterval(this.ticker);
      let n = 0;
      this.ticker = setInterval(() => { this.renderHeader(); if (++n % 3 === 0) this.refreshSession(); }, 1000);
    },

    hide() { clearInterval(this.ticker); this.ticker = null; },

    async refreshSession() {
      try { this.session = await DevTools.rpc("Agent.session"); } catch (_) { this.session = null; }
      const waiting = JSON.stringify((this.session && this.session.waiting) || []);
      if (waiting !== this.lastWaiting) { this.lastWaiting = waiting; if (DevTools.activePanel === "agent") this.render(); }
      else this.renderHeader();
    },

    /// Tokens the way the app counts them (TokenEstimate): ~4 ASCII characters a token, ~1.5 for other scripts.
    tokens(text) {
      if (!text) return 0;
      let ascii = 0, other = 0;
      for (const ch of text) { if (ch.codePointAt(0) < 128) ascii++; else other++; }
      return Math.max(1, Math.ceil(ascii / 4 + other / 1.5));
    },
    callTokens(c) { return typeof c.tokens === "number" ? c.tokens : this.tokens(c.result); },
    formatTokens(n) { return n < 1000 ? n + " tokens" : (n / 1000).toFixed(1) + "k tokens"; },

    clock(ms) {
      const s = Math.max(0, Math.floor(ms / 1000));
      const p = (n) => String(n).padStart(2, "0");
      return s >= 3600 ? `${Math.floor(s / 3600)}:${p(Math.floor(s / 60) % 60)}:${p(s % 60)}` : `${p(Math.floor(s / 60))}:${p(s % 60)}`;
    },

    /// "session a91f · 02:14": the live session, else the one the calls name.
    sessionSummary() {
      const live = this.session;
      const last = this.calls[this.calls.length - 1];
      const id = live ? live.id : (last && last.session) || null;
      const started = live ? live.started : this.calls.length ? this.calls[0].time : null;
      const end = live && live.state !== "stopped" ? Date.now() : last ? last.time + (last.ms || 0) : null;
      return { id, elapsed: started != null && end != null ? this.clock(end - started) : null, live };
    },

    renderHeader() {
      const el = $("#agent-session");
      if (!el) return;
      el.textContent = "";
      const { id, elapsed, live } = this.sessionSummary();
      el.hidden = !this.calls.length && !live;
      if (el.hidden) return;
      const waiting = live && live.waiting && live.waiting.length;
      const errors = this.calls.filter((c) => c.isError).length;
      const state = waiting ? "waiting" : live && live.state === "running" ? "live" : live ? live.state : "ended";
      el.appendChild(h("span", { class: "agent-dot " + (waiting ? "waiting" : errors && !live ? "failed" : live ? "done" : "idle") }));
      el.appendChild(h("span", { class: "agent-session-id" }, (id ? "session " + id : "agent calls") + (elapsed ? " · " + elapsed : "")));
      if (live) el.appendChild(h("span", { class: "agent-chip " + (live.mode === "borrowed" ? "borrowed" : "sandbox") }, live.mode === "borrowed" ? "Borrowed" : "Sandbox"));
      el.appendChild(h("span", { class: "muted" }, [this.client || (live && live.client) || "", state].filter(Boolean).join(" · ")));
      const total = this.calls.reduce((n, c) => n + this.callTokens(c), 0);
      el.appendChild(h("span", { class: "toolbar-spacer" }));
      el.appendChild(h("span", { class: "muted" }, `${this.calls.length} call${this.calls.length === 1 ? "" : "s"}${errors ? ` · ${errors} failed` : ""}${waiting ? ` · ${waiting} waiting` : ""} · ${this.formatTokens(total)} read`));
    },

    /// Called by the app: one finished tool call, or the whole history.
    add(call) {
      const list = Array.isArray(call) ? call : [call];
      for (const c of list) {
        if (this.calls.some((x) => x.id === c.id)) continue;
        this.calls.push(c);
        if (c.client) this.client = c.client;
      }
      if (this.calls.length > 1000) this.calls.splice(0, this.calls.length - 1000);
      if (window.Actors) Actors.addCalls(list);
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
      this.renderHeader();
      body.textContent = "";
      const waiting = (this.session && this.session.waiting) || [];
      if (!this.calls.length && !waiting.length) {
        body.appendChild(h("div", { class: "empty-state agent-empty" },
          h("div", { class: "agent-empty-title" }, "No agent has acted in this tab yet."),
          h("div", {}, "Turn on Settings → Developer → “Let AI agents control this browser over MCP”, add it to Claude Code, Cursor or Codex with the copied command, and every tool call the agent makes here shows up in this list: arguments, timing, and exactly what the agent was told.")));
        return;
      }
      const first = this.calls.length ? this.calls[0].time : (this.session && this.session.started) || Date.now();
      for (const c of this.visible()) {
        const open = this.expanded.has(c.id);
        const row = h("div", { class: "agent-call" + (c.isError ? " agent-error" : "") + (open ? " open" : "") });
        const head = h("div", { class: "agent-head" },
          h("span", { class: "agent-arrow" }, open ? "▾" : "▸"),
          h("span", { class: "agent-dot " + (c.isError ? "failed" : "done"), title: c.isError ? "Failed or refused" : "Done" }),
          h("span", { class: "agent-time" }, "+" + ((c.time - first) / 1000).toFixed(1) + "s"),
          h("span", { class: "agent-tool" }, c.tool),
          h("span", { class: "agent-args" }, this.argsSummary(c.arguments)),
          h("span", { class: "agent-summary" }, (c.isError ? "✗ " : "") + this.firstLine(c.result)),
          h("span", { class: "agent-tokens", title: "What the result cost the agent, estimated as the app counts tokens" }, this.formatTokens(this.callTokens(c))),
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
      for (const w of waiting) {
        body.appendChild(h("div", { class: "agent-waiting" },
          h("span", { class: "agent-arrow" }),
          h("span", { class: "agent-dot waiting", title: "Waiting for your OK" }),
          h("span", { class: "agent-time" }, "+" + ((w.time - first) / 1000).toFixed(1) + "s"),
          h("span", { class: "agent-tool" }, w.tool),
          h("span", { class: "agent-summary" }, "Waiting for approval: " + w.target + (w.fromPage ? " — the instruction came from page content" : "")),
          h("span", { class: "agent-ms" }, this.clock(Date.now() - w.time))));
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
      return [`### ${c.tool} ${c.isError ? "✗" : "✓"} (${c.ms} ms, ${this.formatTokens(this.callTokens(c))})`, "", "```json", JSON.stringify(c.arguments || {}, null, 2), "```", "",
        "```", (c.result || "").slice(0, 20000), "```", ""].join("\n");
    },

    markdown() {
      const { id, elapsed, live } = this.sessionSummary();
      const total = this.calls.reduce((n, c) => n + this.callTokens(c), 0);
      const page = (DevTools.info && DevTools.info.url) || "";
      const out = [`# Agent session${id ? " " + id : ""}${this.client ? " — " + this.client : ""}`, "",
        [live ? `Mode: ${live.mode}` : null, elapsed ? `Elapsed: ${elapsed}` : null, page ? `Tab: ${page}` : null].filter(Boolean).join(" · "),
        `${this.calls.length} tool calls, ${this.calls.filter((c) => c.isError).length} errors, ~${total} tokens of results.`, ""];
      if (this.calls.length) {
        out.push("| # | Time | Tool | Arguments | Status | ms | Tokens |", "|---|---|---|---|---|---|---|");
        const first = this.calls[0].time;
        this.calls.forEach((c, i) => out.push(`| ${i + 1} | +${((c.time - first) / 1000).toFixed(1)}s | ${c.tool} | ${this.argsSummary(c.arguments).replace(/\|/g, "\\|")} | ${c.isError ? "failed" : "done"} | ${c.ms} | ${this.callTokens(c)} |`));
        out.push("");
      }
      for (const w of (live && live.waiting) || []) out.push(`Waiting for approval: ${w.tool} ${w.target}`, "");
      for (const c of this.calls) out.push(this.callMarkdown(c));
      return out.join("\n");
    },
  };

  DevTools.register("agent", AgentPanel);
})();
