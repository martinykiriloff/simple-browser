// SimpleBrowser DevTools — Console panel: messages, filtering, the sidebar,
// settings and message actions. The prompt (editor, history, autocomplete,
// eager evaluation) is in console-prompt.js; value rendering in
// console-values.js.
"use strict";

(function () {
  const URL_RE = /\bhttps?:\/\/[^\s"'<>)]+/g;
  const LEVEL_NAMES = { error: "Error", warn: "Warning", info: "Info", debug: "Verbose", log: "Log", trace: "Info" };
  // The sidebar's categories, as in Chrome.
  const CATEGORIES = [
    ["all", "messages", "console-side-all"],
    ["user", "user messages", "console-side-user"],
    ["error", "errors", "console-side-error"],
    ["warn", "warnings", "console-side-warn"],
    ["info", "info", "console-side-info"],
    ["debug", "verbose", "console-side-debug"],
  ];
  const DEFAULT_SETTINGS = { sidebar: false, groupSimilar: true, hideNetwork: false, logXHR: false, eager: true, timestamps: false, preserve: false };

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
    loggedXHR: new Set(),
    counts: { errors: 0, warnings: 0 },
    settings: Object.assign({}, DEFAULT_SETTINGS),
    side: { category: "all", url: null },
    sideCounts: null,
    lastTop: null,
    pendingLocal: [],

    init() {
      this.messagesEl = $("#console-messages");
      this.prompt = $("#console-prompt");
      this.resetSideCounts();

      $("#console-clear").addEventListener("click", () => this.clear());
      this.loadLive();
      $("#console-filter").addEventListener("input", debounce(() => { this.filterText = $("#console-filter").value.toLowerCase(); this.applyFilter(); }, 100));
      $("#console-levels").addEventListener("change", () => { this.level = $("#console-levels").value; this.applyFilter(); });
      $("#console-preserve").addEventListener("change", (e) => { this.preserve = e.target.checked; this.setSetting("preserve", this.preserve); });
      $("#console-timestamps").addEventListener("change", (e) => { this.setTimestamps(e.target.checked); this.setSetting("timestamps", this.timestamps); });
      $("#console-sidebar-toggle").addEventListener("click", () => this.setSetting("sidebar", !this.settings.sidebar));
      $("#console-settings-toggle").addEventListener("click", () => {
        $("#console-settings").hidden = !$("#console-settings").hidden;
        $("#console-settings-toggle").classList.toggle("active", !$("#console-settings").hidden);
      });
      for (const box of $$("#console-settings input[data-setting]")) {
        box.addEventListener("change", () => this.setSetting(box.dataset.setting, box.checked));
      }
      $("#console-save").addEventListener("click", () => this.saveAs());
      this.messagesEl.addEventListener("click", (e) => { if (!getSelection().toString() && !e.target.closest(".obj, .link, .v-node, .console-similar-badge")) this.prompt.focus(); });
      this.messagesEl.addEventListener("contextmenu", (e) => {
        const el = e.target.closest(".console-message");
        const item = el && this.entries.find((i) => i.el === el);
        e.preventDefault();
        ContextMenu.show(e.clientX, e.clientY, this.contextItems(item, e.target));
      });
      document.addEventListener("keydown", (e) => {
        if ((e.metaKey || e.ctrlKey) && e.key === "k" && DevTools.activePanel === "console") { e.preventDefault(); this.clear(); }
      });

      DevTools.on("Console.entryAdded", (item) => this.add(item));
      DevTools.on("Page.navigated", (p) => {
        if (p.phase === "started") {
          this.reportedFailures.clear();
          this.loggedXHR.clear();
          if (!this.preserve) this.clearView();
        }
        if (p.phase === "committed") this.addLocal("info", "Navigated to " + p.url, { type: "navigation" });
      });
      DevTools.on("Network.requestAdded", ({ request }) => { this.reportFailure(request); this.logXHR(request); });
      DevTools.on("Network.requestUpdated", ({ request }) => { this.reportFailure(request); this.logXHR(request); });
      DevTools.on("Recorder.cleared", () => this.clearView());
      if (this.initPrompt) this.initPrompt();                     // console-prompt.js
      this.loadSettings().then(() => this.load());
    },

    show() { this.prompt.focus(); this.scrollToBottom(); this.startLive(); },
    hide() { this.stopLive(); },

    // ---- settings ---------------------------------------------------------------
    // Kept by the app (the DevTools web view's own storage does not outlive it).
    async loadSettings() {
      try {
        const saved = await DevTools.rpc("Settings.get", { key: "consoleSettings" });
        if (saved) Object.assign(this.settings, JSON.parse(saved));
      } catch (_) {}
      this.applySettings();
    },
    setSetting(name, value) {
      this.settings[name] = value;
      DevTools.rpc("Settings.set", { key: "consoleSettings", value: JSON.stringify(this.settings) }).catch(() => {});
      this.applySettings();
      if (name === "groupSimilar" || name === "hideNetwork") this.rerender();
    },
    applySettings() {
      const s = this.settings;
      for (const box of $$("#console-settings input[data-setting]")) box.checked = !!s[box.dataset.setting];
      $("#console-sidebar").hidden = !s.sidebar;
      $("#console-sidebar-toggle").classList.toggle("active", !!s.sidebar);
      $("#console-sidebar-toggle").setAttribute("aria-pressed", s.sidebar ? "true" : "false");
      this.preserve = !!s.preserve;
      $("#console-preserve").checked = this.preserve;
      if (!!s.timestamps !== this.timestamps) this.setTimestamps(!!s.timestamps);
      $("#console-timestamps").checked = this.timestamps;
      if (this.onSettingsChanged) this.onSettingsChanged();     // console-prompt.js (eager evaluation)
      this.renderSidebar();
    },
    setTimestamps(on) {
      this.timestamps = on;
      this.messagesEl.classList.toggle("show-timestamps", on);
      this.rerender();
    },

    // ---- live expressions ------------------------------------------------------
    // Pinned above the messages and re-evaluated every 250 ms while the
    // Console shows, without logging or keeping objects alive.
    live: [],
    liveTimer: null,

    loadLive() {
      try { this.live = JSON.parse(localStorage.getItem("devtools.console.live") || "[]").map((expression) => ({ expression, value: null })); } catch (_) { this.live = []; }
      $("#console-live-add").addEventListener("click", () => this.addLive(""));
      this.renderLive();
      // The app's copy survives a restart; the web view's does not.
      DevTools.rpc("Settings.get", { key: "consoleLive" }).then((saved) => {
        if (!saved || this.live.length) return;
        try { this.live = JSON.parse(saved).map((expression) => ({ expression, value: null })); } catch (_) {}
        this.renderLive();
      }).catch(() => {});
    },
    saveLive() {
      const list = JSON.stringify(this.live.map((l) => l.expression).filter(Boolean));
      try { localStorage.setItem("devtools.console.live", list); } catch (_) {}
      DevTools.rpc("Settings.set", { key: "consoleLive", value: list }).catch(() => {});
    },
    addLive(expression) {
      const item = { expression, value: null };
      this.live.push(item);
      this.renderLive();
      if (!expression) this.editLive(item);
      else { this.saveLive(); this.evaluateLive(); }
      return item;
    },
    removeLive(item) {
      this.live = this.live.filter((l) => l !== item);
      this.saveLive();
      this.renderLive();
    },
    editLive(item) {
      const row = $$("#console-live .live-row")[this.live.indexOf(item)];
      if (!row) return;
      const input = h("textarea", { class: "live-input", rows: "1", spellcheck: "false", placeholder: "Expression" });
      input.value = item.expression;
      row.querySelector(".live-expression").replaceWith(input);
      input.focus();
      const finish = (commit) => {
        if (commit) item.expression = input.value.trim();
        if (!item.expression) { this.removeLive(item); return; }
        this.saveLive(); this.renderLive(); this.evaluateLive();
      };
      input.addEventListener("keydown", (e) => {
        if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); input.blur(); }
        else if (e.key === "Escape") { e.preventDefault(); input.value = item.expression; input.blur(); }
        e.stopPropagation();
      });
      input.addEventListener("blur", () => finish(true), { once: true });
    },
    renderLive() {
      const box = $("#console-live");
      box.textContent = "";
      box.hidden = !this.live.length;
      for (const item of this.live) {
        const value = item.value == null ? h("span", { class: "muted" }, "not available")
          : item.error ? h("span", { class: "v-error" }, item.error) : h("span", { class: "v-" + (item.value.subtype === "null" ? "null" : item.value.type) }, item.value.type === "string" ? JSON.stringify(item.value.description) : item.value.description);
        const expression = h("div", { class: "live-expression", title: "Click to edit" }, item.expression);
        expression.addEventListener("click", () => this.editLive(item));
        box.appendChild(h("div", { class: "live-row" }, h("span", { class: "live-eye" }, "👁"),
          h("div", { class: "live-main" }, expression, h("div", { class: "live-value" }, value)),
          h("span", { class: "remove", title: "Remove expression", onclick: () => this.removeLive(item) }, "✕")));
      }
    },
    async evaluateLive() {
      if (this.liveBusy || !this.live.length) return;
      this.liveBusy = true;
      try {
        for (const item of this.live) {
          if (!item.expression) continue;
          try {
            const r = await DevTools.rpc("Runtime.evaluateLive", { expression: item.expression });
            item.error = r.exceptionDetails ? r.exceptionDetails.text : null;
            item.value = r.result || item.value || { type: "undefined", description: "undefined" };
          } catch (e) { item.error = /paused/i.test(e.message) ? "(paused in the debugger)" : e.message; item.value = item.value || {}; }
        }
      } finally { this.liveBusy = false; }
      if (!document.activeElement || !document.activeElement.classList.contains("live-input")) this.renderLive();
    },
    startLive() {
      if (this.liveTimer) return;
      this.evaluateLive();
      this.liveTimer = setInterval(() => this.evaluateLive(), 250);
    },
    stopLive() { clearInterval(this.liveTimer); this.liveTimer = null; },

    async load() {
      let entries = [], requests = [];
      try { entries = await DevTools.rpc("Console.getEntries"); } catch (_) {}
      // Requests that failed before the Console was first shown: their
      // "Failed to load resource" lines go where they happened.
      try { requests = await DevTools.rpc("Network.getRequests"); } catch (_) {}
      this.reportedFailures.clear();
      const failures = (requests || []).map((r) => this.failureItem(r)).filter(Boolean)
        .sort((a, b) => this.timeOf(a.entry) - this.timeOf(b.entry));
      this.clearView();
      for (const item of entries) {
        while (failures.length && this.timeOf(failures[0].entry) <= this.timeOf(item.entry)) this.add(failures.shift(), true);
        this.add(item, true);
      }
      for (const item of failures) this.add(item, true);
      for (const item of this.pendingLocal.splice(0)) this.add(item, true);
      this.scrollToBottom();
    },

    // ---- entries --------------------------------------------------------------
    add(item, initial) {
      if (!this.initialized || !this.messagesEl) { this.pendingLocal.push(item); return; }
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
        const badge = prev.el.querySelector(":scope > .repeat");
        if (badge) badge.textContent = String(prev.repeat);
        else prev.el.insertBefore(h("span", { class: "repeat" }, String(prev.repeat)), prev.el.firstChild.nextSibling);
        return;
      }

      this.entries.push(item);
      if (e.level === "error") this.counts.errors++;
      if (e.level === "warn") this.counts.warnings++;
      DevTools.setBadges(this.counts);
      this.countForSidebar(item);

      const wasAtBottom = this.isAtBottom();
      const el = this.render(item);
      item.el = el;
      const parent = this.groupStack[this.groupStack.length - 1] || this.messagesEl;
      if (!this.joinSimilar(item, parent)) {
        parent.appendChild(el);
        if (parent === this.messagesEl) this.lastTop = item;
      }
      if (e.type === "group" || e.type === "groupCollapsed") {
        const container = h("div", { class: "console-group" + (e.type === "groupCollapsed" ? " collapsed" : "") });
        if (e.type === "groupCollapsed") el.classList.add("collapsed");
        parent.appendChild(container);
        this.groupStack.push(container);
        el.addEventListener("click", () => { el.classList.toggle("collapsed"); container.classList.toggle("collapsed"); });
        if (parent === this.messagesEl) this.lastTop = null;
      }
      this.applyFilterTo(item);
      if (wasAtBottom || initial) this.scrollToBottom();
    },

    canCoalesce(prev, item) {
      const a = prev.entry, b = item.entry;
      if (a.type !== "log" || b.type !== "log") return false;
      if (a.level !== b.level || a.message !== b.message) return false;
      if (a.args.length !== b.args.length) return false;
      if (prev.source !== item.source) return false;
      return a.args.every((arg, i) => !arg.objectId && !b.args[i].objectId && arg.description === b.args[i].description);
    },

    // "Group similar": consecutive messages logged by the same line with the
    // same format collapse under the first one, with a count.
    similarKey(item) {
      const e = item.entry;
      if (e.type !== "log" || item.local) return null;
      const where = this.entryLocation(item);
      const first = e.args[0] && e.args[0].type === "string" ? e.args[0].description : e.message.replace(/\d+/g, "#");
      return [e.level, item.source, where ? where.url + ":" + where.line : "", first, e.args.length].join("|");
    },

    joinSimilar(item, parent) {
      if (!this.settings.groupSimilar || parent !== this.messagesEl) return false;
      const key = this.similarKey(item);
      item.similarKey = key;
      const head = this.lastTop;
      if (!key || !head || head.similarKey !== key || !head.el.isConnected) return false;
      if (!head.similar) {
        const container = h("div", { class: "console-similar collapsed" });
        head.el.after(container);
        const badge = h("span", { class: "console-similar-badge", role: "button", tabindex: "0", title: "Show the similar messages" });
        badge.addEventListener("click", (ev) => { ev.stopPropagation(); this.toggleSimilar(head); });
        badge.addEventListener("keydown", (ev) => { if (ev.key === "Enter" || ev.key === " ") { ev.preventDefault(); this.toggleSimilar(head); } });
        head.el.classList.add("similar-head", "collapsed");
        head.el.insertBefore(badge, head.el.querySelector(".body"));
        head.similar = { container, badge, items: [] };
      }
      head.similar.items.push(item);
      item.similarOf = head;
      head.similar.container.appendChild(item.el);
      head.similar.badge.textContent = String(head.similar.items.length + 1);
      return true;
    },

    toggleSimilar(head) {
      const open = head.similar.container.classList.toggle("collapsed") === false;
      head.el.classList.toggle("collapsed", !open);
      head.similar.badge.setAttribute("aria-expanded", open ? "true" : "false");
    },

    addLocal(level, message, extra = {}) {
      this.add({ entry: { level, type: extra.type || "log", message, args: [], stack: [], timestamp: Date.now(), isUncaught: false },
                 source: extra.source || "user", sequence: -1, local: true, location: extra.location });
    },

    reportFailure(request) {
      const item = this.failureItem(request, Date.now());
      if (item) this.add(item);
    },

    failureItem(request, timestamp) {
      if (!request || (!request.isFailure && !request.failure && !(request.statusCode >= 400))) return null;
      if (this.reportedFailures.has(request.id)) return null;
      this.reportedFailures.add(request.id);
      const message = request.failure
        ? "Failed to load resource: " + request.failure
        : `Failed to load resource: the server responded with a status of ${request.statusCode} ()`;
      return { entry: { level: "error", type: "log", message, args: [], stack: [], timestamp: timestamp || request.startedAt || Date.now(), isUncaught: false },
               source: "network", sequence: -1, location: request.url };
    },

    // "Log XMLHttpRequests": one verbose line per finished fetch / XHR, as Chrome writes it.
    logXHR(r) {
      if (!this.settings.logXHR || !r || this.loggedXHR.has(r.id)) return;
      const isXHR = r.initiator === "xmlhttprequest" || r.resourceType === "xhr";
      const isFetch = r.initiator === "fetch" || r.resourceType === "fetch";
      if (!isXHR && !isFetch) return;
      if (r.statusCode == null && !r.failure) return;
      this.loggedXHR.add(r.id);
      const verb = r.failure ? "failed loading" : "finished loading";
      this.add({ entry: { level: "debug", type: "log", message: `${isXHR ? "XHR" : "Fetch"} ${verb}: ${r.method || "GET"} "${r.url}".`, args: [], stack: [], timestamp: Date.now(), isUncaught: false },
                 source: "network", sequence: -1, location: r.url, local: true });
    },

    render(item) {
      const e = item.entry;
      const el = h("div", { class: `console-message level-${e.level} type-${e.type}`, dataset: { level: e.level } }, h("span", { class: "icon" }));
      if (this.timestamps) el.appendChild(h("span", { class: "timestamp" }, formatTime(this.timeOf(e))));
      const body = h("div", { class: "body" });

      if (e.type === "command") {
        const code = h("span", { class: "selectable console-command" });
        const tokens = Highlighter.tokenize(e.message, "js");
        if (tokens) for (const [cls, raw] of tokens) code.appendChild(cls ? h("span", { class: cls }, raw) : document.createTextNode(raw));
        else code.textContent = e.message;
        body.appendChild(code);
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
      } else if (e.args.length && !(e.isUncaught && e.args[0].subtype !== "error") && !(e.args[0].type === "string" && /%[sdifoOjc]/.test(e.args[0].description))) {
        if (e.isUncaught) body.appendChild(document.createTextNode("Uncaught " + (/^Uncaught \(in promise\)/.test(e.message) ? "(in promise) " : "")));
        e.args.forEach((arg, i) => {
          if (i) body.appendChild(document.createTextNode(" "));
          if (arg.type === "string") body.appendChild(this.linkify(arg.description));
          else body.appendChild(ObjectTree.render(arg, { quoteStrings: false }));
        });
      } else {
        body.appendChild(this.linkify(e.message));
      }

      // An error argument shows its own stack; the captured one is only for the rest.
      const errorArg = e.args.some((a) => a.subtype === "error" && /\n/.test(a.description || ""));
      if (e.stack && e.stack.length && !errorArg && (e.level === "error" || e.type === "trace" || e.isUncaught)) {
        const frames = h("div", { class: "console-stack" });
        for (const frame of e.stack.slice(0, 20)) frames.appendChild(this.frameLine(frame));
        const expanded = e.isUncaught || e.type === "trace";
        frames.hidden = !expanded;
        const toggle = h("span", { class: "stack-toggle", role: "button", "aria-label": "Toggle stack" }, expanded ? "▼" : "▶");
        toggle.addEventListener("click", (ev) => { ev.stopPropagation(); frames.hidden = !frames.hidden; toggle.textContent = frames.hidden ? "▶" : "▼"; });
        body.insertBefore(toggle, body.firstChild);
        body.appendChild(frames);
      }
      el.appendChild(body);

      const where = this.entryLocation(item);
      if (where && where.url) {
        const label = fileName(where.url) + (where.line ? ":" + where.line : "");
        el.appendChild(h("span", { class: "location", title: where.url, onclick: (ev) => { ev.stopPropagation(); DevTools.openSource(where.url, where.line, where.column); } }, label));
      }
      return el;
    },

    timeOf(e) {
      // Recorded entries carry Swift's reference date (seconds since 2001).
      const t = e.timestamp;
      return typeof t === "number" && t < 2e9 ? (t + 978307200) * 1000 : t;
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
      if (!this.initialized) return;
      const items = this.entries.slice();
      this.clearView();
      for (const item of items) { delete item.similar; delete item.similarOf; this.add(item, true); }
    },

    // ---- sidebar ---------------------------------------------------------------------
    resetSideCounts() {
      this.sideCounts = {};
      for (const [key] of CATEGORIES) this.sideCounts[key] = { count: 0, files: new Map() };
    },

    categoriesOf(item) {
      const e = item.entry;
      if (e.type === "command" || e.type === "result") return [];
      const out = ["all"];
      if (item.source === "pageWorld" && !e.isUncaught) out.push("user");
      out.push(e.level === "trace" ? "info" : e.level);
      return out;
    },

    countForSidebar(item) {
      const where = this.entryLocation(item);
      const file = where && where.url ? where.url : "";
      for (const key of this.categoriesOf(item)) {
        const bucket = this.sideCounts[key];
        if (!bucket) continue;
        bucket.count++;
        bucket.files.set(file, (bucket.files.get(file) || 0) + 1);
      }
      if (!this.sidebarFrame) this.sidebarFrame = requestAnimationFrame(() => { this.sidebarFrame = 0; this.renderSidebar(); });
    },

    expandedSide: new Set(),

    renderSidebar() {
      const box = $("#console-sidebar");
      if (!box || box.hidden) return;
      box.textContent = "";
      for (const [key, label, id] of CATEGORIES) {
        const bucket = this.sideCounts[key];
        const selected = this.side.category === key && !this.side.url;
        const open = this.expandedSide.has(key);
        const row = h("div", { class: "console-side-row level-" + key + (selected ? " selected" : "") + (open ? " expanded" : ""), id, role: "treeitem", tabindex: "0",
          "aria-selected": selected ? "true" : "false", "aria-expanded": bucket.files.size ? (open ? "true" : "false") : null },
          h("span", { class: "arrow" + (bucket.files.size ? "" : " none") }), h("span", { class: "console-side-icon" }),
          h("span", { class: "console-side-label" }, (bucket.count === 0 ? "No" : String(bucket.count)) + " " + label));
        row.addEventListener("click", (e) => {
          if (e.target.classList.contains("arrow")) { this.toggleSide(key); return; }
          this.selectSide(key, null);
        });
        row.addEventListener("keydown", (e) => {
          if (e.key === "Enter" || e.key === " ") { e.preventDefault(); this.selectSide(key, null); }
          else if (e.key === "ArrowRight" && !open) this.toggleSide(key);
          else if (e.key === "ArrowLeft" && open) this.toggleSide(key);
          else if (e.key === "ArrowDown" || e.key === "ArrowUp") { e.preventDefault(); this.moveSideFocus(row, e.key === "ArrowDown" ? 1 : -1); }
        });
        box.appendChild(row);
        if (!open) continue;
        const files = Array.from(bucket.files).sort((a, b) => b[1] - a[1]);
        for (const [url, count] of files) {
          const sel = this.side.category === key && this.side.url === url;
          const fileRow = h("div", { class: "console-side-row file" + (sel ? " selected" : ""), role: "treeitem", tabindex: "0", title: url || "(no source)" },
            h("span", { class: "console-side-label" }, (url ? fileName(url) : "(no source)")), h("span", { class: "console-side-count" }, String(count)));
          fileRow.addEventListener("click", () => this.selectSide(key, url));
          fileRow.addEventListener("keydown", (e) => {
            if (e.key === "Enter" || e.key === " ") { e.preventDefault(); this.selectSide(key, url); }
            else if (e.key === "ArrowDown" || e.key === "ArrowUp") { e.preventDefault(); this.moveSideFocus(fileRow, e.key === "ArrowDown" ? 1 : -1); }
          });
          box.appendChild(fileRow);
        }
      }
    },
    moveSideFocus(row, dir) {
      const rows = $$("#console-sidebar .console-side-row");
      const next = rows[rows.indexOf(row) + dir];
      if (next) next.focus();
    },
    toggleSide(key) {
      if (this.expandedSide.has(key)) this.expandedSide.delete(key); else this.expandedSide.add(key);
      this.renderSidebar();
      document.querySelector(`#console-sidebar .console-side-row.level-${key}`)?.focus();
    },
    selectSide(category, url) {
      this.side = { category, url };
      this.renderSidebar();
      this.applyFilter();
      const rows = $$("#console-sidebar .console-side-row.selected");
      if (rows[0]) rows[0].focus();
    },

    // ---- message actions -------------------------------------------------------------
    copy(text) { return DevTools.rpc("Clipboard.write", { text }).catch(() => {}); },

    contextItems(item, target) {
      const items = [];
      if (item) {
        items.push({ label: "Copy message", action: () => this.copy(this.plainText(item)) },
                   { label: "Copy for AI (Markdown)", action: async () => this.copy(await this.entryMarkdownForAI(item)) });
        if (this.stackOf(item).length) items.push({ label: "Copy stack", action: () => this.copy(this.stackText(item)) });
        const remote = this.remoteFor(target, item);
        if (remote) items.push({ label: "Store as global variable", action: () => this.storeAsGlobal(remote) });
        const where = this.entryLocation(item);
        if (where && where.url) items.push({ label: "Reveal in Sources panel", action: () => DevTools.openSource(where.url, where.line, where.column) });
        items.push("-");
      }
      const errors = this.entries.filter((i) => i.entry.level === "error");
      if (errors.length) items.push({ label: `Copy all errors as Markdown (${errors.length})`, action: () => this.copy(this.errorsMarkdown()) });
      items.push({ label: "Copy console as Markdown", action: () => this.copy(this.consoleMarkdown()) });
      items.push({ label: "Save as…", action: () => this.saveAs() });
      items.push("-", { label: "Clear console", action: () => this.clear() });
      return items;
    },

    // The value under the pointer, or the message's first object.
    remoteFor(target, item) {
      for (let el = target; el && el !== this.messagesEl; el = el.parentElement) if (el.__remote) return el.__remote;
      const e = item.entry;
      return e.args.find((a) => a.objectId) || (e.type === "result" && e.args[0]) || null;
    },

    async storeAsGlobal(remote) {
      let params;
      if (remote.objectId) params = { objectId: remote.objectId };
      else if (remote.type === "number") params = { value: Number(remote.description) };
      else if (remote.type === "boolean") params = { value: remote.description === "true" };
      else if (remote.type === "string") params = { value: remote.description };
      else if (remote.subtype === "null") params = { value: null };
      else return;
      try {
        const { name } = await DevTools.rpc("Runtime.storeAsGlobal", params);
        this.evaluate(name);
        return name;
      } catch (e) { this.addLocal("error", "Could not store the value: " + e.message); }
    },

    plainText(item) {
      const e = item.entry;
      if (e.type === "table" || !e.args.length || e.isUncaught || e.type === "result") return e.message;
      return e.args.map((a) => a.description).join(" ");
    },

    stackOf(item) {
      const e = item.entry;
      if (e.stack && e.stack.length) return e.stack.filter((f) => f.url || f.functionName);
      const error = e.args.find((a) => a.subtype === "error");
      if (!error) return [];
      return String(error.description || "").split("\n").slice(1).map((l) => ObjectTree.parseFrame(l)).filter(Boolean);
    },

    stackText(item) {
      return this.stackOf(item).map((frame) => {
        const p = frame.url ? this.originalPosition(frame) : null;
        return (frame.functionName || "(anonymous)") + (p ? " @ " + p.url + ":" + p.line + ":" + p.column : "");
      }).join("\n");
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
      const kind = LEVEL_NAMES[e.level] || e.level;
      const where = this.entryLocation(item);
      const head = [`**Console ${kind.toLowerCase()}**`];
      if (e.isUncaught) head.push("(uncaught)");
      if (item.repeat > 1) head.push(`×${item.repeat}`);
      if (where && where.url) head.push("at `" + where.url + (where.line ? ":" + where.line + (where.column ? ":" + where.column : "") : "") + "`");
      const out = [head.join(" "), Markdown.fence(Markdown.truncate(this.plainText(item), 4000), "text")];
      const stack = this.stackOf(item).slice(0, 20);
      if (stack.length) {
        out.push("Stack:");
        for (const frame of stack) {
          const p = frame.url ? this.originalPosition(frame) : null;
          out.push(`- \`${frame.functionName || "(anonymous)"}\`` + (p ? ` — ${p.url}:${p.line}:${p.column}` : ""));
        }
      }
      return out.join("\n");
    },

    // Copy for AI: the message, plus the lines of code around where it came from.
    async entryMarkdownForAI(item) {
      let md = this.entryMarkdown(item);
      const where = this.entryLocation(item);
      if (!where || !where.url || !where.line) return md;
      const text = await this.sourceText(where.url).catch(() => null);
      if (!text) return md;
      const lines = text.split("\n");
      if (where.line > lines.length) return md;
      const from = Math.max(1, where.line - 5), to = Math.min(lines.length, where.line + 5);
      const width = String(to).length;
      const excerpt = [];
      for (let n = from; n <= to; n++) excerpt.push((n === where.line ? "→ " : "  ") + String(n).padStart(width) + " | " + lines[n - 1].slice(0, 300));
      const lang = /\.css(\?|$)/.test(where.url) ? "css" : /\.html?(\?|$)/.test(where.url) || where.url === DevTools.info.url ? "html" : "js";
      md += `\n\nSource around \`${fileName(where.url)}:${where.line}\`:\n` + Markdown.fence(excerpt.join("\n"), lang);
      return md;
    },

    async sourceText(url) {
      if (window.SBSourceMaps && SBSourceMaps.isOriginal(url) && SBSourceMaps.contentOf(url) != null) return SBSourceMaps.contentOf(url);
      const sources = DevTools.panels.sources;
      const file = sources && sources.files.get(url);
      if (file && file.content != null) return file.content;
      const result = await DevTools.rpc("Sources.fetch", { url });
      return result && result.text;
    },

    errorsMarkdown() {
      const errors = this.entries.filter((i) => i.entry.level === "error");
      return [`# Console errors — ${DevTools.info.url || ""}`, "", `${errors.length} error(s)`, "",
        ...errors.map((item, i) => `## ${i + 1}.\n\n` + this.entryMarkdown(item))].join("\n");
    },

    consoleMarkdown() {
      return [`# Console — ${DevTools.info.url || ""}`, "", ...this.entries.slice(-500).map((item) => this.entryMarkdown(item))].join("\n\n");
    },

    // Save as…: the whole console as text, the way Chrome saves it.
    consoleText() {
      return this.entries.map((item) => {
        const e = item.entry;
        const where = this.entryLocation(item);
        const prefix = e.type === "command" ? "> " : e.type === "result" ? "< " : "";
        const location = where && where.url ? fileName(where.url) + (where.line ? ":" + where.line : "") + " " : "";
        const stack = this.stackOf(item).length && (e.level === "error" || e.type === "trace") ? "\n" + this.stackText(item).split("\n").map((l) => "    " + l).join("\n") : "";
        return location + prefix + this.plainText(item) + (item.repeat > 1 ? ` (×${item.repeat})` : "") + stack;
      }).join("\n");
    },
    saveAs() {
      let host = "console";
      try { host = new URL(DevTools.info.url).host || host; } catch (_) {}
      return DevTools.rpc("DevTools.saveFile", { name: `${host}-${Date.now()}.log`, text: this.consoleText() }).catch((e) => this.addLocal("error", e.message));
    },

    // ---- filtering ------------------------------------------------------------
    applyFilter() { for (const item of this.entries) this.applyFilterTo(item); },

    applyFilterTo(item) {
      const e = item.entry;
      const always = e.type === "command" || e.type === "result";
      let visible = true;
      if (this.level !== "all" && !always) {
        visible = e.level === this.level || (this.level === "info" && (e.level === "info" || e.level === "trace"));
      }
      if (visible && this.settings.hideNetwork && item.source === "network") visible = false;
      if (visible && !always && (this.side.category !== "all" || this.side.url)) {
        visible = this.categoriesOf(item).includes(this.side.category);
        if (visible && this.side.url != null) {
          const where = this.entryLocation(item);
          visible = (where && where.url ? where.url : "") === this.side.url;
        }
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
      this.lastTop = null;
      if (this.messagesEl) this.messagesEl.textContent = "";
      this.counts = { errors: 0, warnings: 0 };
      DevTools.setBadges(this.counts);
      this.resetSideCounts();
      this.renderSidebar();
    },

    isAtBottom() {
      const el = this.messagesEl;
      return el.scrollHeight - el.scrollTop - el.clientHeight < 40;
    },
    scrollToBottom() { this.messagesEl.scrollTop = this.messagesEl.scrollHeight; },

    // Runs `text` as if typed at the prompt (history, then the result logged).
    evaluate(text) {
      if (this.remember) this.remember(text);                    // console-prompt.js
      // While paused, the prompt evaluates in the selected call frame, so
      // locals are in scope exactly as in Chrome.
      const callFrameId = window.SBDebugger ? SBDebugger.currentCallFrameId() : undefined;
      DevTools.rpc("Console.evaluate", callFrameId ? { expression: text, callFrameId } : { expression: text })
        .catch((err) => this.addLocal("error", err.message));
      this.scrollToBottom();
    },
  };

  DevTools.register("console", panel);
})();
