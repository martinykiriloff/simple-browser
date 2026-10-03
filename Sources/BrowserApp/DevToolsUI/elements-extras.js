// Keel DevTools — the parts of the Elements panel that need the
// inspector protocol: the Event Listeners tab, forced element state (:hov)
// and "Break on…" DOM breakpoints. Extends the Elements panel (elements.js).
"use strict";

(function () {
  const panel = DevTools.panels.elements;
  const PSEUDO = ["active", "hover", "focus", "focus-visible", "focus-within", "target", "visited"];
  const DOM_BREAK = [["subtree-modified", "Break on subtree modifications"], ["attribute-modified", "Break on attribute modifications"], ["node-removed", "Break on node removal"]];

  // "<button id="action" class="act">" → "button#action.act"
  function shortLabel(data) {
    if (!data) return "node";
    const attrs = data.attributes || [];
    const attr = (name) => { const i = attrs.indexOf(name); return i >= 0 && i % 2 === 0 ? attrs[i + 1] : ""; };
    const id = attr("id"), cls = attr("class").trim().split(/\s+/).filter(Boolean).join(".");
    return (data.nodeName || "node").toLowerCase() + (id ? "#" + id : "") + (cls ? "." + cls : "");
  }
  // WebKit describes a node as its opening tag.
  function labelFromDescription(description) {
    const m = /^<([^\s>]+)([^>]*)>?/.exec(description || "");
    if (!m) return description || "node";
    const id = /\bid="([^"]*)"/.exec(m[2]), cls = /\bclass="([^"]*)"/.exec(m[2]);
    return m[1] + (id && id[1] ? "#" + id[1] : "") + (cls && cls[1].trim() ? "." + cls[1].trim().split(/\s+/).join(".") : "");
  }

  Object.assign(panel, {
    forced: new Map(),          // our node id → Set of forced pseudo-classes
    listenerGeneration: 0,
    collapsedListenerTypes: new Set(),

    // ---- forced state (:hov) -------------------------------------------------------------
    initExtras() {
      const grid = $("#styles-hov-grid");
      for (const name of PSEUDO) {
        const box = h("input", { type: "checkbox", "data-pseudo": name });
        box.addEventListener("change", () => this.forceState(name, box.checked));
        grid.appendChild(h("label", { class: "check" }, box, ":" + name));
      }
      $("#styles-hov").addEventListener("click", () => {
        const pane = $("#styles-hov-pane");
        pane.hidden = !pane.hidden;
        this.syncForcedState();
      });
      $("#listeners-ancestors").addEventListener("change", () => this.refreshSidebar());
      $("#listeners-refresh").addEventListener("click", () => this.refreshSidebar());
      // Forced state belongs to a document's nodes; a new document starts clean.
      DevTools.on("DOM.documentUpdated", () => { this.forced.clear(); this.syncForcedState(); });
    },

    syncForcedState() {
      const forced = this.forced.get(this.selectedId) || new Set();
      for (const box of $$("#styles-hov-grid input")) box.checked = forced.has(box.dataset.pseudo);
      $("#styles-hov").classList.toggle("on", forced.size > 0 || !$("#styles-hov-pane").hidden);
    },

    async forceState(name, on) {
      const id = this.selectedId;
      if (id == null) return;
      const forced = this.forced.get(id) || new Set();
      if (on) forced.add(name); else forced.delete(name);
      if (forced.size) this.forced.set(id, forced); else this.forced.delete(id);
      try {
        await DevTools.rpc("CSS.forcePseudoState", { nodeId: id, classes: Array.from(forced) });
      } catch (e) {
        if (on) forced.delete(name);
        DevTools.panels.console?.addLocal("error", "Could not force :" + name + " — " + e.message);
      }
      this.syncForcedState();
      if (id === this.selectedId) this.refreshSidebar();
    },

    // ---- DOM breakpoints ---------------------------------------------------------------------
    breakOnItems(id) {
      const label = shortLabel(this.nodes.get(id));
      return DOM_BREAK.map(([type, title]) => ({
        label: (SBDebugger.hasDOMBreakpoint(id, type) ? "✓ " : "") + title,
        action: () => SBDebugger.toggleDOMBreakpoint(id, type, label),
      }));
    },

    // ---- Event Listeners ---------------------------------------------------------------------
    async loadListeners(id) {
      const list = $("#listeners-list");
      const generation = ++this.listenerGeneration;
      let result;
      try { result = await DevTools.rpc("DOM.getEventListeners", { nodeId: id }); }
      catch (e) {
        if (generation !== this.listenerGeneration) return;
        list.textContent = "";
        list.appendChild(h("div", { class: "styles-note" }, "Event listeners need the debugger connection: " + e.message));
        return;
      }
      if (generation !== this.listenerGeneration) return;

      const ownNode = result.nodeId;
      const ancestors = $("#listeners-ancestors").checked;
      const listeners = (result.listeners || []).filter((l) => {
        // Our own agents listen on the window; they are not the page's listeners.
        const script = l.location && SBDebugger.scripts.get(String(l.location.scriptId));
        if (script && script.url.startsWith("user-script:")) return false;
        if (/^__sb/.test(l.type)) return false;
        return ancestors || (l.nodeId === ownNode && !l.onWindow);
      });

      // Name each listener's target once.
      const targets = new Map();
      for (const l of listeners) {
        if (l.onWindow || l.nodeId == null || targets.has(l.nodeId)) continue;
        targets.set(l.nodeId, "");
        try {
          const resolved = await SBDebugger.send("DOM.resolveNode", { nodeId: l.nodeId, objectGroup: "sb-listeners" });
          targets.set(l.nodeId, resolved.object.description === "#document" ? "document" : labelFromDescription(resolved.object.description));
        } catch (_) {}
      }
      SBDebugger.send("Runtime.releaseObjectGroup", { objectGroup: "sb-listeners" }).catch(() => {});
      if (generation !== this.listenerGeneration) return;

      list.textContent = "";
      if (!listeners.length) { list.appendChild(h("div", { class: "styles-note" }, ancestors ? "No event listeners" : "No event listeners on this node. Tick Ancestors to include its ancestors, the document and the window.")); return; }
      const byType = new Map();
      for (const l of listeners) { if (!byType.has(l.type)) byType.set(l.type, []); byType.get(l.type).push(l); }
      for (const type of Array.from(byType.keys()).sort()) {
        const group = h("div", { class: "listener-group" + (this.collapsedListenerTypes.has(type) ? " collapsed" : ""), "data-type": type });
        const head = h("div", { class: "listener-type" }, type, h("span", { class: "count" }, String(byType.get(type).length)));
        head.addEventListener("click", () => {
          group.classList.toggle("collapsed");
          if (group.classList.contains("collapsed")) this.collapsedListenerTypes.add(type); else this.collapsedListenerTypes.delete(type);
        });
        group.appendChild(head);
        for (const l of byType.get(type)) group.appendChild(this.renderListener(l, targets));
        list.appendChild(group);
      }
    },

    renderListener(l, targets) {
      const box = h("input", { type: "checkbox", title: "Enable or disable this listener" });
      box.checked = !l.disabled;
      const row = h("div", { class: "listener-row" + (l.disabled ? " off" : ""), "data-listener": String(l.eventListenerId) });
      box.addEventListener("change", async () => {
        try { await SBDebugger.send("DOM.setEventListenerDisabled", { eventListenerId: l.eventListenerId, disabled: !box.checked }); row.classList.toggle("off", !box.checked); }
        catch (e) { box.checked = !box.checked; DevTools.panels.console?.addLocal("error", "Could not change the listener — " + e.message); }
      });
      const flags = [l.isAttribute ? "attribute" : null, l.useCapture ? "capture" : null, l.passive ? "passive" : null, l.once ? "once" : null].filter(Boolean);
      row.append(box, h("div", { style: "min-width:0;flex:1" },
        h("div", { class: "target" }, l.onWindow ? "window" : (targets.get(l.nodeId) || "node")),
        h("div", {}, h("span", { class: "handler" }, l.handlerName ? l.handlerName + "()" : "(anonymous)"), flags.length ? h("span", { class: "flags" }, "  " + flags.join(", ")) : null)));
      const script = l.location && SBDebugger.scripts.get(String(l.location.scriptId));
      if (script && script.url) {
        let where = { url: script.url, line: l.location.lineNumber + 1, column: l.location.columnNumber || 0 };
        const original = SBSourceMaps.original(where.url, where.line, where.column);
        if (original) where = original;
        row.appendChild(h("span", { class: "location", title: where.url + ":" + where.line, onclick: () => DevTools.openSource(where.url, where.line, where.column) }, fileName(where.url) + ":" + where.line));
      }
      return row;
    },
  });

  panel.initExtras();
})();
