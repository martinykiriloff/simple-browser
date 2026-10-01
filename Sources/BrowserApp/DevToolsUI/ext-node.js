// SimpleBrowser DevTools — Node: debug a Node.js process started with
// `node --inspect` (or --inspect-brk), the way chrome://inspect does. Finds
// targets on the inspector ports, then speaks the Chrome DevTools Protocol
// to it over a WebSocket: console and REPL, scripts, breakpoints, pause and
// step, call stack and scope.
"use strict";

(function () {
  class CDP {
    constructor(url, onEvent, onClose) {
      this.ws = new WebSocket(url);
      this.next = 1;
      this.pending = new Map();
      this.ws.onmessage = (m) => {
        const msg = JSON.parse(m.data);
        if (msg.id && this.pending.has(msg.id)) {
          const { resolve, reject } = this.pending.get(msg.id);
          this.pending.delete(msg.id);
          msg.error ? reject(new Error(msg.error.message)) : resolve(msg.result);
        } else if (msg.method) onEvent(msg.method, msg.params || {});
      };
      this.ws.onclose = () => { for (const p of this.pending.values()) p.reject(new Error("disconnected")); this.pending.clear(); onClose(); };
      this.opened = new Promise((resolve, reject) => { this.ws.onopen = resolve; this.ws.onerror = () => reject(new Error("Could not connect to " + url)); });
    }
    send(method, params = {}) {
      const id = this.next++;
      this.ws.send(JSON.stringify({ id, method, params }));
      return new Promise((resolve, reject) => this.pending.set(id, { resolve, reject }));
    }
    close() { try { this.ws.close(); } catch (_) {} }
  }

  const describe = (o) => {
    if (!o) return "undefined";
    if (o.type === "string") return o.value;
    if ("unserializableValue" in o) return o.unserializableValue;
    if ("value" in o) return o.value === null ? "null" : typeof o.value === "object" ? JSON.stringify(o.value) : String(o.value);
    if (o.preview && o.preview.properties) {
      const inner = o.preview.properties.map((p) => (o.subtype === "array" ? "" : p.name + ": ") + (p.type === "string" ? JSON.stringify(p.value) : p.value)).join(", ");
      return (o.subtype === "array" ? `${o.description} [${inner}${o.preview.overflow ? ", …" : ""}]` : `${o.className && o.className !== "Object" ? o.className + " " : ""}{${inner}${o.preview.overflow ? ", …" : ""}}`);
    }
    return o.description || o.type;
  };

  const panel = {
    initialized: false,
    targets: [],
    cdp: null,
    target: null,
    scripts: new Map(),
    breakpoints: [],
    paused: null,
    frame: 0,
    source: null,
    history: [],

    init() {
      const ports = $("#node-ports");
      try { ports.value = localStorage.getItem("devtools.nodePorts") || "9229, 9230"; } catch (_) { ports.value = "9229, 9230"; }
      ports.addEventListener("change", () => { try { localStorage.setItem("devtools.nodePorts", ports.value); } catch (_) {} this.discover(); });
      $("#node-discover").addEventListener("click", () => this.discover());
      $("#node-disconnect").addEventListener("click", () => this.disconnect());
      $("#node-pause").addEventListener("click", () => this.cdp && (this.paused ? this.cdp.send("Debugger.resume") : this.cdp.send("Debugger.pause")));
      $("#node-over").addEventListener("click", () => this.paused && this.cdp.send("Debugger.stepOver"));
      $("#node-into").addEventListener("click", () => this.paused && this.cdp.send("Debugger.stepInto"));
      $("#node-out").addEventListener("click", () => this.paused && this.cdp.send("Debugger.stepOut"));
      $("#node-script-filter").addEventListener("input", () => this.renderScripts());
      const input = $("#node-input");
      input.addEventListener("keydown", (e) => {
        if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); const text = input.value.trim(); if (text) { input.value = ""; this.evaluate(text); } }
        if (e.key === "ArrowUp" && !input.value.includes("\n") && this.history.length) { e.preventDefault(); input.value = this.history[this.history.length - 1]; }
      });
    },

    show() { if (!this.cdp) this.discover(); },

    async discover() {
      const ports = $("#node-ports").value.split(/[\s,]+/).map(Number).filter((n) => n > 0 && n < 65536);
      $("#node-status").textContent = "Looking for Node processes…";
      try { this.targets = await DevTools.rpc("Node.targets", { ports }); } catch (e) { this.targets = []; }
      $("#node-status").textContent = this.cdp ? "" : `${this.targets.length} target${this.targets.length === 1 ? "" : "s"} on port${ports.length === 1 ? "" : "s"} ${ports.join(", ")}`;
      this.renderTargets();
    },

    renderTargets() {
      const box = $("#node-targets");
      box.textContent = "";
      if (!this.targets.length) {
        box.appendChild(SBExt.empty("No Node.js process is listening for a debugger.",
          "Start one with  node --inspect app.js  (or --inspect-brk to stop on the first line), or  NODE_OPTIONS=--inspect npm run dev,  then Refresh.",
          "Ports are those passed to --inspect; 9229 is the default."));
        return;
      }
      for (const t of this.targets) {
        const connect = h("button", { class: "text-button primary" }, this.target && this.target.id === t.id ? "Connected" : "Inspect");
        connect.disabled = !!(this.target && this.target.id === t.id);
        connect.addEventListener("click", () => this.connect(t));
        box.appendChild(h("div", { class: "node-target" },
          h("div", {}, h("div", { class: "node-title" }, t.title || t.url), h("div", { class: "muted mono" }, `${t.url || ""} · port ${t.port}${t.version ? " · " + t.version : ""}`)),
          connect));
      }
    },

    async connect(target) {
      this.disconnect();
      this.target = target;
      this.scripts.clear();
      $("#node-console").textContent = "";
      const cdp = new CDP(target.webSocketDebuggerUrl, (method, params) => this.onEvent(method, params), () => {
        if (this.cdp === cdp) { this.cdp = null; this.target = null; this.paused = null; this.log("info", "Disconnected."); this.updateControls(); this.renderTargets(); }
      });
      this.cdp = cdp;
      try {
        await cdp.opened;
        await cdp.send("Runtime.enable");
        await cdp.send("Debugger.enable");
        await cdp.send("Debugger.setPauseOnExceptions", { state: $("#node-pause-exceptions").checked ? "uncaught" : "none" });
        for (const bp of this.breakpoints) await this.placeBreakpoint(bp).catch(() => {});
        await cdp.send("Runtime.runIfWaitingForDebugger");
        this.log("info", `Connected to ${target.title || target.url}`);
      } catch (e) {
        this.log("error", e.message);
        this.cdp = null; this.target = null;
      }
      $("#node-pause-exceptions").onchange = () => this.cdp && this.cdp.send("Debugger.setPauseOnExceptions", { state: $("#node-pause-exceptions").checked ? "uncaught" : "none" });
      this.updateControls();
      this.renderTargets();
    },

    disconnect() {
      if (this.cdp) { const c = this.cdp; this.cdp = null; c.close(); }
      this.target = null; this.paused = null;
      this.updateControls();
    },

    onEvent(method, params) {
      switch (method) {
        case "Runtime.consoleAPICalled": {
          const level = { error: "error", warning: "warn", warn: "warn", debug: "debug", info: "info" }[params.type] || "log";
          this.log(level, params.args.map(describe).join(" "), params.stackTrace);
          break;
        }
        case "Runtime.exceptionThrown": {
          const d = params.exceptionDetails;
          this.log("error", "Uncaught " + (d.exception ? (d.exception.description || describe(d.exception)) : d.text), d.stackTrace);
          break;
        }
        case "Debugger.scriptParsed":
          if (params.url && !params.url.startsWith("node:") && !params.url.includes("/node_modules/")) this.scripts.set(params.scriptId, params);
          else if (params.url) this.scripts.set(params.scriptId, Object.assign(params, { library: true }));
          if (this.scriptTimer == null) this.scriptTimer = setTimeout(() => { this.scriptTimer = null; this.renderScripts(); }, 200);
          break;
        case "Debugger.paused":
          this.paused = params; this.frame = 0;
          this.updateControls();
          this.showFrame(0);
          break;
        case "Debugger.resumed":
          this.paused = null;
          this.updateControls();
          $("#node-stack").textContent = ""; $("#node-scope").textContent = "";
          if (this.source) this.renderSource();
          break;
      }
    },

    log(level, text, stack) {
      const box = $("#node-console");
      const line = h("div", { class: "node-log node-" + level }, h("span", { class: "selectable" }, text));
      if (stack && stack.callFrames && stack.callFrames.length && (level === "error" || level === "warn")) {
        const frames = h("div", { class: "node-frames" });
        for (const f of stack.callFrames.slice(0, 6)) {
          const link = h("a", { href: "#", class: "link mono" }, `${f.functionName || "(anonymous)"} @ ${f.url.split("/").pop()}:${f.lineNumber + 1}`);
          link.addEventListener("click", (e) => { e.preventDefault(); this.openScript(f.scriptId, f.lineNumber); });
          frames.appendChild(h("div", {}, link));
        }
        line.appendChild(frames);
      }
      box.appendChild(line);
      box.scrollTop = box.scrollHeight;
    },

    async evaluate(expression) {
      this.history.push(expression);
      this.log("command", "› " + expression);
      if (!this.cdp) { this.log("error", "Not connected to a Node process."); return; }
      try {
        const result = this.paused
          ? await this.cdp.send("Debugger.evaluateOnCallFrame", { callFrameId: this.paused.callFrames[this.frame].callFrameId, expression, generatePreview: true, includeCommandLineAPI: true })
          : await this.cdp.send("Runtime.evaluate", { expression, includeCommandLineAPI: true, replMode: true, awaitPromise: true, generatePreview: true });
        if (result.exceptionDetails) this.log("error", result.exceptionDetails.exception ? result.exceptionDetails.exception.description : result.exceptionDetails.text);
        else this.log("result", describe(result.result));
      } catch (e) { this.log("error", e.message); }
    },

    renderScripts() {
      const box = $("#node-scripts");
      if (!box) return;
      const q = $("#node-script-filter").value.toLowerCase();
      box.textContent = "";
      const scripts = Array.from(this.scripts.values()).filter((s) => !s.library && (!q || s.url.toLowerCase().includes(q))).sort((a, b) => a.url.localeCompare(b.url));
      for (const s of scripts.slice(0, 400)) {
        const name = s.url.replace(/^file:\/\//, "");
        const row = h("div", { class: "node-script mono" + (this.source && this.source.scriptId === s.scriptId ? " selected" : ""), title: name }, name.split("/").slice(-2).join("/"));
        row.addEventListener("click", () => this.openScript(s.scriptId));
        box.appendChild(row);
      }
      if (!scripts.length) box.appendChild(h("div", { class: "muted node-hint" }, this.cdp ? "No application scripts loaded yet." : "Connect to see scripts."));
    },

    async openScript(scriptId, line) {
      if (!this.cdp) return;
      const script = this.scripts.get(scriptId);
      try {
        const { scriptSource } = await this.cdp.send("Debugger.getScriptSource", { scriptId });
        this.source = { scriptId, url: script ? script.url : "", text: scriptSource, line };
        this.renderSource();
        this.renderScripts();
      } catch (e) { Toast.show(e.message); }
    },

    renderSource() {
      const box = $("#node-source");
      box.textContent = "";
      if (!this.source) return;
      const pausedFrame = this.paused && this.paused.callFrames[this.frame];
      const pausedLine = pausedFrame && pausedFrame.location.scriptId === this.source.scriptId ? pausedFrame.location.lineNumber : -1;
      const lines = this.source.text.split("\n");
      const bpLines = new Set(this.breakpoints.filter((b) => b.url === this.source.url).map((b) => b.line));
      box.appendChild(h("div", { class: "node-source-title mono" }, this.source.url.replace(/^file:\/\//, "")));
      const code = h("div", { class: "node-code mono" });
      lines.slice(0, 20000).forEach((text, i) => {
        const gutter = h("span", { class: "node-gutter" + (bpLines.has(i) ? " bp" : ""), title: "Toggle breakpoint" }, String(i + 1));
        gutter.addEventListener("click", () => this.toggleBreakpoint(this.source.url, i));
        code.appendChild(h("div", { class: "node-line" + (i === pausedLine ? " paused" : "") + (i === this.source.line ? " focus" : "") }, gutter, h("span", { class: "node-text" }, text || " ")));
      });
      box.appendChild(code);
      const target = code.children[pausedLine >= 0 ? pausedLine : this.source.line ?? 0];
      if (target) target.scrollIntoView({ block: "center" });
    },

    async toggleBreakpoint(url, line) {
      const existing = this.breakpoints.find((b) => b.url === url && b.line === line);
      if (existing) {
        this.breakpoints = this.breakpoints.filter((b) => b !== existing);
        if (this.cdp && existing.id) await this.cdp.send("Debugger.removeBreakpoint", { breakpointId: existing.id }).catch(() => {});
      } else {
        const bp = { url, line };
        this.breakpoints.push(bp);
        if (this.cdp) await this.placeBreakpoint(bp).catch((e) => Toast.show(e.message));
      }
      this.renderSource();
    },

    async placeBreakpoint(bp) {
      const result = await this.cdp.send("Debugger.setBreakpointByUrl", { url: bp.url, lineNumber: bp.line });
      bp.id = result.breakpointId;
    },

    async showFrame(index) {
      this.frame = index;
      const p = this.paused;
      if (!p) return;
      $("#node-reason").textContent = "Paused" + (p.reason && p.reason !== "other" ? " on " + p.reason : "") + (p.data && p.data.description ? ": " + p.data.description.split("\n")[0] : "");
      const stack = $("#node-stack");
      stack.textContent = "";
      p.callFrames.forEach((f, i) => {
        const script = this.scripts.get(f.location.scriptId);
        const row = h("div", { class: "node-frame" + (i === index ? " selected" : "") },
          h("span", {}, f.functionName || "(anonymous)"), h("span", { class: "muted mono" }, ` ${(script ? script.url : f.url || "").split("/").pop()}:${f.location.lineNumber + 1}`));
        row.addEventListener("click", () => this.showFrame(i));
        stack.appendChild(row);
      });
      const frame = p.callFrames[index];
      await this.openScript(frame.location.scriptId, frame.location.lineNumber);
      const scopeBox = $("#node-scope");
      scopeBox.textContent = "";
      for (const scope of frame.scopeChain.filter((s) => s.type !== "global").slice(0, 3)) {
        try {
          const { result } = await this.cdp.send("Runtime.getProperties", { objectId: scope.object.objectId, ownProperties: true, generatePreview: true });
          const values = {};
          for (const prop of result.slice(0, 200)) values[prop.name] = prop.value ? describe(prop.value) : "(getter)";
          scopeBox.append(h("div", { class: "react-section-title" }, scope.type), SBExt.tree(values, 1));
        } catch (_) {}
      }
    },

    updateControls() {
      const connected = !!this.cdp;
      $("#node-connected").hidden = !connected;
      $("#node-pause").textContent = this.paused ? "▶ Resume" : "⏸ Pause";
      for (const id of ["#node-over", "#node-into", "#node-out"]) $(id).disabled = !this.paused;
      $("#node-pause").disabled = !connected;
      $("#node-disconnect").disabled = !connected;
      $("#node-reason").textContent = this.paused ? $("#node-reason").textContent : (connected ? "Running" : "");
      $("#node-status").textContent = connected ? `Connected to ${this.target.title || this.target.url}` : $("#node-status").textContent;
    },
  };

  DevTools.register("node", panel);
  window.SBNode = panel;
})();
