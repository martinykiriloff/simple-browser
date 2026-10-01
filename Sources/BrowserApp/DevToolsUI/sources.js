// SimpleBrowser DevTools — Sources panel: navigator, viewer, find.
"use strict";

(function () {
  const panel = {
    initialized: false,
    files: new Map(),
    expanded: new Set(),
    tabs: [],
    current: null,
    lines: [],
    findHits: [],
    findIndex: -1,
    pendingReveal: null,

    init() {
      $("#sources-filter").addEventListener("input", debounce(() => this.renderTree(), 100));
      document.addEventListener("keydown", (e) => {
        if ((e.metaKey || e.ctrlKey) && e.key === "f" && DevTools.activePanel === "sources") { e.preventDefault(); this.openFind(); }
      });
      $("#sources-find").addEventListener("input", debounce(() => this.runFind(), 120));
      $("#sources-find").addEventListener("keydown", (e) => {
        if (e.key === "Enter") { e.preventDefault(); this.stepFind(e.shiftKey ? -1 : 1); }
        if (e.key === "Escape") { e.preventDefault(); this.closeFind(); }
      });
      $("#sources-find-next").addEventListener("click", () => this.stepFind(1));
      $("#sources-find-prev").addEventListener("click", () => this.stepFind(-1));
      $("#sources-find-close").addEventListener("click", () => this.closeFind());
      $("#sources-pretty").addEventListener("click", () => {
        const file = this.files.get(this.current);
        if (!file || file.content == null) return;
        file.pretty = !file.pretty;
        this.renderCode(file);
      });
      $("#sources-code").addEventListener("click", (e) => {
        const line = e.target.closest(".code-line");
        if (line) $("#sources-position").textContent = "Line " + line.dataset.line;
      });

      DevTools.on("DOM.documentUpdated", () => {
        // Keep open tabs' entries so a reload does not close what you are reading.
        for (const [url, file] of Array.from(this.files)) {
          if (file.type === "snippet") continue;                    // snippets belong to DevTools, not the page
          if (this.tabs.includes(url)) { file.content = null; file.prettyContent = null; } else this.files.delete(url);
        }
        this.refresh();
        if (this.current && !this.current.startsWith(SBDebugger.SCRIPT_PREFIX)) this.open(this.current);
      });
      DevTools.on("Network.requestAdded", ({ request }) => this.addFromRequest(request));
      DevTools.on("Network.requestUpdated", ({ request }) => this.addFromRequest(request));
      this.refresh();
    },

    show() { if (!this.files.size) this.refresh(); },

    async refresh() {
      try {
        const list = await DevTools.rpc("Sources.list");
        for (const f of list) if (!this.files.has(f.url)) this.files.set(f.url, { url: f.url, type: f.type });
      } catch (_) {}
      this.renderTree();
      if (this.pendingReveal) { const p = this.pendingReveal; this.pendingReveal = null; this.open(p.url, p.line, p.column); }
    },

    addFromRequest(r) {
      if (!["script", "stylesheet", "document", "fetch", "xhr"].includes(r.resourceType)) return;
      if (this.files.has(r.url)) return;
      this.files.set(r.url, { url: r.url, type: r.resourceType, requestId: r.id });
      this.renderTree();
    },

    // ---- navigator ------------------------------------------------------------
    renderTree() {
      const root = $("#sources-tree");
      root.textContent = "";
      const filter = $("#sources-filter").value.trim().toLowerCase();
      const tree = {};
      for (const file of this.files.values()) {
        if (filter && !file.url.toLowerCase().includes(filter)) continue;
        let origin = "(other)", segments = [];
        try {
          const u = new URL(file.url);
          origin = u.host || u.protocol;
          segments = u.pathname.split("/").filter(Boolean);
          if (!segments.length) segments = ["(index)"];
          if (u.search) segments[segments.length - 1] += u.search.slice(0, 40);
        } catch (_) { segments = [file.url]; }
        let node = tree[origin] = tree[origin] || { children: {}, files: [] };
        for (const seg of segments.slice(0, -1)) node = node.children[seg] = node.children[seg] || { children: {}, files: [] };
        node.files.push({ name: segments[segments.length - 1], file });
      }
      const nav = h("div", { class: "nav-tree" });
      const build = (node, path, depth) => {
        const frag = document.createDocumentFragment();
        for (const name of Object.keys(node.children).sort()) {
          const key = path + "/" + name;
          const open = filter ? true : this.expanded.has(key);
          const item = h("div", { class: "nav-item folder" + (open ? " expanded" : ""), style: `--depth:${depth}` }, h("span", { class: "arrow" }), h("span", { class: "fileicon" }, "▸"), name);
          item.addEventListener("click", () => { if (this.expanded.has(key)) this.expanded.delete(key); else this.expanded.add(key); this.renderTree(); });
          const children = h("div", { class: "nav-children" });
          children.appendChild(build(node.children[name], key, depth + 1));
          frag.append(item, children);
        }
        for (const { name, file } of node.files.sort((a, b) => a.name.localeCompare(b.name))) {
          const item = h("div", { class: "nav-item file" + (this.current === file.url ? " selected" : ""), style: `--depth:${depth}`, title: file.url },
            h("span", { class: "arrow" }), h("span", { class: "fileicon" }, this.icon(file.type)), name);
          item.addEventListener("click", () => this.open(file.url));
          frag.appendChild(item);
        }
        return frag;
      };
      for (const origin of Object.keys(tree).sort()) {
        const key = "/" + origin;
        const open = filter ? true : (this.expanded.has(key) || this.expanded.size === 0);
        if (open) this.expanded.add(key);
        const item = h("div", { class: "nav-item folder" + (open ? " expanded" : ""), style: "--depth:0" }, h("span", { class: "arrow" }), h("span", { class: "fileicon" }, "☁"), origin);
        item.addEventListener("click", () => { if (this.expanded.has(key)) this.expanded.delete(key); else this.expanded.add(key); this.renderTree(); });
        const children = h("div", { class: "nav-children" });
        children.appendChild(build(tree[origin], key, 1));
        nav.append(item, children);
      }
      if (!this.files.size) nav.appendChild(h("div", { class: "empty-state" }, "No sources yet."));
      root.appendChild(nav);
    },

    icon(type) {
      return { script: "JS", stylesheet: "CSS", document: "</>", fetch: "{}", xhr: "{}" }[type] || "·";
    },

    // ---- viewer ----------------------------------------------------------------------
    async open(url, line, column) {
      if (!this.files.has(url)) this.files.set(url, { url, type: "other" });
      let file = this.files.get(url);
      if (!this.tabs.includes(url)) this.tabs.push(url);
      this.current = url;
      this.renderTabs();
      this.renderTree();
      const code = $("#sources-code");
      if (file.content == null && SBSourceMaps.isOriginal(url) && SBSourceMaps.contentOf(url) != null) {
        file.content = SBSourceMaps.contentOf(url);      // embedded in the map (sourcesContent)
        file.original = true;
      }
      if (file.content == null) {
        code.textContent = "";
        code.appendChild(h("div", { class: "empty-state" }, "Loading " + fileName(url) + "…"));
        try {
          const result = await DevTools.rpc("Sources.fetch", file.scriptId ? { scriptId: file.scriptId } : { url });
          file.content = result.text;
          file.prettyContent = null;
          file.refetched = !!result.refetched;
          file.live = !!result.live;
          // A script may declare its map only in a trailing comment.
          const declared = !file.original && !SBSourceMaps.maps.has(url) && SBSourceMaps.declaredIn(file.content);
          if (declared && /^(https?|file):/.test(url)) SBSourceMaps.load(url, declared);
        } catch (err) {
          file.content = null;
          code.textContent = "";
          code.appendChild(h("div", { class: "empty-state" }, "Could not load: " + err.message));
          return;
        }
      }
      if (this.current !== url) return;
      this.renderCode(file, line, column);
    },

    // A script the debugger stopped in that has no URL (eval, inline handler).
    openScript(scriptId, line, column) {
      const url = SBDebugger.SCRIPT_PREFIX + scriptId;
      if (!this.files.has(url)) this.files.set(url, { url, type: "script", scriptId: String(scriptId), anonymous: true });
      return this.open(url, line, column);
    },

    renderTabs() {
      const bar = $("#sources-tabs");
      bar.textContent = "";
      for (const url of this.tabs) {
        const tab = h("button", { class: "subtab sources-tab" + (url === this.current ? " active" : ""), title: url }, fileName(url));
        const close = h("span", { class: "close" }, "✕");
        close.addEventListener("click", (e) => { e.stopPropagation(); this.closeTab(url); });
        tab.appendChild(close);
        tab.addEventListener("click", () => this.open(url));
        bar.appendChild(tab);
      }
    },

    closeTab(url) {
      this.tabs = this.tabs.filter((u) => u !== url);
      if (this.current === url) {
        this.current = this.tabs[this.tabs.length - 1] || null;
        if (this.current) this.open(this.current);
        else { $("#sources-code").textContent = ""; $("#sources-code").appendChild(h("div", { class: "empty-state" }, "Select a file from the navigator.")); }
      }
      this.renderTabs();
      this.renderTree();
    },

    renderCode(file, line, column) {
      const code = $("#sources-code");
      code.textContent = "";
      const lang = Highlighter.language(file.url, file.type, file.content);
      // A link from the console names a line in the original text, so
      // pretty-printing is switched off when jumping to one.
      if (line) file.pretty = false;
      let text = file.content || "";
      if (file.pretty) {
        if (file.prettyContent == null) file.prettyContent = Highlighter.pretty(text, lang) || text;
        text = file.prettyContent;
      }
      const prettyButton = $("#sources-pretty");
      prettyButton.hidden = !(lang === "js" || lang === "css" || lang === "json");
      prettyButton.classList.toggle("active", !!file.pretty);

      this.lines = text.split("\n");
      const LIMIT = 30000;
      const HIGHLIGHT_LIMIT = 1500000;
      const frag = document.createDocumentFragment();
      if (file.original) frag.appendChild(h("div", { class: "detail-note" }, "Original source, mapped from " + fileName(SBSourceMaps.byOriginal.get(file.url) || "") + ". Breakpoints set here are placed in the generated file."));
      else if (file.refetched) frag.appendChild(h("div", { class: "detail-note" }, "Fetched by the app rather than read from the page; it may differ from what the page ran."));
      if (file.live) frag.appendChild(h("div", { class: "detail-note" }, "Current DOM serialised from the live page, not the bytes the server sent."));
      const count = Math.min(this.lines.length, LIMIT);
      const makeLine = (number) => {
        const textEl = h("span", { class: "code-text" });
        const el = h("div", { class: "code-line" + (line === number ? " highlight" : ""), dataset: { line: String(number) } },
          h("span", { class: "ln" }, String(number)), textEl);
        frag.appendChild(el);
        return textEl;
      };
      const tokens = lang && text.length <= HIGHLIGHT_LIMIT ? Highlighter.tokenize(text, lang) : null;
      if (tokens) {
        let number = 1;
        let current = makeLine(number);
        outer:
        for (const [cls, raw] of tokens) {
          const parts = raw.split("\n");
          for (let p = 0; p < parts.length; p++) {
            if (p > 0) {
              if (++number > count) break outer;
              current = makeLine(number);
            }
            if (parts[p]) current.appendChild(cls ? h("span", { class: cls }, parts[p]) : document.createTextNode(parts[p]));
          }
        }
      } else {
        for (let i = 0; i < count; i++) makeLine(i + 1).textContent = this.lines[i];
      }
      if (this.lines.length > LIMIT) frag.appendChild(h("div", { class: "detail-note" }, `Showing the first ${LIMIT} of ${this.lines.length} lines.`));
      code.appendChild(frag);
      if (line) {
        const el = code.querySelector(`.code-line[data-line="${line}"]`);
        if (el) { el.scrollIntoView({ block: "center" }); $("#sources-position").textContent = `Line ${line}${column ? ", Column " + column : ""}`; }
      } else {
        code.scrollTop = 0;
        $("#sources-position").textContent = `${this.lines.length} lines`;
      }
      if (!$("#sources-find-bar").hidden) this.runFind();
      SBDebugger.decorate(file);
    },

    // ---- find -----------------------------------------------------------------------------
    openFind() { $("#sources-find-bar").hidden = false; $("#sources-find").focus(); $("#sources-find").select(); },
    closeFind() {
      $("#sources-find-bar").hidden = true;
      for (const el of $$(".find-hit, .find-current", $("#sources-code"))) el.classList.remove("find-hit", "find-current");
      this.findHits = []; this.findIndex = -1; $("#sources-find-count").textContent = "";
    },
    runFind() {
      const q = $("#sources-find").value.toLowerCase();
      for (const el of $$(".find-hit, .find-current", $("#sources-code"))) el.classList.remove("find-hit", "find-current");
      this.findHits = []; this.findIndex = -1;
      if (!q) { $("#sources-find-count").textContent = ""; return; }
      this.lines.forEach((text, i) => { if (text.toLowerCase().includes(q)) this.findHits.push(i + 1); });
      for (const n of this.findHits) $("#sources-code").querySelector(`.code-line[data-line="${n}"]`)?.classList.add("find-hit");
      $("#sources-find-count").textContent = this.findHits.length ? `${this.findHits.length} lines` : "No matches";
      if (this.findHits.length) this.stepFind(1);
    },
    stepFind(dir) {
      if (!this.findHits.length) return;
      if (this.findIndex >= 0) $("#sources-code").querySelector(`.code-line[data-line="${this.findHits[this.findIndex]}"]`)?.classList.replace("find-current", "find-hit");
      this.findIndex = (this.findIndex + dir + this.findHits.length) % this.findHits.length;
      const el = $("#sources-code").querySelector(`.code-line[data-line="${this.findHits[this.findIndex]}"]`);
      if (el) { el.classList.add("find-current"); el.scrollIntoView({ block: "center" }); }
      $("#sources-find-count").textContent = `${this.findIndex + 1} of ${this.findHits.length}`;
    },
  };

  DevTools.register("sources", panel);
})();
