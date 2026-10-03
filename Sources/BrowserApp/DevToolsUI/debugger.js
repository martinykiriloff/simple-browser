// Keel DevTools — JavaScript debugger: breakpoints, stepping, call
// stack, scopes and watches, in the Sources panel's sidebar.
//
// Backed by WebKit's real JavaScriptCore debugger over the inspector
// protocol ("Protocol.send" / "Protocol.event"). When the protocol is not
// available the sidebar says so and the rest of DevTools is unaffected.
"use strict";

const SBDebugger = window.SBDebugger = {
  available: false,
  paused: false,
  frames: [],
  selectedFrame: 0,
  scripts: new Map(),          // scriptId → { url, startLine, endLine }
  breakpoints: [],             // { url, line, enabled, id, resolved }
  active: true,
  exceptions: "none",
  watches: [],
  refreshingScripts: null,

  SCRIPT_PREFIX: "debugger:///script/",
  SCOPE_TITLES: { local: "Local", closure: "Closure", global: "Global", globalLexicalEnvironment: "Script",
                  nestedLexical: "Block", catch: "Catch", with: "With", functionName: "Function" },

  send(method, params) { return DevTools.rpc("Protocol.send", { method, params: params || {} }); },

  // ---- setup ------------------------------------------------------------------
  init() {
    try { this.breakpoints = JSON.parse(DevTools.info.breakpoints || "[]").map((b) => ({ url: b.url, line: b.line, enabled: b.enabled !== false, condition: b.condition || "", logMessage: b.logMessage || "", id: null, resolved: false })); }
    catch (_) { this.breakpoints = []; }
    DevTools.rpc("Settings.get", { key: "watches" }).then((saved) => {
      try { this.watches = JSON.parse(saved || "[]"); } catch (_) { this.watches = []; }
      this.renderWatches();
    }).catch(() => {});

    $("#dbg-resume").addEventListener("click", () => this.resumeOrPause());
    $("#dbg-step-over").addEventListener("click", () => this.step("stepOver"));
    $("#dbg-step-into").addEventListener("click", () => this.step("stepInto"));
    $("#dbg-step-out").addEventListener("click", () => this.step("stepOut"));
    $("#dbg-deactivate").addEventListener("click", () => this.setActive(!this.active));
    $("#dbg-exceptions").addEventListener("click", () => this.cycleExceptions());
    $("#dbg-watch-add").addEventListener("click", (e) => { e.stopPropagation(); this.addWatch(); });
    for (const head of $$("#debugger-sections .dbg-head")) {
      head.addEventListener("click", (e) => { if (!e.target.closest("button")) head.parentElement.classList.toggle("collapsed"); });
    }
    $("#sources-code").addEventListener("click", (e) => {
      const gutter = e.target.closest(".ln");
      if (gutter) this.onGutterClick(+gutter.parentElement.dataset.line);
    });
    $("#sources-code").addEventListener("contextmenu", (e) => {
      const gutter = e.target.closest(".ln");
      if (!gutter) return;
      e.preventDefault();
      this.onGutterMenu(+gutter.parentElement.dataset.line, e.clientX, e.clientY);
    });

    document.addEventListener("keydown", (e) => {
      const meta = e.metaKey || e.ctrlKey;
      let action = null;
      if (e.key === "F8" || (meta && e.key === "\\")) action = () => this.resumeOrPause();
      else if (e.key === "F10" || (meta && e.key === "'")) action = () => this.step("stepOver");
      else if (e.key === "F11" && e.shiftKey || (meta && e.shiftKey && e.key === ":")) action = () => this.step("stepOut");
      else if (e.key === "F11" || (meta && e.key === ";")) action = () => this.step("stepInto");
      if (action && this.available) { e.preventDefault(); action(); }
    });

    DevTools.on("Protocol.attached", ({ scripts }) => this.onAttached(scripts || []));
    DevTools.on("Protocol.unavailable", ({ reason }) => this.onUnavailable(reason));
    DevTools.on("Protocol.shown", () => { if (this.available) this.send("Debugger.setBreakpointsActive", { active: this.active }).catch(() => {}); });
    DevTools.on("Protocol.event", ({ method, params }) => this.onEvent(method, params || {}));
    DevTools.on("Page.navigated", (p) => { if (p.phase === "committed" && this.available) this.applyBreakpoints(); });

    SBSourceMaps.onLoad((generatedURL, map) => this.onSourceMapLoaded(generatedURL, map));

    this.renderBreakpoints();
    this.updateControls();
    if (DevTools.info.protocolState === "attached") {
      DevTools.rpc("Protocol.scripts").then((scripts) => this.onAttached(scripts || [])).catch(() => {});
      DevTools.rpc("Protocol.state").then((s) => { if (s && s.paused) this.send("Debugger.resume").catch(() => {}); }).catch(() => {});
    } else {
      $("#debugger-note").textContent = "Connecting the debugger…";
    }
  },

  onAttached(scripts) {
    this.available = true;
    $("#debugger-sidebar").classList.remove("unavailable");
    $("#debugger-note").textContent = "Click a line number to set a breakpoint.";
    for (const s of scripts) this.registerScript(s);
    this.applyBreakpoints();
    this.applyExtraBreakpoints();
    this.send("Debugger.setPauseOnExceptions", { state: this.exceptions }).catch(() => {});
    // Sources read from the live DOM before the debugger connected do not
    // have the engine's line numbers; drop them so they are fetched again.
    const sources = DevTools.panels.sources;
    if (sources) {
      for (const file of sources.files.values()) if (file.live) { file.content = null; file.prettyContent = null; }
      if (sources.current && sources.initialized && sources.files.get(sources.current)?.content == null) sources.open(sources.current);
    }
    this.updateControls();
  },

  onUnavailable(reason) {
    this.available = false;
    $("#debugger-sidebar").classList.add("unavailable");
    $("#debugger-note").textContent = "Debugger unavailable in this build: " + reason;
    this.updateControls();
  },

  // ---- scripts --------------------------------------------------------------------
  registerScript(s) {
    const id = String(s.scriptId);
    this.scripts.set(id, { url: s.url || s.sourceURL || "", startLine: s.startLine || 0, endLine: s.endLine || 0 });
    const url = s.url || s.sourceURL || "";
    const sources = DevTools.panels.sources;
    if (url && !url.startsWith("user-script:") && sources && !sources.files.has(url) && /^(https?|file):/.test(url)) {
      // An inline script reports its document's URL and a non-zero start line.
      const isDocument = url === DevTools.info.url || (s.startLine || 0) > 0;
      sources.files.set(url, { url, type: isDocument ? "document" : "script" });
      if (sources.initialized) sources.renderTree();
    }
    if (url && s.sourceMapURL && /^(https?|file):/.test(url)) {
      if (SBSourceMaps.maps.has(url)) this.onSourceMapLoaded(url, SBSourceMaps.maps.get(url));
      else SBSourceMaps.load(url, s.sourceMapURL);
    }
  },

  // Original files join the navigator, and breakpoints that were set in
  // them (now or in an earlier session) can finally be resolved.
  onSourceMapLoaded(generatedURL, map) {
    const sources = DevTools.panels.sources;
    if (sources) {
      for (const source of map.sources) {
        if (!sources.files.has(source.url)) sources.files.set(source.url, { url: source.url, type: "script", original: true, generatedURL });
      }
      if (sources.initialized) sources.renderTree();
    }
    const waiting = this.breakpoints.filter((bp) => bp.enabled && !bp.id && SBSourceMaps.byOriginal.get(bp.url) === generatedURL);
    if (waiting.length && this.available) {
      Promise.all(waiting.map((bp) => this.install(bp))).then(() => { this.renderBreakpoints(); this.redecorate(); });
    }
  },

  async urlForScript(scriptId) {
    const id = String(scriptId);
    if (!this.scripts.has(id)) {
      // Parsed before we were listening: ask for the frontend's table once.
      this.refreshingScripts = this.refreshingScripts || DevTools.rpc("Protocol.scripts").then((list) => { for (const s of list || []) this.registerScript(s); }).catch(() => {}).finally(() => { this.refreshingScripts = null; });
      await this.refreshingScripts;
    }
    return (this.scripts.get(id) || {}).url || "";
  },

  // ---- protocol events ------------------------------------------------------------------
  onEvent(method, params) {
    switch (method) {
      case "Debugger.scriptParsed": this.registerScript(params); break;
      case "Debugger.paused": this.onPaused(params); break;
      case "Debugger.resumed": this.onResumed(); break;
      case "Debugger.globalObjectCleared": this.scripts.clear(); this.onResumed(); break;
      case "Debugger.breakpointResolved": {
        const bp = this.breakpoints.find((b) => b.id === params.breakpointId);
        if (bp && !bp.resolved) { bp.resolved = true; this.renderBreakpoints(); this.redecorate(); }
        break;
      }
    }
  },

  async onPaused(params) {
    this.paused = true;
    const frames = [];
    for (const f of params.callFrames || []) {
      const url = await this.urlForScript(f.location.scriptId);
      const frame = {
        callFrameId: f.callFrameId, functionName: f.functionName || "(anonymous)",
        scriptId: String(f.location.scriptId), url,
        native: !this.scripts.has(String(f.location.scriptId)),   // setAttribute, fetch…: no script, no source
        line: f.location.lineNumber + 1, column: (f.location.columnNumber || 0) + 1,
        scopeChain: f.scopeChain || [], thisObject: f.this,
      };
      // Show where the developer wrote it, not where the bundler put it.
      if (url) {
        await SBSourceMaps.ready(url);
        const original = SBSourceMaps.original(url, frame.line, frame.column);
        if (original) {
          frame.generated = { url, line: frame.line, column: frame.column };
          frame.url = original.url; frame.line = original.line; frame.column = original.column;
        }
      }
      frames.push(frame);
    }
    if (!this.paused) return;      // resumed while we were resolving scripts
    this.frames = this.withoutAgentFrames(frames);
    document.body.classList.add("debugger-paused");

    // A pause that began in blackboxed code (our own hooks) is reported as
    // such by WebKit, with the real cause inside.
    if (params.reason === "BlackboxedScript" && params.data && params.data.originalReason) {
      params = Object.assign({}, params, { reason: params.data.originalReason, data: params.data.originalData || {} });
    }
    const reasons = { Breakpoint: "Paused on breakpoint", DebuggerStatement: "Paused on debugger statement",
                      exception: "Paused on exception", PauseOnNextStatement: "Paused", assert: "Paused on assertion",
                      CSPViolation: "Paused on CSP violation", Microtask: "Paused on microtask", Timer: "Paused on timer",
                      Listener: "Paused on event listener", Fetch: "Paused on fetch", Interval: "Paused on interval",
                      AnimationFrame: "Paused on animation frame", BlackboxedScript: "Paused" };
    const banner = $("#dbg-banner");
    banner.textContent = reasons[params.reason] || "Paused";
    if (params.reason === "exception" && params.data) {
      const d = this.normalize(params.data);
      banner.appendChild(h("span", { class: "detail" }, d.description));
    }
    // DOM, XHR/fetch and event listener breakpoints (breakpoints.js).
    const extra = this.describePause(params);
    if (extra) {
      banner.textContent = extra.title;
      if (extra.detail) banner.appendChild(h("span", { class: "detail" }, extra.detail));
    }
    banner.hidden = false;

    this.updateControls();
    this.renderStack();
    DevTools.showPanel("sources");
    this.selectFrame(0);
    this.evaluateWatches();
  },

  // A pause raised from native code (a DOM or XHR/fetch breakpoint) has the
  // native function on top, which has no source to show. And fetch, XHR and
  // console are wrapped by our page-world hooks, so our frames can sit above
  // the developer's too. Their stack starts at their call.
  withoutAgentFrames(frames) {
    const ours = (f) => f.native || (f.url || "").startsWith("user-script:");
    const firstPage = frames.findIndex((f) => f.url && !ours(f));
    if (firstPage > 0 && frames.slice(0, firstPage).some(ours)) frames = frames.slice(firstPage);
    const kept = frames.filter((f) => !ours(f));
    return kept.length ? kept : frames;
  },

  onResumed() {
    if (!this.paused && !this.frames.length) return;
    this.paused = false;
    this.frames = [];
    this.selectedFrame = 0;
    document.body.classList.remove("debugger-paused");
    $("#dbg-banner").hidden = true;
    this.clearHit();
    $("#dbg-stack").textContent = ""; $("#dbg-stack").appendChild(h("div", { class: "dbg-empty" }, "Not paused"));
    $("#dbg-scope").textContent = ""; $("#dbg-scope").appendChild(h("div", { class: "dbg-empty" }, "Not paused"));
    this.updateControls();
    this.redecorate();
    this.evaluateWatches();
  },

  currentCallFrameId() {
    return this.paused && this.frames[this.selectedFrame] ? this.frames[this.selectedFrame].callFrameId : undefined;
  },

  // ---- controls ---------------------------------------------------------------------------
  updateControls() {
    const resume = $("#dbg-resume");
    resume.classList.toggle("paused", this.paused);
    resume.title = this.paused ? "Resume script execution (F8, ⌘\\)" : "Pause script execution (F8, ⌘\\)";
    for (const id of ["dbg-step-over", "dbg-step-into", "dbg-step-out"]) $("#" + id).disabled = !this.paused;
    $("#dbg-deactivate").classList.toggle("active", !this.active);
    $("#dbg-deactivate").title = this.active ? "Deactivate breakpoints" : "Activate breakpoints";
    const ex = $("#dbg-exceptions");
    ex.classList.toggle("uncaught", this.exceptions === "uncaught");
    ex.classList.toggle("all", this.exceptions === "all");
    ex.title = { none: "Don't pause on exceptions", uncaught: "Pause on uncaught exceptions", all: "Pause on all exceptions" }[this.exceptions];
  },

  resumeOrPause() {
    if (!this.available) return;
    if (this.paused) this.send("Debugger.resume").catch((e) => this.report(e));
    else {
      this.send("Debugger.pause").catch((e) => this.report(e));
      const banner = $("#dbg-banner"); banner.textContent = "Pausing on the next statement…"; banner.hidden = false;
      setTimeout(() => { if (!this.paused) banner.hidden = true; }, 4000);
    }
  },

  step(kind) {
    if (!this.available || !this.paused) return;
    this.send("Debugger." + kind).catch((e) => this.report(e));
  },

  setActive(active) {
    this.active = active;
    this.updateControls();
    if (this.available) this.send("Debugger.setBreakpointsActive", { active }).catch((e) => this.report(e));
  },

  cycleExceptions() {
    this.exceptions = { none: "uncaught", uncaught: "all", all: "none" }[this.exceptions];
    this.updateControls();
    if (this.available) this.send("Debugger.setPauseOnExceptions", { state: this.exceptions }).catch((e) => this.report(e));
  },

  report(error) {
    if (DevTools.panels.console) DevTools.panels.console.addLocal("warn", "Debugger: " + (error.message || error));
  },

  // ---- breakpoints -----------------------------------------------------------------------------
  save() {
    const plain = this.breakpoints.map((b) => ({ url: b.url, line: b.line, enabled: b.enabled, condition: b.condition || "", logMessage: b.logMessage || "" }));
    DevTools.rpc("Settings.set", { key: "breakpoints", value: JSON.stringify(plain) }).catch(() => {});
  },

  async applyBreakpoints() {
    for (const bp of this.breakpoints) { bp.id = null; bp.resolved = false; }
    for (const bp of this.breakpoints) if (bp.enabled) await this.install(bp);
    this.renderBreakpoints();
    this.redecorate();
  },

  async install(bp) {
    try {
      let params = { url: bp.url, lineNumber: bp.line - 1, columnNumber: 0 };
      if (SBSourceMaps.isOriginal(bp.url)) {
        // The engine only knows the bundle: translate the original line.
        const generated = SBSourceMaps.generated(bp.url, bp.line);
        if (!generated) { bp.id = null; bp.resolved = false; return; }
        params = { url: generated.url, lineNumber: generated.line - 1, columnNumber: generated.column - 1 };
      }
      bp.target = params;
      const options = this.breakpointOptions(bp);
      if (options) params.options = options;
      const result = await this.send("Debugger.setBreakpointByUrl", params);
      bp.id = result.breakpointId;
      bp.resolved = (result.locations || []).length > 0;
    } catch (e) {
      // "Breakpoint at specified location already exists": the backend kept
      // it across a reload, under the id it derives from url:line:column.
      if (/already exists/i.test(e.message || "") && bp.target) { bp.id = bp.target.url + ":" + bp.target.lineNumber + ":" + bp.target.columnNumber; bp.resolved = true; }
      else { bp.id = null; this.report(e); }
    }
  },

  // A condition pauses only when it is truthy. A logpoint never pauses: it
  // runs `console.log(<what you typed>)` in the frame and carries on, so the
  // output flows through the normal console pipeline.
  breakpointOptions(bp) {
    if (bp.logMessage) {
      const options = { autoContinue: true, actions: [{ type: "evaluate", data: "console.log(" + bp.logMessage + ")" }] };
      if (bp.condition) options.condition = bp.condition;
      return options;
    }
    return bp.condition ? { condition: bp.condition } : null;
  },

  async uninstall(bp) {
    if (!bp.id) return;
    try { await this.send("Debugger.removeBreakpoint", { breakpointId: bp.id }); } catch (_) {}
    bp.id = null; bp.resolved = false;
  },

  onGutterClick(line) {
    const file = this.guardFile();
    if (file) this.toggle(file.url, line);
  },

  guardFile() {
    const sources = DevTools.panels.sources;
    const file = sources && sources.files.get(sources.current);
    if (!file) return null;
    if (!this.available) { this.report({ message: $("#debugger-note").textContent }); return null; }
    if (file.pretty) { $("#debugger-note").textContent = "Turn off pretty print to set breakpoints (line numbers differ)."; return null; }
    if (file.url.startsWith(this.SCRIPT_PREFIX)) { $("#debugger-note").textContent = "Breakpoints need a script with a URL."; return null; }
    return file;
  },

  onGutterMenu(line, x, y) {
    const file = this.guardFile();
    if (!file) return;
    const existing = this.breakpoints.find((b) => b.url === file.url && b.line === line);
    const items = [];
    if (!existing) {
      items.push({ label: "Add breakpoint", action: () => this.toggle(file.url, line) });
      items.push({ label: "Add conditional breakpoint\u2026", action: () => this.edit(file.url, line, "condition") });
      items.push({ label: "Add logpoint\u2026", action: () => this.edit(file.url, line, "logMessage") });
    } else {
      items.push({ label: "Remove breakpoint", action: () => this.toggle(file.url, line) });
      items.push({ label: existing.logMessage ? "Edit logpoint\u2026" : "Edit condition\u2026", action: () => this.edit(file.url, line, existing.logMessage ? "logMessage" : "condition") });
      items.push({ label: existing.enabled ? "Disable breakpoint" : "Enable breakpoint", action: () => this.setEnabled(existing, !existing.enabled) });
    }
    if (!existing || existing.condition !== "false") items.push({ label: "Never pause here", action: () => this.neverPauseHere(file.url, line) });
    if (this.paused) items.push("-", { label: "Continue to here", action: () => this.continueToHere(file.url, line) });   // debugger-tools.js
    ContextMenu.show(x, y, items);
    return items;
  },

  // Chrome-style inline editor under the line.
  edit(url, line, field) {
    const code = $("#sources-code");
    const lineEl = code.querySelector(`.code-line[data-line="${line}"]`);
    if (!lineEl) return;
    for (const old of $$(".bp-editor", code)) old.remove();
    const existing = this.breakpoints.find((b) => b.url === url && b.line === line);
    const isLog = field === "logMessage";
    const input = h("input", { type: "text", spellcheck: "false",
      placeholder: isLog ? "Log message, e.g.  'x is', x" : "Expression to check before pausing, e.g.  x > 5" });
    input.value = existing ? (existing[field] || "") : "";
    const editor = h("div", { class: "bp-editor " + (isLog ? "log" : "cond") },
      h("span", { class: "bp-editor-label" }, isLog ? `Line ${line}: Logpoint` : `Line ${line}: Conditional breakpoint`), input);
    lineEl.after(editor);
    input.focus();
    let done = false;
    const finish = (commit) => {
      if (done) return; done = true;
      editor.remove();
      if (commit) this.setBreakpoint(url, line, { [field]: input.value.trim() });
    };
    input.addEventListener("keydown", (e) => {
      e.stopPropagation();
      if (e.key === "Enter") { e.preventDefault(); finish(true); }
      if (e.key === "Escape") { e.preventDefault(); finish(false); }
    });
    input.addEventListener("blur", () => finish(true));
  },

  // Creates or updates the breakpoint at url:line with a condition or log message.
  async setBreakpoint(url, line, fields) {
    let bp = this.breakpoints.find((b) => b.url === url && b.line === line);
    if (bp) await this.uninstall(bp);
    else {
      bp = { url, line, enabled: true, condition: "", logMessage: "", id: null, resolved: false };
      this.breakpoints.push(bp);
      this.breakpoints.sort((a, b) => a.url.localeCompare(b.url) || a.line - b.line);
    }
    if ("condition" in fields) { bp.condition = fields.condition; if (fields.condition) bp.logMessage = ""; }
    if ("logMessage" in fields) { bp.logMessage = fields.logMessage; }
    if (bp.enabled) await this.install(bp);
    this.save();
    this.renderBreakpoints();
    this.redecorate();
    return bp;
  },

  async toggle(url, line) {
    const existing = this.breakpoints.find((b) => b.url === url && b.line === line);
    if (existing) {
      await this.uninstall(existing);
      this.breakpoints = this.breakpoints.filter((b) => b !== existing);
    } else {
      const bp = { url, line, enabled: true, condition: "", logMessage: "", id: null, resolved: false };
      this.breakpoints.push(bp);
      this.breakpoints.sort((a, b) => a.url.localeCompare(b.url) || a.line - b.line);
      await this.install(bp);
    }
    this.save();
    this.renderBreakpoints();
    this.redecorate();
  },

  async setEnabled(bp, enabled) {
    bp.enabled = enabled;
    if (enabled) await this.install(bp); else await this.uninstall(bp);
    this.save();
    this.renderBreakpoints();
    this.redecorate();
  },

  renderBreakpoints() {
    const list = $("#dbg-breakpoints");
    list.textContent = "";
    if (!this.breakpoints.length) { list.appendChild(h("div", { class: "dbg-empty" }, "No breakpoints")); return; }
    const sources = DevTools.panels.sources;
    for (const bp of this.breakpoints) {
      const box = h("input", { type: "checkbox" });
      box.checked = bp.enabled;
      box.addEventListener("change", () => this.setEnabled(bp, box.checked));
      const file = sources && sources.files.get(bp.url);
      const lines = file && file.content && !file.pretty ? file.content.split("\n") : null;
      const snippet = lines && lines[bp.line - 1] ? lines[bp.line - 1].trim().slice(0, 80) : "";
      list.appendChild(h("div", { class: "dbg-bp", title: bp.url + ":" + bp.line },
        box,
        h("div", { style: "min-width:0;flex:1" },
          h("div", { class: "where", onclick: () => DevTools.openSource(bp.url, bp.line, 0) }, fileName(bp.url) + ":" + bp.line),
          bp.logMessage ? h("div", { class: "snippet bp-log" }, "log: " + bp.logMessage) : null,
          bp.condition === "false" ? h("div", { class: "snippet bp-never" }, "Never pause here")
            : bp.condition ? h("div", { class: "snippet bp-cond" }, "if: " + bp.condition) : null,
          snippet ? h("div", { class: "snippet" }, snippet) : null),
        h("span", { class: "remove", title: "Remove breakpoint", onclick: () => this.toggle(bp.url, bp.line) }, "✕")));
    }
  },

  // Marks breakpoints and the execution line in whatever file is showing.
  decorate(file) {
    const code = $("#sources-code");
    for (const el of $$(".code-line.breakpoint, .code-line.exec", code)) el.classList.remove("breakpoint", "disabled", "unresolved", "conditional", "logpoint", "never", "exec");
    if (!file || file.pretty) return;
    for (const bp of this.breakpoints) {
      if (bp.url !== file.url) continue;
      const el = code.querySelector(`.code-line[data-line="${bp.line}"]`);
      if (!el) continue;
      el.classList.add("breakpoint");
      if (bp.logMessage) el.classList.add("logpoint"); else if (bp.condition === "false") el.classList.add("never"); else if (bp.condition) el.classList.add("conditional");
      if (!bp.enabled) el.classList.add("disabled");
      else if (this.available && !bp.resolved) el.classList.add("unresolved");
    }
    const frame = this.paused && this.frames[this.selectedFrame];
    if (frame && this.fileURL(frame) === file.url) {
      code.querySelector(`.code-line[data-line="${frame.line}"]`)?.classList.add("exec");
    }
  },

  redecorate() {
    const sources = DevTools.panels.sources;
    if (sources && sources.initialized) this.decorate(sources.files.get(sources.current));
  },

  // ---- call stack & scopes ------------------------------------------------------------------------
  fileURL(frame) { return frame.url || this.SCRIPT_PREFIX + frame.scriptId; },

  renderStack() {
    const list = $("#dbg-stack");
    list.textContent = "";
    let hidden = 0;
    this.frames.forEach((frame, index) => {
      // Frames in ignore-listed scripts (debugger-tools.js) fold away, as in Chrome.
      const ignored = this.isIgnored && this.isIgnored(frame);
      if (ignored && !this.showIgnoredFrames && index !== this.selectedFrame) { hidden++; return; }
      const row = h("div", { class: "dbg-frame" + (index === this.selectedFrame ? " selected" : "") + (ignored ? " ignored" : ""), tabindex: "0", role: "button",
          onclick: () => this.selectFrame(index), title: this.fileURL(frame) + ":" + frame.line },
        h("span", { class: "fn" }, frame.functionName),
        h("span", { class: "loc" }, (frame.url ? fileName(frame.url) : "(program)") + ":" + frame.line));
      row.addEventListener("keydown", (e) => { if (e.key === "Enter") this.selectFrame(index); });
      row.__frame = frame;
      list.appendChild(row);
    });
    if (hidden) {
      list.appendChild(h("div", { class: "dbg-empty link", role: "button", tabindex: "0", onclick: () => { this.showIgnoredFrames = true; this.renderStack(); } },
        `Show ${hidden} ignore-listed frame${hidden === 1 ? "" : "s"}`));
    }
    if (!this.frames.length) list.appendChild(h("div", { class: "dbg-empty" }, "Not paused"));
  },

  async selectFrame(index) {
    const frame = this.frames[index];
    if (!frame) return;
    this.selectedFrame = index;
    this.renderStack();
    this.renderScope(frame);
    const sources = DevTools.panels.sources;
    if (frame.url) await sources.open(frame.url, frame.line, frame.column);
    else await sources.openScript(frame.scriptId, frame.line, frame.column);
    this.redecorate();
    this.evaluateWatches();
  },

  renderScope(frame) {
    const container = $("#dbg-scope");
    container.textContent = "";
    let expanded = 0;
    frame.scopeChain.forEach((scope, index) => {
      if (scope.empty || !scope.object || !scope.object.objectId) return;
      let title = this.SCOPE_TITLES[scope.type] || scope.type;
      if (scope.name) title += " (" + scope.name + ")";
      const node = ObjectTree.expandableNode({ objectId: scope.object.objectId }, h("span", { class: "dbg-scope-title" }, title));
      const row = h("div", { class: "dbg-scope" }, node);
      container.appendChild(row);
      if (index === 0 && frame.thisObject) {
        node.querySelector(".obj-children").before(h("div", { class: "obj-row", style: "padding-left:14px" }, h("span", { class: "obj-key" }, "this"), ": ", ObjectTree.render(this.normalize(frame.thisObject))));
      }
      if (scope.type !== "global" && expanded < 2) { expanded++; node.querySelector(".obj-toggle").click(); }
    });
    if (!container.childElementCount) container.appendChild(h("div", { class: "dbg-empty" }, "No variables"));
  },

  // WebKit's RemoteObject → what ObjectTree renders.
  normalize(o) {
    if (!o) return { type: "undefined", description: "undefined" };
    const out = { type: o.type, subtype: o.subtype, className: o.className, objectId: o.objectId };
    let description = o.description;
    if (description == null && "value" in o) description = o.value === null ? "null" : String(o.value);
    if (o.preview) {
      if (o.subtype === "array" && o.preview.size != null) description = "Array(" + o.preview.size + ")";
      out.preview = { overflow: !!o.preview.overflow,
                      properties: (o.preview.properties || []).map((p) => ({ name: p.name, type: p.type, subtype: p.subtype, value: p.type === "string" ? JSON.stringify(p.value) : p.value != null ? p.value : this.nestedPreview(p) })) };
    }
    if (o.subtype === "null") description = "null";
    out.description = description == null ? (o.type === "undefined" ? "undefined" : "") : description;
    return out;
  },

  // WebKit gives a nested object in a preview only as its own preview: `{…}`, `Array(2)`, `Map(1)`.
  nestedPreview(p) {
    const d = (p.valuePreview && p.valuePreview.description) || "";
    if (p.subtype === "array" && p.valuePreview && p.valuePreview.size != null) return "Array(" + p.valuePreview.size + ")";
    if (p.type === "function") return "ƒ";
    if (p.type === "object" && (!d || d === "Object")) return "{…}";
    return d;
  },

  // ---- watches ---------------------------------------------------------------------------------------
  addWatch() {
    const row = h("div", { class: "dbg-watch-row" });
    const input = h("span", { class: "expr" });
    row.appendChild(input);
    $("#dbg-watch").appendChild(row);
    $("#dbg-section-watch").classList.remove("collapsed");
    inlineEdit(input, {
      initial: "",
      onCommit: (text) => {
        const expr = text.trim();
        if (expr) { this.watches.push(expr); DevTools.rpc("Settings.set", { key: "watches", value: JSON.stringify(this.watches) }).catch(() => {}); }
        this.renderWatches();
      },
      onCancel: () => this.renderWatches(),
    });
  },

  renderWatches() {
    const list = $("#dbg-watch");
    list.textContent = "";
    if (!this.watches.length) { list.appendChild(h("div", { class: "dbg-empty" }, "No watch expressions")); return; }
    this.watches.forEach((expr, index) => {
      const value = h("span", { class: "value muted" }, "…");
      list.appendChild(h("div", { class: "dbg-watch-row", dataset: { index: String(index) } },
        h("span", { class: "expr" }, expr), ": ", value,
        h("span", { class: "remove", onclick: () => { this.watches.splice(index, 1); DevTools.rpc("Settings.set", { key: "watches", value: JSON.stringify(this.watches) }).catch(() => {}); this.renderWatches(); } }, "✕")));
    });
    this.evaluateWatches();
  },

  async evaluateWatches() {
    if (!this.available || !this.watches.length) return;
    const rows = $$("#dbg-watch .dbg-watch-row");
    for (const row of rows) {
      const expr = this.watches[+row.dataset.index];
      const slot = row.querySelector(".value");
      if (!expr || !slot) continue;
      try {
        const frameId = this.currentCallFrameId();
        const result = frameId
          ? await this.send("Debugger.evaluateOnCallFrame", { callFrameId: frameId, expression: expr, objectGroup: "watch", generatePreview: true })
          : await this.send("Runtime.evaluate", { expression: expr, objectGroup: "watch", generatePreview: true });
        const rendered = result.wasThrown
          ? h("span", { class: "v-error" }, "<" + (this.normalize(result.result).description.split("\n")[0] || "error") + ">")
          : ObjectTree.render(this.normalize(result.result));
        const fresh = h("span", { class: "value" }, rendered);
        slot.replaceWith(fresh);
      } catch (e) {
        slot.textContent = "<unavailable>";
      }
    }
  },
};
