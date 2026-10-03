// Keel DevTools — the breakpoints that are not on a line: XHR/fetch
// (by URL), DOM (on a node) and event listener breakpoints. They live in the
// Sources sidebar, as in Chrome, and are backed by the inspector protocol's
// DOMDebugger domain. Extends SBDebugger (debugger.js).
"use strict";

(function () {
  const EVENT_CATEGORIES = [
    ["Animation", [["animation-frame", "Animation frame fired"]]],
    ["Clipboard", ["copy", "cut", "paste"]],
    ["Control", ["resize", "scroll", "scrollend", "focus", "blur", "focusin", "focusout", "change", "select", "submit", "reset"]],
    ["Drag / drop", ["dragstart", "drag", "dragenter", "dragover", "dragleave", "drop", "dragend"]],
    ["Keyboard", ["keydown", "keyup", "keypress", "input", "beforeinput"]],
    ["Load", ["load", "DOMContentLoaded", "beforeunload", "unload", "pagehide", "pageshow", "error", "hashchange", "popstate"]],
    ["Mouse", ["click", "dblclick", "auxclick", "mousedown", "mouseup", "mouseover", "mouseout", "mouseenter", "mouseleave", "mousemove", "contextmenu", "wheel"]],
    ["Pointer", ["pointerdown", "pointerup", "pointermove", "pointerover", "pointerout", "pointerenter", "pointerleave", "pointercancel"]],
    ["Timer", [["timeout", "setTimeout fired"], ["interval", "setInterval fired"]]],
    ["Touch", ["touchstart", "touchmove", "touchend", "touchcancel"]],
    ["XHR", ["readystatechange", "progress", "loadend", "abort", "timeout"].map((n) => ["listener:" + n, n])],
  ].map(([title, events]) => [title, events.map((e) => Array.isArray(e) ? { key: e[0], label: e[1] } : { key: "listener:" + e, label: e })]);

  const DOM_TYPES = { "subtree-modified": "Subtree modified", "attribute-modified": "Attribute modified", "node-removed": "Node removed" };
  const DOM_PAUSED = { "subtree-modified": "Paused on subtree modification", "attribute-modified": "Paused on attribute modification", "node-removed": "Paused on node removal" };

  // "listener:click" → { breakpointType: "listener", eventName: "click" }; "timeout" → { breakpointType: "timeout" }
  const eventParams = (key) => key.startsWith("listener:") ? { breakpointType: "listener", eventName: key.slice(9) } : { breakpointType: key };

  Object.assign(SBDebugger, {
    urlBreakpoints: [],       // { url, enabled }   url "" means any request
    domBreakpoints: [],       // { nodeId (ours), protocolNodeId, type, label, enabled }
    eventBreakpoints: new Set(),

    async initExtras() {
      const [urls, events] = await Promise.all([
        DevTools.rpc("Settings.get", { key: "urlBreakpoints" }).catch(() => null),
        DevTools.rpc("Settings.get", { key: "eventBreakpoints" }).catch(() => null),
      ]);
      try { this.urlBreakpoints = JSON.parse(urls || "[]"); } catch (_) { this.urlBreakpoints = []; }
      try { this.eventBreakpoints = new Set(JSON.parse(events || "[]")); } catch (_) { this.eventBreakpoints = new Set(); }
      $("#dbg-xhr-add").addEventListener("click", (e) => { e.stopPropagation(); this.addURLBreakpoint(); });
      // Node ids do not survive a new document, and neither do WebKit's DOM breakpoints.
      DevTools.on("DOM.documentUpdated", () => { this.domBreakpoints = []; this.renderDOMBreakpoints(); });
      this.renderURLBreakpoints(); this.renderDOMBreakpoints(); this.renderEventBreakpoints();
      if (this.available) this.applyExtraBreakpoints();
    },

    // Called whenever the protocol (re)attaches: WebKit forgets these with the connection.
    async applyExtraBreakpoints() {
      for (const bp of this.urlBreakpoints) if (bp.enabled) await this.send("DOMDebugger.setURLBreakpoint", { url: bp.url, isRegex: false }).catch(() => {});
      for (const key of this.eventBreakpoints) await this.send("DOMDebugger.setEventBreakpoint", eventParams(key)).catch(() => {});
    },

    // ---- XHR/fetch ---------------------------------------------------------------------
    saveURLBreakpoints() { DevTools.rpc("Settings.set", { key: "urlBreakpoints", value: JSON.stringify(this.urlBreakpoints) }).catch(() => {}); },

    addURLBreakpoint() {
      $("#dbg-section-xhr").classList.remove("collapsed");
      const list = $("#dbg-xhr");
      if (list.querySelector(".dbg-inline-input")) return;
      const input = h("input", { class: "dbg-inline-input", type: "text", placeholder: "Break when URL contains (empty: any request)" });
      let done = false;
      const finish = (commit) => {
        if (done) return; done = true;
        const url = input.value.trim();
        input.remove();
        if (commit) this.setURLBreakpoint(url, true); else this.renderURLBreakpoints();
      };
      input.addEventListener("keydown", (e) => { if (e.key === "Enter") finish(true); else if (e.key === "Escape") finish(false); e.stopPropagation(); });
      input.addEventListener("blur", () => finish(input.value.trim() !== ""));
      list.querySelector(".dbg-empty")?.remove();
      list.prepend(input);
      input.focus();
    },

    async setURLBreakpoint(url, enabled) {
      let bp = this.urlBreakpoints.find((b) => b.url === url);
      if (!bp) { bp = { url, enabled }; this.urlBreakpoints.push(bp); }
      bp.enabled = enabled;
      this.saveURLBreakpoints(); this.renderURLBreakpoints();
      if (!this.available) return;
      try { await this.send(enabled ? "DOMDebugger.setURLBreakpoint" : "DOMDebugger.removeURLBreakpoint", { url, isRegex: false }); }
      catch (e) { if (enabled) this.report(e); }
    },

    async removeURLBreakpoint(url) {
      const bp = this.urlBreakpoints.find((b) => b.url === url);
      this.urlBreakpoints = this.urlBreakpoints.filter((b) => b !== bp);
      this.saveURLBreakpoints(); this.renderURLBreakpoints();
      if (bp && bp.enabled && this.available) await this.send("DOMDebugger.removeURLBreakpoint", { url, isRegex: false }).catch(() => {});
    },

    renderURLBreakpoints() {
      const list = $("#dbg-xhr");
      list.textContent = "";
      if (!this.urlBreakpoints.length) { list.appendChild(h("div", { class: "dbg-empty" }, "No breakpoints")); return; }
      for (const bp of this.urlBreakpoints) {
        const box = h("input", { type: "checkbox" });
        box.checked = bp.enabled;
        box.addEventListener("change", () => this.setURLBreakpoint(bp.url, box.checked));
        list.appendChild(h("div", { class: "dbg-bp", "data-url": bp.url },
          box,
          h("div", { class: "bp-text", title: bp.url || "Any XHR or fetch" }, bp.url ? `URL contains "${bp.url}"` : "Any XHR or fetch"),
          h("span", { class: "remove", title: "Remove breakpoint", onclick: () => this.removeURLBreakpoint(bp.url) }, "✕")));
      }
    },

    // ---- DOM ---------------------------------------------------------------------------
    hasDOMBreakpoint(nodeId, type) { return this.domBreakpoints.some((b) => b.nodeId === nodeId && b.type === type); },

    async toggleDOMBreakpoint(nodeId, type, label) {
      const existing = this.domBreakpoints.find((b) => b.nodeId === nodeId && b.type === type);
      if (existing) return this.removeDOMBreakpoint(existing);
      try {
        const { nodeId: protocolNodeId } = await DevTools.rpc("DOMDebugger.setDOMBreakpoint", { nodeId, type });
        this.domBreakpoints.push({ nodeId, protocolNodeId, type, label, enabled: true });
        $("#dbg-section-dom").classList.remove("collapsed");
      } catch (e) { this.report(e); }
      this.renderDOMBreakpoints();
    },

    async setDOMBreakpointEnabled(bp, enabled) {
      bp.enabled = enabled;
      try { await DevTools.rpc(enabled ? "DOMDebugger.setDOMBreakpoint" : "DOMDebugger.removeDOMBreakpoint", { nodeId: bp.nodeId, type: bp.type }); }
      catch (e) { if (enabled) this.report(e); }
      this.renderDOMBreakpoints();
    },

    async removeDOMBreakpoint(bp) {
      this.domBreakpoints = this.domBreakpoints.filter((b) => b !== bp);
      this.renderDOMBreakpoints();
      if (bp.enabled) await DevTools.rpc("DOMDebugger.removeDOMBreakpoint", { nodeId: bp.nodeId, type: bp.type }).catch(() => {});
    },

    renderDOMBreakpoints() {
      const list = $("#dbg-dom");
      list.textContent = "";
      if (!this.domBreakpoints.length) { list.appendChild(h("div", { class: "dbg-empty" }, "No breakpoints. Right-click a node in Elements → Break on…")); return; }
      for (const bp of this.domBreakpoints) {
        const box = h("input", { type: "checkbox" });
        box.checked = bp.enabled;
        box.addEventListener("change", () => this.setDOMBreakpointEnabled(bp, box.checked));
        list.appendChild(h("div", { class: "dbg-bp", "data-node": String(bp.protocolNodeId), "data-type": bp.type },
          box,
          h("div", { style: "min-width:0;flex:1" },
            h("div", { class: "bp-text link", title: "Reveal in Elements", onclick: () => { DevTools.showPanel("elements"); DevTools.panels.elements.revealNode(bp.nodeId); } }, bp.label),
            h("div", { class: "snippet bp-kind" }, DOM_TYPES[bp.type])),
          h("span", { class: "remove", title: "Remove breakpoint", onclick: () => this.removeDOMBreakpoint(bp) }, "✕")));
      }
    },

    // ---- event listeners -----------------------------------------------------------------
    async setEventBreakpoint(key, enabled) {
      if (enabled) this.eventBreakpoints.add(key); else this.eventBreakpoints.delete(key);
      DevTools.rpc("Settings.set", { key: "eventBreakpoints", value: JSON.stringify(Array.from(this.eventBreakpoints)) }).catch(() => {});
      if (!this.available) return;
      try { await this.send(enabled ? "DOMDebugger.setEventBreakpoint" : "DOMDebugger.removeEventBreakpoint", eventParams(key)); }
      catch (e) { if (enabled) this.report(e); }
    },

    renderEventBreakpoints() {
      const list = $("#dbg-events");
      list.textContent = "";
      for (const [title, events] of EVENT_CATEGORIES) {
        const all = h("input", { type: "checkbox" });
        const boxes = [];
        const sync = () => {
          const on = events.filter((e) => this.eventBreakpoints.has(e.key)).length;
          all.checked = on === events.length; all.indeterminate = on > 0 && on < events.length;
        };
        const body = h("div", { class: "cat-body" });
        for (const event of events) {
          const box = h("input", { type: "checkbox", "data-event": event.key });
          box.checked = this.eventBreakpoints.has(event.key);
          box.addEventListener("change", () => { this.setEventBreakpoint(event.key, box.checked); sync(); });
          boxes.push(box);
          body.appendChild(h("label", {}, box, event.label));
        }
        all.addEventListener("click", (e) => e.stopPropagation());
        all.addEventListener("change", () => {
          for (const [i, event] of events.entries()) if (boxes[i].checked !== all.checked) { boxes[i].checked = all.checked; this.setEventBreakpoint(event.key, all.checked); }
          sync();
        });
        const cat = h("div", { class: "event-cat" }, h("div", { class: "cat-head" }, all, title), body);
        cat.querySelector(".cat-head").addEventListener("click", () => cat.classList.toggle("open"));
        if (events.some((e) => this.eventBreakpoints.has(e.key))) cat.classList.add("open");
        sync();
        list.appendChild(cat);
      }
    },

    // ---- pauses ---------------------------------------------------------------------------
    // What to say in the banner for a pause caused by one of these, and which row to light up.
    describePause(params) {
      const data = params.data || {};
      this.clearHit();
      const hit = (selector) => { const row = document.querySelector(selector); if (row) { row.classList.add("hit"); row.closest(".dbg-section")?.classList.remove("collapsed"); } };
      switch (params.reason) {
        case "DOM": {
          const bp = this.domBreakpoints.find((b) => b.protocolNodeId === data.nodeId && b.type === data.type) || this.domBreakpoints.find((b) => b.type === data.type);
          if (bp) hit(`#dbg-dom .dbg-bp[data-node="${bp.protocolNodeId}"][data-type="${bp.type}"]`);
          return { title: DOM_PAUSED[data.type] || "Paused on DOM breakpoint", detail: bp ? bp.label : "" };
        }
        case "URL": case "XHR": case "Fetch":
          hit(`#dbg-xhr .dbg-bp[data-url="${CSS.escape(data.breakpointURL || "")}"]`);
          return { title: "Paused on XHR or fetch", detail: data.url || "" };
        case "Listener": case "EventListener":
          return { title: "Paused on event listener", detail: data.eventName || "" };
        case "Timer": case "Timeout": return { title: "Paused on setTimeout", detail: "" };
        case "Interval": return { title: "Paused on setInterval", detail: "" };
        case "AnimationFrame": return { title: "Paused on animation frame", detail: "" };
        default: return null;
      }
    },

    clearHit() { for (const row of $$("#debugger-sections .dbg-bp.hit")) row.classList.remove("hit"); },
  });

  // Start with the debugger itself (DevTools.start), once the bridge is ready.
  const init = SBDebugger.init;
  SBDebugger.init = function () { init.call(this); this.initExtras(); };
})();
