// SimpleBrowser DevTools — the debugger's conveniences: hover a variable
// while paused to see its value, values inline at the end of the lines of
// the paused function, Continue to here, Never pause here, the ignore list
// (scripts the debugger steps over and the call stack folds away), and
// Copy call stack / Copy for AI. Extends SBDebugger (debugger.js).
"use strict";

(function () {
  const KEYWORDS = Highlighter.JS_KEYWORDS;
  const INLINE_SCOPES = new Set(["local", "closure", "block", "nestedLexical", "catch", "functionName", "with"]);
  const baseSelectFrame = SBDebugger.selectFrame;
  const baseOnResumed = SBDebugger.onResumed;
  const baseDecorate = SBDebugger.decorate;
  const baseOnAttached = SBDebugger.onAttached;

  // Strings and comments blanked out, so a scan only sees code.
  const masked = (text) => text.replace(/(["'`])(?:\\.|(?!\1).)*\1|\/\/.*$|\/\*.*?\*\//g, (m) => " ".repeat(m.length));

  Object.assign(SBDebugger, {
    ignoreList: [],
    showIgnoredFrames: false,
    inline: null,

    // ---- breakpoints that are not quite breakpoints -------------------------------------------
    neverPauseHere(url, line) { return this.setBreakpoint(url, line, { condition: "false" }); },

    // The engine's location for a line of a file (through the source map for an original).
    scriptLocation(url, line) {
      let target = { url, line, column: 1 };
      if (SBSourceMaps.isOriginal(url)) {
        const generated = SBSourceMaps.generated(url, line);
        if (!generated) return null;
        target = generated;
      }
      const l0 = target.line - 1;
      let best = null;
      for (const [scriptId, s] of this.scripts) {
        if (s.url !== target.url) continue;
        if (l0 < s.startLine || (s.endLine && l0 > s.endLine)) continue;
        if (!best || s.startLine >= best.startLine) best = { scriptId, startLine: s.startLine };
      }
      if (!best && url.startsWith(this.SCRIPT_PREFIX)) best = { scriptId: url.slice(this.SCRIPT_PREFIX.length) };
      return best ? { scriptId: best.scriptId, lineNumber: l0, columnNumber: Math.max(0, (target.column || 1) - 1) } : null;
    },

    async continueToHere(url, line) {
      const location = this.scriptLocation(url, line);
      if (!location) { this.report({ message: "No loaded script covers " + fileName(url) + ":" + line }); return false; }
      try { await this.send("Debugger.continueToLocation", { location }); return true; }
      catch (e) { this.report(e); return false; }
    },

    // ---- ignore list -------------------------------------------------------------------------------
    async loadIgnoreList() {
      try { this.ignoreList = JSON.parse(await DevTools.rpc("Settings.get", { key: "ignoreList" }) || "[]"); } catch (_) { this.ignoreList = []; }
      this.renderIgnoreList();
      if (this.available) this.applyIgnoreList();
    },
    applyIgnoreList() {
      for (const url of this.ignoreList) this.send("Debugger.setShouldBlackboxURL", { url, shouldBlackbox: true, caseSensitive: true, isRegex: false }).catch(() => {});
    },
    // An original file is ignored through the bundle it was mapped from.
    ignoreTarget(url) { return SBSourceMaps.byOriginal.get(url) || url; },
    isIgnoredURL(url) { return !!url && this.ignoreList.includes(this.ignoreTarget(url)); },
    isIgnored(frame) { return this.isIgnoredURL(frame.generated ? frame.generated.url : frame.url); },

    async setIgnored(url, ignored) {
      const target = this.ignoreTarget(url);
      if (!target || target.startsWith(this.SCRIPT_PREFIX)) return false;
      this.ignoreList = this.ignoreList.filter((u) => u !== target);
      if (ignored) this.ignoreList.push(target);
      DevTools.rpc("Settings.set", { key: "ignoreList", value: JSON.stringify(this.ignoreList) }).catch(() => {});
      if (this.available) await this.send("Debugger.setShouldBlackboxURL", { url: target, shouldBlackbox: ignored, caseSensitive: true, isRegex: false }).catch((e) => this.report(e));
      this.renderIgnoreList();
      if (this.paused) this.renderStack();
      return true;
    },

    renderIgnoreList() {
      const list = $("#dbg-ignore");
      list.textContent = "";
      if (!this.ignoreList.length) { list.appendChild(h("div", { class: "dbg-empty" }, "No ignored scripts. Right-click a script or a call frame to add it.")); return; }
      for (const url of this.ignoreList) {
        list.appendChild(h("div", { class: "dbg-bp", title: url },
          h("div", { style: "min-width:0;flex:1" }, h("div", { class: "where", onclick: () => DevTools.openSource(url, 0, 0) }, fileName(url))),
          h("span", { class: "remove", title: "Remove from the ignore list", role: "button", onclick: () => this.setIgnored(url, false) }, "✕")));
      }
    },

    ignoreItem(url) {
      if (!url || url.startsWith(this.SCRIPT_PREFIX) || url.startsWith("snippet:")) return null;
      return this.isIgnoredURL(url)
        ? { label: "Remove script from ignore list", action: () => this.setIgnored(url, false) }
        : { label: "Add script to ignore list", action: () => this.setIgnored(url, true) };
    },

    // ---- inline values -------------------------------------------------------------------------------
    // Values of the paused function's variables, shown after the lines that
    // mention them, from the start of the function down to the paused line.
    async computeInline(frame) {
      const values = new Map();
      for (const scope of frame.scopeChain || []) {
        if (!INLINE_SCOPES.has(scope.type) || !scope.object || !scope.object.objectId) continue;
        try {
          const r = await this.send("Runtime.getProperties", { objectId: scope.object.objectId, ownProperties: true, generatePreview: true });
          for (const p of r.properties || []) if (p.value && !values.has(p.name)) values.set(p.name, this.shortValue(p.value));
        } catch (_) {}
        if (scope.type === "closure" || values.size > 300) break;
      }
      return values;
    },

    shortValue(o) {
      const n = this.normalize(o);
      if (n.type === "string") { const s = JSON.stringify(n.description); return s.length > 40 ? s.slice(0, 39) + "…\"" : s; }
      if (n.type !== "object" && n.type !== "function") return n.description;
      if (n.type === "function") return "ƒ";
      const text = ObjectTree.render(n, { expandable: false }).textContent;
      return text.length > 60 ? text.slice(0, 59) + "…" : text;
    },

    // The line the paused function starts on: walk up until the block that
    // encloses the paused line opens on a line that looks like a function.
    functionStart(lines, line) {
      let depth = 0;
      for (let l = line - 1, steps = 0; l >= 0 && steps < 400; l--, steps++) {
        const text = masked(lines[l] || "");
        for (let c = text.length - 1; c >= 0; c--) {
          if (text[c] === "}") depth++;
          else if (text[c] === "{") {
            if (depth === 0) {
              const control = /^\s*(?:}\s*)?(?:if|for|while|switch|catch|with|else|do|try|finally)\b/.test(text);
              if (/\bfunction\b|=>/.test(text) || (!control && /^\s*(?:async\s+|static\s+|get\s+|set\s+)*[\w$]+\s*\([^)]*\)\s*\{/.test(text))) return l + 1;
            }
            else depth--;
          }
        }
      }
      return Math.max(1, line - 30);
    },

    async renderInlineValues(frame) {
      this.inline = null;
      this.clearInline();
      const sources = DevTools.panels.sources;
      const file = sources && sources.files.get(this.fileURL(frame));
      if (!frame || !file || file.pretty || file.content == null) return;
      const callFrameId = frame.callFrameId;
      const values = await this.computeInline(frame);
      if (!this.paused || this.currentCallFrameId() !== callFrameId) return;
      const lines = file.content.split("\n");
      const start = this.functionStart(lines, frame.line);
      const perLine = new Map();
      for (let n = start; n <= frame.line && n <= lines.length; n++) {
        const seen = [];
        for (const m of masked(lines[n - 1]).matchAll(/(?<![.\w$])[A-Za-z_$][\w$]*/g)) {
          const name = m[0];
          if (KEYWORDS.has(name) || !values.has(name) || seen.includes(name)) continue;
          seen.push(name);
          if (seen.length >= 4) break;
        }
        if (seen.length) perLine.set(n, seen.map((name) => name + " = " + values.get(name)).join(", "));
      }
      this.inline = { callFrameId, url: file.url, perLine };
      this.applyInline();
    },

    applyInline() {
      this.clearInline();
      const sources = DevTools.panels.sources;
      if (!this.inline || !sources || sources.current !== this.inline.url) return;
      const code = $("#sources-code");
      for (const [n, text] of this.inline.perLine) {
        const el = code.querySelector(`.code-line[data-line="${n}"]`);
        if (el) el.appendChild(h("span", { class: "inline-values", title: text }, text));
      }
    },

    clearInline() { for (const el of $$("#sources-code .inline-values")) el.remove(); },

    // ---- hover to see a value -------------------------------------------------------------------------
    initHover() {
      const code = $("#sources-code");
      let timer = null;
      code.addEventListener("mousemove", (e) => {
        if (!this.paused || e.buttons) return;
        clearTimeout(timer);
        const x = e.clientX, y = e.clientY;
        timer = setTimeout(() => this.hoverAt(x, y), 250);
      });
      code.addEventListener("mouseleave", (e) => {
        clearTimeout(timer);
        if (!(e.relatedTarget && e.relatedTarget.closest && e.relatedTarget.closest(".dbg-popover"))) this.hidePopover();
      });
      code.addEventListener("scroll", () => this.hidePopover());
    },

    // The identifier under the point, with the property chain before it (`a.b.c`).
    expressionAt(x, y) {
      const range = document.caretRangeFromPoint ? document.caretRangeFromPoint(x, y) : null;
      if (!range || range.startContainer.nodeType !== 3) return null;
      const lineEl = range.startContainer.parentElement.closest(".code-line");
      const textEl = lineEl && lineEl.querySelector(".code-text");
      if (!textEl || !textEl.contains(range.startContainer)) return null;
      // caretRangeFromPoint snaps to the nearest character; make sure the pointer is on one.
      const probe = document.createRange();
      const node = range.startContainer, off = range.startOffset;
      probe.setStart(node, Math.max(0, off - (off === node.nodeValue.length ? 1 : 0)));
      probe.setEnd(node, Math.min(node.nodeValue.length, probe.startOffset + 1));
      const rect = probe.getBoundingClientRect();
      if (!rect.width || x < rect.left - 8 || x > rect.right + 8 || y < rect.top - 2 || y > rect.bottom + 2) return null;
      const pre = document.createRange();
      pre.setStart(textEl, 0); pre.setEnd(node, off);
      const column = pre.toString().length;
      const line = +lineEl.dataset.line;
      return this.expressionInLine(textEl.textContent, column, line);
    },

    expressionInLine(text, column, line) {
      const isWord = (c) => c && /[\w$]/.test(c);
      let s = column, e = column;
      if (!isWord(text[s]) && isWord(text[s - 1])) { s--; e--; }
      if (!isWord(text[s])) return null;
      while (isWord(text[s - 1])) s--;
      while (isWord(text[e])) e++;
      const word = text.slice(s, e);
      if (/^\d/.test(word) || (KEYWORDS.has(word) && word !== "this")) return null;
      let start = s;
      while (text[start - 1] === "." && isWord(text[start - 2])) {
        let p = start - 1;
        if (text[p - 1] === "?") p--;
        let q = p;
        while (isWord(text[q - 1])) q--;
        if (q === p) break;
        start = q;
        if (text[start - 1] !== "." ) break;
      }
      const expression = text.slice(start, e).replace(/\?\./g, "?.");
      if (masked(text).slice(start, e).trim() !== text.slice(start, e).trim()) return null;   // inside a string or comment
      return { expression, line, start, end: e };
    },

    async hoverAt(x, y) {
      if (!this.paused) return;
      const hit = this.expressionAt(x, y);
      if (!hit) { if (!this.popoverHovered) this.hidePopover(); return; }
      if (this.popover && this.popover.expression === hit.expression && this.popover.line === hit.line) return;
      const value = await this.evaluateHover(hit.expression);
      if (!value || !this.paused) return;
      this.showPopover(hit, value, x, y);
    },

    async evaluateHover(expression) {
      const callFrameId = this.currentCallFrameId();
      if (!callFrameId) return null;
      try {
        const r = await this.send("Debugger.evaluateOnCallFrame", { callFrameId, expression, objectGroup: "popover", generatePreview: true,
          doNotPauseOnExceptionsAndMuteConsole: true, includeCommandLineAPI: false });
        return r.wasThrown ? null : this.normalize(r.result);
      } catch (_) { return null; }
    },

    showPopover(hit, value, x, y) {
      this.hidePopover();
      const box = h("div", { class: "dbg-popover", role: "tooltip" }, h("div", { class: "dbg-popover-title" }, hit.expression), h("div", { class: "dbg-popover-value" }, ObjectTree.render(value)));
      box.addEventListener("mouseenter", () => { this.popoverHovered = true; });
      box.addEventListener("mouseleave", () => { this.popoverHovered = false; this.hidePopover(); });
      document.body.appendChild(box);
      const w = box.offsetWidth, ht = box.offsetHeight;
      box.style.left = Math.max(4, Math.min(x - 10, innerWidth - w - 8)) + "px";
      box.style.top = (y + 18 + ht < innerHeight ? y + 14 : Math.max(4, y - ht - 10)) + "px";
      this.popover = { el: box, expression: hit.expression, line: hit.line };
      // An object opens one level, as Chrome's popover does.
      box.querySelector(".obj-toggle")?.click();
    },

    hidePopover() {
      if (this.popover) { this.popover.el.remove(); this.popover = null; }
      this.popoverHovered = false;
      this.send("Runtime.releaseObjectGroup", { objectGroup: "popover" }).catch(() => {});
    },

    // ---- copy -----------------------------------------------------------------------------------------
    callStackText() {
      return this.frames.map((f) => `${f.functionName} (${f.url || "(program)"}:${f.line}:${f.column})` +
        (f.generated ? ` [generated: ${f.generated.url}:${f.generated.line}:${f.generated.column}]` : "")).join("\n");
    },

    // The pause as Markdown: why, where (with the code around it), the stack and the variables.
    async pauseMarkdown() {
      if (!this.paused) return "Not paused.";
      const frame = this.frames[this.selectedFrame] || this.frames[0];
      const out = ["## Paused in the debugger", "", `- **Reason**: ${$("#dbg-banner").textContent.trim() || "Paused"}`];
      if (DevTools.info.url) out.push(`- **Page**: ${DevTools.info.url}`);
      out.push(`- **Location**: \`${frame.functionName}\` at ${frame.url || "(program)"}:${frame.line}:${frame.column}`);
      const sources = DevTools.panels.sources;
      const file = sources && sources.files.get(this.fileURL(frame));
      if (file && file.content != null) {
        const lines = file.content.split("\n");
        const from = Math.max(1, frame.line - 6), to = Math.min(lines.length, frame.line + 4);
        const width = String(to).length;
        const excerpt = [];
        for (let n = from; n <= to; n++) excerpt.push((n === frame.line ? "→ " : "  ") + String(n).padStart(width) + " | " + (lines[n - 1] || "").slice(0, 300));
        out.push("", "### Code", "", Markdown.fence(excerpt.join("\n"), Highlighter.language(file.url, file.type, file.content) || ""));
      }
      out.push("", "### Call stack", "");
      this.frames.forEach((f, i) => out.push(`${i + 1}. ${i === this.selectedFrame ? "**" : ""}\`${f.functionName}\`${i === this.selectedFrame ? "**" : ""} — ${f.url || "(program)"}:${f.line}:${f.column}` +
        (f.generated ? ` (bundle ${fileName(f.generated.url)}:${f.generated.line}:${f.generated.column})` : "") + (this.isIgnored(f) ? " _(ignore-listed)_" : "")));
      let scopes = 0;
      for (const scope of frame.scopeChain || []) {
        if (scope.type === "global" || !scope.object || !scope.object.objectId || scopes >= 3) continue;
        let props = [];
        try { props = (await this.send("Runtime.getProperties", { objectId: scope.object.objectId, ownProperties: true, generatePreview: true })).properties || []; } catch (_) {}
        if (!props.length) continue;
        scopes++;
        out.push("", `### Scope: ${this.SCOPE_TITLES[scope.type] || scope.type}${scope.name ? " (" + scope.name + ")" : ""}`, "");
        for (const p of props.slice(0, 40)) if (p.value) out.push(`- \`${p.name}\` = ${this.shortValue(p.value).replace(/\n/g, " ")}`);
        if (props.length > 40) out.push(`- … ${props.length - 40} more`);
      }
      const watches = $$("#dbg-watch .dbg-watch-row").map((r) => r.textContent.replace(/✕$/, "").trim()).filter(Boolean);
      if (this.watches.length && watches.length) out.push("", "### Watch", "", ...watches.map((w) => "- `" + w + "`"));
      return out.join("\n");
    },

    initTools() {
      $("#dbg-stack").addEventListener("contextmenu", (e) => {
        if (!this.paused) return;
        e.preventDefault();
        const row = e.target.closest(".dbg-frame");
        const frame = row && row.__frame;
        const copy = (text) => DevTools.rpc("Clipboard.write", { text }).catch(() => {});
        const items = [
          { label: "Copy call stack", action: () => copy(this.callStackText()) },
          { label: "Copy for AI (Markdown)", action: async () => copy(await this.pauseMarkdown()) },
        ];
        const ignore = frame && this.ignoreItem(frame.url);
        if (ignore) items.push("-", ignore);
        items.push({ label: this.showIgnoredFrames ? "Hide ignore-listed frames" : "Show ignore-listed frames", action: () => { this.showIgnoredFrames = !this.showIgnoredFrames; this.renderStack(); } });
        ContextMenu.show(e.clientX, e.clientY, items);
      });
      $("#sources-code").addEventListener("contextmenu", (e) => {
        if (e.target.closest(".ln") || e.target.closest(".snippet-editor")) return;
        const sources = DevTools.panels.sources;
        const file = sources && sources.files.get(sources.current);
        if (!file) return;
        e.preventDefault();
        const selected = getSelection().toString().trim();
        const items = [];
        if (selected) {
          items.push({ label: "Search in all sources", action: () => sources.openSearchAll(selected) });
          items.push({ label: "Evaluate in console", action: () => { DevTools.showPanel("console"); DevTools.panels.console.evaluate(selected); } });
          items.push({ label: "Add selected text to watches", action: () => { this.watches.push(selected); DevTools.rpc("Settings.set", { key: "watches", value: JSON.stringify(this.watches) }).catch(() => {}); this.renderWatches(); } });
          items.push({ label: "Copy", action: () => DevTools.rpc("Clipboard.write", { text: selected }) });
        }
        const ignore = this.ignoreItem(file.url);
        if (ignore) { if (items.length) items.push("-"); items.push(ignore); }
        if (this.paused) { if (items.length) items.push("-"); items.push({ label: "Copy pause for AI (Markdown)", action: async () => DevTools.rpc("Clipboard.write", { text: await this.pauseMarkdown() }) }); }
        if (items.length) ContextMenu.show(e.clientX, e.clientY, items);
      });
      this.initHover();
      this.loadIgnoreList();
    },
  });

  // ---- hooks into debugger.js ---------------------------------------------------------------------------
  SBDebugger.selectFrame = async function (index) {
    const result = await baseSelectFrame.call(this, index);
    const frame = this.frames[index];
    if (frame && this.paused) this.renderInlineValues(frame);
    return result;
  };
  SBDebugger.onResumed = function () {
    this.inline = null;
    this.clearInline();
    this.hidePopover();
    return baseOnResumed.call(this);
  };
  SBDebugger.decorate = function (file) {
    baseDecorate.call(this, file);
    if (this.paused && this.inline) this.applyInline();
  };
  SBDebugger.onAttached = function (scripts) {
    baseOnAttached.call(this, scripts);
    this.applyIgnoreList();
  };

  SBDebugger.initTools();
})();
