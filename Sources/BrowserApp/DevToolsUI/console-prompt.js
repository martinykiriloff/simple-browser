// Keel DevTools — the console prompt: a syntax-highlighted,
// multi-line editor (⇧↩ for a new line; ↩ continues while brackets are
// open), history kept across sessions, autocomplete of the properties of
// whatever is before the dot (with what each one is), and Chrome's eager
// evaluation: a preview of the result under the prompt for expressions
// that cannot change anything. Extends the Console panel (console.js).
"use strict";

(function () {
  const panel = DevTools.panels.console;
  const HISTORY_LIMIT = 500;
  const TYPE_LABELS = { method: "method", function: "function", class: "class", property: "property", accessor: "getter",
                        object: "object", string: "string", number: "number", boolean: "boolean", undefined: "undefined",
                        symbol: "symbol", bigint: "bigint", api: "console API", keyword: "keyword", variable: "variable" };

  Object.assign(panel, {
    history: [],
    historyIndex: 0,
    draft: "",
    completions: [],
    completionIndex: -1,
    completionContext: null,
    eagerGeneration: 0,
    lastEager: null,
    scopeNames: null,

    initPrompt() {
      this.editor = CodeInput.attach(this.prompt, { language: "js" });
      this.eagerEl = h("div", { id: "console-eager", class: "console-eager", hidden: true, "aria-live": "polite" });
      this.editor.wrap.appendChild(this.eagerEl);
      this.prompt.setAttribute("aria-label", "Console prompt");
      this.prompt.setAttribute("aria-autocomplete", "list");
      this.prompt.setAttribute("aria-controls", "console-completions");

      // The history used to live in the web view's storage, which does not
      // outlive the app; it is the app's now. Old entries are carried over.
      try { this.history = JSON.parse(localStorage.getItem("devtools.console.history") || "[]"); } catch (_) {}
      this.historyIndex = this.history.length;
      DevTools.rpc("Settings.get", { key: "consoleHistory" }).then((saved) => {
        let kept = [];
        try { kept = JSON.parse(saved || "[]"); } catch (_) {}
        const merged = kept.concat(this.history.filter((h) => !kept.includes(h))).slice(-HISTORY_LIMIT);
        this.history = merged;
        this.historyIndex = this.history.length;
      }).catch(() => {});

      this.prompt.addEventListener("keydown", (e) => this.onPromptKey(e));
      this.prompt.addEventListener("input", () => { this.autoGrow(); this.requestCompletions(); this.requestEager(); });
      this.prompt.addEventListener("blur", () => setTimeout(() => { if (document.activeElement !== this.prompt) this.hideCompletions(); }, 150));
      this.prompt.addEventListener("click", () => this.hideCompletions());
      DevTools.on("Protocol.event", ({ method }) => { if (method === "Debugger.paused" || method === "Debugger.resumed") this.scopeNames = null; });
    },

    onSettingsChanged() {
      if (!this.settings.eager && this.eagerEl) { this.eagerEl.hidden = true; this.lastEager = null; }
      else if (this.prompt && this.prompt.value) this.requestEager();
    },

    // ---- history --------------------------------------------------------------
    remember(text) {
      if (this.history[this.history.length - 1] !== text) {
        this.history = this.history.filter((h) => h !== text);
        this.history.push(text);
        if (this.history.length > HISTORY_LIMIT) this.history.splice(0, this.history.length - HISTORY_LIMIT);
        const list = JSON.stringify(this.history);
        try { localStorage.setItem("devtools.console.history", list); } catch (_) {}
        DevTools.rpc("Settings.set", { key: "consoleHistory", value: list }).catch(() => {});
      }
      this.historyIndex = this.history.length;
      this.draft = "";
    },

    setPrompt(text) {
      this.prompt.value = text;
      this.editor.paint();
      this.autoGrow();
      this.prompt.setSelectionRange(text.length, text.length);
      this.requestEager();
    },

    autoGrow() {
      this.prompt.style.height = "auto";
      this.prompt.style.height = Math.min(240, this.prompt.scrollHeight) + "px";
      this.editor.sync();
    },

    // ---- keys -----------------------------------------------------------------
    onPromptKey(e) {
      const box = $("#console-completions");
      if (!box.hidden) {
        if (e.key === "ArrowDown") { e.preventDefault(); this.moveCompletion(1); return; }
        if (e.key === "ArrowUp") { e.preventDefault(); this.moveCompletion(-1); return; }
        if (e.key === "Tab" || (e.key === "Enter" && !e.shiftKey && this.completionIndex >= 0) || (e.key === "ArrowRight" && this.caretAtEnd())) {
          e.preventDefault(); this.acceptCompletion(); return;
        }
        if (e.key === "Escape") { e.preventDefault(); this.hideCompletions(); return; }
      }
      if (e.key === "Enter" && !e.shiftKey && !e.altKey) {
        e.preventDefault();
        const text = this.prompt.value;
        if (!text.trim()) return;
        // Open brackets, an unfinished template: keep typing, on the next line.
        if (this.caretAtEnd() && CodeInput.isIncomplete(text)) { this.insertNewline(); return; }
        this.evaluate(text.trim());
        this.setPrompt("");
        this.hideCompletions();
        this.eagerEl.hidden = true;
        this.lastEager = null;
      } else if (e.key === "Enter" && (e.shiftKey || e.altKey)) {
        e.preventDefault();
        this.insertNewline();
      } else if (e.key === "Tab" && !e.shiftKey && this.prompt.value.includes("\n")) {
        e.preventDefault();
        this.insertText("  ");
      } else if (e.key === "ArrowUp" && this.caretOnFirstLine() && !e.shiftKey) {
        if (this.historyIndex > 0) {
          e.preventDefault();
          if (this.historyIndex === this.history.length) this.draft = this.prompt.value;
          this.historyIndex--;
          this.setPrompt(this.history[this.historyIndex]);
        }
      } else if (e.key === "ArrowDown" && this.caretOnLastLine() && !e.shiftKey) {
        if (this.historyIndex < this.history.length) {
          e.preventDefault();
          this.historyIndex++;
          this.setPrompt(this.historyIndex === this.history.length ? this.draft : this.history[this.historyIndex]);
        }
      } else if (e.key === "Escape") {
        this.hideCompletions();
      } else if (e.key === " " && e.ctrlKey) {
        e.preventDefault();
        this.requestCompletions(true);
      }
    },

    insertText(text) {
      const p = this.prompt;
      const start = p.selectionStart, end = p.selectionEnd;
      // execCommand keeps the edit on the textarea's own undo stack.
      if (!document.execCommand("insertText", false, text)) {
        p.value = p.value.slice(0, start) + text + p.value.slice(end);
        p.setSelectionRange(start + text.length, start + text.length);
      }
      this.editor.paint();
      this.autoGrow();
    },

    // A new line, indented like the current one, one step more after an opening bracket.
    insertNewline() {
      const p = this.prompt;
      const before = p.value.slice(0, p.selectionStart);
      const currentLine = before.slice(before.lastIndexOf("\n") + 1);
      let indent = (currentLine.match(/^\s*/) || [""])[0];
      if (/[({[]\s*$/.test(before)) indent += "  ";
      this.insertText("\n" + indent);
      this.hideCompletions();
    },

    caretOnFirstLine() { return !this.prompt.value.slice(0, this.prompt.selectionStart).includes("\n"); },
    caretOnLastLine() { return !this.prompt.value.slice(this.prompt.selectionEnd).includes("\n"); },
    caretAtEnd() { return this.prompt.selectionEnd === this.prompt.value.length; },

    // ---- autocomplete -----------------------------------------------------------
    // What is being completed: the identifier before the caret, and the
    // expression before its dot (brackets balanced), e.g. in
    // `foo(document.body.chi` → object "document.body", prefix "chi".
    completionAt(text, caret) {
      const before = text.slice(0, caret);
      const prefix = (before.match(/[\w$]*$/) || [""])[0];
      let i = before.length - prefix.length;
      if (before[i - 1] !== ".") {
        if (/[\w$.'"`]$/.test(before.slice(0, i)) && i > 0) return null;   // inside a number, string…
        return { object: "", prefix };
      }
      if (before[i - 2] === ".") return null;                               // `...`
      let depth = 0, j = i - 1;
      for (j = i - 2; j >= 0; j--) {
        const c = before[j];
        if (c === ")" || c === "]") depth++;
        else if (c === "(" || c === "[") { if (depth === 0) break; depth--; }
        else if (depth === 0 && /[\s;,=+\-*/%&|!?:<>{}^~]/.test(c)) break;
      }
      const object = before.slice(j + 1, i - 1).trim();
      if (!object || /^\d+$/.test(object)) return null;
      return { object, prefix };
    },

    requestCompletions: debounce(function (force) {
      const self = DevTools.panels.console;
      const text = self.prompt.value;
      const caret = self.prompt.selectionStart;
      if (self.prompt.selectionStart !== self.prompt.selectionEnd) { self.hideCompletions(); return; }
      const after = text.slice(caret);
      if (after && /^[\w$]/.test(after)) { self.hideCompletions(); return; }
      const context = self.completionAt(text, caret);
      if (!context || (!context.object && !context.prefix && !force)) { self.hideCompletions(); return; }
      if (context.object && !EagerEval.isSafe(context.object)) { self.hideCompletions(); return; }
      self.fetchCompletions(context).then((result) => {
        if (self.prompt.value !== text || self.prompt.selectionStart !== caret) return;
        self.showCompletions(context, result);
      }).catch(() => self.hideCompletions());
    }, 90),

    async fetchCompletions(context) {
      const frame = window.SBDebugger && SBDebugger.paused ? SBDebugger.currentCallFrameId() : null;
      if (!frame) {
        const r = await DevTools.rpc("Runtime.getCompletions", { object: context.object, prefix: context.prefix });
        return { names: r.names || [], types: r.types || {} };
      }
      // Paused: names come from the selected frame, its scopes first.
      const collect = "(function (o, prefix) { var out = {}; var n = 0; if (o === null || o === undefined) return out; o = Object(o); " +
        "for (var d = 0; o && d < 20 && n < 800; d++, o = Object.getPrototypeOf(o)) { var keys = Object.getOwnPropertyNames(o); " +
        "for (var i = 0; i < keys.length; i++) { var k = keys[i]; if (k.indexOf(prefix) !== 0 || out[k]) continue; var t = 'property'; " +
        "try { var p = Object.getOwnPropertyDescriptor(o, k); t = p && 'value' in p ? (typeof p.value === 'function' ? 'method' : typeof p.value) : 'accessor'; } catch (e) {} out[k] = t; n++; } } return out; })";
      const target = context.object || "this";
      const result = await SBDebugger.send("Debugger.evaluateOnCallFrame", { callFrameId: frame, expression: collect + "(" + target + ", " + JSON.stringify(context.prefix) + ")",
        objectGroup: "completion", returnByValue: true, doNotPauseOnExceptionsAndMuteConsole: true });
      const types = Object.assign({}, (result && result.result && result.result.value) || {});
      if (!context.object) {
        for (const [name, kind] of Object.entries(await this.frameScopeNames())) if (name.startsWith(context.prefix)) types[name] = kind;
        const globals = await DevTools.rpc("Runtime.getCompletions", { object: "", prefix: context.prefix }).catch(() => null);
        if (globals) for (const n of globals.names) if (!types[n]) types[n] = globals.types[n] || "property";
      }
      return { names: Object.keys(types).sort(), types };
    },

    // Local and closure variables of the selected frame (once per pause).
    async frameScopeNames() {
      if (this.scopeNames && this.scopeNames.frame === SBDebugger.selectedFrame) return this.scopeNames.names;
      const names = {};
      const frame = SBDebugger.frames[SBDebugger.selectedFrame];
      for (const scope of (frame && frame.scopeChain) || []) {
        if (scope.type === "global" || !scope.object || !scope.object.objectId) continue;
        try {
          const r = await SBDebugger.send("Runtime.getProperties", { objectId: scope.object.objectId, ownProperties: true });
          for (const p of r.properties || []) if (!(p.name in names)) names[p.name] = "variable";
        } catch (_) {}
      }
      this.scopeNames = { frame: SBDebugger.selectedFrame, names };
      return names;
    },

    showCompletions(context, { names, types }) {
      let list = names.filter((n) => n !== context.prefix && (context.prefix.startsWith("_") || !n.startsWith("__")));
      // Own and short names first, as Chrome does; then alphabetical.
      list = list.slice(0, 200);
      if (!list.length) { this.hideCompletions(); return; }
      this.completions = list.map((name) => ({ name, prefix: context.prefix, type: types[name] || "property" }));
      this.completionIndex = 0;
      const box = $("#console-completions");
      box.textContent = "";
      box.setAttribute("role", "listbox");
      list.forEach((name, i) => {
        const type = types[name] || "property";
        const item = h("div", { class: "item" + (i === 0 ? " active" : ""), role: "option", id: "console-completion-" + i,
            onmousedown: (e) => { e.preventDefault(); this.completionIndex = i; this.acceptCompletion(); } },
          h("span", { class: "completion-icon kind-" + type }),
          h("span", { class: "completion-name" }, h("b", {}, name.slice(0, context.prefix.length)), name.slice(context.prefix.length)),
          h("span", { class: "completion-type" }, TYPE_LABELS[type] || type));
        box.appendChild(item);
      });
      box.hidden = false;
      this.prompt.setAttribute("aria-activedescendant", "console-completion-0");
    },

    moveCompletion(dir) {
      const items = $$("#console-completions .item");
      if (!items.length) return;
      this.completionIndex = (this.completionIndex + dir + items.length) % items.length;
      items.forEach((el, i) => el.classList.toggle("active", i === this.completionIndex));
      items[this.completionIndex].scrollIntoView({ block: "nearest" });
      this.prompt.setAttribute("aria-activedescendant", items[this.completionIndex].id);
    },

    acceptCompletion() {
      const c = this.completions[this.completionIndex];
      if (!c) return;
      const p = this.prompt;
      const caret = p.selectionStart;
      p.setSelectionRange(caret - c.prefix.length, caret);
      this.insertText(c.name);
      this.hideCompletions();
      this.requestEager();
    },

    hideCompletions() {
      $("#console-completions").hidden = true;
      this.completions = [];
      this.completionIndex = -1;
      if (this.prompt) this.prompt.removeAttribute("aria-activedescendant");
    },

    // ---- eager evaluation -------------------------------------------------------------
    requestEager: debounce(function () { DevTools.panels.console.eager(); }, 120),

    async eager() {
      const text = this.prompt.value.trim();
      const show = (node) => { this.eagerEl.textContent = ""; if (node) { this.eagerEl.appendChild(node); this.eagerEl.hidden = false; } else this.eagerEl.hidden = true; };
      if (!this.settings.eager || !text || /^\s*\/\//.test(text)) { this.lastEager = null; show(null); return; }
      if (text === this.lastEager) return;
      this.lastEager = text;
      if (!EagerEval.isSafe(text)) { show(null); return; }
      const generation = ++this.eagerGeneration;
      let result;
      try {
        const frame = window.SBDebugger && SBDebugger.paused ? SBDebugger.currentCallFrameId() : null;
        if (frame) {
          const r = await SBDebugger.send("Debugger.evaluateOnCallFrame", { callFrameId: frame, expression: text, objectGroup: "eager",
            generatePreview: true, doNotPauseOnExceptionsAndMuteConsole: true });
          result = r.wasThrown ? { exceptionDetails: { text: "" } } : { result: SBDebugger.normalize(r.result) };
          if (result.result) delete result.result.objectId;
          SBDebugger.send("Runtime.releaseObjectGroup", { objectGroup: "eager" }).catch(() => {});
        } else {
          result = await DevTools.rpc("Runtime.evaluateEager", { expression: text });
        }
      } catch (e) { result = { exceptionDetails: { text: e.message } }; }
      if (generation !== this.eagerGeneration) return;
      this.eagerResult = result;
      // An error while typing is expected (half an expression); Chrome shows nothing.
      if (!result || result.exceptionDetails || !result.result) { show(null); return; }
      const value = result.result;
      // A literal previews as itself; nothing to add.
      if (value.type === "undefined" || (value.type !== "object" && value.type !== "function" && String(value.description) === text)) { show(null); return; }
      show(h("span", { class: "console-eager-value" }, ObjectTree.render(value, { quoteStrings: true, expandable: false })));
    },
  });
})();
