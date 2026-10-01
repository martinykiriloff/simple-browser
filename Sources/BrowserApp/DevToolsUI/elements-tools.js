// SimpleBrowser DevTools — the Elements panel's editing tools: undo/redo
// (⌘Z / ⇧⌘Z) of every edit, drag and drop in the tree, badges (grid, flex,
// scroll, event, slot) with the grid and flex overlays, search
// highlighting, the Copy menu (selector, JS path, XPath, styles, element
// for AI), Store as global variable. Extends the Elements panel.
"use strict";

(function () {
  const panel = DevTools.panels.elements;
  const BADGE_TITLES = {
    grid: "Grid container: click to show the grid overlay in the page",
    flex: "Flex container: click to show the flex overlay in the page",
    scroll: "Scroll container",
    event: "Has event listeners: click to see them",
    slot: "Slotted into a <slot>: click to reveal the slot",
  };
  const NOT_DRAGGABLE = new Set(["html", "head", "body"]);

  const baseFillNode = panel.fillNode;
  const baseStepSearch = panel.stepSearch;
  const baseRunSearch = panel.runSearch;
  const baseCloseSearch = panel.closeSearch;

  Object.assign(panel, {
    undoStack: [],
    redoStack: [],

    // ---- undo -----------------------------------------------------------------------------
    // Every edit goes through here: the inverse is captured before the edit
    // runs, so ⌘Z restores attributes, text, HTML, removed or moved nodes and
    // style changes exactly, keeping the same nodes (and their listeners).
    async mutate(method, params) {
      const rpc = (m, p) => DevTools.rpc(m, p);
      const node = params.nodeId;
      switch (method) {
        case "DOM.setAttributeValue": case "DOM.removeAttribute": case "DOM.setAttributesAsText": case "DOM.setAttributes": {
          const before = (await rpc("DOM.describeNode", { nodeId: node, depth: 0 })).attributes || [];
          const result = await rpc(method, params);
          const after = (await rpc("DOM.describeNode", { nodeId: node, depth: 0 })).attributes || [];
          const last = this.undoStack[this.undoStack.length - 1];
          // A rename is a remove then a set: one step, as typed.
          if (last && last.kind === "attributes" && last.nodeId === node && Date.now() - last.at < 400) { last.after = after; last.at = Date.now(); return result; }
          const record = { kind: "attributes", label: "Edit attributes", nodeId: node, before, after, at: Date.now(),
            undo: () => rpc("DOM.setAttributes", { nodeId: node, attributes: record.before }),
            redo: () => rpc("DOM.setAttributes", { nodeId: node, attributes: record.after }),
            refresh: () => this.refreshNode(node) };
          this.record(record);
          return result;
        }
        case "DOM.setNodeValue": {
          const before = (await rpc("DOM.describeNode", { nodeId: node, depth: 0 })).nodeValue;
          const result = await rpc(method, params);
          const parent = this.textParents.get(node);
          this.record({ label: "Edit text", undo: () => rpc(method, { nodeId: node, value: before }), redo: () => rpc(method, params),
                        refresh: () => this.refreshNode(parent != null ? parent : node) });
          return result;
        }
        case "DOM.removeNode": {
          const where = await rpc("DOM.position", { nodeId: node });
          const result = await rpc(method, params);
          this.record({ label: "Delete node", undo: () => rpc("DOM.moveTo", { nodeId: node, parentId: where.parentId, beforeId: where.beforeId }),
                        redo: () => rpc(method, params), refresh: async () => { await this.refreshNode(where.parentId, true); this.reveal(node); } });
          return result;
        }
        case "DOM.replaceWithHTML": {
          const result = await rpc(method, params);
          let ids = result.newIds;
          this.record({ label: "Edit as HTML", undo: () => rpc("DOM.restoreReplaced", { nodeId: node, newIds: ids }),
                        redo: async () => { ids = (await rpc(method, params)).newIds; },
                        refresh: () => this.refreshNode(result.parentId, true) });
          return result;
        }
        case "DOM.moveTo": {
          const from = await rpc(method, params);
          this.record({ label: "Move node", undo: () => rpc(method, { nodeId: node, parentId: from.parentId, beforeId: from.beforeId }),
                        redo: () => rpc(method, params),
                        refresh: async () => { await this.refreshNode(from.parentId, true); await this.refreshNode(params.parentId, true); this.reveal(node); } });
          return from;
        }
        case "DOM.toggleHidden": {
          const result = await rpc(method, params);
          this.record({ label: "Hide element", undo: () => rpc(method, params), redo: () => rpc(method, params), refresh: () => this.refreshNode(node) });
          return result;
        }
        case "CSS.updateStyle": case "CSS.setStyleText": {
          const target = params.styleId ? { styleId: params.styleId } : { nodeId: params.nodeId };
          const before = await rpc("CSS.updateStyle", Object.assign({ edits: [] }, target));
          const result = await rpc(method, params);
          const key = JSON.stringify(target);
          const last = this.undoStack[this.undoStack.length - 1];
          // Dragging in the colour picker or nudging a number is one step.
          if (last && last.kind === "style" && last.key === key && Date.now() - last.at < 700) { last.after = result.cssText; last.at = Date.now(); return result; }
          const record = { kind: "style", key, label: "Edit style", before: before.cssText, after: result.cssText, at: Date.now(),
            undo: () => rpc("CSS.setStyleText", Object.assign({ text: record.before }, target)),
            redo: () => rpc("CSS.setStyleText", Object.assign({ text: record.after }, target)),
            refresh: () => { this.disabled.clear(); this.refreshSidebar(); } };
          this.record(record);
          return result;
        }
        default:
          return rpc(method, params);
      }
    },

    record(entry) {
      this.undoStack.push(entry);
      if (this.undoStack.length > 200) this.undoStack.shift();
      this.redoStack = [];
    },

    async undo() { return this.replay(this.undoStack, this.redoStack, "undo", "Undo"); },
    async redo() { return this.replay(this.redoStack, this.undoStack, "redo", "Redo"); },

    async replay(from, to, action, verb) {
      const entry = from.pop();
      if (!entry) return false;
      try { await entry[action](); }
      catch (e) { this.notify(verb + " failed: " + e.message); return false; }
      entry.at = 0;           // never merged into after an undo
      to.push(entry);
      try { await entry.refresh(); } catch (_) {}
      if (window.Toast) Toast.show(verb + ": " + entry.label);
      return true;
    },

    async reveal(id) { if (id != null) { try { await this.revealNode(id); } catch (_) {} } },

    // ---- badges -------------------------------------------------------------------------------
    fillNode(li, data) {
      baseFillNode.call(this, li, data);
      const line = li.querySelector(":scope > .node-line");
      if (!line) return;
      line.draggable = data.nodeType === 1 && !NOT_DRAGGABLE.has(data.nodeName) && !data.isShadow;
      const markup = line.querySelector(".markup");
      if (data.nodeType === 11 && markup && !markup.querySelector(".dom-badge")) {
        markup.appendChild(h("span", { class: "dom-badge shadow" }, data.shadowRootMode || "shadow"));
      }
      for (const badge of data.badges || []) {
        const on = (badge === "grid" || badge === "flex") && data.overlay === badge;
        const el = h("span", { class: "dom-badge " + badge + (on ? " on" : ""), title: BADGE_TITLES[badge] || badge, role: "button", "data-badge": badge }, badge);
        el.addEventListener("click", (e) => { e.stopPropagation(); this.onBadge(data.nodeId, badge, el); });
        el.addEventListener("dblclick", (e) => e.stopPropagation());
        line.appendChild(el);
      }
    },

    async onBadge(id, badge, el) {
      const data = this.nodes.get(id);
      if (badge === "grid" || badge === "flex") {
        const enabled = !el.classList.contains("on");
        try {
          const r = await DevTools.rpc("Overlay.setLayoutOverlay", { nodeId: id, kind: badge, enabled });
          el.classList.toggle("on", r.enabled);
          if (data) data.overlay = r.enabled ? badge : null;
        } catch (e) { this.notify(e.message); }
      } else if (badge === "event") {
        this.select(id);
        $('#styles-tabs [data-subpanel="listeners"]').click();
      } else if (badge === "slot" && data && data.assignedSlotId) {
        this.revealNode(data.assignedSlotId);
      } else {
        this.select(id);
      }
    },

    // ---- drag and drop -----------------------------------------------------------------------
    initDragDrop() {
      const tree = $("#dom-tree");
      let dragId = null, marked = null;
      const clear = () => { if (marked) marked.classList.remove("drop-before", "drop-after", "drop-inside"); marked = null; };
      const zone = (line, e) => {
        const r = line.getBoundingClientRect();
        const data = this.nodes.get(+line.parentElement.dataset.nodeId);
        const y = (e.clientY - r.top) / r.height;
        const canHold = data && data.nodeType === 1 && !["br", "img", "input", "hr", "meta", "link"].includes(data.nodeName);
        if (canHold && y > 0.3 && y < 0.7) return "inside";
        return y < 0.5 ? "before" : "after";
      };
      tree.addEventListener("dragstart", (e) => {
        const line = e.target.closest && e.target.closest(".node-line");
        if (!line || !line.draggable) { e.preventDefault(); return; }
        dragId = +line.parentElement.dataset.nodeId;
        e.dataTransfer.effectAllowed = "move";
        e.dataTransfer.setData("text/plain", this.shortName(this.nodes.get(dragId)));
        line.classList.add("dragging");
      });
      tree.addEventListener("dragover", (e) => {
        if (dragId == null) return;
        const line = e.target.closest(".node-line");
        if (!line) { clear(); return; }
        const li = line.parentElement;
        if (li.closest(`li.node[data-node-id="${dragId}"]`)) { clear(); return; }        // onto itself or inside itself
        e.preventDefault();
        e.dataTransfer.dropEffect = "move";
        const where = zone(line, e);
        if (marked !== line) clear();
        marked = line;
        line.classList.remove("drop-before", "drop-after", "drop-inside");
        line.classList.add("drop-" + where);
      });
      tree.addEventListener("dragleave", (e) => { if (!tree.contains(e.relatedTarget)) clear(); });
      tree.addEventListener("drop", (e) => {
        const line = e.target.closest(".node-line");
        if (dragId == null || !line) return;
        e.preventDefault();
        const where = zone(line, e);
        const targetId = +line.parentElement.dataset.nodeId;
        clear();
        this.moveNode(dragId, targetId, where);
      });
      tree.addEventListener("dragend", () => { clear(); for (const l of $$(".node-line.dragging", tree)) l.classList.remove("dragging"); dragId = null; });
    },

    // Moves `id` before or after `targetId`, or to the end of it ("inside").
    async moveNode(id, targetId, where) {
      const targetLi = this.elements.get(targetId);
      if (!targetLi || id === targetId) return false;
      let parentId, beforeId = null;
      if (where === "inside") parentId = targetId;
      else {
        const parentLi = targetLi.parentElement.closest("li.node");
        if (!parentLi) return false;
        parentId = +parentLi.dataset.nodeId;
        if (where === "before") beforeId = targetId;
        else { const next = targetLi.nextElementSibling; beforeId = next && next.matches("li.node") ? +next.dataset.nodeId : null; }
      }
      try {
        const from = await this.mutate("DOM.moveTo", { nodeId: id, parentId, beforeId });
        await this.refreshNode(from.parentId, true);
        if (from.parentId !== parentId) await this.refreshNode(parentId, true);
        if (where === "inside") await this.expand(parentId);
        await this.reveal(id);
        return true;
      } catch (e) { this.notify("Could not move the node: " + e.message); return false; }
    },

    // ---- search highlighting ------------------------------------------------------------------
    async stepSearch(dir) {
      await baseStepSearch.call(this, dir);
      this.markSearch();
    },
    async runSearch() {
      this.clearSearchMarks();
      await baseRunSearch.call(this);
    },
    closeSearch() {
      this.clearSearchMarks();
      baseCloseSearch.call(this);
    },
    markSearch() {
      this.clearSearchMarks();
      const query = $("#elements-search").value.trim();
      if (!query || /^[/(]/.test(query)) return;
      const lower = query.toLowerCase();
      for (const id of this.searchHits.slice(0, 300)) {
        const li = this.elements.get(id);
        const line = li && li.querySelector(":scope > .node-line .markup");
        if (!line) continue;
        const walker = document.createTreeWalker(line, NodeFilter.SHOW_TEXT);
        const texts = [];
        let n;
        while ((n = walker.nextNode())) texts.push(n);
        for (const text of texts) {
          const value = text.nodeValue, at = value.toLowerCase().indexOf(lower);
          if (at < 0) continue;
          const range = document.createRange();
          range.setStart(text, at); range.setEnd(text, at + query.length);
          const mark = h("mark", { class: "dom-search-mark" + (id === this.searchHits[this.searchIndex] ? " current" : "") });
          range.surroundContents(mark);
        }
      }
    },
    clearSearchMarks() {
      for (const mark of $$("mark.dom-search-mark", this.tree)) {
        const parent = mark.parentNode;
        mark.replaceWith(document.createTextNode(mark.textContent));
        parent.normalize();
      }
    },

    // ---- copy ------------------------------------------------------------------------------------
    copyItems(id) {
      const copy = (fn) => async () => {
        try { await DevTools.rpc("Clipboard.write", { text: await fn() }); }
        catch (e) { this.notify(e.message); }
      };
      return [
        { label: "Copy outerHTML", action: () => this.copyOuterHTML(id) },
        { label: "Copy selector", action: copy(() => DevTools.rpc("DOM.copyPath", { nodeId: id, kind: "selector" })) },
        { label: "Copy JS path", action: copy(() => DevTools.rpc("DOM.copyPath", { nodeId: id, kind: "jsPath" })) },
        { label: "Copy XPath", action: copy(() => DevTools.rpc("DOM.copyPath", { nodeId: id, kind: "xpath" })) },
        { label: "Copy full XPath", action: copy(() => DevTools.rpc("DOM.copyPath", { nodeId: id, kind: "fullXPath" })) },
        { label: "Copy styles", action: copy(() => this.stylesText(id)) },
        { label: "Copy element for AI (Markdown)", action: copy(() => this.elementMarkdown(id)) },
      ];
    },

    // The declarations that win for the node, as CSS text (Chrome's "Copy styles").
    async stylesText(id) {
      const styles = await DevTools.rpc("CSS.getMatchedStyles", { nodeId: id });
      const sections = this.cascadeOrder(styles, id).filter((s) => !s.pseudo);
      const winners = this.computeWinners(sections);
      const out = [];
      sections.forEach((section, si) => section.declarations.forEach((d, di) => {
        if (winners.get(d.name) === si + ":" + di) out.push(d.name + ": " + d.value + (d.important ? " !important" : "") + ";");
      }));
      return out.join("\n");
    },

    // Everything an assistant needs to talk about an element without seeing
    // the page: what it is, how it is exposed to assistive technology, its
    // attributes, size and the rules that style it.
    async elementMarkdown(id) {
      const rpc = (m, p) => DevTools.rpc(m, p).catch(() => null);
      const [data, selector, box, computed, styles, ax, html] = await Promise.all([
        rpc("DOM.describeNode", { nodeId: id, depth: 0 }), rpc("DOM.copyPath", { nodeId: id, kind: "selector" }),
        rpc("DOM.getBoxModel", { nodeId: id }), rpc("CSS.getComputedStyle", { nodeId: id }),
        rpc("CSS.getMatchedStyles", { nodeId: id }), rpc("Accessibility.getNode", { nodeId: id }), rpc("DOM.getOuterHTML", { nodeId: id })]);
      if (!data) throw new Error("The node is gone");
      const attrs = data.attributes || [];
      const out = [`## Element \`<${data.nodeName}>\``, ""];
      if (selector) out.push(`- **Selector**: \`${selector}\``);
      if (DevTools.info.url) out.push(`- **Page**: ${DevTools.info.url}`);
      if (ax) out.push(`- **Accessibility**: role \`${ax.role || "generic"}\`, name ${ax.name ? JSON.stringify(ax.name) : "(none)"}` + (ax.nameSource ? ` (from ${ax.nameSource})` : ""));
      if (box) out.push(`- **Box**: ${Math.round(box.rect.width)} × ${Math.round(box.rect.height)} px at (${Math.round(box.rect.x)}, ${Math.round(box.rect.y)}), content ${Math.round(box.content.width)} × ${Math.round(box.content.height)}, display \`${box.display}\`, position \`${box.position}\``);
      if (data.badges && data.badges.length) out.push(`- **Flags**: ${data.badges.join(", ")}`);
      if (attrs.length) {
        out.push("", "### Attributes", "");
        for (let i = 0; i < attrs.length; i += 2) out.push(`- \`${attrs[i]}\`` + (attrs[i + 1] !== "" ? ` = ${JSON.stringify(attrs[i + 1].slice(0, 300))}` : ""));
      }
      if (computed) {
        const KEY = ["display", "position", "top", "left", "width", "height", "margin", "padding", "box-sizing", "flex-direction", "justify-content", "align-items",
          "grid-template-columns", "gap", "color", "background-color", "font-family", "font-size", "font-weight", "line-height", "opacity", "visibility", "z-index", "overflow"];
        const map = new Map(computed);
        const shorthand = (name) => ["top", "right", "bottom", "left"].map((s) => map.get(name + "-" + s)).join(" ");
        const rows = KEY.map((k) => [k, map.has(k) ? map.get(k) : (k === "margin" || k === "padding") ? shorthand(k) : null]).filter(([, v]) => v != null && v !== "" && v !== "normal" && v !== "none" && v !== "auto" || false);
        out.push("", "### Key computed styles", "", Markdown.table(["Property", "Value"], rows));
      }
      if (styles) {
        const rules = this.cascadeOrder(styles, id).filter((s) => s.kind === "inline" ? s.declarations.length : true);
        if (rules.length) {
          out.push("", "### Matched rules (most specific first)", "");
          for (const r of rules.slice(0, 15)) {
            const decls = r.declarations.map((d) => `${d.name}: ${d.value}${d.important ? " !important" : ""}`).join("; ");
            out.push(`- \`${r.kind === "inline" ? "element.style" : r.selectorText}\`` + (r.origin ? ` — ${fileName(r.origin)}` : "") + (r.active === false ? " (inactive)" : "") + (decls ? `: ${decls.slice(0, 300)}` : ""));
          }
        }
      }
      if (html) out.push("", "### HTML", "", Markdown.fence(Markdown.truncate(html, 2000), "html"));
      return out.join("\n");
    },

    // Store as global variable: `temp1` in the console, as in Chrome.
    async storeAsGlobal(id) {
      try {
        await DevTools.rpc("DOM.mark", { nodeId: id });
        const { name } = await DevTools.rpc("Runtime.storeMarkedAsGlobal");
        const cons = DevTools.panels.console;
        if (!cons.initialized) { cons.initialized = true; cons.init(); }
        cons.evaluate(name);
        return name;
      } catch (e) { this.notify("Could not store the node: " + e.message); return null; }
    },
  });

  // ⌘Z / ⇧⌘Z while the Elements panel is in front and nothing is being typed.
  document.addEventListener("keydown", (e) => {
    if (DevTools.activePanel !== "elements" || !(e.metaKey || e.ctrlKey) || e.key.toLowerCase() !== "z") return;
    if (e.target.closest && e.target.closest("input, textarea, [contenteditable='true'], [contenteditable='plaintext-only'], .editing")) return;
    e.preventDefault();
    if (e.shiftKey) panel.redo(); else panel.undo();
  });

  panel.initDragDrop();
})();
