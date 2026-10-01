// SimpleBrowser DevTools — the Sources panel's editor tools: search across
// every loaded source (⌥⌘F, in the drawer), go to line (⌃G / ⌘L), go to
// symbol (⇧⌘O), the current line, matching brackets, highlights of the
// selected word, folding of {} blocks, and Snippets: scripts you keep,
// edit and run (⌘↩) on any page. Extends the Sources panel (sources.js).
"use strict";

(function () {
  const panel = DevTools.panels.sources;
  const baseRenderCode = panel.renderCode;
  const baseOpen = panel.open;
  const SNIPPET_PREFIX = "snippet:///";
  const OPEN = { "(": ")", "[": "]", "{": "}" }, CLOSE = { ")": "(", "]": "[", "}": "{" };
  const FOLD_LIMIT = 1500000;

  // ---- marking characters inside a rendered line -----------------------------------------------
  // Wraps the characters [start, end) of a line's text in spans with `cls`,
  // splitting the token spans' text nodes as needed.
  function markRange(lineEl, start, end, cls) {
    const textEl = lineEl.querySelector(".code-text");
    if (!textEl || end <= start) return;
    const walker = document.createTreeWalker(textEl, NodeFilter.SHOW_TEXT);
    const pieces = [];
    let offset = 0, node;
    while ((node = walker.nextNode())) {
      const len = node.nodeValue.length;
      const from = Math.max(start, offset), to = Math.min(end, offset + len);
      if (from < to) pieces.push([node, from - offset, to - offset]);
      offset += len;
      if (offset >= end) break;
    }
    for (const [text, from, to] of pieces) {
      const range = document.createRange();
      range.setStart(text, from); range.setEnd(text, to);
      range.surroundContents(h("span", { class: "code-mark " + cls }));
    }
  }
  function clearMarks(root, cls) {
    for (const mark of $$(".code-mark" + (cls ? "." + cls : ""), root)) {
      const parent = mark.parentNode;
      mark.replaceWith(document.createTextNode(mark.textContent));
      parent.normalize();
    }
  }
  // Line number and column under a point, from the caret position there.
  function positionAt(x, y) {
    const range = document.caretRangeFromPoint ? document.caretRangeFromPoint(x, y) : null;
    if (!range) return null;
    const lineEl = range.startContainer.parentElement && range.startContainer.parentElement.closest(".code-line");
    const textEl = lineEl && lineEl.querySelector(".code-text");
    if (!textEl || !textEl.contains(range.startContainer)) return null;
    const pre = document.createRange();
    pre.setStart(textEl, 0); pre.setEnd(range.startContainer, range.startOffset);
    return { lineEl, line: +lineEl.dataset.line, column: pre.toString().length };
  }

  Object.assign(panel, {
    folded: new Set(),
    snippets: [],

    // ---- render hook ------------------------------------------------------------------------------
    renderCode(file, line, column) {
      if (file && file.type === "snippet") { this.renderSnippet(file); return; }
      $("#snippet-run").hidden = true;
      $("#snippet-result").textContent = "";
      const code = $("#sources-code");
      code.classList.remove("snippet-mode");
      baseRenderCode.call(this, file, line, column);
      this.foldRanges = null;
      if (this.foldKey !== file.url + (file.pretty ? ":pretty" : "")) { this.folded = new Set(); this.foldKey = file.url + (file.pretty ? ":pretty" : ""); }
      this.addFolding(file);
      if (line) this.setCurrentLine(line);
    },

    // ---- current line, brackets, word highlight ---------------------------------------------------
    initEditorTools() {
      const code = $("#sources-code");
      code.addEventListener("mouseup", (e) => {
        if (code.classList.contains("snippet-mode") || e.button !== 0 || e.target.closest(".ln, .fold-toggle")) return;
        const at = positionAt(e.clientX, e.clientY);
        clearMarks(code, "bracket-match");
        clearMarks(code, "word-hit");
        if (!at) return;
        this.setCurrentLine(at.line);
        const selected = getSelection().toString();
        if (/^[A-Za-z_$][\w$]*$/.test(selected)) this.highlightWord(selected);
        else if (!selected) this.matchBracket(at.line, at.column);
      });
      code.addEventListener("dblclick", () => {
        const selected = getSelection().toString().trim();
        if (/^[A-Za-z_$][\w$]*$/.test(selected)) { clearMarks(code, "word-hit"); this.highlightWord(selected); }
      });
    },

    setCurrentLine(n) {
      const code = $("#sources-code");
      for (const el of $$(".code-line.current-line", code)) el.classList.remove("current-line");
      const el = code.querySelector(`.code-line[data-line="${n}"]`);
      if (el) el.classList.add("current-line");
      this.currentLine = n;
    },

    // The bracket at (or just before) the caret, and its partner.
    matchBracket(line, column) {
      const text = this.lines[line - 1] || "";
      let col = OPEN[text[column]] || CLOSE[text[column]] ? column : (OPEN[text[column - 1]] || CLOSE[text[column - 1]] ? column - 1 : -1);
      if (col < 0) return null;
      const match = this.findPartner(line, col);
      if (!match) return null;
      const code = $("#sources-code");
      const mark = (l, c) => { const el = code.querySelector(`.code-line[data-line="${l}"]`); if (el) markRange(el, c, c + 1, "bracket-match"); };
      mark(line, col); mark(match.line, match.column);
      return match;
    },

    // Walks to the partner of the bracket at line:col, skipping strings and
    // comments on the way (a light scan, not a parse).
    findPartner(line, col) {
      const lines = this.lines;
      const ch = lines[line - 1][col];
      const forward = !!OPEN[ch];
      const want = forward ? OPEN[ch] : CLOSE[ch];
      let depth = 0;
      const limit = 20000;
      let steps = 0;
      for (let l = line - 1; l >= 0 && l < lines.length && steps < limit; l += forward ? 1 : -1, steps++) {
        const t = lines[l];
        const masked = t.replace(/(["'`])(?:\\.|(?!\1).)*\1|\/\/.*$/g, (m) => " ".repeat(m.length));
        let c = l === line - 1 ? col : (forward ? 0 : masked.length - 1);
        for (; c >= 0 && c < masked.length; c += forward ? 1 : -1) {
          const x = masked[c];
          if (x === ch) depth++;
          else if (x === want) { depth--; if (depth === 0) return { line: l + 1, column: c }; }
        }
      }
      return null;
    },

    // Every whole-word occurrence of `word` in the shown lines.
    highlightWord(word) {
      const code = $("#sources-code");
      const re = new RegExp("(?<![\\w$])" + word.replace(/\$/g, "\\$") + "(?![\\w$])", "g");
      let count = 0;
      for (let i = 0; i < this.lines.length && count < 2000; i++) {
        const text = this.lines[i];
        if (!text.includes(word)) continue;
        const el = code.querySelector(`.code-line[data-line="${i + 1}"]`);
        if (!el || el.classList.contains("folded")) continue;
        const hits = [];
        for (const m of text.matchAll(re)) hits.push(m.index);
        for (const at of hits.reverse()) { markRange(el, at, at + word.length, "word-hit"); count++; }
      }
      return count;
    },

    // ---- folding --------------------------------------------------------------------------------------
    computeFoldRanges(text, lang) {
      const ranges = new Map();
      if (!text || text.length > FOLD_LIMIT || !(lang === "js" || lang === "css" || lang === "json")) return ranges;
      const tokens = Highlighter.tokenize(text, lang);
      if (!tokens) return ranges;
      const stack = [];
      let line = 1;
      for (const [cls, raw] of tokens) {
        if (cls === null) {
          for (const ch of raw) {
            if (ch === "\n") line++;
            else if (ch === "{" || ch === "[") stack.push(line);
            else if ((ch === "}" || ch === "]") && stack.length) {
              const start = stack.pop();
              if (line - start >= 2 && !ranges.has(start)) ranges.set(start, line);
            }
          }
        } else {
          for (const ch of raw) if (ch === "\n") line++;
        }
      }
      return ranges;
    },

    addFolding(file) {
      if (!file || file.content == null) return;
      const lang = Highlighter.language(file.url, file.type, file.content);
      const text = file.pretty && file.prettyContent != null ? file.prettyContent : file.content;
      this.foldRanges = this.computeFoldRanges(text, lang);
      const code = $("#sources-code");
      for (const [start, end] of this.foldRanges) {
        const el = code.querySelector(`.code-line[data-line="${start}"]`);
        if (!el) continue;
        const toggle = h("span", { class: "fold-toggle", role: "button", title: "Fold lines " + (start + 1) + "–" + (end - 1), "aria-expanded": "true" });
        toggle.addEventListener("mousedown", (e) => e.preventDefault());
        toggle.addEventListener("click", (e) => { e.stopPropagation(); this.toggleFold(start); });
        el.insertBefore(toggle, el.querySelector(".code-text"));
      }
      this.applyFolds();
    },

    toggleFold(start) {
      if (!this.foldRanges || !this.foldRanges.has(start)) return false;
      if (this.folded.has(start)) this.folded.delete(start); else this.folded.add(start);
      this.applyFolds();
      return this.folded.has(start);
    },

    applyFolds() {
      const code = $("#sources-code");
      for (const el of $$(".code-line.folded", code)) el.classList.remove("folded");
      for (const el of $$(".code-line.fold-start", code)) el.classList.remove("fold-start");
      for (const start of this.folded) {
        const end = this.foldRanges.get(start);
        if (end == null) continue;
        const head = code.querySelector(`.code-line[data-line="${start}"]`);
        if (head) { head.classList.add("fold-start"); head.querySelector(".fold-toggle")?.setAttribute("aria-expanded", "false"); }
        for (let n = start + 1; n < end; n++) code.querySelector(`.code-line[data-line="${n}"]`)?.classList.add("folded");
      }
      for (const el of $$(".code-line:not(.fold-start) .fold-toggle", code)) el.setAttribute("aria-expanded", "true");
    },

    // ---- go to line / symbol --------------------------------------------------------------------------
    // One quick-open box, as Chrome's: ":" for a line, "@" for a symbol.
    openGoto(mode) {
      if (!this.current) return;
      let box = $("#sources-goto");
      if (!box) {
        box = h("div", { id: "sources-goto", role: "dialog", "aria-label": "Go to" },
          h("input", { type: "text", id: "sources-goto-input", spellcheck: "false", autocomplete: "off", "aria-controls": "sources-goto-list" }),
          h("div", { id: "sources-goto-list", role: "listbox" }));
        document.body.appendChild(box);
        const input = box.querySelector("input");
        input.addEventListener("input", () => this.renderGoto());
        input.addEventListener("keydown", (e) => {
          e.stopPropagation();
          if (e.key === "Escape") { e.preventDefault(); this.closeGoto(); }
          else if (e.key === "Enter") { e.preventDefault(); this.acceptGoto(); }
          else if (e.key === "ArrowDown" || e.key === "ArrowUp") { e.preventDefault(); this.moveGoto(e.key === "ArrowDown" ? 1 : -1); }
        });
        input.addEventListener("blur", () => setTimeout(() => { if (!box.contains(document.activeElement)) this.closeGoto(); }, 120));
      }
      box.hidden = false;
      const input = $("#sources-goto-input");
      input.value = mode === "symbol" ? "@" : ":";
      this.gotoIndex = 0;
      this.renderGoto();
      input.focus();
      input.setSelectionRange(1, 1);
    },

    closeGoto() { const box = $("#sources-goto"); if (box) box.hidden = true; },

    symbols() {
      const file = this.files.get(this.current);
      const lang = file ? Highlighter.language(file.url, file.type, file.content) : null;
      const out = [];
      const patterns = lang === "css"
        ? [[/^\s*([^{}@;/][^{};]*?)\s*\{/, "rule"], [/^\s*(@[\w-]+[^{;]*?)\s*\{/, "at-rule"]]
        : [[/\bfunction\s*\*?\s*([A-Za-z_$][\w$]*)\s*\(/, "function"], [/\bclass\s+([A-Za-z_$][\w$]*)/, "class"],
           [/\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s+)?(?:function\b|\([^)]*\)\s*=>|[A-Za-z_$][\w$]*\s*=>)/, "function"],
           [/^\s*(?:static\s+|async\s+|get\s+|set\s+)*([A-Za-z_$][\w$]*)\s*\([^)]*\)\s*\{/, "method"],
           [/\b([A-Za-z_$][\w$]*)\s*:\s*(?:async\s+)?function\b/, "method"],
           [/(?:\.|\b)([A-Za-z_$][\w$]*)\s*=\s*(?:async\s+)?function\b/, "function"]];
      const keywords = new Set(["if", "for", "while", "switch", "catch", "function", "return", "with"]);
      this.lines.forEach((text, i) => {
        if (text.length > 2000) return;
        for (const [re, kind] of patterns) {
          const m = re.exec(text);
          if (m && !keywords.has(m[1])) { out.push({ name: m[1].trim().slice(0, 120), kind, line: i + 1 }); break; }
        }
      });
      return out;
    },

    gotoItems() {
      const value = $("#sources-goto-input").value;
      if (value.startsWith("@")) {
        const q = value.slice(1).trim().toLowerCase();
        return this.symbols().filter((s) => !q || s.name.toLowerCase().includes(q))
          .sort((a, b) => q ? (a.name.toLowerCase().indexOf(q) - b.name.toLowerCase().indexOf(q)) || a.line - b.line : a.line - b.line).slice(0, 300);
      }
      const m = /^:?\s*(\d+)?(?::(\d+))?/.exec(value);
      const n = m && m[1] ? Math.min(+m[1], this.lines.length) : null;
      return [{ name: n ? `Go to line ${n}` + (m[2] ? `, column ${m[2]}` : "") : `Type a line number between 1 and ${this.lines.length}`, line: n, column: m && m[2] ? +m[2] : 0, kind: "line" }];
    },

    renderGoto() {
      const list = $("#sources-goto-list");
      list.textContent = "";
      this.gotoList = this.gotoItems();
      this.gotoIndex = Math.min(this.gotoIndex || 0, Math.max(0, this.gotoList.length - 1));
      this.gotoList.forEach((item, i) => {
        const row = h("div", { class: "command-item" + (i === this.gotoIndex ? " active" : ""), role: "option", id: "sources-goto-" + i },
          item.kind !== "line" ? h("span", { class: "command-category" }, item.kind) : null,
          h("span", { class: "command-title" }, item.name),
          item.kind !== "line" ? h("span", { class: "command-subtitle" }, ":" + item.line) : null);
        row.addEventListener("mousedown", (e) => { e.preventDefault(); this.gotoIndex = i; this.acceptGoto(); });
        list.appendChild(row);
      });
      if (!this.gotoList.length) list.appendChild(h("div", { class: "command-empty" }, "No symbols"));
    },

    moveGoto(dir) {
      if (!this.gotoList || !this.gotoList.length) return;
      this.gotoIndex = (this.gotoIndex + dir + this.gotoList.length) % this.gotoList.length;
      this.renderGoto();
      $("#sources-goto-list .command-item.active")?.scrollIntoView({ block: "nearest" });
    },

    acceptGoto() {
      const item = this.gotoList && this.gotoList[this.gotoIndex];
      if (!item || !item.line) return;
      this.closeGoto();
      this.revealLine(item.line, item.column);
    },

    revealLine(line, column) {
      const code = $("#sources-code");
      // Unfold whatever hides it.
      for (const start of Array.from(this.folded)) { const end = this.foldRanges && this.foldRanges.get(start); if (end && line > start && line < end) this.folded.delete(start); }
      if (this.foldRanges) this.applyFolds();
      const el = code.querySelector(`.code-line[data-line="${line}"]`);
      if (!el) return false;
      for (const old of $$(".code-line.highlight", code)) old.classList.remove("highlight");
      el.classList.add("highlight");
      el.scrollIntoView({ block: "center" });
      this.setCurrentLine(line);
      $("#sources-position").textContent = `Line ${line}${column ? ", Column " + column : ""}`;
      return true;
    },

    // ---- search across all sources (drawer) ---------------------------------------------------------
    async ensureContent(file) {
      if (file.content != null) return file.content;
      if (file.type === "snippet") return file.content || "";
      if (SBSourceMaps.isOriginal(file.url) && SBSourceMaps.contentOf(file.url) != null) { file.content = SBSourceMaps.contentOf(file.url); file.original = true; return file.content; }
      try {
        const result = await DevTools.rpc("Sources.fetch", file.scriptId ? { scriptId: file.scriptId } : { url: file.url });
        file.content = result.text; file.refetched = !!result.refetched; file.live = !!result.live;
      } catch (_) { file.content = null; }
      return file.content;
    },

    async searchAll(query, { caseSensitive = false, regex = false } = {}) {
      let re;
      try { re = new RegExp(regex ? query : query.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), caseSensitive ? "g" : "gi"); }
      catch (e) { return { error: e.message, files: [] }; }
      const files = Array.from(this.files.values()).filter((f) => ["script", "stylesheet", "document", "snippet"].includes(f.type) || f.original);
      const queue = files.slice();
      const worker = async () => { while (queue.length) await this.ensureContent(queue.shift()); };
      await Promise.all([worker(), worker(), worker(), worker()]);
      const results = [];
      let total = 0;
      for (const file of files) {
        if (!file.content) continue;
        const lines = file.content.split("\n");
        const hits = [];
        for (let i = 0; i < lines.length && total < 5000; i++) {
          re.lastIndex = 0;
          const text = lines[i];
          if (text.length > 5000) {
            const m = re.exec(text);
            if (m) { hits.push({ line: i + 1, column: m.index, text: text.slice(Math.max(0, m.index - 60), m.index + 140), offset: Math.max(0, m.index - 60) }); total++; }
            continue;
          }
          if (re.test(text)) { hits.push({ line: i + 1, column: (re.lastIndex = 0, re.exec(text).index), text, offset: 0 }); total++; }
        }
        if (hits.length) results.push({ file, hits });
      }
      results.sort((a, b) => a.file.url.localeCompare(b.file.url));
      return { files: results, total, re };
    },

    async runSearchAll() {
      const query = $("#srcsearch-input").value;
      const box = $("#srcsearch-results");
      box.textContent = "";
      if (!query) { $("#srcsearch-count").textContent = ""; return null; }
      $("#srcsearch-count").textContent = "Searching…";
      const result = await this.searchAll(query, { caseSensitive: $("#srcsearch-case").checked, regex: $("#srcsearch-regex").checked });
      if (query !== $("#srcsearch-input").value) return result;
      if (result.error) { $("#srcsearch-count").textContent = result.error; return result; }
      $("#srcsearch-count").textContent = result.total ? `${result.total} match${result.total === 1 ? "" : "es"} in ${result.files.length} file${result.files.length === 1 ? "" : "s"}` : "No matches";
      for (const { file, hits } of result.files) {
        const group = h("div", { class: "srcsearch-file", role: "treeitem", "aria-expanded": "true" });
        const head = h("div", { class: "srcsearch-head", title: file.url, tabindex: "0" }, h("span", { class: "arrow" }), h("span", { class: "srcsearch-name" }, fileName(file.url)),
          h("span", { class: "muted" }, " — " + file.url.replace(/^[a-z]+:\/\//, "").slice(0, 120)), h("span", { class: "srcsearch-count" }, String(hits.length)));
        head.addEventListener("click", () => { group.classList.toggle("collapsed"); group.setAttribute("aria-expanded", group.classList.contains("collapsed") ? "false" : "true"); });
        group.appendChild(head);
        for (const hit of hits.slice(0, 200)) {
          const row = h("div", { class: "srcsearch-hit", tabindex: "0", role: "treeitem" }, h("span", { class: "srcsearch-line" }, String(hit.line)));
          const text = h("span", { class: "srcsearch-text" });
          const shown = hit.text.trim().length ? hit.text : hit.text;
          let last = 0;
          result.re.lastIndex = 0;
          for (const m of shown.matchAll(result.re)) {
            if (!m[0]) break;
            text.appendChild(document.createTextNode(shown.slice(last, m.index)));
            text.appendChild(h("mark", {}, m[0]));
            last = m.index + m[0].length;
          }
          text.appendChild(document.createTextNode(shown.slice(last)));
          row.appendChild(text);
          const go = () => { this.revealFrom(file.url, hit.line, hit.column); };
          row.addEventListener("click", go);
          row.addEventListener("keydown", (e) => { if (e.key === "Enter") go(); else if (e.key === "ArrowDown") row.nextElementSibling?.focus(); else if (e.key === "ArrowUp") row.previousElementSibling?.focus(); });
          group.appendChild(row);
        }
        if (hits.length > 200) group.appendChild(h("div", { class: "srcsearch-hit muted" }, `… ${hits.length - 200} more in this file`));
        box.appendChild(group);
      }
      return result;
    },

    async revealFrom(url, line, column) {
      DevTools.showPanel("sources");
      if (this.files.get(url)?.type === "snippet") { await this.open(url); return; }
      await this.open(url, line, column + 1);
    },

    initSearchAll() {
      Drawer.register("source-search", {
        title: "Search sources",
        show: () => { setTimeout(() => { $("#srcsearch-input").focus(); $("#srcsearch-input").select(); }, 0); },
      });
      $("#srcsearch-input").addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); this.runSearchAll(); } });
      $("#srcsearch-case").addEventListener("change", () => this.runSearchAll());
      $("#srcsearch-regex").addEventListener("change", () => this.runSearchAll());
    },

    openSearchAll(query) {
      Drawer.show("source-search");
      const selected = getSelection().toString();
      if (query != null) $("#srcsearch-input").value = query;
      else if (selected && !selected.includes("\n") && selected.length < 200) $("#srcsearch-input").value = selected;
      if ($("#srcsearch-input").value) return this.runSearchAll();
      return null;
    },

    // ---- snippets ---------------------------------------------------------------------------------------
    async loadSnippets() {
      try { this.snippets = JSON.parse(await DevTools.rpc("Settings.get", { key: "snippets" }) || "[]"); } catch (_) { this.snippets = []; }
      for (const s of this.snippets) this.registerSnippet(s);
      this.renderSnippets();
    },
    saveSnippets() {
      DevTools.rpc("Settings.set", { key: "snippets", value: JSON.stringify(this.snippets.map((s) => ({ name: s.name, content: s.content }))) }).catch(() => {});
    },
    snippetURL(name) { return SNIPPET_PREFIX + encodeURIComponent(name); },
    registerSnippet(s) {
      const url = this.snippetURL(s.name);
      const file = this.files.get(url) || { url, type: "snippet" };
      file.content = s.content; file.snippet = s;
      this.files.set(url, file);
      return file;
    },

    newSnippet(content = "") {
      let n = 1;
      while (this.snippets.some((s) => s.name === "Script snippet #" + n)) n++;
      const snippet = { name: "Script snippet #" + n, content };
      this.snippets.push(snippet);
      this.registerSnippet(snippet);
      this.saveSnippets();
      this.renderSnippets();
      this.open(this.snippetURL(snippet.name));
      return snippet;
    },

    renameSnippet(snippet, name) {
      name = name.trim();
      if (!name || name === snippet.name || this.snippets.some((s) => s.name === name)) { this.renderSnippets(); return false; }
      const oldURL = this.snippetURL(snippet.name);
      this.files.delete(oldURL);
      const wasOpen = this.tabs.includes(oldURL);
      this.tabs = this.tabs.filter((u) => u !== oldURL);
      snippet.name = name;
      const file = this.registerSnippet(snippet);
      this.saveSnippets();
      this.renderSnippets();
      if (wasOpen) this.open(file.url); else this.renderTabs();
      return true;
    },

    deleteSnippet(snippet) {
      const url = this.snippetURL(snippet.name);
      this.snippets = this.snippets.filter((s) => s !== snippet);
      this.files.delete(url);
      if (this.tabs.includes(url)) this.closeTab(url);
      this.saveSnippets();
      this.renderSnippets();
    },

    renderSnippets() {
      const list = $("#snippet-list");
      list.textContent = "";
      if (!this.snippets.length) { list.appendChild(h("div", { class: "empty-state" }, "Snippets are scripts you keep and run on any page.")); return; }
      for (const snippet of this.snippets) {
        const url = this.snippetURL(snippet.name);
        const name = h("span", { class: "snippet-name" }, snippet.name);
        const row = h("div", { class: "nav-item file snippet-item" + (this.current === url ? " selected" : ""), style: "--depth:0", role: "option", tabindex: "0", title: snippet.name },
          h("span", { class: "fileicon" }, "JS"), name,
          h("span", { class: "snippet-actions" },
            h("span", { class: "snippet-action", title: "Run", role: "button", onclick: (e) => { e.stopPropagation(); this.runSnippet(snippet); } }, "▶"),
            h("span", { class: "snippet-action", title: "Delete", role: "button", onclick: (e) => { e.stopPropagation(); this.deleteSnippet(snippet); } }, "✕")));
        row.addEventListener("click", () => this.open(url));
        row.addEventListener("dblclick", () => inlineEdit(name, { initial: snippet.name, onCommit: (t) => this.renameSnippet(snippet, t), onCancel: () => {} }));
        row.addEventListener("keydown", (e) => {
          if (e.key === "Enter") this.open(url);
          else if (e.key === "F2") inlineEdit(name, { initial: snippet.name, onCommit: (t) => this.renameSnippet(snippet, t), onCancel: () => {} });
          else if (e.key === "ArrowDown") row.nextElementSibling?.focus();
          else if (e.key === "ArrowUp") row.previousElementSibling?.focus();
        });
        row.addEventListener("contextmenu", (e) => {
          e.preventDefault();
          ContextMenu.show(e.clientX, e.clientY, [
            { label: "Run", action: () => this.runSnippet(snippet) },
            { label: "Rename…", action: () => inlineEdit(name, { initial: snippet.name, onCommit: (t) => this.renameSnippet(snippet, t), onCancel: () => {} }) },
            { label: "Remove", action: () => this.deleteSnippet(snippet) },
          ]);
        });
        list.appendChild(row);
      }
    },

    renderSnippet(file) {
      const code = $("#sources-code");
      code.textContent = "";
      code.classList.add("snippet-mode");
      $("#sources-pretty").hidden = true;
      $("#snippet-run").hidden = false;
      this.lines = (file.content || "").split("\n");
      const area = h("textarea", { class: "snippet-input", spellcheck: "false", "aria-label": "Snippet " + file.snippet.name });
      area.value = file.content || "";
      code.appendChild(area);
      const editor = CodeInput.attach(area, { language: "js", gutter: true });
      editor.wrap.classList.add("snippet-editor");
      const save = debounce(() => { file.snippet.content = area.value; file.content = area.value; this.saveSnippets(); }, 300);
      area.addEventListener("input", () => { file.snippet.content = area.value; file.content = area.value; this.lines = area.value.split("\n"); save(); });
      area.addEventListener("keydown", (e) => {
        if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); this.runSnippet(file.snippet); }
        else if (e.key === "Tab" && !e.shiftKey) { e.preventDefault(); document.execCommand("insertText", false, "  "); }
        e.stopPropagation();
      });
      $("#sources-position").textContent = "";
      $("#snippet-result").textContent = "⌘↩ runs the snippet in the page";
      this.renderSnippets();
      setTimeout(() => area.focus(), 0);
    },

    // Runs in the page (or the paused frame), logged in the Console like Chrome.
    async runSnippet(snippet) {
      const result = $("#snippet-result");
      result.textContent = "Running…";
      const cons = DevTools.panels.console;
      if (!cons.initialized) { cons.initialized = true; cons.init(); }
      const callFrameId = window.SBDebugger ? SBDebugger.currentCallFrameId() : undefined;
      const source = snippet.content + "\n//# sourceURL=" + this.snippetURL(snippet.name);
      try {
        const r = await DevTools.rpc("Console.evaluate", callFrameId ? { expression: source, callFrameId } : { expression: source });
        const text = r && r.exceptionDetails ? "✕ " + r.exceptionDetails.text : r && r.result ? "< " + (r.result.type === "string" ? JSON.stringify(r.result.description) : r.result.description) : "Done";
        result.textContent = text.split("\n")[0].slice(0, 200);
        result.classList.toggle("error", !!(r && r.exceptionDetails));
        return r;
      } catch (e) {
        result.textContent = "✕ " + e.message;
        result.classList.add("error");
        return null;
      }
    },

    async open(url, line, column) {
      if (url && url.startsWith(SNIPPET_PREFIX) && !this.files.has(url)) return;
      const result = await baseOpen.call(this, url, line, column);
      if (url && url.startsWith(SNIPPET_PREFIX)) { this.showNav("snippets"); this.renderTree(); }
      return result;
    },

    showNav(name) {
      for (const tab of $$("#sources-nav-tabs .subtab")) { tab.classList.toggle("active", tab.dataset.nav === name); tab.setAttribute("aria-selected", tab.dataset.nav === name ? "true" : "false"); }
      $("#sources-nav-page").hidden = name !== "page";
      $("#sources-nav-snippets").hidden = name !== "snippets";
    },
  });

  // The Page navigator lists what the page loaded; snippets have their own tab.
  const baseRenderTree = panel.renderTree;
  panel.renderTree = function () {
    const hidden = [];
    for (const [url, file] of this.files) if (file.type === "snippet") { hidden.push([url, file]); this.files.delete(url); }
    try { baseRenderTree.call(this); } finally { for (const [url, file] of hidden) this.files.set(url, file); }
  };

  for (const tab of $$("#sources-nav-tabs .subtab")) tab.addEventListener("click", () => panel.showNav(tab.dataset.nav));
  $("#snippet-new").addEventListener("click", () => panel.newSnippet(""));
  $("#snippet-run").addEventListener("click", () => {
    const file = panel.files.get(panel.current);
    if (file && file.snippet) panel.runSnippet(file.snippet);
  });
  panel.initEditorTools();
  // drawer.js loads after this file.
  window.addEventListener("DOMContentLoaded", () => panel.initSearchAll());
  panel.loadSnippets();

  document.addEventListener("keydown", (e) => {
    const meta = e.metaKey || e.ctrlKey;
    if (meta && e.altKey && (e.key === "f" || e.key === "ƒ" || e.code === "KeyF")) {
      e.preventDefault();
      panel.openSearchAll();
      return;
    }
    if (DevTools.activePanel !== "sources" || (e.target.closest && e.target.closest("input, textarea, [contenteditable='plaintext-only'], [contenteditable='true']"))) return;
    if ((e.ctrlKey && !e.metaKey && e.key === "g") || (e.metaKey && !e.shiftKey && (e.key === "l" || (e.key === "g" && $("#sources-find-bar").hidden)))) {
      e.preventDefault(); panel.openGoto("line");
    } else if (meta && e.shiftKey && (e.key === "o" || e.key === "O")) {
      e.preventDefault(); panel.openGoto("symbol");
    } else if (e.altKey && meta && (e.key === "[" || e.key === "]" || e.code === "BracketLeft" || e.code === "BracketRight")) {
      // ⌥⌘[ / ⌥⌘] fold and unfold the block at the current line.
      e.preventDefault();
      const start = panel.foldRanges && Array.from(panel.foldRanges.keys()).filter((s) => s <= (panel.currentLine || 0) && panel.foldRanges.get(s) >= (panel.currentLine || 0)).pop();
      if (start != null) { if ((e.code === "BracketLeft") !== panel.folded.has(start)) panel.toggleFold(start); }
    }
  });
})();
