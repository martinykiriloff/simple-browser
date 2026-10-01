// SimpleBrowser DevTools — Console panel.
"use strict";

(function () {
  const URL_RE = /\bhttps?:\/\/[^\s"'<>)]+/g;

  const panel = {
    initialized: false,
    entries: [],
    messagesEl: null,
    prompt: null,
    filterText: "",
    level: "all",
    preserve: false,
    timestamps: false,
    groupStack: [],
    reportedFailures: new Set(),
    history: [],
    historyIndex: 0,
    draft: "",
    counts: { errors: 0, warnings: 0 },
    completions: [],
    completionIndex: -1,

    init() {
      this.messagesEl = $("#console-messages");
      this.prompt = $("#console-prompt");
      try { this.history = JSON.parse(localStorage.getItem("devtools.console.history") || "[]"); } catch (_) {}
      this.historyIndex = this.history.length;

      $("#console-clear").addEventListener("click", () => this.clear());
      $("#console-filter").addEventListener("input", debounce(() => { this.filterText = $("#console-filter").value.toLowerCase(); this.applyFilter(); }, 100));
      $("#console-levels").addEventListener("change", () => { this.level = $("#console-levels").value; this.applyFilter(); });
      $("#console-preserve").addEventListener("change", (e) => { this.preserve = e.target.checked; });
      $("#console-timestamps").addEventListener("change", (e) => { this.timestamps = e.target.checked; this.messagesEl.classList.toggle("show-timestamps", this.timestamps); this.rerender(); });
      this.messagesEl.addEventListener("click", () => { if (!getSelection().toString()) this.prompt.focus(); });
      this.messagesEl.addEventListener("contextmenu", (e) => {
        const el = e.target.closest(".console-message");
        const item = el && this.entries.find((i) => i.el === el);
        e.preventDefault();
        ContextMenu.show(e.clientX, e.clientY, this.contextItems(item));
      });

      this.prompt.addEventListener("keydown", (e) => this.onPromptKey(e));
      this.prompt.addEventListener("input", () => { this.autoGrow(); this.requestCompletions(); });
      document.addEventListener("keydown", (e) => {
        if ((e.metaKey || e.ctrlKey) && e.key === "k" && DevTools.activePanel === "console") { e.preventDefault(); this.clear(); }
      });

      DevTools.on("Console.entryAdded", (item) => this.add(item));
      DevTools.on("Page.navigated", (p) => {
        if (p.phase === "started") {
          this.reportedFailures.clear();
          if (!this.preserve) this.clearView();
        }
        if (p.phase === "committed") this.addLocal("info", "Navigated to " + p.url, { type: "navigation" });
      });
      DevTools.on("Network.requestAdded", ({ request }) => this.reportFailure(request));
      DevTools.on("Network.requestUpdated", ({ request }) => this.reportFailure(request));
      DevTools.on("Recorder.cleared", () => this.clearView());
      this.load();
    },

    show() { this.prompt.focus(); this.scrollToBottom(); },

    async load() {
      let entries = [];
      try { entries = await DevTools.rpc("Console.getEntries"); } catch (_) {}
      this.clearView();
      for (const item of entries) this.add(item, true);
      this.scrollToBottom();
    },

    // ---- entries --------------------------------------------------------------
    add(item, initial) {
      const e = item.entry;
      if (e.type === "clear") {
        if (!this.preserve) this.clearView();
        this.addLocal("info", "Console was cleared", { type: "system" });
        return;
      }
      if (e.type === "groupEnd") { this.groupStack.pop(); return; }

      const prev = this.entries[this.entries.length - 1];
      if (prev && this.canCoalesce(prev, item)) {
        prev.repeat = (prev.repeat || 1) + 1;
        const badge = prev.el.querySelector(".repeat");
        if (badge) badge.textContent = String(prev.repeat);
        else prev.el.insertBefore(h("span", { class: "repeat" }, String(prev.repeat)), prev.el.firstChild.nextSibling);
        return;
      }

      this.entries.push(item);
      if (e.level === "error") this.counts.errors++;
      if (e.level === "warn") this.counts.warnings++;
      DevTools.setBadges(this.counts);

      const wasAtBottom = this.isAtBottom();
      const el = this.render(item);
      item.el = el;
      const parent = this.groupStack[this.groupStack.length - 1] || this.messagesEl;
      parent.appendChild(el);
      if (e.type === "group" || e.type === "groupCollapsed") {
        const container = h("div", { class: "console-group" + (e.type === "groupCollapsed" ? " collapsed" : "") });
        if (e.type === "groupCollapsed") el.classList.add("collapsed");
        parent.appendChild(container);
        this.groupStack.push(container);
        el.addEventListener("click", () => { el.classList.toggle("collapsed"); container.classList.toggle("collapsed"); });
      }
      this.applyFilterTo(item);
      if (wasAtBottom || initial) this.scrollToBottom();
    },

    canCoalesce(prev, item) {
      const a = prev.entry, b = item.entry;
      if (a.type !== "log" || b.type !== "log") return false;
      if (a.level !== b.level || a.message !== b.message) return false;
      if (a.args.length !== b.args.length) return false;
      return a.args.every((arg, i) => !arg.objectId && !b.args[i].objectId && arg.description === b.args[i].description);
    },

    addLocal(level, message, extra = {}) {
      this.add({ entry: { level, type: extra.type || "log", message, args: [], stack: [], timestamp: Date.now(), isUncaught: false }, source: "user", sequence: -1, local: true });
    },

    reportFailure(request) {
      if (!request.isFailure && !request.failure && !(request.statusCode >= 400)) return;
      if (this.reportedFailures.has(request.id)) return;
      this.reportedFailures.add(request.id);
      const message = request.failure
        ? "Failed to load resource: " + request.failure
        : `Failed to load resource: the server responded with a status of ${request.statusCode} ()`;
      this.add({ entry: { level: "error", type: "log", message, args: [], stack: [], timestamp: Date.now(), isUncaught: false },
                 source: "network", sequence: -1, location: request.url });
    },

    render(item) {
      const e = item.entry;
      const el = h("div", { class: `console-message level-${e.level} type-${e.type}`, dataset: { level: e.level } }, h("span", { class: "icon" }));
      if (this.timestamps) el.appendChild(h("span", { class: "timestamp" }, formatTime(e.timestamp)));
      const body = h("div", { class: "body" });

      if (e.type === "command") {
        body.appendChild(h("span", { class: "selectable" }, e.message));
      } else if (e.type === "table" && e.table) {
        const table = h("table", { class: "data-table console-table" });
        table.appendChild(h("thead", {}, h("tr", {}, e.table.columns.map((c) => h("th", {}, c)))));
        table.appendChild(h("tbody", {}, e.table.rows.map((row) => h("tr", {}, row.map((cell) => h("td", { title: cell }, cell))))));
        body.appendChild(table);
        if (e.table.truncatedRows) body.appendChild(h("div", { class: "muted" }, `… ${e.table.truncatedRows} more rows`));
        if (e.args.length) body.appendChild(ObjectTree.render(e.args[0], { quoteStrings: false }));
      } else if (e.type === "result") {
        if (e.args.length) body.appendChild(ObjectTree.render(e.args[0], { quoteStrings: true }));
        else body.appendChild(document.createTextNode(e.message));
      } else if (e.args.length && !e.isUncaught && !(e.args[0].type === "string" && /%[sdifoOjc]/.test(e.args[0].description))) {
        e.args.forEach((arg, i) => {
          if (i) body.appendChild(document.createTextNode(" "));
          if (arg.type === "string") body.appendChild(this.linkify(arg.description));
          else body.appendChild(ObjectTree.render(arg, { quoteStrings: false }));
        });
      } else {
        body.appendChild(this.linkify(e.message));
      }

      if (e.stack && e.stack.length && (e.level === "error" || e.type === "trace" || e.isUncaught)) {
        const frames = h("div", { class: "console-stack" });
        for (const frame of e.stack.slice(0, 20)) frames.appendChild(this.frameLine(frame));
        const expanded = e.isUncaught || e.type === "trace";
        frames.hidden = !expanded;
        const toggle = h("span", { class: "stack-toggle" }, expanded ? "▼" : "▶");
        toggle.addEventListener("click", (ev) => { ev.stopPropagation(); frames.hidden = !frames.hidden; toggle.textContent = frames.hidden ? "▶" : "▼"; });
        body.insertBefore(toggle, body.firstChild);
        body.appendChild(frames);
      }
      el.appendChild(body);

      const location = item.location || (e.stack && e.stack[0] && e.stack[0].url ? e.stack[0] : null);
      if (location) {
        const where = typeof location === "string" ? { url: location, line: 0, column: 0 } : this.originalPosition(location);
        const label = fileName(where.url) + (where.line ? ":" + where.line : "");
        el.appendChild(h("span", { class: "location", title: where.url, onclick: (ev) => { ev.stopPropagation(); DevTools.openSource(where.url, where.line, where.column); } }, label));
      }
      return el;
    },

    // Stack frames arrive with positions in the generated file; show the
    // original one when a source map is loaded for it.
    originalPosition(frame) {
      const mapped = frame.url && frame.line ? SBSourceMaps.original(frame.url, frame.line, frame.column) : null;
      return mapped || { url: frame.url, line: frame.line, column: frame.column };
    },

    frameLine(frame) {
      const line = h("span", { class: "frame" }, (frame.functionName || "(anonymous)") + " @ ");
      if (frame.url) {
        const where = this.originalPosition(frame);
        line.appendChild(h("span", { class: "link", title: where.url, onclick: () => DevTools.openSource(where.url, where.line, where.column) },
          fileName(where.url) + (where.line ? ":" + where.line + ":" + where.column : "")));
      }
      return line;
    },

    linkify(text) {
      const frag = document.createDocumentFragment();
      let last = 0;
      for (const m of String(text).matchAll(URL_RE)) {
        frag.appendChild(document.createTextNode(text.slice(last, m.index)));
        const url = m[0];
        frag.appendChild(h("span", { class: "link", onclick: (e) => { e.stopPropagation(); DevTools.openSource(url, 0, 0); } }, url));
        last = m.index + url.length;
      }
      frag.appendChild(document.createTextNode(String(text).slice(last)));
      return frag;
    },

    rerender() {
      const items = this.entries.slice();
      this.clearView();
      for (const item of items) this.add(item, true);
    },

    // ---- Copy for AI -------------------------------------------------------------
    contextItems(item) {
      const copy = (text) => DevTools.rpc("Clipboard.write", { text }).catch(() => {});
      const items = [];
      if (item) {
        items.push({ label: "Copy message", action: () => copy(this.plainText(item)) },
                   { label: "Copy for AI (Markdown)", action: () => copy(this.entryMarkdown(item)) });
      }
      const errors = this.entries.filter((i) => i.entry.level === "error");
      if (errors.length) items.push({ label: `Copy all errors as Markdown (${errors.length})`, action: () => copy(this.errorsMarkdown()) });
      items.push({ label: "Copy console as Markdown", action: () => copy(this.consoleMarkdown()) });
      items.push("-", { label: "Clear console", action: () => this.clear() });
      return items;
    },

    plainText(item) {
      const e = item.entry;
      if (e.type === "table" || !e.args.length || e.isUncaught || e.type === "result") return e.message;
      return e.args.map((a) => a.description).join(" ");
    },

    // Where an entry came from: the first stack frame, mapped to the original source.
    entryLocation(item) {
      if (typeof item.location === "string") return { url: item.location, line: 0, column: 0 };
      const frame = item.location || (item.entry.stack || []).find((f) => f.url);
      return frame ? this.originalPosition(frame) : null;
    },

    // One message as Markdown: level, text, source location and stack.
    entryMarkdown(item) {
      const e = item.entry;
      const kind = { error: "Error", warn: "Warning", info: "Info", debug: "Verbose", log: "Log" }[e.level] || e.level;
      const where = this.entryLocation(item);
      const head = [`**Console ${kind.toLowerCase()}**`];
      if (e.isUncaught) head.push("(uncaught)");
      if (item.repeat > 1) head.push(`×${item.repeat}`);
      if (where && where.url) head.push("at `" + where.url + (where.line ? ":" + where.line + (where.column ? ":" + where.column : "") : "") + "`");
      const out = [head.join(" "), Markdown.fence(Markdown.truncate(this.plainText(item), 4000), "text")];
      const stack = (e.stack || []).slice(0, 20);
      if (stack.length) {
        out.push("Stack:");
        for (const frame of stack) {
          const p = frame.url ? this.originalPosition(frame) : null;
          out.push(`- \`${frame.functionName || "(anonymous)"}\`` + (p ? ` — ${p.url}:${p.line}:${p.column}` : ""));
        }
      }
      return out.join("\n");
    },

    errorsMarkdown() {
      const errors = this.entries.filter((i) => i.entry.level === "error");
      return [`# Console errors — ${DevTools.info.url || ""}`, "", `${errors.length} error(s)`, "",
        ...errors.map((item, i) => `## ${i + 1}.\n\n` + this.entryMarkdown(item))].join("\n");
    },

    consoleMarkdown() {
      return [`# Console — ${DevTools.info.url || ""}`, "", ...this.entries.slice(-500).map((item) => this.entryMarkdown(item))].join("\n\n");
    },

    // ---- filtering ------------------------------------------------------------
    applyFilter() { for (const item of this.entries) this.applyFilterTo(item); },

    applyFilterTo(item) {
      const e = item.entry;
      let visible = true;
      if (this.level !== "all") {
        const always = e.type === "command" || e.type === "result";
        if (!always) visible = e.level === this.level || (this.level === "info" && (e.level === "info" || e.level === "trace"));
      }
      if (visible && this.filterText) {
        const text = (e.message + " " + e.args.map((a) => a.description).join(" ")).toLowerCase();
        visible = text.includes(this.filterText);
      }
      if (item.el) item.el.hidden = !visible;
    },

    clear() {
      DevTools.rpc("Console.clear").catch(() => {});
      this.clearView();
    },

    clearView() {
      this.entries = [];
      this.groupStack = [];
      this.messagesEl.textContent = "";
      this.counts = { errors: 0, warnings: 0 };
      DevTools.setBadges(this.counts);
    },

    isAtBottom() {
      const el = this.messagesEl;
      return el.scrollHeight - el.scrollTop - el.clientHeight < 40;
    },
    scrollToBottom() { this.messagesEl.scrollTop = this.messagesEl.scrollHeight; },

    // ---- prompt --------------------------------------------------------------------
    autoGrow() {
      this.prompt.style.height = "auto";
      this.prompt.style.height = Math.min(200, this.prompt.scrollHeight) + "px";
    },

    onPromptKey(e) {
      const box = $("#console-completions");
      if (!box.hidden) {
        if (e.key === "ArrowDown") { e.preventDefault(); this.moveCompletion(1); return; }
        if (e.key === "ArrowUp") { e.preventDefault(); this.moveCompletion(-1); return; }
        if (e.key === "Tab" || (e.key === "Enter" && this.completionIndex >= 0) || e.key === "ArrowRight" && this.caretAtEnd()) {
          e.preventDefault(); this.acceptCompletion(); return;
        }
        if (e.key === "Escape") { e.preventDefault(); this.hideCompletions(); return; }
      }
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        const text = this.prompt.value.trim();
        if (!text) return;
        this.evaluate(text);
        this.prompt.value = "";
        this.autoGrow();
        this.hideCompletions();
      } else if (e.key === "ArrowUp" && this.caretOnFirstLine()) {
        if (this.historyIndex > 0) {
          e.preventDefault();
          if (this.historyIndex === this.history.length) this.draft = this.prompt.value;
          this.historyIndex--;
          this.prompt.value = this.history[this.historyIndex];
          this.autoGrow();
          this.prompt.setSelectionRange(this.prompt.value.length, this.prompt.value.length);
        }
      } else if (e.key === "ArrowDown" && this.caretOnLastLine()) {
        if (this.historyIndex < this.history.length) {
          e.preventDefault();
          this.historyIndex++;
          this.prompt.value = this.historyIndex === this.history.length ? this.draft : this.history[this.historyIndex];
          this.autoGrow();
        }
      } else if (e.key === "Escape") {
        this.hideCompletions();
      }
    },

    caretOnFirstLine() { return !this.prompt.value.slice(0, this.prompt.selectionStart).includes("\n"); },
    caretOnLastLine() { return !this.prompt.value.slice(this.prompt.selectionEnd).includes("\n"); },
    caretAtEnd() { return this.prompt.selectionEnd === this.prompt.value.length; },

    evaluate(text) {
      if (this.history[this.history.length - 1] !== text) {
        this.history.push(text);
        if (this.history.length > 300) this.history.shift();
        try { localStorage.setItem("devtools.console.history", JSON.stringify(this.history)); } catch (_) {}
      }
      this.historyIndex = this.history.length;
      this.draft = "";
      // While paused, the prompt evaluates in the selected call frame, so
      // locals are in scope exactly as in Chrome.
      const callFrameId = window.SBDebugger ? SBDebugger.currentCallFrameId() : undefined;
      DevTools.rpc("Console.evaluate", callFrameId ? { expression: text, callFrameId } : { expression: text })
        .catch((err) => this.addLocal("error", err.message));
      this.scrollToBottom();
    },

    requestCompletions: debounce(function () {
      const self = DevTools.panels.console;
      const text = self.prompt.value;
      if (!text.trim() || text.includes("\n") || !self.caretAtEnd()) { self.hideCompletions(); return; }
      const tail = text.match(/[\w$.\[\]'"]*$/)[0];
      if (!tail || /\.\.$/.test(tail)) { self.hideCompletions(); return; }
      DevTools.rpc("Runtime.getCompletions", { expression: tail }).then(({ names, prefix }) => {
        if (self.prompt.value !== text) return;
        const list = names.filter((n) => n !== prefix).slice(0, 50);
        if (!list.length) { self.hideCompletions(); return; }
        self.completions = list.map((name) => ({ name, prefix }));
        self.completionIndex = 0;
        const box = $("#console-completions");
        box.textContent = "";
        list.forEach((name, i) => box.appendChild(h("div", { class: "item" + (i === 0 ? " active" : ""), onmousedown: (e) => { e.preventDefault(); self.completionIndex = i; self.acceptCompletion(); } }, name)));
        box.hidden = false;
      }).catch(() => self.hideCompletions());
    }, 120),

    moveCompletion(dir) {
      const items = $$("#console-completions .item");
      if (!items.length) return;
      this.completionIndex = (this.completionIndex + dir + items.length) % items.length;
      items.forEach((el, i) => el.classList.toggle("active", i === this.completionIndex));
      items[this.completionIndex].scrollIntoView({ block: "nearest" });
    },

    acceptCompletion() {
      const c = this.completions[this.completionIndex];
      if (!c) return;
      const value = this.prompt.value;
      this.prompt.value = value.slice(0, value.length - c.prefix.length) + c.name;
      this.hideCompletions();
      this.autoGrow();
    },

    hideCompletions() {
      $("#console-completions").hidden = true;
      this.completions = [];
      this.completionIndex = -1;
    },
  };

  DevTools.register("console", panel);
})();
